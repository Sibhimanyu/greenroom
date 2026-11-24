//
//  PresenceBubble.swift
//  Greenroom
//
//  The camera as a floating bubble on the presenter's own screen. Dragging or
//  resizing it moves the camera in the picture that goes to Zoom and the
//  recording, live. Ported from Recorditor's CameraBubbleController
//  (docs/recorditor-integration/).
//
//  The bubble is a control, not a capture source:
//   - The compositor still draws the camera. The bubble only reports where the
//     presenter put it (as StageLayout fractions, via PresenceGeometry).
//   - It is kept out of every capture. StageScreenSource excludes the whole
//     app and lets back in only the windows ShareVisibleWindows lists; this
//     panel is never registered there. Whether OTHER apps' captures (QuickTime,
//     Loom, OBS, a native Zoom share) see it is `sharingType`, set from
//     Settings -> Webcam -> "Show my camera bubble in other apps' recordings"
//     (PresenceRecorderRules): `.readOnly` by default, `.none` when off. Those
//     apps do not read our filter, so they need the bubble to be a real picture:
//     unmirrored, sharp at its on-screen pixel size, and with its hover chrome
//     shown only while it is being grabbed. Greenroom's own picture never has
//     the bubble twice: the filter keeps it out whatever sharingType says.
//   - The picture it shows is the compositor's own camera picture (effects and
//     cutout applied), handed over per frame; it opens no camera session.
//
import AppKit
import CoreImage
import QuartzCore
import SwiftUI

/// The live camera picture, throttled and shrunk for a small window.
final class PresenceFeed: @unchecked Sendable {
    /// Main thread. The picture is already mirrored (a self-view).
    var onPicture: ((CGImage) -> Void)?
    /// Crop to a centred square before showing (the Circle shape).
    var cropsToSquare: Bool {
        get { lock.withLock { _square } }
        set { lock.withLock { _square = newValue } }
    }
    /// Settings -> Webcam -> "Mirror my camera" (default on, like Recorditor and
    /// Zoom's "Mirror my video"): the presenter sees themselves as in a mirror.
    /// Everyone in the meeting and the recording get the unmirrored picture
    /// whatever this says. Read per frame, so flipping it shows at once.
    static let mirrorKey = "camera.mirrorSelfView"
    static var userMirrors: Bool {
        (UserDefaults.standard.object(forKey: mirrorKey) as? Bool) ?? true
    }
    /// What is really drawn: never mirrored while other apps can record the bubble.
    static var mirrorsSelfView: Bool {
        PresenceRecorderRules.effectiveMirror(userMirror: userMirrors,
                                              visibleToRecorders: PresenceRecorderRules.storedVisibleToRecorders)
    }
    /// Pixel width cap of the shown picture (PresenceRecorderRules.feedWidth).
    var maxWidth: CGFloat {
        get { lock.withLock { _maxWidth } }
        set { lock.withLock { _maxWidth = max(newValue, 1) } }
    }

    private let framesPerSecond = 30.0
    private var _maxWidth: CGFloat = PresenceRecorderRules.cheapFeedWidth
    private let queue = DispatchQueue(label: "greenroom.presence.feed", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var _square = false
    private var lastTaken: UInt64 = 0
    private var busy = false

    /// Any queue (the render queue). Returns quickly.
    func push(_ picture: CIImage) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let due = !busy && Double(now &- lastTaken) / 1e9 >= 1 / framesPerSecond
        if due { busy = true; lastTaken = now }
        let square = _square
        let maxWidth = _maxWidth
        lock.unlock()
        guard due else { return }
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            var image = picture
            var e = image.extent
            guard e.width > 1, e.height > 1 else { return }
            if square {
                let side = min(e.width, e.height)
                image = image.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
                e = image.extent
            }
            image = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            let s = min(1, maxWidth / e.width)
            if s < 1 { image = image.transformed(by: CGAffineTransform(scaleX: s, y: s)) }
            if Self.mirrorsSelfView {
                image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                    .translatedBy(x: -image.extent.width, y: 0))
            }
            guard let cg = context.createCGImage(image, from: image.extent) else { return }
            DispatchQueue.main.async { [weak self] in self?.onPicture?(cg) }
        }
    }
}

private final class PresencePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Bigger / Smaller animate the panel briefly.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.15 }
}

// MARK: Quick controls (hover strip)

/// What the strip shows and does. The bubble owns it; the coordinator fills it.
@MainActor
final class PresenceQuickModel: ObservableObject {
    @Published var shape: WebcamShape = .circle
    @Published var background: CameraBackground = .normal
    var onShape: ((WebcamShape) -> Void)?
    var onBackground: ((CameraBackground) -> Void)?
    var onSize: ((Int) -> Void)?
    /// Press (true) and release (false) on Bigger / Smaller: holding repeats.
    var onSizePress: ((Int, Bool) -> Void)?
    /// Blur and Image sit behind a person in a bubble shape; the Cutout and
    /// Presenter key the background out instead (same rule as Settings).
    var offersBackground: Bool { !shape.usesChromaKey }
    static let shapes: [WebcamShape] = [.square, .circle, .roundedRectangle, .cutout]
}

private struct PresenceQuickStrip: View {
    @ObservedObject var model: PresenceQuickModel
    @State private var pressed: Set<Int> = []

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PresenceQuickModel.shapes) { shape in
                button(shape.symbol, shape.label, selected: model.shape == shape) { model.onShape?(shape) }
            }
            if model.offersBackground {
                divider
                button("person.fill", "Your room", selected: model.background == .normal) { model.onBackground?(.normal) }
                button("drop.halffull", "Blur behind you", selected: model.background == .blur) { model.onBackground?(.blur) }
                button("photo.fill", "Picture behind you", selected: model.background == .image) { model.onBackground?(.image) }
            }
            divider
            sizeButton("minus.magnifyingglass", "Smaller", -1)
            sizeButton("plus.magnifyingglass", "Bigger", 1)
        }
        .padding(4)
        .greenroomGlass(in: Capsule())
        .fixedSize()
    }

    private var divider: some View {
        Rectangle().fill(.secondary.opacity(0.3)).frame(width: 1, height: 14).padding(.horizontal, 3)
    }

    /// Press steps at once; holding repeats; release settles. The bubble owns the timing.
    private func sizeButton(_ symbol: String, _ label: String, _ direction: Int) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.primary)
            .frame(width: 26, height: 26)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed.contains(direction) { pressed.insert(direction); model.onSizePress?(direction, true) } }
                .onEnded { _ in pressed.remove(direction); model.onSizePress?(direction, false) })
            .help(label)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.onSize?(direction) }
    }

    private func button(_ symbol: String, _ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(selected ? Brand.green : Color.primary)
                .frame(width: 26, height: 26)
                .background(selected ? Brand.green.opacity(0.18) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Hosts the strip: takes the first click on a non-activating panel and says
/// when the pointer is over it.
private final class PresenceStripHost: NSHostingView<PresenceQuickStrip> {
    var onHover: ((Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

@MainActor
final class PresenceBubble {
    /// The presenter moved or resized the bubble: the layout it now means.
    /// `final` is false for every step of a drag or resize (push to the
    /// compositor only) and true when it settles (persist).
    var onPlacement: ((StageLayout, Bool) -> Void)?
    let feed = PresenceFeed()
    let quick = PresenceQuickModel()

    private var panel: PresencePanel?
    private let clip = CALayer()
    // Hover affordance, drawn above the picture: a thin accent outline and four
    // corner handles. Opaque strokes, so they are also real hit pixels for the
    // window server. `hitRing` is the invisible-but-nonzero band (see styleClip).
    private let outline = CAShapeLayer()
    private let handles: [CALayer] = (0..<4).map { _ in CALayer() }
    private let hitRing = CAShapeLayer()
    private static let handleSize: CGFloat = 9
    private let interaction = PresenceBubbleInteractionView()
    private var geometry: PresenceGeometry?
    private var layout = StageLayout()
    private var aspect: CGFloat = 16.0 / 9.0
    private var interacting = false
    private var programmatic = false
    private var observers: [NSObjectProtocol] = []
    private var strip: PresencePanel?
    private var hoverBubble = false
    private var hoverStrip = false
    private var lingerItem: DispatchWorkItem?
    private var stripShown = false
    private var stripAbove = true
    private var repeatTimer: Timer?
    private var settleItem: DispatchWorkItem?
    private var settlePending = false
    private var pointerMonitor: Any?
    private var fadeItem: DispatchWorkItem?
    private var appliedVisible: Bool?
    private var defaultsObserver: NSObjectProtocol?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Shows the bubble over `geometry.display` where `layout` puts the camera,
    /// or moves it there. Call again whenever the layout, display or content
    /// rect changes; a drag in progress is never fought.
    func show(layout: StageLayout, geometry: PresenceGeometry) {
        // A drag owns the panel: nothing here may move it or touch its state.
        guard !interacting else { return }
        self.layout = layout
        self.geometry = geometry
        if quick.shape != layout.cameraShape { quick.shape = layout.cameraShape }
        feed.cropsToSquare = layout.cameraShape.cropsToSquare
        let panel = makePanelIfNeeded()
        styleClip(for: layout.cameraShape)
        let a = effectiveAspect
        let target = geometry.frame(for: layout.presenceBox, aspect: a)
        if abs(panel.frame.minX - target.minX) > 0.5 || abs(panel.frame.minY - target.minY) > 0.5
            || abs(panel.frame.width - target.width) > 0.5 || abs(panel.frame.height - target.height) > 0.5 {
            programmatic = true
            panel.setFrame(target, display: true)
            programmatic = false
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        startPointerWatch()
        updateClipCorners()
        if stripShown { positionStrip() }
    }

    func hide() {
        hoverBubble = false; hoverStrip = false
        repeatTimer?.invalidate(); repeatTimer = nil
        settle()
        hideStrip(animated: false)
        panel?.orderOut(nil)
        stopPointerWatch()
        updateHitBand()
    }

    /// Bigger (+1) or Smaller (-1) by one step (accessibility, single taps).
    func step(_ steps: Int) {
        resize(by: PresenceGeometry.sizeStep * Double(steps), animated: true)
        settle()
    }

    /// Press (true) steps once and, held past 0.35s, repeats every 0.12s;
    /// release (false) persists once.
    func press(_ direction: Int, down: Bool) {
        repeatTimer?.invalidate(); repeatTimer = nil
        guard down else { settle(); return }
        let amount = PresenceGeometry.sizeStep * Double(direction)
        resize(by: amount, animated: false)
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resize(by: amount, animated: false) }
                }
            }
        }
    }

    /// Scroll over the bubble: small steps, persisted once after a pause.
    private func scrolled(_ delta: Double, ended: Bool) {
        if delta != 0 { resize(by: delta, animated: false) }
        if ended { settle() } else { settleSoon() }
    }

    /// One size change, pushed to the compositor only (never persisted here).
    /// The edge nearest the strip stays put, and a strip the pointer is on
    /// never moves, so the next click lands on the same button.
    private func resize(by amount: Double, animated: Bool) {
        guard !interacting, let panel, let geometry else { return }
        let box = geometry.stepped(layout.presenceBox, aspect: Double(effectiveAspect), by: amount,
                                   anchor: stripAbove ? .top : .bottom)
        guard box != layout.presenceBox else { return }
        var placed = layout
        placed.apply(box)
        layout = placed
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let frozen = stripShown ? strip?.frame : nil
        programmatic = true
        // A child window follows its parent, so a held strip is put back after.
        panel.setFrame(geometry.frame(for: box, aspect: effectiveAspect), display: true,
                       animate: animated && !reduce && !hoverStrip)
        programmatic = false
        relayout()
        if hoverStrip, let frozen, let strip { if strip.frame != frozen { strip.setFrame(frozen, display: true) } }
        else { positionStrip() }
        settlePending = true
        onPlacement?(placed, false)
        settleSoon()
    }

    private func settleSoon() {
        settleItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.settle() }
        settleItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Persist the layout once.
    private func settle() {
        settleItem?.cancel(); settleItem = nil
        guard settlePending else { return }
        settlePending = false
        onPlacement?(layout, true)
    }

    // MARK: Strip

    private func makeStripIfNeeded() -> PresencePanel {
        if let strip { return strip }
        let host = PresenceStripHost(rootView: PresenceQuickStrip(model: quick))
        host.onHover = { [weak self] inside in self?.hoverStrip = inside; self?.updateStrip() }
        let created = PresencePanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                                    styleMask: [.nonactivatingPanel, .borderless],
                                    backing: .buffered, defer: false)
        created.isReleasedWhenClosed = false
        created.level = .floating
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.hidesOnDeactivate = false
        created.allowsToolTipsWhenApplicationIsInactive = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.sharingType = .none
        created.contentView = host
        created.alphaValue = 0
        strip = created
        return created
    }

    /// Hover over the bubble or the strip shows it; it lingers a moment after.
    private func updateStrip() {
        let wanted = (hoverBubble || hoverStrip) && !interacting && isVisible
        lingerItem?.cancel()
        if wanted {
            showStrip(reposition: !hoverStrip)
        } else if stripShown {
            let item = DispatchWorkItem { [weak self] in self?.hideStrip(animated: true) }
            lingerItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        }
    }

    private func showStrip(reposition: Bool = false) {
        if stripShown, hoverStrip { return }
        let strip = makeStripIfNeeded()
        positionStrip(creating: strip, reposition: reposition)
        guard !stripShown else { return }
        stripShown = true
        if let panel { panel.addChildWindow(strip, ordered: .above) }
        strip.orderFrontRegardless()
        fade(strip, to: 1) {}
    }

    private func hideStrip(animated: Bool) {
        lingerItem?.cancel()
        guard stripShown, let strip else { return }
        stripShown = false
        let finish = { [weak self, weak strip] in
            guard let strip, self?.stripShown == false else { return }
            self?.panel?.removeChildWindow(strip)
            strip.orderOut(nil)
        }
        if animated { fade(strip, to: 0, finish) } else { strip.alphaValue = 0; finish() }
    }

    private func fade(_ strip: NSPanel, to alpha: CGFloat, _ done: @escaping () -> Void) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            strip.alphaValue = alpha; done(); return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            strip.animator().alphaValue = alpha
        }, completionHandler: done)
    }

    /// Just above the bubble, centred; below it when there is no room above.
    /// While the pointer is on the strip it stays where it is (`reposition`
    /// overrides, once the pointer has left).
    private func positionStrip(creating given: PresencePanel? = nil, reposition: Bool = false) {
        guard let strip = given ?? strip, let panel else { return }
        if hoverStrip, !reposition, given == nil { return }
        let size = (strip.contentView as? PresenceStripHost)?.fittingSize ?? strip.frame.size
        let f = panel.frame
        let screen = NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(f), ib = b.frame.intersection(f)
            return ia.width * ia.height < ib.width * ib.height
        } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? f.insetBy(dx: -400, dy: -400)
        let gap: CGFloat = 4
        var y = f.maxY + gap
        if y + size.height > vis.maxY { y = f.minY - gap - size.height }
        if y < vis.minY { y = min(f.maxY - size.height - gap, vis.maxY - size.height) }
        let x = max(vis.minX, min(f.midX - size.width / 2, vis.maxX - size.width))
        let frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        stripAbove = y >= f.maxY
        guard strip.frame != frame else { return }
        if reposition, stripShown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                strip.animator().setFrame(frame, display: true)
            }
        } else {
            strip.setFrame(frame, display: true)
        }
    }

    // MARK: Visible to other apps' recordings

    private static func sharingType() -> NSWindow.SharingType {
        PresenceRecorderRules.sharing(visibleToRecorders: PresenceRecorderRules.storedVisibleToRecorders) == .readOnly
            ? .readOnly : .none
    }

    private var visibleToRecorders: Bool { PresenceRecorderRules.storedVisibleToRecorders }

    /// Applies the setting to the panel and the feed; called on every change.
    private func applyRecorderSetting() {
        guard let panel else { return }
        let visible = visibleToRecorders
        guard visible != appliedVisible else { return }
        appliedVisible = visible
        panel.sharingType = Self.sharingType()
        feed.maxWidth = PresenceRecorderRules.feedWidth(
            visibleToRecorders: visible, bubbleWidthPoints: panel.frame.width,
            backingScale: panel.backingScaleFactor)
        if !visible || !interacting { fadeItem?.cancel(); setAffordance(visible: PresenceRecorderRules.showsChrome(
            visibleToRecorders: visible, hovering: hoverBubble, interacting: interacting)) }
    }

    // MARK: Panel

    /// A circle is square; everything else follows the camera.
    private var effectiveAspect: CGFloat { layout.cameraShape.cropsToSquare ? 1 : aspect }

    private func makePanelIfNeeded() -> PresencePanel {
        if let panel { return panel }
        let created = PresencePanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 135),
                                    styleMask: [.nonactivatingPanel, .borderless],
                                    backing: .buffered, defer: false)
        created.isReleasedWhenClosed = false
        // One step under .floating: above normal windows, but under the control
        // bar and the other floating panels, so the camera never blocks their
        // clicks (owner, 2026-11-17).
        created.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        created.isOpaque = false
        created.backgroundColor = .clear
        // No window shadow: a Cutout is transparent, and AppKit would shadow
        // the person's silhouette.
        created.hasShadow = false
        created.hidesOnDeactivate = false
        created.allowsToolTipsWhenApplicationIsInactive = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Other apps' recordings see it unless the setting is off. Our own
        // capture never does (the filter excludes the app; file header).
        created.sharingType = Self.sharingType()

        let container = NSView(frame: created.contentRect(forFrameRect: created.frame))
        container.wantsLayer = true
        clip.masksToBounds = true
        clip.contentsGravity = .resizeAspectFill
        clip.frame = container.bounds
        clip.borderWidth = 0
        container.layer?.addSublayer(clip)
        // Hit band first (under the outline), then the hover outline and handles.
        hitRing.isHidden = true
        hitRing.fillRule = .evenOdd
        hitRing.fillColor = NSColor.black.withAlphaComponent(Self.hitAlpha).cgColor
        container.layer?.addSublayer(hitRing)
        outline.fillColor = nil
        outline.lineWidth = 1.5
        outline.opacity = 0
        container.layer?.addSublayer(outline)
        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: Self.handleSize, height: Self.handleSize)
            handle.cornerRadius = 2
            handle.borderWidth = 1.5
            handle.opacity = 0
            container.layer?.addSublayer(handle)
        }
        applyAccent()

        interaction.frame = container.bounds
        interaction.autoresizingMask = [.width, .height]
        interaction.aspect = { [weak self] in self?.effectiveAspect ?? 16.0 / 9.0 }
        interaction.widthRange = { [weak self] in
            guard let self, let geometry else { return 80...800 }
            return geometry.widthRange(for: layout.presenceBox, aspect: Double(effectiveAspect))
        }
        // Drags and resizes stay inside the shared display (the content, never the bars), so the bubble is always the
        // camera's rect (PresenceGeometry.cameraRect keeps the camera inside it).
        interaction.limit = { [weak self] in self?.geometry?.boundsOnScreen }
        interaction.flushBottom = { [weak self] in self?.layout.cameraShape == .cutout }
        interaction.onResize = { [weak self] frame in
            // The cheapest move there is: no redraw request, and a plain
            // origin change when only the position moved.
            guard let self, let panel else { return }
            if abs(frame.width - panel.frame.width) < 0.01, abs(frame.height - panel.frame.height) < 0.01 {
                panel.setFrameOrigin(frame.origin)
            } else {
                panel.setFrame(frame, display: false)
            }
            report(final: false)
        }
        interaction.onInteraction = { [weak self] begin in
            guard let self else { return }
            if begin {
                interacting = true
                fadeItem?.cancel()
                if visibleToRecorders { setAffordance(visible: true) }
                updateHitBand()
                hideStrip(animated: false)
            } else {
                interacting = false
                if visibleToRecorders { fadeChromeAfterInteraction() }
                updateHitBand()
                report(final: true)
                if let geometry { show(layout: layout, geometry: geometry) }
            }
        }
        interaction.onScroll = { [weak self] delta, ended in self?.scrolled(delta, ended: ended) }
        interaction.onHover = { [weak self] inside in
            guard let self else { return }
            hoverBubble = inside
            updateStrip()
            // The accent outline and handles say "grab me"; idle stays clean.
            // Visible to recorders: not on hover (they would record it).
            setAffordance(visible: PresenceRecorderRules.showsChrome(
                visibleToRecorders: visibleToRecorders, hovering: inside, interacting: interacting))
        }
        container.addSubview(interaction)
        created.contentView = container

        feed.onPicture = { [weak self] image in
            guard let self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            clip.contents = image
            CATransaction.commit()
            let newAspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
            if abs(newAspect - aspect) > 0.01, !layout.cameraShape.cropsToSquare {
                aspect = newAspect
                if !interacting, let geometry { show(layout: layout, geometry: geometry) }
            }
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: created, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.stripShown { self.positionStrip() }
                if !self.interacting { self.report(final: true) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: created, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.relayout()
                if !self.interacting { self.report(final: true) }
            }
        })
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyRecorderSetting() }
        }
        panel = created
        applyRecorderSetting()
        return created
    }

    private func relayout() {
        guard let panel, let bounds = panel.contentView?.bounds else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clip.frame = bounds
        CATransaction.commit()
        updateClipCorners()
        // Sharp at the real on-screen size while recorders can see it.
        feed.maxWidth = PresenceRecorderRules.feedWidth(
            visibleToRecorders: visibleToRecorders, bubbleWidthPoints: bounds.width,
            backingScale: panel.backingScaleFactor)
    }

    private static let hitAlpha: CGFloat = 0.02

    /// The accent follows the token (AccentColor), and the appearance.
    private func applyAccent() {
        let accent = (NSColor(named: "AccentColor") ?? .controlAccentColor).cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.strokeColor = accent
        for handle in handles {
            handle.borderColor = accent
            handle.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
        CATransaction.commit()
    }

    /// Recorded bubble: the chrome lingers for the fade after the pointer lets
    /// go (unless it is still hovering a visible-to-nobody bubble), then goes.
    private func fadeChromeAfterInteraction() {
        fadeItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            setAffordance(visible: PresenceRecorderRules.showsChrome(
                visibleToRecorders: visibleToRecorders, hovering: hoverBubble, interacting: interacting))
        }
        fadeItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + PresenceRecorderRules.chromeFade, execute: item)
    }

    private func setAffordance(visible: Bool) {
        applyAccent()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduce ? 0 : 0.12)
        if reduce { CATransaction.setDisableActions(true) }
        let value: Float = visible ? 1 : 0
        outline.opacity = value
        handles.forEach { $0.opacity = value }
        CATransaction.commit()
    }

    /// Outline, handles and hit band follow the panel's size and the shape.
    private func layoutAffordance() {
        guard let bounds = panel?.contentView?.bounds else { return }
        let radius = clip.cornerRadius
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Stroke inside the edge so it is never clipped by the panel.
        let inset = bounds.insetBy(dx: 0.75, dy: 0.75)
        outline.frame = bounds
        outline.path = CGPath(roundedRect: inset, cornerWidth: max(0, radius - 0.75),
                              cornerHeight: max(0, radius - 0.75), transform: nil)
        // Handles sit on the corners; on a rounded shape, on the arc's diagonal.
        let h = Self.handleSize
        let along = max(radius * (1 - 0.7071), h / 2 + 1)
        let xs = [along, bounds.maxX - along, along, bounds.maxX - along]
        let ys = [bounds.maxY - along, bounds.maxY - along, along, along]
        for (i, handle) in handles.enumerated() { handle.position = CGPoint(x: xs[i], y: ys[i]) }
        // The band the pointer must find: 14pt of near-invisible pixels around
        // the edge, so a Cutout's transparent corners still receive the mouse.
        let band: CGFloat = 14
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(bounds.insetBy(dx: min(band, bounds.width / 2), dy: min(band, bounds.height / 2)))
        hitRing.frame = bounds
        hitRing.path = path
        CATransaction.commit()
        updateHitBand()
    }

    /// The edge band is drawn only while the pointer is over the bubble (see
    /// PresenceHitBand). A global mouse-moved monitor sees the pointer arrive
    /// even though a transparent window gets no events there.
    private func updateHitBand() {
        let over = panel.map { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) } ?? false
        let drawn = PresenceHitBand.isDrawn(isCutout: layout.cameraShape == .cutout,
                                            pointerOverBubble: over, interacting: interacting)
        guard hitRing.isHidden != !drawn else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hitRing.isHidden = !drawn
        CATransaction.commit()
    }

    private func startPointerWatch() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHitBand() }
        }
    }

    private func stopPointerWatch() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
    }

    private func styleClip(for shape: WebcamShape) {
        updateClipCorners()
        // A Cutout is transparent around the person, and the window server
        // sends clicks and hover through (near-)transparent pixels: a 1/255
        // whole-rect tint did not bring the edge cursors. 3% over the whole
        // rect showed as a box (owner, 2026-11-17). So the whole rect keeps the
        // 1/255 tint (move anywhere) and only the 14pt edge band gets 2% (the
        // hitRing), where resize is grabbed; the hover outline and handles are
        // opaque. The other shapes are grabbed by their visible shape.
        let tint: CGColor? = shape == .cutout ? NSColor.black.withAlphaComponent(1.0 / 255.0).cgColor : nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        panel?.contentView?.layer?.backgroundColor = tint
        CATransaction.commit()
    }

    private func updateClipCorners() {
        let size = clip.bounds.size
        let radius: CGFloat
        switch layout.cameraShape {
        case .circle: radius = min(size.width, size.height) / 2
        case .roundedRectangle: radius = min(size.width, size.height) * 0.18
        default: radius = 0
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clip.cornerRadius = radius
        CATransaction.commit()
        layoutAffordance()
    }

    /// Turns the panel's frame into the layout it now means and reports it.
    private func report(final: Bool) {
        guard !programmatic, let panel, let geometry else { return }
        var placed = layout
        placed.apply(geometry.layout(applying: panel.frame, to: layout.presenceBox, aspect: Double(effectiveAspect)))
        layout = placed
        onPlacement?(placed, final)
    }
}

extension StageLayout {
    var presenceBox: PresenceBox {
        PresenceBox(widthFraction: widthFraction, rightInset: rightInset, bottomInset: bottomInset,
                    cutoutHeightFraction: cutoutHeightFraction, cutoutRightInset: cutoutRightInset,
                    isCutout: cameraShape == .cutout)
    }

    mutating func apply(_ box: PresenceBox) {
        widthFraction = box.widthFraction
        rightInset = box.rightInset
        bottomInset = box.bottomInset
        cutoutHeightFraction = box.cutoutHeightFraction
        cutoutRightInset = box.cutoutRightInset
    }

    /// The look has a box the presenter can move. Presenter and the full-frame
    /// talking head have a fixed picture, so nothing is placed.
    var isPresencePlaceable: Bool { showsContent && showsCamera && cameraShape != .presenterLarge }
}
