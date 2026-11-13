//
//  CameraProbe.swift
//  Greenroom
//
//  Looking through one camera to see what angle it reads you at.
//
//  This exists because of a bug worth keeping the shape of. The angle
//  readout in Settings once depended on machinery that was not running while
//  somebody sat at their desk aiming a camera, so no picture arrived, the
//  angle stayed empty, and the window told somebody sitting directly in front
//  of their camera that there was no face in it.
//
//  The lesson was about shape, not message: aiming a camera is what somebody
//  does before a class, with nothing running, so it must not depend on the
//  machinery of the live task. That is still true, and it is cheap to keep
//  now. Setup and class use the same kind of opener - a plain AVCaptureSession
//  on the camera - and differ only in who holds it:
//
//   - **Setting up, idle:** this. Greenroom opens the camera itself, so any
//     camera can be checked instantly, with no session started.
//   - **In a class:** CameraDirector, reading the frames of the cameras
//     StageCompositor already holds open. Nothing opens a camera a second time.
//
//  This only runs when no session is live (see the guards in
//  CoordinatorController, and `cameraProbe.stop()` when a session starts), so
//  the two never contend for a device.
//
import AVFoundation
import CoreImage
import Foundation

@MainActor
final class CameraProbe: NSObject, ObservableObject {

    /// What the camera can see right now.
    @Published private(set) var sight: CameraSight = .idle

    /// Which camera this is looking through, by uniqueID.
    @Published private(set) var cameraUID: String?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "greenroom.camera-probe")

    /// Vision runs on some frames, not all of them. Three times a second is
    /// far more than a person aiming a camera can react to, and it keeps this
    /// from being a reason the fans come on while somebody reads a settings
    /// window.
    private static let everyNthFrame = 10
    private var frameNumber = 0
    private var busy = false

    private var deviceObservers: [NSObjectProtocol] = []

    /// The camera being aimed can be unplugged, or come back, while Settings
    /// is open. A dead session says nothing, so without this the readout kept
    /// its last answer. Same events CutoutPublisher recovers from; this only
    /// reports and re-opens (idle only, so there is never a stand-in here:
    /// aiming a camera that is not the one you chose would be a wrong answer).
    private func watchDevices() {
        guard deviceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        deviceObservers = [
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let device = note.object as? AVCaptureDevice,
                          device.uniqueID == self.cameraUID else { return }
                    self.sight = .noPicture("\(device.localizedName) was unplugged.")
                }
            },
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let device = note.object as? AVCaptureDevice,
                          device.uniqueID == self.cameraUID else { return }
                    let uid = device.uniqueID
                    self.stop()
                    self.start(uid: uid)
                }
            },
        ]
    }

    // MARK: Starting and stopping

    /// Opens a camera and starts reporting the angle.
    ///
    /// Idempotent per camera: asking for the one already open does nothing,
    /// so a settings view rebuilding does not restart the hardware.
    func start(uid: String) {
        watchDevices()
        guard cameraUID != uid else { return }
        stop()
        cameraUID = uid
        sight = .idle

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            open(uid: uid)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.cameraUID == uid else { return }
                    granted ? self.open(uid: uid)
                            : (self.sight = .noPicture("Greenroom needs camera access. System Settings \u{2192} Privacy & Security \u{2192} Camera."))
                }
            }
        default:
            sight = .noPicture("Camera access is off for Greenroom. System Settings \u{2192} Privacy & Security \u{2192} Camera.")
        }
    }

    func stop() {
        cameraUID = nil
        sight = .idle
        guard session.isRunning || !session.inputs.isEmpty else { return }
        session.stopRunning()
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for out in session.outputs { session.removeOutput(out) }
        session.commitConfiguration()
    }

    private func open(uid: String) {
        guard let device = AVCaptureDevice(uniqueID: uid) else {
            sight = .noPicture("That camera isn't plugged in.")
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            sight = .noPicture("Couldn't open \(device.localizedName). Something else may have it.")
            return
        }
        session.beginConfiguration()
        // Low. This measures the angle of a head; it is never shown to
        // anybody, and a 4K frame would cost real power to look at.
        session.sessionPreset = .low
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            sight = .noPicture("Couldn't open \(device.localizedName).")
            return
        }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        // startRunning blocks until the device is open, which on a Continuity
        // camera waking up is not instant.
        let capture = session
        Task.detached { capture.startRunning() }
    }
}

extension CameraProbe: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Copy what is needed off the buffer before returning: the sample
        // buffer is recycled the moment this call ends, and Vision on the
        // main actor would be reading freed memory.
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cgImage = CameraProbe.context.createCGImage(image, from: image.extent) else { return }
        Task { @MainActor [weak self] in self?.consider(cgImage) }
    }

    private func consider(_ frame: CGImage) {
        frameNumber += 1
        guard frameNumber % Self.everyNthFrame == 0, !busy else { return }
        busy = true
        defer { busy = false }
        sight = CameraDirector.look(at: frame)
    }

    /// One, reused. Building a CIContext per frame is the classic way to make
    /// a cheap thing expensive.
    fileprivate static let context = CIContext(options: [.useSoftwareRenderer: false])
}
