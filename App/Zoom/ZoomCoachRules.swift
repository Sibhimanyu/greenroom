//
//  ZoomCoachRules.swift
//  Greenroom
//
//  The coach drawn on top of Zoom's page (spec R6): which control it points
//  at, found later by its visible label, and the one line on its card with a
//  step counter. The card text always comes from here, never from the page.
//  Pure: Foundation only.
//
import Foundation

/// A later stage of a flow that stays on one address (Created apps: + → Build → the
/// "What kind of app" dialog → Create). The page shows the furthest stage it can find.
struct ZoomCoachStage: Equatable, Codable {
    enum Kind: String, Codable {
        /// A menu item with exactly this text (the + menu's "Build app").
        case menuItem
        /// The radio row with this label inside the "What kind of app" dialog.
        case chooseRow
        /// The dialog's Create button, once the row with this label is chosen.
        case createAfter
        /// Done when the switch named `switchLabel` is on: spotlight the nav link `label`.
        case afterSwitchOn
        /// Done when every text in `texts` is visible on the page (outside any open panel): spotlight `label`.
        case afterTextsPresent
        /// Done when the page shows an activated state: spotlight `label`.
        case afterActivated
        /// The name dialog ("Create a ... app", heading starts with `label`): spotlight its name field while empty.
        case nameField
        /// The same dialog once the name field has text (read: non-empty only): spotlight Create.
        case createNamed
    }
    var kind: Kind
    /// What to spotlight (a row, button, menu item or, for the "after" kinds, a nav link).
    var label: String
    var text: String
    /// The counter to show once this stage is the furthest.
    var counter: String? = nil
    var texts: [String]? = nil
    var switchLabel: String? = nil
}

struct ZoomCoach: Equatable, Codable {
    enum Kind: String, Codable { case none, row, control, toggle, appRow, build, credRow }
    /// The visible label of the control to spotlight; nil for a card alone.
    var label: String?
    var kind: Kind
    var counter: String
    var text: String
    /// The card's line while the Add Scopes panel's search field is open.
    var searchText: String? = nil
    /// Which row of the Created apps scan to spotlight (kind appRow).
    var rowIndex: Int? = nil
    /// True: with no target found the card still shows, without a spotlight.
    var optional = false
    /// Later stages on the same address, furthest last (Created apps' create flow).
    var then: [ZoomCoachStage]? = nil
    /// "Do this step" (R16): the actor step the button runs, its plan line, a result note, and busy.
    var action: String? = nil
    var plan: String? = nil
    var note: String? = nil
    var busy = false
    /// The card's line while a dialog the coach doesn't know is open (nothing behind it is pointed at).
    var dialogText = "Finish this window first. Greenroom carries on after it."

    /// The JSON the coach script takes. Only these fields, only Swift's own words.
    var json: String {
        guard let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }
}

enum ZoomCoachRules {
    /// Created apps' create flow after the first spotlight: the + menu's Build, the
    /// part's app type in the dialog, then Create once that type is chosen.
    static func createFlow(_ part: ZoomGuidePart) -> [ZoomCoachStage] {
        let type = part == .hostingApp ? "Server to server OAuth app" : "General app"
        let heading = part == .hostingApp ? "Create a Server-to-Server OAuth app" : "Create a General app"
        return [ZoomCoachStage(kind: .menuItem, label: "Build app", text: "Press Build app."),
                ZoomCoachStage(kind: .chooseRow, label: type, text: "Choose \(type)."),
                ZoomCoachStage(kind: .createAfter, label: type, text: "Press Create."),
                ZoomCoachStage(kind: .nameField, label: heading, text: "Name it, for example Greenroom, then press Create."),
                ZoomCoachStage(kind: .createNamed, label: heading, text: "Press Create.")]
    }

    /// Zoom's name dialog is headed "Create a Server-to-Server OAuth app" / "Create a General app".
    static func part(forHeading heading: String) -> ZoomGuidePart? {
        let t = heading.lowercased().replacingOccurrences(of: "-", with: " ")
        if t.contains("server to server oauth") { return .hostingApp }
        if t.contains("general app") { return .meetingApp }
        return nil
    }

    /// The part a dialog moves the coach to: the name dialog's own heading, or the type picked in "What kind of app".
    static func partFollowing(_ heading: String?, _ chosen: String?) -> ZoomGuidePart? {
        guard let heading else { return nil }
        let h = heading.lowercased()
        if h.hasPrefix("create a ") { return part(forHeading: heading) }
        if h.hasPrefix("what kind of app"), let chosen { return part(forHeading: chosen) }
        return nil
    }

    /// `needsApp`: the part's keys are filled but its app's ID is not known yet (R12).
    /// `appRows`: the Type text of each row on Created apps (nil until scanned).
    static func coach(part: ZoomGuidePart, page: ZoomMarketplacePage, keysFilled: Bool, tipsOn: Bool, needsApp: Bool = false,
                      appRows: [String]? = nil, missingKeys: [ZoomKeyField]? = nil) -> ZoomCoach? {
        if page == .passkey {
            guard tipsOn else { return nil }
            return ZoomCoach(label: "Try another way", kind: .control, counter: "",
                             text: "Passkeys don\u{2019}t work in this window. Press Try another way and use your password, or sign in in Safari.",
                             optional: true)
        }
        if tipsOn, page == .createdApps, part != .check, let appRows {
            let counter = ZoomRun.counter(ZoomRun.firstStep(of: part) ?? 1)
            let name = part == .meetingApp ? "Meeting app" : "Hosting app"
            let matches = matchingRows(part, appRows)
            switch matches.count {
            case 0:
                return ZoomCoach(label: nil, kind: .build, counter: counter, text: "Press + to build your \(name).", then: createFlow(part))
            case 1:
                return ZoomCoach(label: nil, kind: .appRow, counter: counter, text: "This is your \(name). Click it.", rowIndex: matches[0], then: createFlow(part))
            default:
                let type = part == .meetingApp ? "General app" : "Server-to-Server OAuth app"
                return ZoomCoach(label: nil, kind: .appRow, counter: counter, text: "Click the \(type) you made for Greenroom.", rowIndex: matches[0], then: createFlow(part))
            }
        }
        if tipsOn, needsApp, part != .check, page == .createdApps {
            return ZoomCoach(label: nil, kind: .none, counter: "", text: ZoomStartOverRules.coachFindMyApp)
        }
        guard tipsOn, let step = ZoomGuideFollowRules.step(part: part, page: page) else { return nil }
        let counter = ZoomRun.counter(step)
        func make(_ label: String?, _ kind: ZoomCoach.Kind, _ text: String, search: String? = nil, then: [ZoomCoachStage]? = nil) -> ZoomCoach {
            ZoomCoach(label: label, kind: kind, counter: counter, text: text, searchText: search, then: then)
        }
        switch page {
        case .chooseType:
            let name = part == .hostingApp ? "Server to server OAuth app" : "General app"
            return make(name, .row, "Choose \(name), then press Create.")
        case .s2s(_, .scopes):
            return make("Add Scopes", .control, "Press + Add Scopes.",
                        search: "Paste one scope, tick it, repeat. Copy scopes is in the guide.",
                        then: [ZoomCoachStage(kind: .afterTextsPresent, label: "Activation", text: "All \(ZoomScopes.count) scopes are in. Now open Activation.",
                                              counter: ZoomRun.counter(6), texts: ZoomScopes.names)])
        case .s2s(_, .activation):
            return make("Activate", .control, "Press Activate to turn the app on.",
                        then: [ZoomCoachStage(kind: .afterActivated, label: "App Credentials", text: "The app is on. Now open App Credentials for the keys.",
                                              counter: ZoomRun.counter(7))])
        case .general(_, .embed):
            return make("Meeting SDK", .toggle, "Turn on Meeting SDK.",
                        then: [ZoomCoachStage(kind: .afterSwitchOn, label: "Basic information",
                                              text: "Meeting SDK is on. Now open Basic information for the keys.",
                                              counter: ZoomRun.counter(3), switchLabel: "Meeting SDK")])
        case .s2s(_, .credentials), .general(_, .information):
            // Always speaks once it knows what is missing: point at the row of the first missing key and say to
            // press Zoom's own copy button (the secret is not in the page); no "Do this step" here.
            if let missingKeys {
                guard let first = missingKeys.first else { return make(nil, .none, "Got it: the keys are in Greenroom.") }
                let name = keyLabel(first)
                return make(name, .credRow, "Hover \(name) and press its copy button. Greenroom fills it in.")
            }
            return keysFilled ? make(nil, .none, "Got it: the keys are in Greenroom.") : nil
        default:
            return nil
        }
    }

    /// Adds the "Do this step" button and its plan line when the page's step has one (R16).
    static func offeringAction(_ coach: ZoomCoach?, part: ZoomGuidePart, page: ZoomMarketplacePage) -> ZoomCoach? {
        guard var c = coach, let step = ZoomActorRules.step(part: part, page: page, coachKind: c.kind) else { return coach }
        c.action = step.rawValue
        c.plan = ZoomActorRules.plan(step, part: part)
        return c
    }

    /// Zoom's own spelling of a key's label (it writes "Client secret").
    static func keyLabel(_ f: ZoomKeyField) -> String {
        switch f {
        case .accountID: return "Account ID"
        case .clientID: return "Client ID"
        case .clientSecret: return "Client secret"
        }
    }

    /// Rows whose Type text is the part's kind (Meeting app: General app; Hosting app: Server-to-Server OAuth).
    /// Only the type column is read, never an app's name.
    static func matchingRows(_ part: ZoomGuidePart, _ types: [String]) -> [Int] {
        let want: String
        switch part {
        case .meetingApp: want = "general app"
        case .hostingApp: want = "server to server oauth"
        case .check: return []
        }
        return types.enumerated().compactMap { i, t in
            t.lowercased().replacingOccurrences(of: "-", with: " ").contains(want) ? i : nil
        }
    }
}
