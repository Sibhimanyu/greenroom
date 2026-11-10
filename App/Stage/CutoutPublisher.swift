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

final class CutoutPublisher: NSObject {

    /// One camera frame, handed straight to the compositor.
    struct Frame {
        /// The camera's own picture, untouched.
        let raw: CVPixelBuffer
        /// The same frame with everything but the person transparent. Nil
        /// unless `removesBackground` was on when the frame arrived. Empty
        /// (fully clear) when nobody was found.
        let cutout: CIImage?
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

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.sibhimanyu.greenroom.cutout", qos: .userInteractive)
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let sequence = VNSequenceRequestHandler()

    /// Nil when the camera cannot be opened.
    init?(uid: String, slot: Int, removesBackground: Bool) {
        guard let camera = AVCaptureDevice(uniqueID: uid),
              let input = try? AVCaptureDeviceInput(device: camera) else { return nil }
        self.uid = uid
        self.slot = slot
        self._removesBackground = removesBackground
        super.init()

        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8

        session.beginConfiguration()
        // 1080p where the camera has it: the cutout is drawn large, up to
        // full frame height in Presenter, and a 720p person shows it.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else {
            session.sessionPreset = .high
        }
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // A late frame is dropped, never queued: a queue would add delay to
        // the picture that never comes back.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
        session.commitConfiguration()
    }

    func start() {
        queue.async { [session] in session.startRunning() }
    }

    func stop() {
        queue.sync { session.stopRunning() }
    }

    // MARK: Per frame

    private func process(_ frame: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(cvPixelBuffer: frame)

        let removing = removesBackground
        if removing {
            let found = (try? sequence.perform([segmentation], on: frame)) != nil
                ? segmentation.results?.first?.pixelBuffer : nil
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

        if !removing { notePerson(true) }
        onFrame?(Frame(raw: frame, cutout: removing ? image : nil))
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
        process(frame)
    }
}
