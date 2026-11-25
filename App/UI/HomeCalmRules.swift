//
//  HomeCalmRules.swift
//  Greenroom
//
//  The pure parts of Home's calmer setup and readiness (DESIGN.md, 2026-11-13,
//  "Home is calmer"): the one-line setup summary and the reduction of the
//  readiness list to "Ready" or just the problems. No SwiftUI, no coordinator,
//  so both are unit-tested.
//
import Foundation

/// One part of the setup summary line.
struct SetupSummaryItem: Equatable, Identifiable {
    enum Kind: String { case look, share, camera, microphone, layout, autoRecord }
    let kind: Kind
    let symbol: String
    let text: String
    /// Needs the user's attention: drawn amber.
    var attention: Bool = false
    /// More on hover: what to do about a problem, or what a part means.
    var help: String? = nil

    var id: String { kind.rawValue }
}

enum SetupSummary {
    /// What the one line says, in order: look, share, camera, microphone,
    /// layout. The look only means something while there is a camera to give
    /// it to, so it is left out when the camera is off.
    static func items(cameraOff: Bool, lookSymbol: String, lookText: String,
                      shareSymbol: String, shareText: String, shareGone: Bool,
                      cameraText: String, cameraMissing: Bool,
                      micText: String, layoutText: String,
                      autoRecord: Bool = false) -> [SetupSummaryItem] {
        var items: [SetupSummaryItem] = []
        if !cameraOff {
            items.append(SetupSummaryItem(kind: .look, symbol: lookSymbol, text: lookText))
        }
        items.append(SetupSummaryItem(kind: .share, symbol: shareSymbol, text: shareText, attention: shareGone,
                                      help: shareGone ? shareGoneHelp : nil))
        let noCamera = cameraMissing && !cameraOff
        items.append(SetupSummaryItem(kind: .camera, symbol: (cameraOff ? VisibilitySymbol.cameraOff : VisibilitySymbol.cameraOn).name,
                                      text: cameraText, attention: noCamera,
                                      help: noCamera ? cameraMissingHelp : nil))
        items.append(SetupSummaryItem(kind: .microphone, symbol: "mic", text: micText))
        items.append(SetupSummaryItem(kind: .layout, symbol: "rectangle.split.2x1", text: layoutText))
        // Said out loud, so a recording that starts with the meeting is never
        // a surprise (owner, 2026-11-16: "sometimes the recording is started
        // on its own").
        if autoRecord {
            items.append(SetupSummaryItem(kind: .autoRecord, symbol: "record.circle",
                                          text: "Records with the meeting", help: autoRecordHelp))
        }
        return items
    }

    /// A share target that is gone: an app that is no longer running, or a
    /// window that is no longer open. Whole-screen, whiteboard and "nothing"
    /// cannot go missing. An unset app or window is a choice not yet made,
    /// not a loss.
    enum ShareKind { case display, app, window, whiteboard, nothing }

    ///
    /// The same rule the share itself follows (`ShareTarget.resolve`): a
    /// window whose title changed (a Finder window moved to another folder,
    /// a browser on another tab) is still that app's window and still shared,
    /// so only an app with no window open at all counts as gone.
    static func shareIsGone(kind: ShareKind, appBundleID: String, windowTitle: String,
                            runningApps: [String], openWindows: [(bundleID: String, title: String)]) -> Bool {
        switch kind {
        case .app:
            return !appBundleID.isEmpty && !runningApps.contains(appBundleID)
        case .window:
            return !appBundleID.isEmpty
                && !openWindows.contains { $0.bundleID == appBundleID }
        case .display, .whiteboard, .nothing:
            return false
        }
    }
}

extension SetupSummary {
    /// The line's words when the share is gone: what is missing, and what the
    /// class would see instead, so the amber explains itself.
    static func goneShareText(kind: ShareKind, appName: String) -> String {
        switch kind {
        case .window: return "No \(appName) window open, shares whole screen"
        case .app: return "\(appName) isn\u{2019}t open, shares whole screen"
        case .display, .whiteboard, .nothing: return ""
        }
    }

    static let shareGoneHelp = "What you picked to share isn\u{2019}t open, so everyone would see your whole screen. Open it again, or pick something else from Share."
    static let autoRecordHelp = "Recording starts by itself as soon as the meeting is live. Change it from the Record button on Home."
    static let cameraMissingHelp = "No camera is connected. Plug one in, or pick No camera from Camera."
}

/// One thing a start needs.
struct ReadinessItem: Equatable, Identifiable {
    let id: String
    let title: String
    /// nil: ready. Otherwise what is wrong, in the pill's own words.
    var problem: String?
}

enum ReadinessSummary {
    /// "Ready" when nothing is wrong, otherwise the problems only.
    enum Reduced: Equatable {
        case ready
        case problems([ReadinessItem])
    }

    static func reduce(_ items: [ReadinessItem]) -> Reduced {
        let bad = items.filter { $0.problem != nil }
        return bad.isEmpty ? .ready : .problems(bad)
    }
}
