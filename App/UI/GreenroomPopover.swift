//
//  GreenroomPopover.swift
//
//  Greenroom's one popover, built the way AppKit builds its own. It always
//  hangs below its button and never changes side. A SwiftUI `.popover` is an
//  NSPopover, and NSPopover re-places itself whenever its content size changes
//  and no longer fits, so a popup that grows (a toggle that reveals a slider)
//  jumped above its button. Never use a bare `.popover` for a button.
//
//  Structure (the panel frame is exactly the visible rounded body):
//    Panel           borderless NSPanel, child of the anchor's window; clear and
//                    non-opaque, `hasShadow` on: the WINDOW shadow, which macOS
//                    derives from the drawn pixels, so it follows the rounded
//                    shape. `invalidateShadow()` after every resize.
//      Container     layer-backed, continuous corner radius, masksToBounds
//        Glass       `GreenroomGlassAppKit.makeBacking` (NSGlassEffectView on 26)
//          Scroll    NSScrollView: overlay scroller, elastic, 8 pt insets
//            Document flipped view holding the NSHostingView of the content
//  Scrolling is pure AppKit: moving the clip view never touches SwiftUI. The
//  content is measured (the hosting view's fitting size) only when SwiftUI
//  says its ideal size changed, on the next run-loop turn; panel height =
//  min(content + insets, room below), from `PopoverPlacement`.
//
//  Key window: the panel takes key (so Escape and the first scroll go to it)
//  only when Greenroom is already active and the anchor's window is key, the
//  normal case of a click in our own window. It never activates the app: an
//  activation over another app's full-screen desktop drags windows or jumps
//  Spaces (1.8.3, MeetingMenuPanel). Closing hands key back to the anchor's
//  window.
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

    private static let gap: CGFloat = 8
    private static let margin: CGFloat = 12
    private static let radius: CGFloat = 16
    /// Room above and below the scrolling content (scroll view content insets).
    private static let inset: CGFloat = 8

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    /// The hosting view tells us when SwiftUI's ideal size changes; that is
    /// the only time the panel is measured again.
    private final class Host: NSHostingView<AnyView> {
        var onIdealChange: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            onIdealChange()
        }
        #if DEBUG
        override func layout() {
            PopoverDebug.layoutPasses += 1
            let t = CACurrentMediaTime(); super.layout(); PopoverDebug.layoutTime += CACurrentMediaTime() - t
        }
        #endif
    }

    private final class Scroll: NSScrollView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private final class Document: NSView {
        override var isFlipped: Bool { true }
    }

    private weak var anchor: AnchorView?
    private weak var anchorWindow: NSWindow?
    private var panel: Panel?
    private var host: Host?
    private var scroll: Scroll?
    /// The content's ideal size plus the vertical insets; zero until measured.
    private var ideal = CGSize.zero
    private var measurePending = false
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

    private static func root(_ content: AnyView) -> AnyView {
        AnyView(PopoverRoot(content: content))
    }

    // MARK: Present, update, dismiss

    func present(anchor view: AnchorView, content: AnyView) {
        if anchor === view, panel != nil {
            host?.rootView = Self.root(content)
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
        ideal = .zero

        let host = Host(rootView: Self.root(content))
        // The hosting view never sizes the window or itself: `measure()` and
        // `layout()` do, so the scroll view knows what does not fit.
        host.sizingOptions = [.intrinsicContentSize]
        // No safe area: with one, every scroll step re-derived it against the
        // window and laid the content out again (measured: 4x the passes).
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.setAccessibilityRole(.popover)
        host.onIdealChange = { [weak self] in self?.scheduleMeasure() }

        let document = Document()
        document.addSubview(host)

        let scroll = Scroll()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Self.inset, left: 0, bottom: Self.inset, right: 0)
        scroll.contentView.drawsBackground = false
        scroll.documentView = document

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.radius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        let glass = GreenroomGlassAppKit.makeBacking(cornerRadius: Self.radius, content: scroll)
        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)

        let panel = Panel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        // Stays on the anchor window's Space as its child; never joins all Spaces.
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        GreenroomGlassAppKit.prepare(panel)
        panel.hasShadow = true
        panel.appearance = window.effectiveAppearance
        panel.contentView = container
        panel.alphaValue = 0
        self.host = host
        self.scroll = scroll
        self.panel = panel

        measure()
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        if NSApp.isActive && window.isKeyWindow { panel.makeKey() }
        #if DEBUG
        NSLog("greenroomPopover: shown, panel.isKeyWindow=%@ (app active %@)",
              "\(panel.isKeyWindow)", "\(NSApp.isActive)")
        #endif
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
        scroll = nil
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

    // MARK: Measure (only when the content's ideal size changes)

    private func scheduleMeasure() {
        guard !measurePending else { return }
        measurePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurePending = false
            self.measure()
        }
    }

    private func measure() {
        guard let host else { return }
        let fit = host.fittingSize
        let size = CGSize(width: ceil(fit.width), height: ceil(fit.height) + 2 * Self.inset)
        if abs(size.width - ideal.width) > 0.5 || abs(size.height - ideal.height) > 0.5 {
            ideal = size
        }
        layout()
    }

    // MARK: Geometry (the top never moves; only the height and width change)

    private func layout() {
        guard let panel, let host, let scroll, let anchor, let window = anchor.window else { return }
        let target = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // The screen the anchor's window is on (visibleFrame: no Dock, no menu bar).
        let screen = window.screen
            ?? NSScreen.screens.first { $0.frame.contains(CGPoint(x: target.midX, y: target.midY)) }
            ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let ready = ideal.width > 0 && ideal.height > 0
        let frame = PopoverPlacement.frame(anchor: target, contentSize: ideal, visible: area,
                                           gap: Self.gap, margin: Self.margin).panelFrame

        let docSize = CGSize(width: frame.width, height: max(0, ideal.height - 2 * Self.inset))
        if host.frame.size != docSize {
            host.frame = CGRect(origin: .zero, size: docSize)
            scroll.documentView?.frame = host.frame
        }
        if abs(panel.frame.minX - frame.minX) > 0.5 || abs(panel.frame.minY - frame.minY) > 0.5
            || abs(panel.frame.width - frame.width) > 0.5 || abs(panel.frame.height - frame.height) > 0.5 {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        if ready, !shown {
            shown = true
            panel.invalidateShadow()
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduce ? 0.001 : 0.14
                panel.animator().alphaValue = 1
            } completionHandler: { [weak panel] in
                // The shadow is taken from what is drawn: take it again once opaque.
                MainActor.assumeIsolated { panel?.invalidateShadow() }
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

/// The content at its ideal size on both axes, drawn from the top left.
private struct PopoverRoot: View {
    let content: AnyView
    var body: some View {
        #if DEBUG
        let _ = PopoverDebug.bodyPasses += 1
        #endif
        content.fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .tint(Brand.green)
    }
}

#if DEBUG
/// Work the open popup's SwiftUI content does, for the tour's `popupScroll`:
/// hosting-view layout passes (and their time) and root body evaluations.
@MainActor enum PopoverDebug {
    static var layoutPasses = 0
    static var layoutTime: Double = 0
    static var bodyPasses = 0
}
#endif
