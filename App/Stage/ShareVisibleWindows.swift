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
    static func crossCheck(pieces: [LayoutPiece], target: Visibility.Target) {
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
