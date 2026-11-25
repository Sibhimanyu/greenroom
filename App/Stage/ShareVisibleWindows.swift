//
//  ShareVisibleWindows.swift
//  Greenroom
//
//  "Show on my share": the windows of ours that are let into the picture of a
//  shared display. Greenroom leaves all its own windows out of a display share
//  (StageScreenSource excludes the whole app); each window here is excepted from
//  that exclusion. The rule is ShowOnShare (pure, tested); this is the live list.
//
//  Window numbers, because an SCWindow's windowID is the NSWindow's windowNumber.
//
import AppKit

@MainActor
enum ShareVisibleWindows {
    /// Posted when a window is added or removed, or the kind of share changes.
    static let didChange = Notification.Name("ShareVisibleWindowsDidChange")

    private(set) static var windowNumbers: Set<Int> = []
    private(set) static var kind: ShowOnShare.ShareKind = .other

    /// Other apps kept out of everyone's picture (their 📡 is off), set from the
    /// layout by `LayoutShareChoice`; `Visibility.hiddenAppIDs` is the only rule.
    private(set) static var hiddenAppIDs: Set<String> = []

    static func setHiddenApps(_ ids: Set<String>) {
        guard ids != hiddenAppIDs else { return }
        hiddenAppIDs = ids
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Everything the display filter depends on. The capture compares it once a
    /// second, so a switch flipped mid-meeting, a window that came or went, and an
    /// excluded app that launched or quit all rebuild the filter.
    struct FilterState: Equatable {
        var windowNumbers: Set<Int> = []
        var hiddenAppIDs: Set<String> = []
        /// The running processes of those apps: a relaunch is a new process.
        var hiddenPIDs: Set<pid_t> = []
        /// The hidden apps that have a running process right now (`ExclusionResolution` compares
        /// them with what ScreenCaptureKit lists).
        var runningHiddenIDs: Set<String> = []
    }

    static var filterState: FilterState {
        // Only a whole-display share has an app exclusion (Visibility.hiddenAppIDs says so too).
        let hidden = kind == .display ? hiddenAppIDs : []
        let pids = hidden.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier) }
        let running = hidden.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        return FilterState(windowNumbers: effectiveNumbers, hiddenAppIDs: hidden, hiddenPIDs: Set(pids), runningHiddenIDs: running)
    }

    static func contains(_ number: Int) -> Bool { windowNumbers.contains(number) }

    static func add(_ number: Int) {
        guard windowNumbers.insert(number).inserted else { return }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func remove(_ number: Int) {
        guard windowNumbers.remove(number) != nil else { return }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func setKind(_ new: ShowOnShare.ShareKind) {
        guard new != kind else { return }
        kind = new
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// What the capture should except right now: the listed windows that are
    /// really on screen, and nothing at all unless a whole display is shared.
    static var effectiveNumbers: Set<Int> {
        let visible = windowNumbers.filter { NSApp.window(withWindowNumber: $0)?.isVisible ?? false }
        // The rule (Visibility.windowBadge) decides whether the browser is in.
        let always = Set([BrowserWindowController.visibleWindowNumber].compactMap { $0 })
        return ShowOnShare.exceptionIDs(kind: kind, registry: Set(visible), alwaysShared: always) ?? []
    }
}

extension ShowOnShare.ShareKind {
    init(_ kind: ShareTarget.Kind) {
        switch kind {
        case .display: self = .display
        case .app: self = .app
        case .window: self = .window
        case .whiteboard, .nothing: self = .other
        }
    }
}

extension Visibility.Target {
    /// The rule's view of what is shared now.
    init(_ target: ShareTarget) {
        switch target.kind {
        case .display: self = .wholeScreen
        case .app, .window: self = .window(bundleID: target.appBundleID.isEmpty ? nil : target.appBundleID)
        case .whiteboard: self = .whiteboard
        case .nothing: self = .justMe
        }
    }
}

#if DEBUG
import os

extension ShareVisibleWindows {
    /// DEBUG cross-check: the live windows of the pieces, against the list the
    /// stream really passes to ScreenCaptureKit (`effectiveNumbers`). A disagreement
    /// is logged and trips an assertion: it is the Greenroom Browser bug again.
    /// It asks the rule about the capture's own kind (`Visibility.Target(captureKind:)`),
    /// so it compares like with like, and only runs while a capture is live: with no
    /// meeting there is no list to compare against.
    static func crossCheck(pieces: [LayoutPiece]) {
        guard let c = CoordinatorController.shared, c.stage != nil, c.sceneInUse || c.isRunning else { return }
        let target = Visibility.Target(captureKind: kind)
        var live: [(piece: LayoutPiece, number: Int)] = []
        for p in pieces {
            var number: Int?
            switch p.kind {
            case .chat: number = ChatWindowController.currentWindow.flatMap { $0.isVisible ? $0.windowNumber : nil }
            case .meeting: number = ParticipantGridWindowController.meetingWindow.flatMap { $0.isVisible ? $0.windowNumber : nil }
            case let .app(a): number = AppCatalog.isBuiltInBrowser(a.bundleID) ? BrowserWindowController.visibleWindowNumber : nil
            case .view, .roomScreen: number = nil
            }
            if let number { live.append((p, number)) }
        }
        let bad = Visibility.mismatches(windows: live, target: target, exceptionList: effectiveNumbers)
        guard !bad.isEmpty else { return }
        Logger(subsystem: "com.greenroom", category: "Visibility")
            .error("Preview: Everyone disagrees with the capture's exception list for \(bad.count, privacy: .public) piece(s)")
        assertionFailure("Visibility rule and the capture's exception list disagree")
    }
}
#endif
