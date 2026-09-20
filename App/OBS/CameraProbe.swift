//
//  CameraProbe.swift
//  Greenroom
//
//  Looking through one camera to see what angle it reads you at.
//
//  This exists because of a bug worth keeping the shape of. The angle
//  readout in Settings originally came through OBS, the same route
//  CameraDirector uses during a class. OBS was not running, so no picture
//  arrived, so the angle stayed empty - and the window told somebody sitting
//  directly in front of their camera that there was no face in it.
//
//  The deeper mistake was not the message. It was making the SETUP task
//  depend on the machinery of the LIVE task. Aiming a camera is what somebody
//  does before a class, at a desk, with nothing running. Requiring them to
//  start a screen-capture tool first to find out where their camera is
//  pointing is the wrong shape for the job.
//
//  So the two paths are deliberately different, and the difference is the
//  point:
//
//   - **Setting up, idle:** this. Greenroom opens the camera itself. No OBS,
//     no scene, no virtual camera. Any camera can be checked instantly,
//     including one OBS has never heard of.
//   - **In a class:** CameraDirector, through OBS. There is exactly one
//     opener of the camera then, which is the whole reason that path exists.
//
//  Nothing here is ever running while a session is - see the guards in
//  CoordinatorController - so the two never contend for a device.
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

    // MARK: Starting and stopping

    /// Opens a camera and starts reporting the angle.
    ///
    /// Idempotent per camera: asking for the one already open does nothing,
    /// so a settings view rebuilding does not restart the hardware.
    func start(uid: String) {
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
