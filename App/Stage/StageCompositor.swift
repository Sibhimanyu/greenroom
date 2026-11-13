//
//  StageCompositor.swift
//  Greenroom
//
//  The class picture, made in-process: the shared screen, then the live
//  camera shaped and placed over it, at a fixed clock, handed to whoever
//  subscribed. The geometry is in StageRenderer.swift.
//
//  Threads. Drawing happens on `renderQueue` (userInteractive, serial) and
//  nowhere else; never the main thread. Inputs arrive on their own capture
//  queues and are dropped into `StageInputBoard`, a lock around "latest of
//  each". A tick reads the board and draws what is there; an input that has
//  not delivered is skipped, nothing waits.
//
//  Live changes never blank the picture. Layout, shape and look are swapped
//  on the render queue between ticks. A new share target is started beside
//  the old one, and only replaces it when its first frame has arrived.
//
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation

/// Plain-language, observable state for the coordinator to show later.
/// Mutated on the main thread only.
final class StageStatus: ObservableObject {
    @Published fileprivate(set) var isRunning = false
    /// The screen capture is running and has delivered a picture. (A still
    /// screen delivers no new frames, so this is not "a frame this second".)
    @Published fileprivate(set) var screenLive = false
    /// One entry per camera slot: a frame arrived in the last two seconds.
    @Published fileprivate(set) var camerasLive: [Bool] = []
    /// False while background removal finds nobody in slot 0's camera.
    @Published fileprivate(set) var personInView = true
    /// What is being shared ("Keynote", "Chrome \u{2013} Lesson plan"), nil for a display.
    @Published fileprivate(set) var shareLabel: String?
    /// Why the picked app or window was not shared and the display was.
    @Published fileprivate(set) var shareFallback: String?
    /// A saved display was not plugged in and the main display was used.
    @Published fileprivate(set) var displayFellBack = false
    @Published fileprivate(set) var lastError: String?
}

/// Latest picture from each input, behind one lock.
final class StageInputBoard {
    struct Screen { var buffer: CVPixelBuffer; var wholeDisplay: Bool }
    struct Snapshot {
        var screen: Screen?
        var slotUIDs: [String]
        var cameras: [String: CutoutPublisher.Frame]
        var cameraAge: [String: TimeInterval]
    }

    private let lock = NSLock()
    private var screen: Screen?
    private var activeScreen: UUID?
    private var pendingScreen: UUID?
    private var slotUIDs: [String] = []
    private var cameras: [String: CutoutPublisher.Frame] = [:]
    private var cameraTime: [String: TimeInterval] = [:]

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        return Snapshot(screen: screen, slotUIDs: slotUIDs, cameras: cameras,
                        cameraAge: cameraTime.mapValues { now - $0 })
    }

    func setSlots(_ uids: [String]) {
        lock.lock(); defer { lock.unlock() }
        slotUIDs = uids
        for uid in Array(cameras.keys) where !uids.contains(uid) { cameras[uid] = nil; cameraTime[uid] = nil }
    }

    func setCamera(_ uid: String, _ frame: CutoutPublisher.Frame) {
        lock.lock(); defer { lock.unlock() }
        cameras[uid] = frame
        cameraTime[uid] = ProcessInfo.processInfo.systemUptime
    }

    func raw(slot: Int) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard slotUIDs.indices.contains(slot) else { return nil }
        return cameras[slotUIDs[slot]]?.raw
    }

    func expectScreen(_ id: UUID) { lock.lock(); pendingScreen = id; lock.unlock() }
    func dropPending(_ id: UUID) { lock.lock(); if pendingScreen == id { pendingScreen = nil }; lock.unlock() }
    func clearScreen() { lock.lock(); screen = nil; activeScreen = nil; pendingScreen = nil; lock.unlock() }

    /// Returns true when this frame promoted a pending source to active.
    var activeScreenID: UUID? { lock.lock(); defer { lock.unlock() }; return activeScreen }

    func offerScreen(_ buffer: CVPixelBuffer, wholeDisplay: Bool, from id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if id == activeScreen { screen = Screen(buffer: buffer, wholeDisplay: wholeDisplay); return false }
        if id == pendingScreen {
            activeScreen = id; pendingScreen = nil
            screen = Screen(buffer: buffer, wholeDisplay: wholeDisplay)
            return true
        }
        return false
    }
}

final class StageCompositor: StageFrameSource {

    let outputSize: CGSize
    let frameRate: Int
    let status = StageStatus()

    private let sinks = StageSinkList()
    private let renderer: StageRenderer
    private let pool: StageBufferPool
    private let board = StageInputBoard()
    private let renderQueue = DispatchQueue(label: "greenroom.stage.render", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "greenroom.stage.control", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    // Render-queue state.
    private var scene = StageScene()
    private var slotUIDs: [String] = []
    private var fadeBegan: TimeInterval = 0
    private var fadeLength: TimeInterval = 0
    private var lastStatusPush: TimeInterval = 0
    private var lastPushed: (Bool, [Bool])?

    // Control state, only touched under `lock`.
    private let lock = NSLock()
    private var publishers: [String: CutoutPublisher] = [:]
    private var screenSources: [UUID: StageScreenSource] = [:]
    private var shareKey: String?
    private var screenGeneration = 0
    private var running = false
    /// The screen was wanted but Screen Recording was off. `update` tries again
    /// once it is on, without the caller having to change anything.
    private var waitingForPermission = false
    /// The configuration most recently applied, so a display change can
    /// rebuild the capture without being handed it again.
    private var lastConfiguration: StageConfiguration?
    /// What the running screen capture was built against (see DisplayPlan).
    private var activeCapture = DisplayPlan.Capture(activeUUID: nil, preferredUUID: "", fellBack: false,
                                                    activePixelSize: nil, isWholeDisplay: true)

    init?(size: CGSize = CGSize(width: 1920, height: 1080), frameRate: Int = 30) {
        guard let pool = StageBufferPool(size: size) else { return nil }
        self.pool = pool
        outputSize = size
        self.frameRate = frameRate
        renderer = StageRenderer(canvas: size)
    }

    func addSink(_ sink: StageFrameSink) { sinks.add(sink) }
    func removeSink(_ sink: StageFrameSink) { sinks.remove(sink) }

    // MARK: Where the screen is in the picture

    /// Maps a point on the real screen to where that spot is in the finished
    /// video: 0...1, top-left origin, over the whole canvas. Nil when the
    /// point is not on the shared content (outside the display or window being
    /// captured) or no screen is drawn right now (nothing shared, or layout
    /// with content off).
    ///
    ///   source  = captured display's frame, or the followed window's CURRENT
    ///             frame (global CG points, top-left origin)
    ///   u, v    = (p - source.origin) / source.size
    ///   rect    = where `StageRenderer.compose` drew the screen in the last
    ///             frame (canvas px, top-left): fitted + letterboxed into the
    ///             full-frame box, the window margin box or the presenter panel
    ///   x, y    = (rect.minX + u * rect.width) / canvas.width, likewise y
    ///
    /// Both halves are read at call time, so a window that moved or a layout
    /// that changed mid-recording is followed.
    func videoPosition(ofGlobalPoint p: CGPoint) -> CGPoint? {
        guard let rect = renderer.lastContentRect, rect.width > 0, rect.height > 0 else { return nil }
        lock.lock()
        let source = board.activeScreenID.flatMap { screenSources[$0] }
        lock.unlock()
        guard let frame = source?.capturedFrame(), frame.width > 1, frame.height > 1,
              frame.contains(p) else { return nil }
        let u = (p.x - frame.minX) / frame.width
        let v = (p.y - frame.minY) / frame.height
        return CGPoint(x: (rect.minX + u * rect.width) / outputSize.width,
                       y: (rect.minY + v * rect.height) / outputSize.height)
    }

    // MARK: Permission

    /// Whether ScreenCaptureKit will deliver. Does not prompt.
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows macOS's prompt the first time; after a refusal it opens the
    /// System Settings pane instead (once per launch), the only place the
    /// answer can change.
    @MainActor static func requestScreenRecordingAccess() {
        if CGRequestScreenCaptureAccess() { return }
        StageScreenSource.openPermissionPaneOnce()
    }

    // MARK: Control

    /// Starts the clock and opens the inputs. Safe to call again: it then
    /// behaves as `update`.
    func start(_ configuration: StageConfiguration) {
        lock.lock()
        let already = running
        running = true
        lock.unlock()
        apply(configuration)
        guard !already else { return }
        post { $0.isRunning = true; $0.lastError = nil }
        renderQueue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(frameRate), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    /// Changes layout, shape, look, share target or cameras while running.
    /// Nothing here blanks the picture.
    func update(_ configuration: StageConfiguration) { apply(configuration) }

    func stop() {
        lock.lock()
        running = false
        screenGeneration += 1
        let cams = Array(publishers.values), screens = Array(screenSources.values)
        publishers = [:]; screenSources = [:]; shareKey = nil
        activeCapture.activeUUID = nil
        lock.unlock()
        cams.forEach { $0.stop() }
        screens.forEach { $0.stop(because: "the picture was stopped") }
        board.setSlots([]); board.clearScreen()
        renderQueue.async { [self] in timer?.cancel(); timer = nil }
        post {
            $0.isRunning = false; $0.screenLive = false; $0.camerasLive = []
            $0.shareLabel = nil; $0.shareFallback = nil
        }
    }

    /// Cuts, or crossfades, to the camera in `slot`. The timing is
    /// `switchCamera`'s: smoothstep up for the incoming camera, one minus its
    /// square down for the outgoing one.
    func cut(toSlot slot: Int, fade: TimeInterval) {
        renderQueue.async { [self] in
            guard slot != scene.liveSlot else { return }
            let outgoing = scene.liveSlot
            scene.liveSlot = slot
            if fade > 0 {
                scene.fade = (outgoing, 0)
                fadeBegan = ProcessInfo.processInfo.systemUptime
                fadeLength = fade
            } else {
                scene.fade = nil
            }
        }
    }

    /// The most recent raw frame from the camera in `slot`, for
    /// CameraDirector. Opened cameras keep delivering while hidden, so the
    /// director can look through one the class cannot see.
    func latestCameraFrame(slot: Int) -> CVPixelBuffer? { board.raw(slot: slot) }

    // MARK: Applying a configuration

    private func apply(_ cfg: StageConfiguration) {
        let layout = cfg.normalizedLayout
        let wantsRemoval = layout.shape.usesChromaKey && layout.showsCamera && cfg.backgroundRemoval == .automatic

        // Cameras wanted: none when "No camera" was chosen.
        let uids = layout.showsCamera ? cfg.cameraUIDs : []
        board.setSlots(uids)

        renderQueue.async { [self] in
            scene.layout = layout
            scene.removal = cfg.backgroundRemoval
            slotUIDs = uids
            if scene.liveSlot >= uids.count { scene.liveSlot = 0; scene.fade = nil }
        }

        lock.lock()
        lastConfiguration = cfg
        let key = "\(cfg.share.kind.rawValue)|\(cfg.share.appBundleID)|\(cfg.share.windowTitle)|\(cfg.displayUUID)"
        let permissionArrived = waitingForPermission && Self.screenRecordingGranted
        let restartScreen = key != shareKey || permissionArrived
        // Cleared here, in the same locked step that bumps the round. It used
        // to be cleared later inside syncScreen, so two applies in quick
        // succession (the permission watcher, then a tile click) each saw
        // "waiting" and each bumped the round: the first capture was started
        // and then stopped as superseded a few dozen milliseconds later.
        if permissionArrived { waitingForPermission = false }
        if restartScreen { shareKey = key; screenGeneration += 1 }
        let generation = screenGeneration
        lock.unlock()
        if restartScreen {
            StageScreenSource.log("Screen wanted: \(cfg.share.kind.rawValue)\(cfg.share.appBundleID.isEmpty ? "" : " " + cfg.share.appBundleID)\(cfg.share.windowTitle.isEmpty ? "" : " \u{201C}" + cfg.share.windowTitle + "\u{201D}"), display \(cfg.displayUUID.isEmpty ? "automatic" : cfg.displayUUID) (round \(generation)).")
        }

        controlQueue.async { [self] in syncCameras(uids: uids, removal: wantsRemoval) }
        if restartScreen { Task.detached { [self] in await syncScreen(cfg, generation: generation) } }
    }

    // MARK: Displays coming and going

    /// Called once the displays have settled after a plug or unplug.
    ///
    /// The picture never goes black: a replacement capture is started BESIDE
    /// the old one and only takes over when it has delivered its first frame
    /// (see `retireScreens` in `syncScreen`), so until then the class keeps
    /// seeing the last frame. A capture that is working is left alone, except
    /// to go back to the chosen display when it had fallen back to the main
    /// one and the chosen one has returned.
    func displaysDidChange(connected: [DisplayPlan.Display], main: String?, displaySetChanged: Bool) {
        lock.lock()
        let cfg = lastConfiguration, isRunning = running
        let capture = activeCapture
        lock.unlock()
        guard isRunning, let cfg, cfg.share.kind != .nothing, Self.screenRecordingGranted else { return }

        let decision: DisplayPlan.Decision
        if capture.activeUUID == nil {
            decision = .rebuild("the screen capture isn\u{2019}t running; trying again now the displays have settled")
        } else {
            decision = DisplayPlan.decide(capture: capture, connected: connected,
                                          displaySetChanged: displaySetChanged, main: main)
        }
        switch decision {
        case .keep:
            StageScreenSource.log("Displays changed; the screen capture is on a display that is still there, so it stays as it is.")
        case .rebuild(let reason):
            lock.lock()
            screenGeneration += 1
            let generation = screenGeneration
            lock.unlock()
            StageScreenSource.log("Displays changed: \(reason). The class keeps seeing the last picture until the new capture has one (round \(generation)).")
            Task.detached { [self] in await syncScreen(cfg, generation: generation, retries: 3) }
        }
    }

    // MARK: Cameras

    /// Every camera open at once, like `ensureCameraInputs`: a cut is a
    /// change of which one is drawn, nothing to open and nothing to wait for.
    /// Cameras already open are left alone so the picture does not blink.
    private func syncCameras(uids: [String], removal: Bool) {
        lock.lock()
        guard running else { lock.unlock(); return }
        let existing = publishers
        lock.unlock()

        for (uid, publisher) in existing where !uids.contains(uid) {
            publisher.stop()
            lock.lock(); publishers[uid] = nil; lock.unlock()
        }
        var failure: String?
        for (slot, uid) in uids.enumerated() {
            if let publisher = existing[uid] { publisher.removesBackground = removal; continue }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted:
                failure = "Camera access is off for Greenroom. System Settings \u{2192} Privacy & Security \u{2192} Camera."
                continue
            default: break
            }
            guard let publisher = CutoutPublisher(uid: uid, slot: slot, removesBackground: removal) else {
                let name = LocalDeviceResolver.cameraName(uid: uid) ?? "the camera"
                failure = "Couldn\u{2019}t open \u{201C}\(name)\u{201D}. It may be unplugged or in use by another app."
                continue
            }
            publisher.onFrame = { [board] frame in board.setCamera(uid, frame) }
            if slot == 0 {
                publisher.onPersonInView = { [weak self] seen in self?.post { $0.personInView = seen } }
            }
            lock.lock(); publishers[uid] = publisher; lock.unlock()
            publisher.start()
        }
        if let failure { post { $0.lastError = failure } }
    }

    // MARK: Screen

    private func syncScreen(_ cfg: StageConfiguration, generation: Int, retries: Int = 0) async {
        func current() -> Bool { isCurrent(generation) }

        guard cfg.share.kind != .nothing else {
            // Nothing shared: let the screen go entirely, not hidden. (An earlier design
            // kept the source for the sake of a teardown crash;
            // ScreenCaptureKit has no such problem.)
            retireScreens(except: nil, because: "Nothing was chosen for Behind you")
            board.clearScreen()
            post { $0.screenLive = false; $0.shareLabel = nil; $0.shareFallback = nil; $0.displayFellBack = false }
            return
        }
        guard Self.screenRecordingGranted else {
            lock.lock(); waitingForPermission = true; lock.unlock()
            StageScreenSource.log("Not started: Screen Recording is off for Greenroom.")
            post { $0.screenLive = false; $0.lastError = StageScreenSource.permissionMessage }
            return
        }

        lock.lock(); waitingForPermission = false; lock.unlock()
        let display = LocalDeviceResolver.resolveCaptureDisplay(preferred: cfg.displayUUID)
        guard let displayUUID = display.uuid else {
            post { $0.lastError = "Couldn\u{2019}t find a screen to share." }
            return
        }
        // Resolved now, at start, by app and title, as ShareTarget does.
        let resolved = cfg.share.resolve(displayUUID: displayUUID)
        let target: StageScreenSource.Target
        switch resolved.kind {
        case .app: target = .app(bundleID: cfg.share.appBundleID)
        case .window: target = .window(id: CGWindowID(resolved.windowID ?? 0))
        default: target = .display
        }
        let source = StageScreenSource(target: target, displayUUID: displayUUID, maxSize: outputSize)
        source.onFrame = { [weak self, weak source] buffer in
            guard let self, let source else { return }
            if self.board.offerScreen(buffer, wholeDisplay: source.wholeDisplay, from: source.id) {
                self.retireScreens(except: source.id, because: "replaced by a newer capture that has a picture")
                self.post { $0.screenLive = true; $0.lastError = nil }
            }
        }
        source.onNoPicture = { [weak self] message in
            self?.post { $0.screenLive = false; $0.lastError = message }
        }
        source.onStop = { [weak self, weak source] error in
            guard let self, let source else { return }
            // macOS ended the stream. The last picture stays up while a
            // replacement starts, so the class sees a still frame, not black.
            self.post {
                $0.screenLive = false
                $0.lastError = "The screen capture stopped (\(error.localizedDescription)). Restarting it."
            }
            self.setScreenSource(source.id, nil)
            let again = self.isCurrent(generation)
            source.stop(because: "macOS ended it, \(StageScreenSource.describe(error))")
            guard again else { return }
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.syncScreen(cfg, generation: generation)
            }
        }

        guard current() else {
            StageScreenSource.log("Not started: a newer choice (round \(generation) is out of date) arrived first.")
            return
        }
        setScreenSource(source.id, source)
        board.expectScreen(source.id)
        do { try await source.start() } catch {
            board.dropPending(source.id)
            setScreenSource(source.id, nil)
            // The old picture, if there is one, is still on screen: nothing
            // was retired. After a display change ScreenCaptureKit can take a
            // moment to list the new arrangement, so a rebuild tries again.
            if retries > 0, current() {
                StageScreenSource.log("The new capture didn\u{2019}t start (\(error.localizedDescription)); trying again in 1.5 s (\(retries) left).")
                Task.detached { [self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await syncScreen(cfg, generation: generation, retries: retries - 1)
                }
                return
            }
            post { $0.screenLive = false; $0.lastError = error.localizedDescription }
            return
        }
        let pixel = await MainActor.run { DisplayMonitor.connectedForCapture().first { $0.uuid == displayUUID }?.pixelSize }
        record(DisplayPlan.Capture(activeUUID: displayUUID, preferredUUID: cfg.displayUUID,
                                   fellBack: display.fellBack, activePixelSize: pixel,
                                   isWholeDisplay: source.wholeDisplay))
        post {
            $0.shareLabel = resolved.label
            $0.shareFallback = resolved.fallback
            $0.displayFellBack = display.fellBack
        }
        if !current() { // Superseded while starting.
            setScreenSource(source.id, nil)
            board.dropPending(source.id)
            source.stop(because: "superseded: the choice changed, or the picture stopped, while it was starting (round \(generation))")
        }
    }

    private func record(_ capture: DisplayPlan.Capture) {
        lock.lock(); activeCapture = capture; lock.unlock()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && generation == screenGeneration
    }

    private func setScreenSource(_ id: UUID, _ source: StageScreenSource?) {
        lock.lock(); screenSources[id] = source; lock.unlock()
    }

    private func retireScreens(except keep: UUID?, because reason: String) {
        lock.lock()
        let old = screenSources.filter { $0.key != keep }
        for key in old.keys { screenSources[key] = nil }
        lock.unlock()
        old.values.forEach { $0.stop(because: reason) }
    }

    // MARK: The clock

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let snap = board.snapshot()
        pushStatus(snap, now: now)
        guard !sinks.isEmpty else { return }

        if let fade = scene.fade {
            let t = fadeLength > 0 ? (now - fadeBegan) / fadeLength : 1
            scene.fade = t >= 1 ? nil : (fade.outgoing, t)
        }
        scene.contentIsWholeDisplay = snap.screen?.wholeDisplay ?? true

        var cameras: [Int: StageCameraInput] = [:]
        var needed = [scene.liveSlot]
        if let fade = scene.fade { needed.append(fade.outgoing) }
        for slot in needed where slotUIDs.indices.contains(slot) {
            if let frame = snap.cameras[slotUIDs[slot]] {
                cameras[slot] = StageCameraInput(raw: CIImage(cvPixelBuffer: frame.raw), cutout: frame.cutout)
            }
        }
        let image = renderer.compose(scene: scene,
                                     screen: snap.screen.map { CIImage(cvPixelBuffer: $0.buffer) },
                                     cameras: cameras)
        guard let buffer = pool.make() else { return }
        renderer.render(image, to: buffer)
        sinks.deliver(buffer, at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private func pushStatus(_ snap: StageInputBoard.Snapshot, now: TimeInterval) {
        guard now - lastStatusPush > 1 else { return }
        lastStatusPush = now
        let live = snap.slotUIDs.map { (snap.cameraAge[$0] ?? .infinity) < 2 }
        let screen = snap.screen != nil
        if let last = lastPushed, last.0 == screen, last.1 == live { return }
        lastPushed = (screen, live)
        post { if $0.isRunning { $0.screenLive = screen }; $0.camerasLive = live }
    }

    private func post(_ change: @escaping (StageStatus) -> Void) {
        DispatchQueue.main.async { [status] in change(status) }
    }
}

#if DEBUG
// MARK: Debug still

extension StageCompositor {
    /// One frame from supplied pictures, through exactly the draw code the
    /// live clock uses. For off-screen verification: no cameras, no screen
    /// capture, no app launch.
    struct StillInputs {
        var scene = StageScene()
        var screen: CIImage?
        var cameras: [Int: StageCameraInput] = [:]
        var size = CGSize(width: 1920, height: 1080)
    }

    static func renderStill(inputs: StillInputs) -> CGImage? {
        let renderer = StageRenderer(canvas: inputs.size)
        let image = renderer.compose(scene: inputs.scene, screen: inputs.screen, cameras: inputs.cameras)
        return renderer.context.createCGImage(image, from: CGRect(origin: .zero, size: inputs.size),
                                              format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
#endif
