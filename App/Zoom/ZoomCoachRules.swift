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

struct ZoomCoach: Equatable, Codable {
    enum Kind: String, Codable { case none, row, control, toggle, appRow, build }
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

    /// The JSON the coach script takes. Only these fields, only Swift's own words.
    var json: String {
        guard let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }
}

enum ZoomCoachRules {
    /// `needsApp`: the part's keys are filled but its app's ID is not known yet (R12).
    /// `appRows`: the Type text of each row on Created apps (nil until scanned).
    static func coach(part: ZoomGuidePart, page: ZoomMarketplacePage, keysFilled: Bool, tipsOn: Bool, needsApp: Bool = false,
                      appRows: [String]? = nil) -> ZoomCoach? {
        if page == .passkey {
            guard tipsOn else { return nil }
            return ZoomCoach(label: "Try another way", kind: .control, counter: "",
                             text: "Passkeys don\u{2019}t work in this window. Press Try another way and use your password, or sign in in Safari.",
                             optional: true)
        }
        if tipsOn, page == .createdApps, part != .check, let appRows {
            let total = part == .meetingApp ? ZoomMarketplaceGuide.sdkSteps.count : ZoomMarketplaceGuide.s2sSteps.count
            let counter = "Step 1 of \(total)"
            let name = part == .meetingApp ? "Meeting app" : "Hosting app"
            let matches = matchingRows(part, appRows)
            switch matches.count {
            case 0:
                return ZoomCoach(label: nil, kind: .build, counter: counter, text: "Press + to build your \(name).")
            case 1:
                return ZoomCoach(label: nil, kind: .appRow, counter: counter, text: "This is your \(name). Click it.", rowIndex: matches[0])
            default:
                let type = part == .meetingApp ? "General app" : "Server-to-Server OAuth app"
                return ZoomCoach(label: nil, kind: .appRow, counter: counter, text: "Click the \(type) you made for Greenroom.", rowIndex: matches[0])
            }
        }
        if tipsOn, needsApp, part != .check, page == .createdApps {
            return ZoomCoach(label: nil, kind: .none, counter: "", text: ZoomStartOverRules.coachFindMyApp)
        }
        guard tipsOn, let step = ZoomGuideFollowRules.step(part: part, page: page) else { return nil }
        let total = part == .meetingApp ? ZoomMarketplaceGuide.sdkSteps.count : ZoomMarketplaceGuide.s2sSteps.count
        let counter = "Step \(step) of \(total)"
        func make(_ label: String?, _ kind: ZoomCoach.Kind, _ text: String, search: String? = nil) -> ZoomCoach {
            ZoomCoach(label: label, kind: kind, counter: counter, text: text, searchText: search)
        }
        switch page {
        case .chooseType:
            let name = part == .hostingApp ? "Server to server OAuth app" : "General app"
            return make(name, .row, "Choose \(name), then press Create.")
        case .s2s(_, .scopes):
            return make("Add Scopes", .control, "Press + Add Scopes.",
                        search: "Paste one scope, tick it, repeat. Copy scopes is in the guide.")
        case .s2s(_, .activation):
            return make("Activate", .control, "Press Activate to turn the app on.")
        case .general(_, .embed):
            return make("Meeting SDK", .toggle, "Turn on Meeting SDK.")
        case .s2s(_, .credentials), .general(_, .information):
            return keysFilled ? make(nil, .none, "Got it: the keys are in Greenroom.") : nil
        default:
            return nil
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
