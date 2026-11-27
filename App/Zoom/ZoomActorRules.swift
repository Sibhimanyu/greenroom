//
//  ZoomActorRules.swift
//  Greenroom
//
//  "Do this step" (spec R16, owner 2026-11-27): on the person's press only,
//  Greenroom presses a few safe controls on Zoom's page. This file is the one
//  place that decides what the actor may press: the steps it has, each step's
//  allow-list of exact labels, the deny-list that wins over everything, the
//  plan line the card shows first and the words after a run. The page script
//  (`ZoomActorScript`) is given these lists as arguments and has one place that
//  clicks. Pure: Foundation only.
//
import Foundation

enum ZoomActorStep: String, CaseIterable, Codable, Equatable {
    case createApp, addScopes, activate, enableSDK, readKeys, continueInfo

    /// The log word, e.g. "step:scopes click Add Scopes ok".
    var logName: String {
        switch self {
        case .createApp: return "create"
        case .addScopes: return "scopes"
        case .activate: return "activate"
        case .enableSDK: return "embed"
        case .readKeys: return "keys"
        case .continueInfo: return "info"
        }
    }
}

/// What the page script reports. Only counts, codes and our own scope names.
struct ZoomActorResult: Equatable, Codable {
    var code: String
    var added: Int? = nil
    var total: Int? = nil
    var notFound: [String]? = nil
    /// "click <allow-list label> ok" lines, labels from the allow-list only.
    var log: [String]? = nil
}

enum ZoomActorRules {
    static let buttonTitle = "Do this step"
    static let busyTitle = "Working\u{2026}"

    /// Never pressed, even when a label is on an allow-list.
    static let denyPattern = "(regenerate|delete|remove|deactivate|disable|submit|publish|agree|accept|terms|sign out|log out|uninstall)"

    static func isDenied(_ text: String) -> Bool {
        text.range(of: denyPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Exact labels (normalized, lowercase) per step. The scope checkboxes are separate (`allowedScopeCheckbox`).
    static func allowList(for step: ZoomActorStep) -> [String] {
        switch step {
        case .createApp: return ["+", "build app", "build", "general app", "server to server oauth app", "create"]
        case .addScopes: return ["add scopes", "+ add scopes", "done", "save", "continue"]
        case .activate: return ["activate", "activate your app"]
        case .enableSDK: return ["meeting sdk"]
        case .readKeys: return ["copy"]
        case .continueInfo: return ["continue"]
        }
    }

    static func allowed(_ label: String, for step: ZoomActorStep) -> Bool {
        !isDenied(label) && allowList(for: step).contains(normalize(label))
    }

    static func allowed(label: String) -> Bool { ZoomActorStep.allCases.contains { allowed(label, for: $0) } }

    /// Words that make a control something other than a plain copy: reveal, show, eye and view are never pressed.
    static let copyDenyPattern = "(reveal|show|hide|eye|view|visib)"

    /// A control the actor may press to copy a key: its text or label is Copy (or "Copy <something>"), never a reveal
    /// control, and the main deny-list wins (a Copy inside a Regenerate control is still denied).
    static func allowedCopyControl(text: String, label: String) -> Bool {
        let t = normalize(text), l = normalize(label)
        if isDenied(t) || isDenied(l) { return false }
        for w in [t, l] where !w.isEmpty {
            if w.range(of: copyDenyPattern, options: .regularExpression) != nil { return false }
        }
        return t == "copy" || l == "copy" || l.hasPrefix("copy ")
    }

    enum Restoration: Equatable { case restore(String); case clear }

    /// After a key is picked up from the clipboard: put the previous plain-text contents back, or clear it.
    static func restoration(previous: String?) -> Restoration {
        guard let previous, !previous.isEmpty else { return .clear }
        return .restore(previous)
    }

    /// A scope's checkbox: only one of our scopes; the checkbox's own name is checked against the
    /// deny-list with the scope string removed (the scope names themselves contain "delete").
    static func allowedScopeCheckbox(name: String, scope: String) -> Bool {
        guard ZoomScopes.names.contains(scope) else { return false }
        return !isDenied(name.replacingOccurrences(of: scope, with: ""))
    }

    /// Zoom's name dialogs (lowercase heading prefixes): the ONLY place the actor may type a name.
    static let nameHeadings = ["create a server-to-server oauth app", "create a general app"]

    static func allowedNameDialog(_ heading: String) -> Bool {
        let h = normalize(heading)
        return nameHeadings.contains { h.hasPrefix($0) }
    }

    /// The name the actor gives the app, unless the person already typed one.
    static func appName(_ part: ZoomGuidePart) -> String { part == .hostingApp ? "Greenroom Hosting" : "Greenroom Meeting" }

    /// A step runs only on its own pages (checked again in Swift when the card's button is pressed).
    static func pageAllows(_ step: ZoomActorStep, _ page: ZoomMarketplacePage) -> Bool {
        switch (step, page) {
        case (.createApp, .createdApps), (.createApp, .chooseType): return true
        case (.addScopes, .s2s(_, .scopes)): return true
        case (.activate, .s2s(_, .activation)): return true
        case (.enableSDK, .general(_, .embed)): return true
        case (.readKeys, .s2s(_, .credentials)), (.readKeys, .general(_, .information)): return true
        case (.continueInfo, .s2s(_, .information)), (.continueInfo, .s2s(_, .feature)): return true
        default: return false
        }
    }

    /// The step a page offers (nil on credentials, sign-in and every other page). `coachKind` is the coach's spotlight kind.
    static func step(part: ZoomGuidePart, page: ZoomMarketplacePage, coachKind: ZoomCoach.Kind) -> ZoomActorStep? {
        switch (part, page) {
        case (.meetingApp, .createdApps), (.hostingApp, .createdApps): return coachKind == .build ? .createApp : nil
        case (.meetingApp, .chooseType), (.hostingApp, .chooseType): return .createApp
        case (.hostingApp, .s2s(_, .scopes)): return .addScopes
        case (.hostingApp, .s2s(_, .activation)): return .activate
        case (.meetingApp, .general(_, .embed)): return .enableSDK
        case (.hostingApp, .s2s(_, .credentials)), (.meetingApp, .general(_, .information)): return coachKind == .none ? nil : .readKeys
        case (.hostingApp, .s2s(_, .information)), (.hostingApp, .s2s(_, .feature)): return .continueInfo
        default: return nil
        }
    }

    static func plan(_ step: ZoomActorStep, part: ZoomGuidePart) -> String {
        switch step {
        case .createApp:
            let type = part == .hostingApp ? "Server to server OAuth app" : "General app"
            return "Greenroom will press + \u{2192} Build app, choose \(type), press Create, then name it \(appName(part)) and press Create."
        case .addScopes:
            return "Greenroom will add the \(ZoomScopes.countWord) scopes: open + Add Scopes, tick each one and press Done."
        case .activate: return "Greenroom will press Activate your app."
        case .enableSDK: return "Greenroom will turn on Meeting SDK."
        case .readKeys:
            return part == .hostingApp ? "Greenroom will read the three keys and fill them in."
                                       : "Greenroom will read the Client ID and copy the Client secret."
        case .continueInfo: return "Greenroom will press Continue if Zoom\u{2019}s required fields are filled in."
        }
    }

    /// The card's line after a run (or after it stopped).
    static func message(_ step: ZoomActorStep, _ r: ZoomActorResult) -> String {
        if r.code == "refused" { return "Greenroom only does this step on its own page." }
        switch (step, r.code) {
        case (.addScopes, "done"):
            let total = r.total ?? 0, added = r.added ?? 0
            if let missing = r.notFound, !missing.isEmpty {
                return "Added \(added) of \(total); couldn\u{2019}t find \(missing.joined(separator: ", ")): add them by hand (Copy scopes is in the bar)."
            }
            return "Added \(added) scopes."
        case (.addScopes, "already"): return "All the scopes are already on this page."
        case (.addScopes, "no-confirm"): return "Press Done to save the scopes."
        case (.addScopes, "no-add-scopes"): return "Couldn\u{2019}t find + Add Scopes. Press it yourself; Copy scopes is in the bar."
        case (.addScopes, "no-panel"): return "The scopes panel didn\u{2019}t open. Press + Add Scopes yourself; Copy scopes is in the bar."
        case (.createApp, "done"): return "Pressed Create. Fill in what Zoom asks next."
        case (.createApp, "named"): return "Named it and pressed Create. Fill in what Zoom asks next."
        case (.createApp, "no-name"): return "Couldn\u{2019}t find the name field. Type a name yourself, then press Create."
        case (.createApp, "no-create-enabled"): return "Typed the name but Create didn\u{2019}t turn on. Check the name and press Create yourself."
        case (.createApp, "no-plus"): return "Couldn\u{2019}t find the + button. Press it yourself."
        case (.createApp, "no-build"): return "Couldn\u{2019}t find Build app in the menu. Press it yourself."
        case (.createApp, "no-chooser"): return "The app type dialog didn\u{2019}t open. Press Build app yourself."
        case (.createApp, "no-radio"): return "Couldn\u{2019}t choose the app type. Choose it yourself, then press Create."
        case (.createApp, "no-create"): return "Chose the app type but couldn\u{2019}t find Create. Press it yourself."
        case (.activate, "done"): return "Activated. Zoom now shows the app as activated."
        case (.activate, "already"): return "The app is already activated."
        case (.activate, "no-button"): return "Couldn\u{2019}t find Activate. Finish Information first, then press it yourself."
        case (.activate, "not-verified"): return "Pressed Activate, but Zoom doesn\u{2019}t show it as activated yet. Check the page."
        case (.enableSDK, "done"): return "Meeting SDK is on."
        case (.enableSDK, "already"): return "Meeting SDK was already on."
        case (.enableSDK, "no-switch"): return "Couldn\u{2019}t find the Meeting SDK switch. Turn it on yourself."
        case (.readKeys, "done"): return "Read the keys and filled them in."
        case (.readKeys, "partial"): return "Filled in what Zoom shows. Press Zoom\u{2019}s Copy button for the rest."
        case (.readKeys, "no-copy"): return "Couldn\u{2019}t find a Copy button. Press it yourself and Greenroom will pick the key up."
        case (.continueInfo, "done"): return "Pressed Continue."
        case (.continueInfo, "needs-field"): return "A required field is empty. Fill it in, then press Continue."
        case (.continueInfo, "no-continue"): return "Couldn\u{2019}t find Continue. Press it yourself."
        case (.enableSDK, "not-verified"): return "Pressed the switch, but it doesn\u{2019}t look on. Check the page."
        default: return "Stopped. Check the page and finish this step yourself."
        }
    }
}
