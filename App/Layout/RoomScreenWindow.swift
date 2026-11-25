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
//  Speed: no CIImage, no CGImage, no main-thread hop. Each IOSurface-backed
//  CVPixelBuffer is wrapped in a CMSampleBuffer (DisplayImmediately) and handed to an
//  AVSampleBufferDisplayLayer, which the GPU shows straight from the surface.
//
//  Out of Greenroom's own share and recordings: the display capture excludes the
//  whole of Greenroom. Other apps' captures may see it (default sharingType). No chrome, no glass:
//  the picture on black. A piece that fills the display covers screen.frame at
//  .screenSaver level (above the menu bar); the picture is aspect fit on black.
//
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import os

// MARK: - Feeding the layer

/// Turns pixel buffers into display-immediately sample buffers for one layer.
/// Called from the compositor's render queue or the capture queue; the layer's
/// renderer is thread-safe, so nothing hops to the main thread.
final class RoomFrameFeeder: StageFrameSink {
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var format: CMVideoFormatDescription?   // under lock
    #if DEBUG
    private let stats = DeliveryStats()
    /// The latest capture frame's own host-clock stamp (capture queue only).
    var captureStamp = CMTime.invalid
    #endif

    init(layer: AVSampleBufferDisplayLayer) {
        renderer = layer.sampleBufferRenderer
    }

    func stageDidRender(_ frame: CVPixelBuffer, at time: CMTime) { show(frame, stampedAt: time) }

    func show(_ pixels: CVPixelBuffer, stampedAt time: CMTime) {
        #if DEBUG
        stats.record(frameTime: time)
        #endif
        lock.lock()
        if let current = format, CMVideoFormatDescriptionMatchesImageBuffer(current, imageBuffer: pixels) {
            // keep it
        } else {
            var made: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &made)
            format = made
        }
        let description = format
        lock.unlock()
        guard let description else { return }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixels, formatDescription: description,
            sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}

#if DEBUG
/// DEBUG only: the average time from a frame's own stamp to the moment it was
/// handed to the layer, logged every 300 frames with os_log.
private final class DeliveryStats {
    private let lock = NSLock()
    private var total = 0.0
    private var count = 0
    private static let log = Logger(subsystem: "com.sibhimanyu.greenroom", category: "RoomScreen")

    func record(frameTime: CMTime) {
        guard frameTime.isValid else { return }
        let delay = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), frameTime)) * 1000
        lock.lock()
        total += delay; count += 1
        let report = count >= 300
        let average = total / Double(max(count, 1))
        let n = count
        if report { total = 0; count = 0 }
        lock.unlock()
        if report {
            Self.log.debug("Room screen: average delivery \(average, format: .fixed(precision: 2)) ms over \(n) frames")
        }
    }
}

#endif

// MARK: - The view

final class RoomScreenView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - The window and its controller

@MainActor
enum RoomScreen {
    private static var window: MeetingViewPanel?
    private static var feeder: RoomFrameFeeder?
    private static var roomScreenID = ""
    private static var hidden = false
    private static var observer: NSObjectProtocol?

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

    /// Opens the window at `frame` on the display `screenID`, or moves it there.
    /// A piece that fills the display (`rect` is full) covers `screen.frame`, above the menu bar and
    /// Dock of that display; any other piece stays a normal-level window at `frame`.
    static func place(frame: NSRect, rect: UnitRect, screenID: String, hidden: Bool) {
        guard let screen = DisplayResolver.screen(forUUID: screenID) else { close(); return }
        roomScreenID = screenID
        let panel = window ?? makeWindow()
        let full = RoomScreenRules.isFullDisplay(rect)
        let frame = RoomScreenRules.windowFrame(pieceFrame: frame, rect: rect, screenFrame: screen.frame)
        // .screenSaver sits above .mainMenu; the window only covers the room display, so the owner's
        // main-display menu bar is untouched.
        let level: NSWindow.Level = full ? .screenSaver : .normal
        if panel.level != level { panel.level = level }
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        setHidden(hidden)
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
        guard let panel = window else { return }
        window = nil
        feeder = nil
        panel.orderOut(nil)
        panel.close()
        log("closed.")
    }

    // MARK: Window

    private static func makeWindow() -> MeetingViewPanel {
        let panel = MeetingViewPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        panel.level = .normal
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Default sharingType (RoomScreenRules.sharingForOtherApps): other apps' captures may see it.
        // Greenroom's own capture excludes the whole app, so it never films itself.
        let view = RoomScreenView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        panel.contentView = view
        feeder = RoomFrameFeeder(layer: view.displayLayer)
        window = panel
        log("opened.")
        return panel
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

    // MARK: Sources

    private static func syncSource() {
        guard window != nil, !hidden, let feeder else { stopSources(); return }
        let wanted = RoomScreenRules.source(compositorRunning: compositor != nil)
        if wanted == sourceInUse, wanted != .compositor || sinkedStage === compositor { return }
        stopSources()
        sourceInUse = wanted
        switch wanted {
        case .compositor:
            guard let stage = compositor else { return }
            stage.addSink(feeder)
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
