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
    enum Kind: String, Codable { case none, row, control, toggle }
    /// The visible label of the control to spotlight; nil for a card alone.
    var label: String?
    var kind: Kind
    var counter: String
    var text: String
    /// The card's line while the Add Scopes panel's search field is open.
    var searchText: String? = nil

    /// The JSON the coach script takes. Only these fields, only Swift's own words.
    var json: String {
        guard let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }
}

enum ZoomCoachRules {
    static func coach(part: ZoomGuidePart, page: ZoomMarketplacePage, keysFilled: Bool, tipsOn: Bool) -> ZoomCoach? {
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
}
