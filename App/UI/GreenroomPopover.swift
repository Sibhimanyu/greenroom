//
//  GreenroomPopover.swift
//
//  Greenroom's one popover, drawn by us. It always hangs below its button and
//  never changes side. A SwiftUI `.popover` is an NSPopover, and NSPopover
//  re-places itself whenever its content size changes and no longer fits, so
//  a popup that grows (a toggle that reveals a slider) jumped above its
//  button. This is a child panel of the anchor's window instead: its top is
//  fixed under the anchor, its height is the content's ideal height capped to
//  the room below (the content scrolls past that), and it only ever grows
//  downward. Never use a bare `.popover` for a button.
//
//  Environment: the content is a closure, so what it captures comes along
//  (objects, bindings). Nothing here forwards the call site's
//  `@EnvironmentObject`s (SwiftUI has no way to); a panel that needs one must
//  capture it or take it as a parameter. The panel's appearance is the anchor
//  window's, and the brand tint is applied here.
//
import AppKit
import SwiftUI

extension View {
    func greenroomPopover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(PopoverAnchor(isPresented: isPresented, content: { AnyView(content()) }))
    }
}

// MARK: - Anchor (the view the popup hangs from)

private struct PopoverAnchor: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: () -> AnyView

    func makeNSView(context: Context) -> AnchorView { AnchorView() }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.binding = $isPresented
        if !isPresented {
            view.closedWhileTrue = false
            PopoverController.shared.dismiss(anchor: view)
        } else if !view.closedWhileTrue {
            PopoverController.shared.present(anchor: view, content: content())
        }
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {
        PopoverController.shared.dismiss(anchor: view)
    }
}

final class AnchorView: NSView {
    var binding: Binding<Bool>?
    /// The popup was closed by us (click outside, Escape...) and the binding
    /// has not caught up yet; do not reopen on the next view update.
    var closedWhileTrue = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { PopoverController.shared.dismiss(anchor: self) }
    }

    override func layout() {
        super.layout()
        PopoverController.shared.reposition(anchor: self)
    }

    func closeBinding() {
        let binding = binding
        DispatchQueue.main.async { binding?.wrappedValue = false }
    }
}

// MARK: - Controller (one open at a time)

@MainActor
private final class PopoverController {
    static let shared = PopoverController()

    private static let arrowHeight: CGFloat = 7
    private static let arrowWidth: CGFloat = 16
    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 12
    static let radius: CGFloat = 16
    /// Transparent room round the glass (sides, bottom) for its drawn shadow.
    static let shadowPad: CGFloat = 14

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private final class Host: NSHostingView<PopoverRoot> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private weak var anchor: AnchorView?
    private weak var anchorWindow: NSWindow?
    private var panel: Panel?
    private var host: Host?
    private let model = PopoverModel()
    private var monitors: [Any] = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var shown = false

    /// The anchor an outside click just closed. While Greenroom is inactive a
    /// press on the anchor reaches the global monitor first and closes the
    /// popup, and then the button's own action would open it again. Within a
    /// moment, that press is the toggle (same rule as MeetingMenuPanel).
    private weak var dismissedAnchor: AnchorView?
    private var dismissedAt = Date.distantPast

    private func justDismissed(_ view: AnchorView) -> Bool {
        defer { dismissedAnchor = nil }
        return dismissedAnchor === view && Date().timeIntervalSince(dismissedAt) < 0.5
    }

    // MARK: Present, update, dismiss

    func present(anchor view: AnchorView, content: AnyView) {
        if anchor === view, panel != nil {
            host?.rootView = PopoverRoot(model: model, content: content)
            return
        }
        guard let window = view.window, view.bounds.width > 0 else { return }
        if justDismissed(view) {
            view.closedWhileTrue = true
            view.closeBinding()
            return
        }
        closeCurrent(reason: .replaced)

        anchor = view
        anchorWindow = window
        shown = false
        model.reset()
        model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        model.onIdealChange = { [weak self] in self?.layout() }

        let host = Host(rootView: PopoverRoot(model: model, content: content))
        // The hosting view must not size or constrain the window from its
        // content: it grew the panel past the room below, so the scroll view
        // thought everything fitted. `layout()` is the only thing that sizes.
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.isOpaque = false
        host.setAccessibilityRole(.popover)
        let panel = Panel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // the shadow is drawn in SwiftUI, following the shape
        panel.appearance = window.effectiveAppearance
        panel.contentView = host
        panel.alphaValue = 0
        self.host = host
        self.panel = panel

        layout()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        watch(window)
    }

    func dismiss(anchor view: AnchorView) {
        guard anchor === view else { return }
        closeCurrent(reason: .binding)
    }

    private enum Reason { case binding, user, replaced }

    private func closeCurrent(reason: Reason) {
        guard let panel else { return }
        let wasKey = panel.isKeyWindow
        let anchorView = anchor
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for item in observers { item.center.removeObserver(item.token) }
        observers = []
        anchorWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        host = nil
        anchor = nil
        shown = false
        if reason != .binding, let anchorView {
            anchorView.closedWhileTrue = true
            anchorView.closeBinding()
        }
        if wasKey { anchorWindow?.makeKey() }
        anchorWindow = nil
    }

    func reposition(anchor view: AnchorView) {
        guard anchor === view else { return }
        layout()
    }

    // MARK: Geometry (the top never moves; only the height and width change)

    private func layout() {
        guard let panel, let anchor, let window = anchor.window else { return }
        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // The screen the anchor's window is on (visibleFrame: no Dock, no menu bar).
        let screen = window.screen
            ?? NSScreen.screens.first { $0.frame.contains(CGPoint(x: target.midX, y: target.midY)) }
            ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let ideal = model.ideal
        let ready = ideal.width > 0 && ideal.height > 0
        let placed = PopoverPlacement.frame(
            anchor: target, contentSize: ideal, visible: area,
            gap: Self.gap, margin: Self.margin, arrowHeight: Self.arrowHeight,
            arrowEdge: Self.radius + Self.arrowWidth / 2 + 2, shadowPad: Self.shadowPad)

        // Publish only real changes: every assignment re-renders the root, and
        // a re-render while the owner scrolls must not touch the scroll view.
        if model.bodySize != placed.bodySize { model.bodySize = placed.bodySize }
        if abs(model.arrowX - placed.arrowX) > 0.5 { model.arrowX = placed.arrowX }
        let frame = placed.panelFrame
        if abs(panel.frame.minX - frame.minX) > 0.5 || abs(panel.frame.minY - frame.minY) > 0.5
            || abs(panel.frame.width - frame.width) > 0.5 || abs(panel.frame.height - frame.height) > 0.5 {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        if ready, !shown {
            shown = true
            model.appeared = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = model.reduceMotion ? 0.001 : 0.14
                panel.animator().alphaValue = 1
            }
        }
    }

    // MARK: Dismissal sources

    private func owns(_ window: NSWindow?) -> Bool {
        guard let window, let panel else { return false }
        if window === panel || window.parent === panel { return true }
        // Menus and pickers opened from inside the content.
        return window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
    }

    private func watch(_ window: NSWindow) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dismissedAnchor = self.anchor
                self.dismissedAt = Date()
                self.closeCurrent(reason: .user)
            }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.owns(event.window) else { return }
                // A press on the anchor is the toggle: the button's own action closes it.
                if let anchor = self.anchor, event.window === anchor.window,
                   anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
                self.closeCurrent(reason: .user)
            }
            return event
        }) { monitors.append(local) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, let self, self.panel != nil else { return event }
            MainActor.assumeIsolated { self.closeCurrent(reason: .user) }
            return nil
        }) { monitors.append(local) }

        let space = NSWorkspace.shared.notificationCenter
        observers.append((space, space.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.closeCurrent(reason: .user) } }))
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append((center, center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let gone = note.object as? NSWindow else { return }
                    if note.name == NSWindow.didChangeOcclusionStateNotification, gone.isVisible { return }
                    self.closeCurrent(reason: .user)
                }
            }))
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                     NSWindow.didChangeScreenNotification] {
            observers.append((center, center.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.layout() }
            }))
        }
    }
}

// MARK: - SwiftUI side

@MainActor
private final class PopoverModel: ObservableObject {
    /// The content's own ideal size, measured live.
    @Published var ideal = CGSize.zero
    /// The visible body after the room cap (height) and screen clamp (width).
    @Published var bodySize = CGSize(width: 320, height: 200)
    @Published var arrowX: CGFloat = 40
    @Published var appeared = false
    var reduceMotion = false
    var onIdealChange: () -> Void = {}

    func reset() {
        ideal = .zero
        appeared = false
    }

    func measured(_ size: CGSize) {
        guard abs(size.width - ideal.width) > 0.5 || abs(size.height - ideal.height) > 0.5 else { return }
        ideal = size
        onIdealChange()
    }
}

private struct PopoverRoot: View {
    @ObservedObject var model: PopoverModel
    let content: AnyView

    var body: some View {
        let shape = PopoverShape(arrowX: model.arrowX)
        ScrollView {
            content
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.measured($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollContentBackground(.hidden)
        .frame(width: model.bodySize.width, height: model.bodySize.height)
        .clipShape(RoundedRectangle(cornerRadius: PopoverController.radius, style: .continuous))
        .frame(width: model.bodySize.width, height: model.bodySize.height + PopoverShape.arrowHeight, alignment: .bottom)
        .greenroomGlass(in: shape)
        .shadow(color: .black.opacity(0.22), radius: 9, y: 3)
        .padding(.horizontal, PopoverController.shadowPad)
        .padding(.bottom, PopoverController.shadowPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .tint(Brand.green)
        .scaleEffect(model.appeared || model.reduceMotion ? 1 : 0.98, anchor: .top)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.14), value: model.appeared)
    }
}

/// A rounded body with a small notch on top pointing up at the anchor.
private struct PopoverShape: InsettableShape {
    var arrowX: CGFloat
    var insetAmount: CGFloat = 0
    static let arrowHeight: CGFloat = 7
    static let arrowWidth: CGFloat = 16

    func inset(by amount: CGFloat) -> PopoverShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + Self.arrowHeight,
                          width: rect.width, height: rect.height - Self.arrowHeight)
            .insetBy(dx: insetAmount, dy: insetAmount)
        var path = RoundedRectangle(cornerRadius: PopoverController.radius, style: .continuous).path(in: body)
        var arrow = Path()
        let half = Self.arrowWidth / 2
        arrow.move(to: CGPoint(x: arrowX - half, y: body.minY + 1))
        arrow.addLine(to: CGPoint(x: arrowX, y: rect.minY + insetAmount))
        arrow.addLine(to: CGPoint(x: arrowX + half, y: body.minY + 1))
        arrow.closeSubpath()
        path = path.union(arrow)
        return path
    }
}
