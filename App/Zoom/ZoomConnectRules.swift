//
//  ZoomConnectRules.swift
//  Greenroom
//
//  The Connect Zoom step as one button (spec R14): "Set up Zoom" / "Continue
//  setup" opens the Zoom window on the first unfinished part; a status line per
//  part; the check row once both are done; and a collapsed manual route that
//  deep links open. Pure: Foundation only.
//
import Foundation

struct ZoomConnectButton: Equatable {
    let title: String
    /// The first unfinished part (Meeting app first).
    let part: ZoomGuidePart
}

enum ZoomConnectRules {
    static let intro = "Greenroom needs two small apps in your Zoom account. It takes about 10 minutes, and Greenroom shows you each click."
    static let manualTitle = "Enter the keys yourself"

    /// nil once both parts are done: the check row takes its place.
    static func button(_ f: ZoomGuideFlowFacts) -> ZoomConnectButton? {
        let flow = ZoomGuideFlowRules.flow(f)
        let part: ZoomGuidePart
        if flow.meetingApp != .done { part = .meetingApp }
        else if flow.hostingApp != .done { part = .hostingApp }
        else { return nil }
        return ZoomConnectButton(title: f.anythingFilled ? "Continue setup" : "Set up Zoom", part: part)
    }

    /// Where the button opens the window: Created apps, or the remembered app's next page.
    static func entryPage(_ part: ZoomGuidePart, ids: ZoomAppIDs, filled: Int) -> ZoomMarketplacePage {
        switch part {
        case .meetingApp:
            guard let id = ids.meeting else { return .createdApps }
            return .general(id, filled > 0 ? .information : .embed)
        case .hostingApp:
            guard let id = ids.hosting else { return .createdApps }
            return .s2s(id, filled > 0 ? .credentials : .scopes)
        case .check:
            return .createdApps
        }
    }

    static func showsCheckRow(_ f: ZoomGuideFlowFacts) -> Bool {
        let flow = ZoomGuideFlowRules.flow(f)
        return (flow.meetingApp == .done && flow.hostingApp == .done) || f.check != .notRun
    }

    /// A deep link to the keys, scopes or activation unfolds the manual route.
    static func opensManual(_ spot: ZoomGuideSpot) -> Bool { spot != .zoomStep }

    /// The "..." menu's shortcuts on a part's line: only the pages whose app ID is known.
    static func shortcuts(_ part: ZoomGuidePart, ids: ZoomAppIDs) -> [ZoomGuideRowLink] {
        ZoomMarketplaceGuide.rows(part: part, ids: ids).compactMap { $0.link }.filter { $0.page != .createdApps }
    }
}
