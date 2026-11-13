//
//  MeetingMenuAppKit.swift
//  Greenroom
//
//  Turns a `[MenuEntry]` into an NSMenu and pops it above a control.
//
//  Why not SwiftUI's Menu: on macOS a Menu flattens a custom label to an inline
//  image-and-title, so Share, React and Host tools drew as small text buttons
//  next to the icon-over-caption cells (the owner's screenshot). A control that
//  pops a hand-built NSMenu keeps the cell exactly as drawn, and the project
//  already pops menus this way from its non-activating panels (ToolMenuButton in
//  ParticipantGridWindow.swift), so no click brings Greenroom's windows forward.
//
import AppKit
import SwiftUI

@MainActor
enum MeetingMenuBuilder {

    /// A menu item that owns its closure. NSMenuItem.target is weak, and the
    /// item is its own target.
    final class Item: NSMenuItem {
        private let handler: () -> Void
        init(_ title: String, handler: @escaping () -> Void) {
            self.handler = handler
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("not used") }
        @objc private func fire() { handler() }
    }

    static func menu(_ entries: [MenuEntry]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries { menu.addItem(item(for: entry)) }
        return menu
    }

    private static func item(for entry: MenuEntry) -> NSMenuItem {
        switch entry.kind {
        case .separator:
            return .separator()
        case .header:
            return NSMenuItem.sectionHeader(title: entry.title)
        case .item:
            let item = Item(entry.title, handler: entry.action ?? {})
            item.isEnabled = entry.enabled
            item.state = entry.checked ? .on : .off
            if let combo = entry.shortcut, let key = combo.menuKey, key.count == 1 {
                item.keyEquivalent = key
                var mask: NSEvent.ModifierFlags = []
                if combo.modifiers & KeyCombo.command != 0 { mask.insert(.command) }
                if combo.modifiers & KeyCombo.option != 0 { mask.insert(.option) }
                if combo.modifiers & KeyCombo.control != 0 { mask.insert(.control) }
                if combo.modifiers & KeyCombo.shift != 0 { mask.insert(.shift) }
                item.keyEquivalentModifierMask = mask
            }
            if let note = entry.note, !note.isEmpty {
                let text = NSMutableAttributedString(
                    string: entry.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                text.append(NSAttributedString(
                    string: "\n" + note,
                    attributes: [.font: NSFont.menuFont(ofSize: 11),
                                 .foregroundColor: NSColor.secondaryLabelColor]))
                item.attributedTitle = text
            }
            return item
        case .submenu:
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.isEnabled = entry.enabled
            item.submenu = menu(entry.children)
            return item
        }
    }

    /// Pops the menu so it opens upward from `view`'s top edge: the toolbar sits
    /// at the foot of the window, where the default (downward) would leave it.
    static func popUp(_ entries: [MenuEntry], above view: NSView, below: Bool = false) {
        guard !entries.isEmpty else { return }
        let built = menu(entries)
        // The meeting window is dark whatever the system is (MeetingTheme).
        built.appearance = NSAppearance(named: .darkAqua)
        let height = built.size.height
        // `below` opens it downward instead, for a control at the top of the window.
        let y: CGFloat = below ? (view.isFlipped ? view.bounds.maxY + 4 : -4)
                               : (view.isFlipped ? -4 : view.bounds.maxY + height + 4)
        built.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
    }
}

/// A transparent AppKit layer over a toolbar cell: a press pops the menu. It
/// answers the first click (the panel is rarely key) and exposes itself to
/// VoiceOver as a button that opens the same menu.
struct MenuPopUpOverlay: NSViewRepresentable {
    let label: String
    let entries: () -> [MenuEntry]

    func makeNSView(context: Context) -> PopView { PopView() }

    func updateNSView(_ view: PopView, context: Context) {
        view.entries = entries
        view.setAccessibilityLabel(label)
    }

    final class PopView: NSView {
        var entries: (() -> [MenuEntry])?

        override var isFlipped: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .menuButton }

        override func mouseDown(with event: NSEvent) { open() }
        override func accessibilityPerformPress() -> Bool { open(); return true }

        private func open() {
            guard let entries = entries?() else { return }
            MeetingMenuBuilder.popUp(entries, above: self)
        }
    }
}
