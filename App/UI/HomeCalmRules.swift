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
    enum Kind: String { case look, share, camera, microphone, layout }
    let kind: Kind
    let symbol: String
    let text: String
    /// Needs the user's attention: drawn amber.
    var attention: Bool = false

    var id: String { kind.rawValue }
}

enum SetupSummary {
    /// What the one line says, in order: look, share, camera, microphone,
    /// layout. The look only means something while there is a camera to give
    /// it to, so it is left out when the camera is off.
    static func items(cameraOff: Bool, lookSymbol: String, lookText: String,
                      shareSymbol: String, shareText: String, shareGone: Bool,
                      cameraText: String, cameraMissing: Bool,
                      micText: String, layoutText: String) -> [SetupSummaryItem] {
        var items: [SetupSummaryItem] = []
        if !cameraOff {
            items.append(SetupSummaryItem(kind: .look, symbol: lookSymbol, text: lookText))
        }
        items.append(SetupSummaryItem(kind: .share, symbol: shareSymbol, text: shareText, attention: shareGone))
        items.append(SetupSummaryItem(kind: .camera, symbol: cameraOff ? "video.slash" : "camera",
                                      text: cameraText, attention: cameraMissing && !cameraOff))
        items.append(SetupSummaryItem(kind: .microphone, symbol: "mic", text: micText))
        items.append(SetupSummaryItem(kind: .layout, symbol: "rectangle.split.2x1", text: layoutText))
        return items
    }

    /// A share target that is gone: an app that is no longer running, or a
    /// window that is no longer open. Whole-screen, whiteboard and "nothing"
    /// cannot go missing. An unset app or window is a choice not yet made,
    /// not a loss.
    enum ShareKind { case display, app, window, whiteboard, nothing }

    static func shareIsGone(kind: ShareKind, appBundleID: String, windowTitle: String,
                            runningApps: [String], openWindows: [(bundleID: String, title: String)]) -> Bool {
        switch kind {
        case .app:
            return !appBundleID.isEmpty && !runningApps.contains(appBundleID)
        case .window:
            return !appBundleID.isEmpty
                && !openWindows.contains { $0.bundleID == appBundleID && $0.title == windowTitle }
        case .display, .whiteboard, .nothing:
            return false
        }
    }
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
