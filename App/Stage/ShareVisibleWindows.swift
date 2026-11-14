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
        return ShowOnShare.exceptionIDs(kind: kind, registry: Set(visible)) ?? []
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
