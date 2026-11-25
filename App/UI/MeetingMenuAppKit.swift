//
//  MeetingMenuAppKit.swift
//  Greenroom
//
//  Opens a `[MenuEntry]` as a MeetingMenuPanel above a control. No NSMenu: it
//  shows nothing while Greenroom is not the active app, which is where the bar
//  and the meeting's panels are used from.
//
//  Why not SwiftUI's Menu: on macOS a Menu flattens a custom label to an inline
//  image-and-title, so Share, React and Host tools drew as small text buttons
//  next to the icon-over-caption cells (the owner's screenshot). A control that
//  pops a panel of its own keeps the cell exactly as drawn, and no click brings
//  Greenroom's windows forward.
//
import AppKit
import SwiftUI

@MainActor
enum MeetingMenuBuilder {

    /// Opens the menu (our own floating panel, see MeetingMenuPanel) upward from
    /// `view`'s top edge: the toolbar sits at the foot of the window, where the
    /// default (downward) would leave it. NSMenu shows nothing while the app is
    /// inactive, which is where the bar is used from.
    static func popUp(_ entries: [MenuEntry], above view: NSView, below: Bool = false) {
        guard !entries.isEmpty else { return }
        MeetingMenuPanel.show(entries, above: view, below: below)
    }
}

/// A transparent AppKit layer over a toolbar cell: a press pops the menu. It
/// answers the first click (the panel is rarely key) and exposes itself to
/// VoiceOver as a button that opens the same menu.
struct MenuPopUpOverlay: NSViewRepresentable {
    let label: String
    /// Hang the menu below the control (a list row) rather than above it (the toolbar).
    var below = false
    let entries: () -> [MenuEntry]

    func makeNSView(context: Context) -> PopView { PopView() }

    func updateNSView(_ view: PopView, context: Context) {
        view.entries = entries
        view.below = below
        view.setAccessibilityLabel(label)
    }

    final class PopView: NSView {
        var entries: (() -> [MenuEntry])?
        var below = false

        override var isFlipped: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .menuButton }

        override func mouseDown(with event: NSEvent) { open() }
        override func accessibilityPerformPress() -> Bool { open(); return true }

        private func open() {
            let w = window
            CoordinatorController.sessionLog("Bar: menu cell pressed (\(accessibilityLabel() ?? "no label"); window visible \(w?.isVisible ?? false), onActiveSpace \(w?.isOnActiveSpace ?? false), alpha \(w?.alphaValue ?? -1))")
            guard let entries = entries?() else { return }
            MeetingMenuBuilder.popUp(entries, above: self, below: below)
        }
    }
}
