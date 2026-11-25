//
//  WindowShareController.swift
//  Greenroom
//
//  "Show to class" for one window, one mechanism for all of them. Greenroom's
//  windows are hidden from the picture of a shared display by default (the whole
//  app is excluded in StageScreenSource). The small eye in a window's title bar
//  lets the person show that window: it joins ShareVisibleWindows (the capture
//  excepts it from the exclusion, so it really is in the picture), its background
//  goes solid (WindowFrost). Off, it leaves the picture and goes back to frost.
//  Windows a layout places start on (LayoutPiece.defaultShowsToEveryone), the rest
//  off; the one place a choice is remembered is the layout
//  (LayoutPiece.showsToEveryone, applied by LayoutShareChoice).
//
//  The decisions (which windows offer it, the words, when it is available) are
//  ShareSwitchState / ShareableWindow in ShareVisibilityRules.swift (tested); this
//  file only draws and wires them. The Meeting view windows use the
//  same controller with buttons of their own (`addButton`).
//
import AppKit
import SwiftUI

@MainActor
final class WindowShareController: NSObject {
    private struct Entry { let button: NSButton; let pointSize: CGFloat; let showsTitle: Bool }

    /// One controller per window; the window is held weakly.
    private static var all: [ObjectIdentifier: WindowShareController] = [:]

    /// Posted whenever a window's switch (or the share kind) changes, for toolbar
    /// buttons drawn in SwiftUI.
    static let stateDidChange = Notification.Name("WindowShareControllerStateDidChange")

    /// The controller already attached to `window`, if any.
    static func existing(for window: NSWindow?) -> WindowShareController? {
        window.flatMap { all[ObjectIdentifier($0)] }
    }

    private weak var window: NSWindow?
    private(set) var isOn = false
    private var registeredNumber: Int?
    private var entries: [Entry] = []
    private let idleTint: NSColor
    private let mutedTint: NSColor
    private let markedTint: NSColor
    private var observers: [NSObjectProtocol] = []

    private init(window: NSWindow, idleTint: NSColor, mutedTint: NSColor, markedTint: NSColor) {
        self.window = window
        self.markedTint = markedTint
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
            idleTint: dark ? NSColor.white.withAlphaComponent(0.4) : .tertiaryLabelColor,
            mutedTint: dark ? NSColor.white.withAlphaComponent(0.25) : .quaternaryLabelColor,
            // Amber text/icons under 14px use --net-text on light (DESIGN.md).
            markedTint: dark ? MeetingTheme.netNS : NSColor(Brand.netText))
        all[ObjectIdentifier(window)] = controller
        if accessory { controller.addTitleAccessory() }
        return controller
    }

    private func addTitleAccessory() {
        guard let window else { return }
        let size: CGFloat = 24
        let button = ShowOnShareSwitch.make(size: size) { [weak self] in self?.toggle() }
        // The host is as tall as the whole title bar (a tab toolbar makes it taller
        // than 28pt) and keeps the eye in its vertical middle.
        let barHeight = max(28, window.frame.height - window.contentLayoutRect.height)
        let host = CentredHost(frame: NSRect(x: 0, y: 0, width: size + 12, height: barHeight))
        host.addSubview(button)
        let controller = NSTitlebarAccessoryViewController()
        controller.view = host
        controller.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(controller)
        addButton(button, pointSize: 11, showsTitle: false)
    }

    /// A switch someone else laid out (the view windows' title bar).
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

    /// The buttons, the registry and the backdrop follow
    /// the choice and what is being shared right now.
    func refresh() {
        guard let window else { return }
        let kind = ShareVisibleWindows.kind
        for entry in entries {
            ShowOnShareSwitch.apply(to: entry.button, on: isOn, kind: kind, pointSize: entry.pointSize,
                                    showsTitle: entry.showsTitle, idleTint: idleTint, mutedTint: mutedTint, markedTint: markedTint)
        }
        // Registered whenever the person has it on, so a change of share kind
        // needs no re-adding; the capture decides by kind (exceptionIDs).
        syncRegistry(window: window)
        let marked = ShowOnShare.marksWindow(on: isOn, kind: kind)
        WindowFrost.show(ShareVisibility(marked: marked).backdrop, in: window)
        NotificationCenter.default.post(name: Self.stateDidChange, object: window)
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
        if let window { WindowFrost.show(.frosted, in: window) }
        for entry in entries {
            ShowOnShareSwitch.apply(to: entry.button, on: false, kind: ShareVisibleWindows.kind, pointSize: entry.pointSize,
                                    showsTitle: entry.showsTitle, idleTint: idleTint, mutedTint: mutedTint, markedTint: markedTint)
        }
        NotificationCenter.default.post(name: Self.stateDidChange, object: window)
    }
}

/// Attach to a SwiftUI window's root view that has no frost of its own (Settings):
/// the window gets the same eye in its title bar.
struct ShareableWindowAnchor: NSViewRepresentable {
    final class Anchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                // Frost under the content, like every other hidden window; without
                // it the window stayed opaque however the eye was set.
                WindowFrost.install(in: window, solid: .windowBackgroundColor)
                _ = WindowShareController.attach(to: window, dark: false)
            }
        }
    }

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ anchor: Anchor, context: Context) {}
}

/// Keeps its one subview in the middle of its height.
private final class CentredHost: NSView {
    override func layout() {
        super.layout()
        guard let button = subviews.first else { return }
        button.frame.origin = NSPoint(x: 0, y: ((bounds.height - button.frame.height) / 2).rounded())
    }
}


/// What the layout says about each of Greenroom's own windows ("Show to
/// everyone" on a piece). Recorded when a layout is applied and used for a
/// window opened later (the chat opens at the join), and pushed to windows that
/// are already open.
@MainActor
enum LayoutShareChoice {
    /// A window the layout does not place stays hidden; a placed one follows its
    /// piece, which defaults to shown (LayoutPiece.defaultShowsToEveryone).
    static var meeting = false
    static var chat = false
    static var views: [MeetingView: Bool] = [:]

    static func view(_ view: MeetingView) -> Bool { views[view] ?? false }

    /// No layout runs: every window of Greenroom's goes back to "Only you". Called
    /// at Start with Start layout None and when a session ends, so a layout's
    /// choices never leak into a later session.
    static func reset() {
        meeting = false
        chat = false
        views = [:]
        ShareVisibleWindows.setHiddenApps([])
    }

    static func record(_ r: LayoutResolver.Result) {
        meeting = LayoutShareRule.startsShown(placedBy: r.meeting?.piece)
        chat = LayoutShareRule.startsShown(placedBy: r.chat?.piece)
        views = [:]
        for placed in r.views { if let v = placed.piece.kind.view { views[v] = LayoutShareRule.startsShown(placedBy: placed.piece) } }
        WindowShareController.existing(for: ChatWindowController.currentWindow)?.set(chat)
        WindowShareController.existing(for: ParticipantGridWindowController.meetingWindow)?.set(meeting)
        MeetingViewWindows.applyLayoutShare()
        // Other apps whose 📡 is off leave the display capture; every layout pass re-says it.
        ShareVisibleWindows.setHiddenApps(Visibility.hiddenAppIDs(pieces: r.apps.map(\.piece), target: .wholeScreen))
    }
}
