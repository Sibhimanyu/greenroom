//
//  RoomScreenWindow.swift
//  Greenroom
//
//  The Room screen piece at run time: a borderless window on the big screen in
//  the room (set as an extended display, because mirroring copies private
//  windows too) that shows what the meeting sees, Greenroom's private windows
//  left out. Pure rules are in RoomScreenRules.
//
//  Where the picture comes from:
//   - the compositor is running (a session): its output frames, camera overlay
//     included, exactly what the meeting gets (`StageFrameSink`);
//   - otherwise a capture of its own: `StageScreenSource(.display)`, whose filter
//     already leaves out every Greenroom window not marked "Everyone sees this".
//     At 60 fps, queue depth 3, sized to the room display's pixels, cursor on.
//
//  Speed: no CIImage, no CGImage, no copy. The newest IOSurface-backed
//  CVPixelBuffer's surface becomes a plain CALayer's contents, once per main-queue
//  turn (`RoomFrameFeeder`); the GPU shows it straight from the surface. Not an
//  AVSampleBufferDisplayLayer: its image queue froze on the room display (2026-11-26).
//  Health goes to os_log (category RoomScreen) every 5 s while open.
//
//  Out of Greenroom's own share and recordings: the display capture excludes the
//  whole of Greenroom. Other apps' captures may see it (default sharingType). No glass:
//  the picture on black, aspect fit. A real macOS window (R46): title bar see-through
//  over the picture, drag and resize like any window; a piece that fills the display
//  goes into native full screen on it (title bar on hover, the green button and ⌃⌘F
//  leave it). Once the owner moves, resizes or changes its full screen by hand,
//  `place` leaves it where they put it (`RoomScreenRules.Ownership`).
//
import AppKit
import CoreMedia
import CoreVideo
import os

// MARK: - Feeding the layer

/// The feeder itself lives in RoomFrameFeeder.swift (testable on its own).
extension RoomFrameFeeder: StageFrameSink {
    func stageDidRender(_ frame: CVPixelBuffer, at time: CMTime) { show(frame, stampedAt: time) }
}

// MARK: - The view

final class RoomScreenView: NSView {
    let displayLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.contentsGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - The window and its controller

/// Reports the window's moves, resizes and full-screen changes to `RoomScreen.ownership`.
@MainActor
private final class RoomWindowWatcher: NSObject, NSWindowDelegate {
    func windowDidMove(_ notification: Notification) { RoomScreen.ownership.windowChanged(.moveOrResize) }
    func windowDidResize(_ notification: Notification) { RoomScreen.ownership.windowChanged(.moveOrResize) }
    func windowWillEnterFullScreen(_ notification: Notification) { RoomScreen.ownership.windowChanged(.fullScreenWillChange) }
    func windowWillExitFullScreen(_ notification: Notification) { RoomScreen.ownership.windowChanged(.fullScreenWillChange) }
    func windowDidEnterFullScreen(_ notification: Notification) { RoomScreen.ownership.windowChanged(.fullScreenDidChange) }
    func windowDidExitFullScreen(_ notification: Notification) {
        RoomScreen.ownership.windowChanged(.fullScreenDidChange)
        RoomScreen.applyFrameAfterFullScreen()
    }
}

@MainActor
enum RoomScreen {
    private static var window: NSWindow?
    private static var watcher: RoomWindowWatcher?
    /// The owner's changes vs ours (R46); a fresh window starts as Greenroom's again.
    fileprivate static var ownership = RoomScreenRules.Ownership()
    /// A frame to set once our own exit from full screen ends (it is ignored mid-animation).
    fileprivate static var frameAfterFullScreen: NSRect?
    private static var feeder: RoomFrameFeeder?
    private static var roomScreenID = ""
    private static var hidden = false
    /// The piece's "Show my camera" (R47): off takes the compositor's camera-less picture.
    private static var showsMyCamera = true
    private static var observer: NSObjectProtocol?
    private static var occlusionObserver: NSObjectProtocol?
    private static var healthTimer: Timer?
    private static let healthLog = Logger(subsystem: "com.sibhimanyu.greenroom", category: "RoomScreen")

    /// The compositor while one runs; set by the coordinator after Start's
    /// `stage.start` and cleared when the stage is torn down.
    private static weak var compositor: StageCompositor?
    private static var sourceInUse: RoomScreenRules.Source?
    private static var sinkedStage: StageCompositor?
    private static var own: StageScreenSource?
    private static var ownTask: Task<Void, Never>?

    static var isOpen: Bool { window != nil }

    private static func log(_ line: String) { CoordinatorController.sessionLog("Room screen: " + line) }

    // MARK: Coordinator and engine API

    /// Opens the window at `frame` on the display `screenID`, or places it there: native full screen
    /// on that display when the piece fills it, else a window at `frame`
    /// (`RoomScreenRules.placeSteps`). Nothing moves once the owner has moved it by hand.
    static func place(frame: NSRect, rect: UnitRect, screenID: String, hidden: Bool, showsMyCamera: Bool = true) {
        guard DisplayResolver.screen(forUUID: screenID) != nil else { close(); return }
        roomScreenID = screenID
        Self.showsMyCamera = showsMyCamera
        let win = window ?? makeWindow()
        let fullScreen = win.styleMask.contains(.fullScreen)
        let steps = RoomScreenRules.placeSteps(rect: rect, pieceFrame: frame, currentFrame: win.frame,
                                               isFullScreen: fullScreen, ownerTookOver: ownership.ownerTookOver)
        // In full screen a frame waits until our exit from it ends (`frameAfterFullScreen`).
        if !fullScreen, case .setFrame(let target)? = steps.first {
            ownership.placing { _ in win.setFrame(target, display: false) }
        }
        setHidden(hidden)
        if steps.contains(.enterFullScreen), !hidden, win.isVisible {
            ownership.expectOurFullScreenChange()
            win.toggleFullScreen(nil)
        }
        if steps.contains(.leaveFullScreen) {
            if case .setFrame(let target)? = steps.last { frameAfterFullScreen = target }
            ownership.expectOurFullScreenChange()
            win.toggleFullScreen(nil)
        }
        watchDisplays()
    }

    /// Only `place` calls this, with `RoomScreenRules.isHidden`: the layout's hide never reaches it.
    private static func setHidden(_ value: Bool) {
        hidden = value
        guard let window else { return }
        if value {
            window.orderOut(nil)
        } else if !window.isVisible {
            window.orderFrontRegardless()
        }
        syncSource()
    }

    /// The stage started (or stopped): the picture comes from it, or from the
    /// screen's own capture.
    static func setCompositor(_ stage: StageCompositor?) {
        compositor = stage
        syncSource()
    }

    static func close() {
        stopSources()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        healthTimer?.invalidate()
        healthTimer = nil
        guard let panel = window else { return }
        window = nil
        feeder = nil
        panel.delegate = nil
        watcher = nil
        ownership = RoomScreenRules.Ownership()
        frameAfterFullScreen = nil
        panel.orderOut(nil)
        panel.close()
        log("closed.")
    }

    // MARK: Window

    private static func makeWindow() -> NSWindow {
        // Titled so it is a real window: native full screen, drag, resize, ⌃⌘F. Not closable: the
        // layout opens and closes it with the meeting.
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                             styleMask: [.titled, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = RoomScreenRules.title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .normal
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenPrimary, .managed]
        let watch = RoomWindowWatcher()
        panel.delegate = watch
        watcher = watch
        // Default sharingType (it never sets sharingType; Greenroom's own capture leaves it out through `Visibility.roomScreenReason`): other apps' captures may see it.
        // Greenroom's own capture excludes the whole app, so it never films itself.
        let view = RoomScreenView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        panel.contentView = view
        let made = RoomFrameFeeder(layer: view.displayLayer)
        feeder = made
        window = panel
        log("opened.")
        watchHealth(panel, made)
        return panel
    }

    /// So the next freeze is diagnosable: the window server hiding the window, and
    /// every 5 s the frames handed in vs put on the layer
    /// (`log stream --predicate 'category == "RoomScreen"'`).
    private static func watchHealth(_ panel: NSWindow, _ feeder: RoomFrameFeeder) {
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated {
                let visible = panel.occlusionState.contains(.visible)
                log(visible ? "the window server shows it again." : "the window server reports it hidden (occluded).")
            }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak feeder] _ in
            MainActor.assumeIsolated {
                guard let feeder, let window else { return }
                let (received, applied) = feeder.takeCounts()
                let visible = window.occlusionState.contains(.visible)
                let screen = window.screen?.localizedName ?? "none"
                healthLog.notice("Room screen: \(received) frames in, \(applied) shown in 5 s; visible \(visible); on \(screen, privacy: .public)")
                if received > 0, applied == 0 { log("frames arrive but none reached the layer in 5 s.") }
            }
        }
    }

    /// The room display going away closes the window quietly.
    private static func watchDisplays() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if DisplayResolver.screen(forUUID: roomScreenID) == nil { close() }
            }
        }
    }

    /// Our own exit from full screen ended: the frame the layout asked for.
    fileprivate static func applyFrameAfterFullScreen() {
        guard let target = frameAfterFullScreen, let win = window else { return }
        frameAfterFullScreen = nil
        ownership.placing { _ in win.setFrame(target, display: false) }
    }

    // MARK: Sources

    private static func syncSource() {
        guard window != nil, !hidden, let feeder else { stopSources(); return }
        let wanted = RoomScreenRules.source(compositorRunning: compositor != nil, showsMyCamera: showsMyCamera)
        if wanted == sourceInUse, wanted == .ownDisplay || sinkedStage === compositor { return }
        stopSources()
        sourceInUse = wanted
        switch wanted {
        case .compositor, .compositorWithoutCamera:
            guard let stage = compositor else { return }
            if wanted == .compositor { stage.addSink(feeder) } else { stage.addCameralessSink(feeder) }
            sinkedStage = stage
        case .ownDisplay:
            startOwnCapture(feeder)
        }
    }

    private static func stopSources() {
        if let stage = sinkedStage, let feeder { stage.removeSink(feeder) }
        sinkedStage = nil
        ownTask?.cancel()
        ownTask = nil
        own?.stop(because: "the Room screen no longer needs it")
        own = nil
        sourceInUse = nil
    }

    /// The same screen source the share uses (same filter: Greenroom's windows
    /// out, "Everyone sees this" windows in), at the display's refresh rate and size.
    private static func startOwnCapture(_ feeder: RoomFrameFeeder) {
        guard let screen = DisplayResolver.screen(forUUID: roomScreenID) else { return }
        // A layout with a Room screen always shares its main display (LayoutTemplate.effectiveSharedSlot),
        // so the Screen choice is not consulted: the screen shows the main display.
        let preferred = ""
        let resolved = LocalDeviceResolver.resolveCaptureDisplay(preferred: preferred).uuid
        let target = RoomScreenRules.captureDisplay(preferred: resolved ?? "", roomDisplay: roomScreenID,
                                                    main: LocalDeviceResolver.mainDisplayUUID)
        let size = RoomScreenRules.streamSize(roomPoints: screen.frame.size, scale: screen.backingScaleFactor)
        let source = StageScreenSource(target: .display, displayUUID: target, maxSize: size)
        source.framesPerSecond = 60
        source.queueDepth = 3
        source.quietFailures = true
        #if DEBUG
        // Both callbacks run on the capture queue, one after the other: the stamp is the frame's own.
        source.onFrameTime = { [weak feeder] time in feeder?.captureStamp = time }
        source.onFrame = { [weak feeder] pixels in
            guard let feeder else { return }
            feeder.show(pixels, stampedAt: feeder.captureStamp)
        }
        #else
        source.onFrame = { [weak feeder] pixels in feeder?.show(pixels, stampedAt: .invalid) }
        #endif
        source.onStop = { _ in
            Task { @MainActor in
                // macOS ended the capture: start it again while the screen is still wanted.
                guard own === source else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if own === source, !hidden, window != nil { stopSources(); syncSource() }
            }
        }
        own = source
        ownTask = Task {
            do { try await source.start() } catch {
                log("couldn\u{2019}t start its capture: \(error.localizedDescription)")
            }
        }
    }
}
