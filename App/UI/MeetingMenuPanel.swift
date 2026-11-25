//
//  MeetingMenuPanel.swift
//  Greenroom
//
//  The bar's menus, drawn by us. NSMenu.popUp and popUpContextMenu show
//  nothing while Greenroom is not the active app, and after a desktop swipe
//  another app is in front. Activating Greenroom to fix that would drag its
//  other windows forward or jump desktops, so the menu is a floating,
//  non-activating panel instead: it shows whatever app is in front.
//
//  Not handled: arrow-key navigation and type-to-select (Escape, a click
//  outside, a desktop switch or the anchor going away close it).
//
import AppKit
import SwiftUI

@MainActor
final class MeetingMenuPanel {

    // MARK: Open menus (one chain at a time: root, then its open submenu)

    private static var chain: [MeetingMenuPanel] = []
    private static var anchorView: NSView?
    private static var monitors: [Any] = []
    private static var observers: [NSObjectProtocol] = []
    /// The anchor whose menu an outside click just closed. While Greenroom is
    /// inactive, a press on the anchor itself (the bar cell, the menu-bar icon)
    /// reaches the global monitor first and closes the menu, and then its
    /// button action would open it again. Within a moment, that press is the toggle.
    private static weak var dismissedAnchor: NSView?
    private static var dismissedAt = Date.distantPast

    /// True (and forgotten) when `view`'s menu was closed by this same press.
    private static func justDismissed(_ view: NSView) -> Bool {
        defer { dismissedAnchor = nil }
        return dismissedAnchor === view && Date().timeIntervalSince(dismissedAt) < 0.5
    }

    /// Opens the entries above the view (or below it), aligned to its left
    /// edge. Pressing the same cell again closes it.
    static func show(_ entries: [MenuEntry], above view: NSView, below: Bool = false) {
        if let current = anchorView, current === view, !chain.isEmpty { closeAll(); return }
        if justDismissed(view) { return }
        closeAll()
        guard !entries.isEmpty, let window = view.window else { return }
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        open(entries, anchor: anchor, view: view, window: window, below: below)
    }

    /// Hangs the entries below a status bar button. Pressing the same button
    /// again closes it. Returns false (and shows nothing) when the button has
    /// no window to measure from, so the caller can log why.
    @discardableResult
    static func show(_ entries: [MenuEntry], belowStatusButton button: NSView) -> Bool {
        if let current = anchorView, current === button, !chain.isEmpty { closeAll(); return true }
        if justDismissed(button) { return true }
        closeAll()
        guard !entries.isEmpty, let window = button.window else { return false }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        open(entries, anchor: anchor, view: button, window: window, below: true)
        return true
    }

    /// A right-click: the menu hangs from the mouse point, as a context menu does.
    static func show(_ entries: [MenuEntry], for event: NSEvent) {
        guard let window = event.window else { return }
        show(entries, atWindowPoint: event.locationInWindow, in: window)
    }

    /// The menu hangs from a point in `view` (its own coordinates).
    static func show(_ entries: [MenuEntry], at point: NSPoint, in view: NSView) {
        guard let window = view.window else { return }
        show(entries, atWindowPoint: view.convert(point, to: nil), in: window)
    }

    private static func show(_ entries: [MenuEntry], atWindowPoint point: NSPoint, in window: NSWindow) {
        closeAll()
        guard !entries.isEmpty else { return }
        let screenPoint = window.convertPoint(toScreen: point)
        open(entries, anchor: CGRect(origin: screenPoint, size: .zero), view: nil, window: window, below: true)
    }

    private static func open(_ entries: [MenuEntry], anchor: CGRect, view: NSView?, window: NSWindow, below: Bool) {
        let menu = MeetingMenuPanel(entries: entries)
        let size = menu.size
        let area = (NSScreen.screens.first { screen in
            screen.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main)?.visibleFrame ?? anchor
        // Above the cell, unless it would run off the top; then below.
        var y = below ? anchor.minY - 4 - size.height : anchor.maxY + 4
        if !below, y + size.height > area.maxY { y = anchor.minY - 4 - size.height }
        if below, y < area.minY { y = anchor.maxY + 4 }
        menu.place(at: NSPoint(x: anchor.minX, y: y), in: area)
        anchorView = view
        chain = [menu]
        menu.panel.orderFrontRegardless()
        watch(window)
        CoordinatorController.sessionLog(
            "Bar: menu opened (\(entries.count) items, app active \(NSApp.isActive ? "yes" : "no"))")
    }

    static func closeAll() {
        for menu in chain.reversed() { menu.panel.orderOut(nil) }
        chain = []
        anchorView = nil
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    private static func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return chain.contains { menu in menu.panel === window }
    }

    private static func watch(_ window: NSWindow) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { _ in
            MainActor.assumeIsolated {
                dismissedAnchor = anchorView
                dismissedAt = Date()
                closeAll()
            }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { event in
            MainActor.assumeIsolated {
                if owns(event.window) { return }
                // A press on the anchor cell is the toggle: its own handler closes.
                if let anchor = anchorView, event.window === anchor.window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
                closeAll()
            }
            return event
        }) { monitors.append(local) }
        // Escape: the global one needs Accessibility permission, so best effort.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            if event.keyCode == 53 { MainActor.assumeIsolated { closeAll() } }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { closeAll() }
            return nil
        }) { monitors.append(local) }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { closeAll() }
        })
        for name in [NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let gone = note.object as? NSWindow else { return }
                    if note.name == NSWindow.willCloseNotification || !gone.isVisible { closeAll() }
                }
            })
        }
    }

    // MARK: One panel

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// A click on an inactive panel is the click, not a request to focus.
    private final class Host: NSHostingView<MenuPanelView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let panel: NSPanel
    private let size: CGSize
    private weak var child: MeetingMenuPanel?

    private init(entries: [MenuEntry]) {
        let handlers = Handlers()
        let host = Host(rootView: MenuPanelView(entries: entries, handlers: handlers))
        let size = host.fittingSize
        self.size = size
        host.setFrameSize(size)
        host.setAccessibilityRole(.menu)
        host.setAccessibilityLabel("Menu")
        let panel = Panel(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        // Other apps record menus as shown; Greenroom's own capture excludes the
        // panel through the app-wide filter.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // The meeting window is dark whatever the system is (MeetingTheme).
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
        self.panel = panel
        handlers.open = { [weak self] entry, row in self?.openSubmenu(entry, row: row) }
        handlers.hover = { [weak self] entry in
            // Moving onto a plain row folds an open submenu away.
            if entry.kind != .submenu { self?.closeChild() }
        }
        handlers.pick = { entry in
            MeetingMenuPanel.closeAll()
            entry.action?()
        }
    }

    private func place(at origin: NSPoint, in area: CGRect) {
        let x = min(max(origin.x, area.minX), max(area.minX, area.maxX - size.width))
        let y = min(max(origin.y, area.minY), max(area.minY, area.maxY - size.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func closeChild() {
        guard let child else { return }
        child.closeChild()
        child.panel.orderOut(nil)
        MeetingMenuPanel.chain.removeAll { menu in menu === child }
        self.child = nil
    }

    /// Opens the entry's children beside its row (the row is in this panel's
    /// content space, origin top-left), to the left if the right is full.
    private func openSubmenu(_ entry: MenuEntry, row: CGRect) {
        closeChild()
        guard entry.enabled, !entry.children.isEmpty else { return }
        let sub = MeetingMenuPanel(entries: entry.children)
        let frame = panel.frame
        let area = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        var x = frame.maxX - 4
        if x + sub.size.width > area.maxX { x = frame.minX - sub.size.width + 4 }
        let top = frame.maxY - row.minY + 6
        sub.place(at: NSPoint(x: x, y: top - sub.size.height), in: area)
        child = sub
        MeetingMenuPanel.chain.append(sub)
        sub.panel.orderFrontRegardless()
    }
}

/// What the rows call back into; filled in once the panel exists.
@MainActor
private final class Handlers {
    var open: (MenuEntry, CGRect) -> Void = { _, _ in }
    var hover: (MenuEntry) -> Void = { _ in }
    var pick: (MenuEntry) -> Void = { _ in }
}

/// The rows. Dark, glass, menu-sized type; hover lights a row.
private struct MenuPanelView: View {
    let entries: [MenuEntry]
    let handlers: Handlers

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                switch entry.kind {
                case .separator:
                    Divider().padding(.vertical, 4).padding(.horizontal, 6)
                case .header:
                    Text(entry.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                case .item, .submenu:
                    MenuRow(entry: entry, handlers: handlers)
                }
            }
        }
        .padding(6)
        .frame(minWidth: 200, alignment: .leading)
        .fixedSize()
        .coordinateSpace(name: "menu")
        .greenroomGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

private struct MenuRow: View {
    let entry: MenuEntry
    let handlers: Handlers
    @State private var hovering = false
    @State private var frame = CGRect.zero

    var body: some View {
        Button {
            if entry.kind == .submenu { handlers.open(entry, frame) }
            else if entry.enabled { handlers.pick(entry) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(entry.checked ? 1 : 0)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.system(size: 13))
                    if let note = entry.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 300, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 16)
                if entry.kind == .submenu {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                } else if let combo = entry.shortcut {
                    Text(combo.glyphs).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(hovering && entry.enabled ? 0.14 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(entry.enabled ? 1 : 0.4)
        .onGeometryChange(for: CGRect.self) { proxy in proxy.frame(in: .named("menu")) } action: { new in frame = new }
        .onHover { inside in
            hovering = inside
            if inside {
                handlers.hover(entry)
                if entry.kind == .submenu { handlers.open(entry, frame) }
            }
        }
        .accessibilityLabel(entry.title)
        .accessibilityHint(entry.note ?? "")
        .accessibilityAddTraits(.isButton)
    }
}
