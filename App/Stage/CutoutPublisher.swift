//
//  CutoutPublisher.swift
//  Greenroom
//
//  One camera, opened by StageCompositor, with the background removed in
//  software when the look wants it.
//
//  Cutout and Presenter used to need a real green screen: the green was keyed
//  out, and without one the whole room came along. Most people do not own a
//  green screen, so for most people those two looks did not exist. This opens
//  the camera, asks Vision where the person is
//  (VNGeneratePersonSegmentationRequest, on device), and hands the compositor
//  both the untouched frame and a cutout with everything else transparent.
//
//  For the bubble shapes there is nothing to remove, so the cutout is left
//  out and the frame goes through untouched. That keeps one opener per camera
//  whatever the shape, which is what lets the shape change mid-class without
//  reopening anything.
//
//  Measured before building (docs/stage-and-looks-plan.md, spike result):
//  `.balanced` takes about 12 ms a 720p frame on an M5 Pro with clean edges
//  and hair; `.fast` leaves jagged fringes, `.accurate` costs three times as
//  much for nothing visible.
//
import AVFoundation
import CoreImage
import Foundation
import Metal
import Vision

//  Camera backgrounds (Blur, Image) and camera recovery, added in the
//  Recorditor port (docs/recorditor-integration/camera-port-log.md):
//
//   - The same segmentation answers for Cutout/Presenter (`cutout`) and for
//     Blur/Image (`background`). Only one of them is made for a frame, and
//     nothing is segmented at all while the look is a plain bubble set to
//     Normal.
//   - If the camera this publisher was opened for is unplugged mid-session
//     (or its session fails), it is rebuilt around what is there: the
//     system default camera stands in, and the chosen camera gets five
//     seconds to deliver when it returns. See `recover`. With two or more
//     cameras the CameraDirector owns which one is live, so no stand-in is
//     ever chosen then; the publisher only re-attaches its own camera.

final class CutoutPublisher: NSObject {

    /// One camera frame, handed straight to the compositor.
    struct Frame {
        /// The camera's own picture, untouched.
        let raw: CVPixelBuffer
        /// The same frame with everything but the person transparent. Nil
        /// unless `removesBackground` was on when the frame arrived. Empty
        /// (fully clear) when nobody was found.
        let cutout: CIImage?
        /// The same frame with Blur or an Image behind the person. Nil
        /// unless a background was asked for (and then only for the bubble
        /// shapes: Cutout and Presenter take their own path above).
        let background: CIImage?
    }

    /// Called on the capture queue for every frame. Must return quickly; keep
    /// the frame, hand it on.
    var onFrame: ((Frame) -> Void)?

    let uid: String
    let slot: Int

    /// Cut the person out, or pass the frame through. Read on the capture
    /// queue, written from the main thread, so it is guarded.
    var removesBackground: Bool {
        get { lock.withLock { _removesBackground } }
        set { lock.withLock { _removesBackground = newValue } }
    }
    private var _removesBackground = false
    private let lock = NSLock()

    /// Called on the main thread when the camera starts or stops seeing
    /// anyone, so the page can say why the picture is empty. A laptop camera
    /// tipped back under a monitor sees the ceiling, removes everything, and
    /// otherwise looks exactly like a broken camera.
    var onPersonInView: ((Bool) -> Void)?
    private var lastPersonSeen = Date()
    private var reportedInView = true

    /// Blur or an Image behind the person, for the bubble shapes. Read on
    /// the capture queue, written from the control queue.
    func setBackground(_ mode: CameraBackground, image: CIImage?) {
        lock.withLock { _background = (mode, image) }
    }
    private var _background: (mode: CameraBackground, image: CIImage?) = (.normal, nil)

    /// Called (any queue) when another camera starts or stops standing in
    /// for the chosen one. A sentence for the log, or nil when the chosen
    /// camera is back.
    var onStandIn: ((String?) -> Void)?

    /// May the system default camera stand in when the chosen one is gone?
    /// Only while this is the one camera the stage holds; with several, the
    /// CameraDirector decides which one shows.
    func setAllowsStandIn(_ allowed: Bool) {
        controlQueue.async { [self] in
            guard allowsStandIn != allowed else { return }
            allowsStandIn = allowed
            guard wantsRunning else { return }
            applyPreferredDevice()
            startIfNeeded()
        }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.sibhimanyu.greenroom.cutout", qos: .userInteractive)
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let sequence = VNSequenceRequestHandler()
    private let refiner = MaskRefiner()
    private var effectWasOn = false   // capture queue only

    // Recovery state. controlQueue only, except `lastFrameAt` (under `lock`).
    private let controlQueue = DispatchQueue(label: "com.sibhimanyu.greenroom.cutout.control", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var allowsStandIn = false
    private var standingIn = false
    private var wantsRunning = false
    private var lastRecoveryAt: CFAbsoluteTime = 0
    /// The chosen camera came back on its own and has 5 s to deliver a frame
    /// (a Continuity Camera iPhone in a pocket is "connected" but never
    /// streams), after which the stand-in returns.
    private var probing: (token: Int, since: CFAbsoluteTime)?
    private var probeToken = 0
    /// The chosen camera failed its probe: passed over until it disconnects
    /// and reconnects.
    private var skipUntilReconnect = false
    private var observers: [NSObjectProtocol] = []
    private var lastFrameAt: CFAbsoluteTime = 0   // under `lock`

    /// Nil when no camera can be opened. `allowsStandIn`: see `setAllowsStandIn`.
    init?(uid: String, slot: Int, removesBackground: Bool, allowsStandIn: Bool = false) {
        self.uid = uid
        self.slot = slot
        self._removesBackground = removesBackground
        self.allowsStandIn = allowsStandIn
        super.init()

        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8

        session.beginConfiguration()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // A late frame is dropped, never queued: a queue would add delay to
        // the picture that never comes back.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return nil }
        session.addOutput(output)
        session.commitConfiguration()

        applyPreferredDevice()
        guard !attachedVideoInputs.isEmpty else { return nil }
        watchDevices()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func start() {
        controlQueue.async { [self] in
            wantsRunning = true
            startIfNeeded()
        }
    }

    func stop() {
        controlQueue.sync { [self] in
            wantsRunning = false
            probing = nil
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: Camera recovery (controlQueue)
    //
    // Ported from Recorditor's CameraCapture (resolveDevice,
    // applyPreferredDevice, replaceVideoInputs, recover, checkFrames). The
    // chosen camera is `uid`; there is no "System default" choice here
    // (LocalDeviceResolver picks what to open), so "the chosen camera" is
    // simply the one this publisher was made for.

    private var attachedVideoInputs: [AVCaptureDeviceInput] {
        session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.video) }
    }

    private func startIfNeeded() {
        guard wantsRunning, !session.isRunning, !session.inputs.isEmpty else { return }
        session.startRunning()
    }

    private func watchDevices() {
        let center = NotificationCenter.default
        // AVFoundation posts a runtime error and leaves the dead input in the
        // session, so nothing arrives again, not even after the device comes
        // back. Rebuild around whatever camera is there now.
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session,
                                            queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.controlQueue.async {
                self?.recover(reason: "runtime error \(error?.code ?? 0): \(error?.localizedDescription ?? "?")")
            }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil,
                                            queue: nil) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice, device.hasMediaType(.video) else { return }
            self?.controlQueue.async {
                guard let self,
                      self.attachedVideoInputs.contains(where: { $0.device.uniqueID == device.uniqueID }) else { return }
                self.recover(reason: "\(device.localizedName) disconnected")
            }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil,
                                            queue: nil) { [weak self] note in
            guard let device = note.object as? AVCaptureDevice, device.hasMediaType(.video) else { return }
            self?.controlQueue.async {
                guard let self, self.wantsRunning else { return }
                if device.uniqueID == self.uid { self.skipUntilReconnect = false }
                // The chosen camera is back, or (stand-in allowed) the first
                // camera arrived after everything had gone: go to it.
                let nothingAttached = self.attachedVideoInputs.isEmpty && self.allowsStandIn
                guard device.uniqueID == self.uid || nothingAttached else { return }
                let wasStandingIn = self.standingIn || self.attachedVideoInputs.isEmpty
                self.applyPreferredDevice()
                self.startIfNeeded()
                if wasStandingIn, !self.standingIn, device.uniqueID == self.uid {
                    self.beginProbe()
                }
            }
        })
    }

    /// The chosen camera when it is connected. Otherwise, when a stand-in is
    /// allowed: the system default, or any other connected camera.
    private func resolveDevice(excluding dead: Set<String>) -> (device: AVCaptureDevice, standingIn: Bool)? {
        let usable: (AVCaptureDevice) -> Bool = { [skipUntilReconnect, uid] in
            $0.isConnected && !dead.contains($0.uniqueID) && !(skipUntilReconnect && $0.uniqueID == uid)
        }
        if let device = AVCaptureDevice(uniqueID: uid), usable(device) { return (device, false) }
        guard allowsStandIn else { return nil }
        if let device = AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video),
           usable(device), device.uniqueID != uid {
            return (device, true)
        }
        let others = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified).devices
            .filter { usable($0) && $0.uniqueID != uid }
        let pick = others.first { !$0.isSuspended } ?? others.first
        return pick.map { ($0, true) }
    }

    /// Puts the resolved camera into the session unless it is already the one
    /// attached and still connected.
    private func applyPreferredDevice(excluding dead: Set<String> = []) {
        let attached = attachedVideoInputs
        guard let pick = resolveDevice(excluding: dead) else {
            if !attached.isEmpty { replaceVideoInputs(with: nil) }
            setStandingIn(false, device: nil)
            return
        }
        setStandingIn(pick.standingIn, device: pick.device)
        if attached.count == 1, attached[0].device === pick.device, pick.device.isConnected { return }
        guard let input = try? AVCaptureDeviceInput(device: pick.device) else { return }
        replaceVideoInputs(with: input)
    }

    private func replaceVideoInputs(with input: AVCaptureDeviceInput?) {
        session.beginConfiguration()
        for existing in attachedVideoInputs { session.removeInput(existing) }
        if let input, session.canAddInput(input) { session.addInput(input) }
        // 1080p where the camera has it: the cutout is drawn large, up to
        // full frame height in Presenter, and a 720p person shows it. A
        // stand-in may not have it.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        session.commitConfiguration()
    }

    private func setStandingIn(_ now: Bool, device: AVCaptureDevice?) {
        guard now != standingIn else { return }
        standingIn = now
        let chosen = LocalDeviceResolver.cameraName(uid: uid) ?? "the chosen camera"
        onStandIn?(now ? "Using \(device?.localizedName ?? "another camera") until \(chosen) is back." : nil)
    }

    /// After a runtime error or a disconnect: drop the video input(s) and
    /// attach what is available, restarting the session if the error stopped
    /// it. The disconnect and the error for the same event arrive back to
    /// back; the second pass is skipped.
    private func recover(reason: String) {
        guard wantsRunning else { return }
        let attached = attachedVideoInputs
        let dead = Set(attached.filter { !$0.device.isConnected }.map(\.device.uniqueID))
        let now = CFAbsoluteTimeGetCurrent()
        if dead.isEmpty, now - lastRecoveryAt < 1 { return }
        lastRecoveryAt = now
        StageScreenSource.log("Camera recovering (\(reason)): \(attached.count) video input(s), \(dead.count) dead.")
        replaceVideoInputs(with: nil)
        applyPreferredDevice(excluding: dead)
        startIfNeeded()
    }

    /// The chosen camera is back: five seconds to deliver a frame, then the
    /// stand-in returns and the camera is passed over until it reconnects.
    private func beginProbe() {
        probeToken += 1
        let token = probeToken
        let since = CFAbsoluteTimeGetCurrent()
        probing = (token, since)
        controlQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.wantsRunning, let probe = self.probing, probe.token == token else { return }
            self.probing = nil
            let last = self.lock.withLock { self.lastFrameAt }
            if last > probe.since { return }       // it delivers: it stays
            StageScreenSource.log("Camera reconnected but sent nothing for 5 s; back to the stand-in.")
            self.skipUntilReconnect = true
            self.applyPreferredDevice()
            self.startIfNeeded()
        }
    }

    // MARK: Per frame

    private func process(_ frame: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(cvPixelBuffer: frame)
        lock.withLock { lastFrameAt = CFAbsoluteTimeGetCurrent() }

        let removing = removesBackground
        let effect = lock.withLock { _background }
        // Vision runs only when something will use the answer.
        let wantsEffect = !removing && effect.mode != .normal
        var found: CVPixelBuffer?
        if removing || wantsEffect {
            found = (try? sequence.perform([segmentation], on: frame)) != nil
                ? segmentation.results?.first?.pixelBuffer : nil
        }

        if removing {
            notePerson(found.map(Self.hasPerson) ?? false)
            if let mask = found {
                var matte = CIImage(cvPixelBuffer: mask)
                matte = matte.transformed(by: CGAffineTransform(
                    scaleX: CGFloat(width) / matte.extent.width,
                    y: CGFloat(height) / matte.extent.height))
                image = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: bounds),
                    kCIInputMaskImageKey: matte
                ])
            } else {
                // No person found, or Vision failed on this frame: send
                // nothing rather than the room. The class sees the shared
                // screen for a frame, not your kitchen.
                image = CIImage(color: .clear).cropped(to: bounds)
            }
        }

        var background: CIImage?
        if wantsEffect {
            effectWasOn = true
            background = CameraEffects.apply(image, maskBuffer: refiner.refine(found),
                                             mode: effect.mode, background: effect.image)
        } else if effectWasOn {
            effectWasOn = false
            refiner.reset()
        }

        if !removing { notePerson(true) }
        onFrame?(Frame(raw: frame, cutout: removing ? image : nil, background: background))
    }

    /// Whether the mask covers more than a sliver of the frame. Sampled on a
    /// coarse grid: this is a yes-or-no, not a measurement.
    private static func hasPerson(_ mask: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
        let row = CVPixelBufferGetBytesPerRow(mask)
        var on = 0, total = 0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                total += 1
                if base[y * row + x] > 128 { on += 1 }
            }
        }
        return total > 0 && Double(on) / Double(total) > 0.01
    }

    /// A second of nobody before saying so, so turning away or a missed
    /// frame does not flicker the warning.
    private func notePerson(_ seen: Bool) {
        let now = Date()
        if seen { lastPersonSeen = now }
        let inView = seen || now.timeIntervalSince(lastPersonSeen) < 1
        guard inView != reportedInView else { return }
        reportedInView = inView
        DispatchQueue.main.async { [weak self] in self?.onPersonInView?(inView) }
    }
}

extension CutoutPublisher: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 30 fps callbacks never let this queue drain its autorelease pool, so
        // the per-frame Core Image temporaries pile up. Drain every frame.
        autoreleasepool { process(frame) }
    }
}
