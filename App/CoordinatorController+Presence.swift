//
//  CoordinatorController+Presence.swift
//  Greenroom
//
//  Wires the presence bubble (App/UI/PresenceBubble.swift) to the stage.
//
//  Shown while the camera is on during a class or a solo recording, over the
//  display being shared, at the placement the layout gives. Hidden otherwise.
//  Dragging it writes the new placement into the same defaults the Settings
//  layout uses and pushes it to the compositor for the next frame.
//
//  Talking head (nothing shared) has no bubble: the camera fills the whole
//  picture there, so there is no box to place and a bubble over the meeting
//  window would be a control that moves nothing. The look is not placeable
//  (`isPresencePlaceable`) and the panel stays hidden.
//
//  When it runs. `objectWillChange` fires BEFORE a property changes, so the
//  refresh is queued a short beat later (it then reads the new values) and a
//  burst of changes makes one run (at most about 7 a second). The coordinator
//  publishes only discrete state (about 85 @Published fields: flags, counts,
//  the upload fraction), never per-frame pictures or meter levels, so bursts
//  are short. A timer covers what is not published: 1 s normally, 4 Hz while a
//  window or app share is up (the window can move), and a screen-parameters
//  notification covers a display being plugged, unplugged or resized.
//
//  What the bubble is measured against: where the renderer last drew the
//  shared content (canvas pixels) and the real frame of what is captured (the
//  display, or the window). Without a drawn rect there is nothing honest to
//  map to, so the bubble waits instead of guessing "the display fills the
//  canvas" (wrong for any display that is not 16:9).
//
import AppKit
import Combine

extension CoordinatorController {
    func startPresenceBubble() {
        presenceBubble.onPlacement = { [weak self] layout, final in
            // A drag step only moves the compositor's camera: no @Published
            // write, no defaults, so SwiftUI stays out of the way. It settles
            // once, when the mouse is released.
            if final { self?.applyPresencePlacement(layout) } else { self?.stage?.updatePlacement(layout) }
        }
        let quick = presenceBubble.quick
        quick.onShape = { [weak self] shape in
            self?.webcamShape = shape
            self?.requestShapeApply()
        }
        quick.onBackground = { [weak self] mode in self?.cameraBackground = mode }
        quick.onSizePress = { [weak self] direction, down in self?.presenceBubble.press(direction, down: down) }
        quick.onSize = { [weak self] steps in self?.presenceBubble.step(steps) }
        objectWillChange
            .sink { [weak self] _ in self?.schedulePresenceRefresh() }
            .store(in: &presenceCancellables)
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.schedulePresenceRefresh() }
            .store(in: &presenceCancellables)
        presenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.presenceTicks &+= 1
                let every = PresenceVisibility.pollInterval(shareKind: self.presenceShareKind,
                                                            bubbleUp: self.presenceBubble.isVisible)
                if every <= 0.25 || self.presenceTicks % 4 == 0 { self.refreshPresenceBubble() }
            }
        }
    }

    /// Queues one refresh a beat from now; further requests in that beat join it.
    func schedulePresenceRefresh() {
        guard !presenceRefreshPending else { return }
        presenceRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.presenceRefreshPending = false
                self?.refreshPresenceBubble()
            }
        }
    }

    var presenceShareKind: PresenceVisibility.ShareKind {
        switch shareTarget.kind {
        case .display: return .display
        case .app: return .app
        case .window: return .window
        case .whiteboard: return .whiteboard
        case .nothing: return .nothing
        }
    }

    /// Shows, moves or hides the bubble to match the stage. Idempotent; reads
    /// current values, so call it after a change has landed (see above).
    func refreshPresenceBubble() {
        let layout = makeStageConfiguration().normalizedLayout
        let kind = presenceShareKind
        let windowShare = kind == .app || kind == .window
        let inMeeting = zoomChatClient.myUserID != nil
        // The share kind decides only where the bubble sits. A whiteboard or Just my camera has no
        // captured screen, so it sits on the display holding the whiteboard (else the main display):
        // its visible frame, with the picture's whole canvas as the content, never hidden for lack of a frame.
        let noScreenShare = kind == .whiteboard || kind == .nothing
        let shared = stage != nil
            ? (noScreenShare ? presenceFallbackFrame(for: kind) : capturedFrameInCocoa(wholeDisplay: !windowShare)) : nil
        let content = noScreenShare ? CGRect(x: 0, y: 0, width: 1920, height: 1080) : stage?.lastContentRect
        let inputs = PresenceVisibility.Inputs(
            live: stage != nil && phase.isCameraBusy,
            layoutPlaceable: layout.isPresencePlaceable,
            // Zoom video off (the meeting's camera control): an empty frame
            // would float on the screen. Greenroom's own "no camera" is in
            // `layoutPlaceable` (showsCamera).
            cameraOn: !inMeeting || zoomChatClient.myVideoIsOn,
            hasCapturedFrame: shared != nil,
            hasContentRect: content != nil,
            hiddenByPresenter: presenceBubbleHidden,
            shareKind: kind,
            sharedWindowVisible: !windowShare
                || (stage?.capturedWindowID() != nil && stage?.capturedScreenFrame(onThisDesktop: true) != nil),
            nativeZoomShareActive: zoomChatClient.shareViewer.selfSharing)
        guard PresenceVisibility.decide(inputs) == .show, let stage, let shared, let content else {
            hidePresenceBubble()
            return
        }
        // Only while shown does the compositor spend time on self-view pictures.
        if presenceBubble.quick.background != cameraBackground { presenceBubble.quick.background = cameraBackground }
        stage.setSelfViewHandler { [feed = presenceBubble.feed] in feed.push($0) }
        presenceFeedInstalled = true
        presenceBubble.show(layout: layout, geometry: PresenceGeometry(display: shared, content: content))
    }

    /// Where the bubble sits when nothing of the screen is captured: the visible frame of the display
    /// holding the presented whiteboard, else of the main display (Just my camera: the layout's camera spot there).
    private func presenceFallbackFrame(for kind: PresenceVisibility.ShareKind) -> CGRect? {
        let screen = (kind == .whiteboard ? presentedWhiteboardScreen : nil) ?? NSScreen.screens.first
        return screen?.visibleFrame
    }

    /// The captured display or window as Cocoa points (bottom-left origin).
    /// Nil when the capture does not match a display that exists now (a
    /// display just unplugged or resized, before the capture catches up), so
    /// the bubble never sits on a wrong screen.
    private func capturedFrameInCocoa(wholeDisplay: Bool) -> CGRect? {
        guard let cg = capturedScreenFrame(), let primary = NSScreen.screens.first else { return nil }
        let ids = NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        if wholeDisplay {
            guard ids.contains(where: {
                let b = CGDisplayBounds(CGDirectDisplayID($0))
                return abs(b.minX - cg.minX) < 1 && abs(b.minY - cg.minY) < 1
                    && abs(b.width - cg.width) < 1 && abs(b.height - cg.height) < 1
            }) else { return nil }
        } else {
            let centre = CGPoint(x: cg.midX, y: cg.midY)
            guard ids.contains(where: { CGDisplayBounds(CGDirectDisplayID($0)).contains(centre) }) else { return nil }
        }
        return CGRect(x: cg.minX, y: primary.frame.height - cg.maxY, width: cg.width, height: cg.height)
    }

    private func hidePresenceBubble() {
        if presenceBubble.isVisible { presenceBubble.hide() }
        if presenceFeedInstalled {
            stage?.setSelfViewHandler(nil)
            presenceFeedInstalled = false
        }
    }

    /// The presenter moved the bubble: keep it (persisted like the Settings
    /// layout) and tell the compositor now, without the full apply.
    private func applyPresencePlacement(_ layout: StageLayout) {
        bubbleWidthFraction = layout.widthFraction
        bubbleRightInset = layout.rightInset
        bubbleBottomInset = layout.bottomInset
        cutoutHeightFraction = layout.cutoutHeightFraction
        cutoutRightInset = layout.cutoutRightInset
        stage?.updatePlacement(stageLayout)
    }

    /// Home's preview: the camera was dragged there. A step only tells the
    /// compositor (no @Published write, no defaults); the end commits once.
    func previewPlacementStep(_ box: PresenceBox) {
        var layout = stageLayout
        layout.apply(box)
        stage?.updatePlacement(layout)
    }

    /// A drag of the camera in a preview ended. Settings -> Layouts (and the Webcam tab) also write
    /// the active layout's saved camera; Home's preview changes the running session's working copy
    /// only (R4.3).
    func commitPreviewPlacement(_ box: PresenceBox, source: LayoutEditSource) {
        var layout = stageLayout
        layout.apply(box)
        applyPresencePlacement(layout)
        if source.writesSavedLayout { saveCameraToActiveLayout() }
    }
}
