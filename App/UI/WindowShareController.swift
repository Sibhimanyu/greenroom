//
//  WindowShareController.swift
//  Greenroom
//
//  "Show to class" for one window, one mechanism for all of them. Greenroom's
//  windows are hidden from the picture of a shared display by default (the whole
//  app is excluded in StageScreenSource). The small eye in a window's title bar
//  lets the person show that window: it joins ShareVisibleWindows (the capture
//  excepts it from the exclusion, so it really is in the picture), its background
//  goes solid (WindowFrost) and it gets the amber edge. Off, it leaves the picture,
//  goes back to frost and loses the edge. Off every launch; never remembered.
//
//  The decisions (which windows offer it, the words, when it is available) are
//  ShareSwitchState / ShareableWindow in ShareVisibilityRules.swift (tested); this
//  file only draws and wires them. The Meeting view windows and the Mini use the
//  same controller with buttons of their own (`addButton`).
//
import AppKit
import SwiftUI

@MainActor
final class WindowShareController: NSObject {
    private struct Entry { let button: NSButton; let pointSize: CGFloat; let showsTitle: Bool }

    /// One controller per window; the window is held weakly.
    private static var all: [ObjectIdentifier: WindowShareController] = [:]

    private weak var window: NSWindow?
    private(set) var isOn = false
    private var registeredNumber: Int?
    private var border: ShareBorderOverlay?
    private var entries: [Entry] = []
    private let announcer = ShareVisibilityAnnouncer()
    private let idleTint: NSColor
    private let mutedTint: NSColor
    private var observers: [NSObjectProtocol] = []

    private init(window: NSWindow, idleTint: NSColor, mutedTint: NSColor) {
        self.window = window
        self.idleTint = idleTint
        self.mutedTint = mutedTint
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ShareVisibleWindows.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        for name in [NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowClosed() }
            })
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.border?.sync() }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: Attaching

    /// Gives `window` the switch (once; calling again returns the same controller).
    /// `accessory`: put the small eye in the title bar's trailing side. The view
    /// windows pass false and add their own buttons.
    @discardableResult
    static func attach(to window: NSWindow, dark: Bool, accessory: Bool = true) -> WindowShareController {
        all = all.filter { $0.value.window != nil }
        if let existing = all[ObjectIdentifier(window)] { return existing }
        let controller = WindowShareController(
            window: window,
            idleTint: dark ? .white : .secondaryLabelColor,
            mutedTint: dark ? MeetingTheme.secondaryTextNS : .tertiaryLabelColor)
        all[ObjectIdentifier(window)] = controller
        if accessory { controller.addTitleAccessory() }
        return controller
    }

    private func addTitleAccessory() {
        guard let window else { return }
        let size: CGFloat = 24
        let button = ShowOnShareSwitch.make(size: size) { [weak self] in self?.toggle() }
        button.frame = NSRect(x: 0, y: 2, width: size, height: size)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: size + 12, height: 28))
        host.addSubview(button)
        let controller = NSTitlebarAccessoryViewController()
        controller.view = host
        controller.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(controller)
        addButton(button, pointSize: 12, showsTitle: false)
    }

    /// A switch someone else laid out (the view windows' title bar, the Mini's strip).
    func addButton(_ button: NSButton, pointSize: CGFloat, showsTitle: Bool) {
        entries.append(Entry(button: button, pointSize: pointSize, showsTitle: showsTitle))
        refresh()
    }

    // MARK: State

    func toggle() { set(!isOn) }

    func set(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        refresh()
    }

    /// The buttons, the registry, the border, the backdrop and the island follow
    /// the choice and what is being shared right now.
    func refresh() {
        guard let window else { return }
        let kind = ShareVisibleWindows.kind
        for entry in entries {
            ShowOnShareSwitch.apply(to: entry.button, on: isOn, kind: kind, pointSize: entry.pointSize,
                                    showsTitle: entry.showsTitle, idleTint: idleTint, mutedTint: mutedTint)
        }
        // Registered whenever the person has it on, so a change of share kind
        // needs no re-adding; the capture decides by kind (exceptionIDs).
        syncRegistry(window: window)
        let marked = ShowOnShare.marksWindow(on: isOn, kind: kind)
        if marked, border == nil { border = ShareBorderOverlay(parent: window) }
        border?.show(marked)
        WindowFrost.show(ShareVisibility(marked: marked).backdrop, in: window)
        announcer.update(marked: marked)
    }

    private func syncRegistry(window: NSWindow) {
        let number: Int? = isOn && window.windowNumber > 0 ? window.windowNumber : nil
        if registeredNumber != number {
            if let old = registeredNumber { ShareVisibleWindows.remove(old) }
            registeredNumber = number
            if let number { ShareVisibleWindows.add(number) }
        }
    }

    /// Closing puts it back to hidden: the choice is for this showing only.
    private func windowClosed() {
        isOn = false
        if let old = registeredNumber { ShareVisibleWindows.remove(old) }
        registeredNumber = nil
        border?.close()
        border = nil
        if let window { WindowFrost.show(.frosted, in: window) }
        for entry in entries {
            ShowOnShareSwitch.apply(to: entry.button, on: false, kind: ShareVisibleWindows.kind, pointSize: entry.pointSize,
                                    showsTitle: entry.showsTitle, idleTint: idleTint, mutedTint: mutedTint)
        }
        announcer.update(marked: false)
    }
}

/// Attach to a SwiftUI window's root view that has no frost of its own (Settings):
/// the window gets the same eye in its title bar.
struct ShareableWindowAnchor: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated { _ = WindowShareController.attach(to: window, dark: false) }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ anchor: Anchor, context: Context) {}
}
