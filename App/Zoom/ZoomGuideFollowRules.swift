//
//  ZoomGuideFollowRules.swift
//  Greenroom
//
//  The setup guide follows the page the Zoom window is on (spec R3), fills
//  the keys in from it (R5) and starts the check by itself (R7). Pure:
//  Foundation only; the window and the guide only apply these decisions.
//
import Foundation

/// The Zoom window's setup is ONE run of eight steps across both apps, in Zoom's own tab order (owner, 2026-11-27):
/// the Meeting app's three (Basic information comes first, then Embed), then the Hosting app's five (App Credentials,
/// Information, Scopes, Activation). The only source of the numbering and the step names.
enum ZoomRun {
    static let names = ["Create the meeting app", "Copy its keys", "Turn on Meeting SDK",
                        "Create the hosting app", "Copy its keys", "Fill in Information", "Add the permissions", "Turn it on"]
    static var total: Int { names.count }

    static func name(_ step: Int) -> String { (1...total).contains(step) ? names[step - 1] : "" }
    static func counter(_ step: Int) -> String { "Step \(step) of \(total)" }

    /// The step a part starts at (Created apps): 1 for the Meeting app, 4 for the Hosting app.
    static func firstStep(of part: ZoomGuidePart) -> Int? {
        switch part {
        case .meetingApp: return 1
        case .hostingApp: return 4
        case .check: return nil
        }
    }

    static func part(ofStep step: Int) -> ZoomGuidePart { step <= 3 ? .meetingApp : .hostingApp }
}

enum ZoomGuideFollowRules {
    /// The current step (1 to 7, across both apps) of `part` for the page the window shows; nil when the page is no step of that part.
    static func step(part: ZoomGuidePart, page: ZoomMarketplacePage?) -> Int? {
        guard let page else { return nil }
        switch (part, page) {
        case (.meetingApp, .createdApps), (.meetingApp, .chooseType): return 1
        case (.meetingApp, .general(_, .information)): return 2
        case (.meetingApp, .general(_, .embed)): return 3
        case (.hostingApp, .createdApps), (.hostingApp, .chooseType): return 4
        case (.hostingApp, .s2s(_, .credentials)): return 5
        case (.hostingApp, .s2s(_, .information)), (.hostingApp, .s2s(_, .feature)): return 6
        case (.hostingApp, .s2s(_, .scopes)): return 7
        case (.hostingApp, .s2s(_, .activation)): return 8
        default: return nil
        }
    }

    /// The part a page opens. A page of the other kind leaves a part with typing in it alone; nil leaves the guide as it is.
    static func part(for page: ZoomMarketplacePage, open: ZoomGuidePart?, typing: Bool) -> ZoomGuidePart? {
        let target: ZoomGuidePart
        switch page.app {
        case .sdk: target = .meetingApp
        case .s2s: target = .hostingApp
        case nil: return nil
        }
        if typing, let open, open != target { return nil }
        return target
    }
}

/// What a read of the page's key inputs does to the guide's fields.
enum ZoomKeyFillDecision: Equatable {
    case nothing
    /// Write these now (the fields were empty or already the same).
    case fill([ZoomKeyField: String])
    /// Offer these; nothing is written until the person says so.
    case offer([ZoomKeyField: String])
}

enum ZoomKeyFillRules {
    static func decide(current: [ZoomKeyField: String], found: [ZoomKeyField: String]) -> ZoomKeyFillDecision {
        let keys = found.filter { ZoomMarketplacePages.isKey($0.value) }
        func have(_ f: ZoomKeyField) -> String { (current[f] ?? "").trimmingCharacters(in: .whitespaces) }
        let changes = keys.filter { have($0.key) != $0.value }
        if changes.isEmpty { return .nothing }
        let clash = changes.contains { !have($0.key).isEmpty }
        return clash ? .offer(changes) : .fill(changes)
    }

    /// Check Zoom setup starts by itself once, when the window's fill makes both parts complete and nothing is live.
    static func shouldAutoCheck(bothFilledBefore: Bool, bothFilledAfter: Bool, inSession: Bool, checkRunning: Bool) -> Bool {
        bothFilledAfter && !bothFilledBefore && !inSession && !checkRunning
    }
}

/// What the guide needs to know about the Zoom window, as plain values (the render feeds samples).
struct ZoomGuideAssistState: Equatable {
    var page: ZoomMarketplacePage?
    var ids = ZoomAppIDs()
    /// Parts whose fields the window filled ("Filled in from Zoom", with Undo).
    var filled: Set<ZoomGuidePart> = []
    /// Parts where the page's keys differ from what is typed ("Use the keys from this page").
    var offers: Set<ZoomGuidePart> = []
    /// Parts whose keys were just removed by "Use a different app" ("Keys removed", with Undo).
    var removed: Set<ZoomGuidePart> = []
}
