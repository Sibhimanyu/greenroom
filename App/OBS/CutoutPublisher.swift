//
//  CutoutPublisher.swift
//  Greenroom
//
//  The camera, with the background removed in software, handed to OBS.
//
//  Cutout and Presenter used to need a real green screen: OBS keyed the green
//  out, and without one the whole room came along. Most people do not own a
//  green screen, so for most people those two looks did not exist. This opens
//  the camera in Greenroom instead, asks Vision where the person is
//  (VNGeneratePersonSegmentationRequest, on device), and publishes the
//  picture with everything else transparent over Syphon. OBS 32 ships a
//  Syphon source that keeps the transparency, so the scene treats it exactly
//  like a keyed camera.
//
//  For the bubble shapes there is nothing to remove, so the frame goes through
//  untouched. That keeps one source per camera whatever the shape, which is
//  what lets the shape change mid-class without rebuilding anything.
//
//  Measured before building (docs/stage-and-looks-plan.md, spike result):
//  `.balanced` takes about 12 ms a 720p frame on an M5 Pro with clean edges
//  and hair; `.fast` leaves jagged fringes, `.accurate` costs three times as
//  much for nothing visible.
//
//  Syphon is loaded at runtime (see SyphonServer below), so nothing here
//  needs its headers, and a build without the framework still runs: the
//  publisher reports itself unavailable and the scene keeps OBS's own camera.
//
import AVFoundation
import CoreImage
import Foundation
import Metal
import Vision

final class CutoutPublisher: NSObject {

    /// What OBS's Syphon source looks for. One per camera, so two cameras can
    /// be cut between exactly as before.
    static func serverName(slot: Int) -> String {
        slot == 0 ? "Greenroom Camera" : "Greenroom Camera \(slot + 1)"
    }

    /// The process name OBS lists the servers under.
    static var appName: String { ProcessInfo.processInfo.processName }

    static var isAvailable: Bool { SyphonServer.isAvailable && MTLCreateSystemDefaultDevice() != nil }

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
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let server: SyphonServer
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private let sequence = VNSequenceRequestHandler()
    private var texture: MTLTexture?

    /// Nil when Syphon or Metal is missing, or the camera cannot be opened.
    init?(uid: String, slot: Int, removesBackground: Bool) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let server = SyphonServer(name: Self.serverName(slot: slot), device: device),
              let camera = AVCaptureDevice(uniqueID: uid),
              let input = try? AVCaptureDeviceInput(device: camera) else { return nil }
        self.uid = uid
        self.slot = slot
        self.device = device
        self.commandQueue = commandQueue
        self.server = server
        self.context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
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
        server.stop()
    }

    // MARK: Per frame

    private func publish(_ frame: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        guard let target = texture(width: width, height: height),
              let buffer = commandQueue.makeCommandBuffer() else { return }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var image = CIImage(cvPixelBuffer: frame)

        if removesBackground {
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

        if !removesBackground { notePerson(true) }
        context.render(image, to: target, commandBuffer: buffer, bounds: bounds,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        // Not waited on. The command queue runs in order, so the next frame's
        // render cannot overtake Syphon's copy of this one, and blocking here
        // was most of what the spike measured as per-frame cost.
        server.publish(texture: target, on: buffer, region: bounds)
        buffer.commit()
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

    private func texture(width: Int, height: Int) -> MTLTexture? {
        if let texture, texture.width == width, texture.height == height { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        texture = device.makeTexture(descriptor: descriptor)
        return texture
    }
}

extension CutoutPublisher: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        publish(frame)
    }
}

/// `SyphonMetalServer`, reached through the Objective-C runtime.
///
/// The framework is embedded but not linked, and has no headers in it, so the
/// three calls Greenroom needs go through `objc_msgSend` directly - the same
/// calls the spike proved against OBS.
private final class SyphonServer {
    private static let handle: UnsafeMutableRawPointer? = {
        guard let url = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("Syphon.framework/Syphon") else { return nil }
        return dlopen(url.path, RTLD_NOW)
    }()
    private static var serverClass: NSObject.Type? {
        guard handle != nil else { return nil }
        return NSClassFromString("SyphonMetalServer") as? NSObject.Type
    }
    static var isAvailable: Bool { serverClass != nil }

    private typealias InitFn = @convention(c) (AnyObject, Selector, NSString, MTLDevice, NSDictionary?) -> AnyObject?
    private typealias PublishFn = @convention(c) (AnyObject, Selector, MTLTexture, MTLCommandBuffer, NSRect, Bool) -> Void
    private typealias StopFn = @convention(c) (AnyObject, Selector) -> Void
    private static let send = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")

    private let object: AnyObject

    init?(name: String, device: MTLDevice) {
        guard let serverClass = Self.serverClass, let send = Self.send,
              let allocated = serverClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let object = unsafeBitCast(send, to: InitFn.self)(
                allocated, NSSelectorFromString("initWithName:device:options:"),
                name as NSString, device, nil) else { return nil }
        self.object = object
    }

    func publish(texture: MTLTexture, on buffer: MTLCommandBuffer, region: CGRect) {
        guard let send = Self.send else { return }
        unsafeBitCast(send, to: PublishFn.self)(
            object, NSSelectorFromString("publishFrameTexture:onCommandBuffer:imageRegion:flipped:"),
            texture, buffer, NSRect(origin: region.origin, size: region.size), false)
    }

    func stop() {
        guard let send = Self.send else { return }
        unsafeBitCast(send, to: StopFn.self)(object, NSSelectorFromString("stop"))
    }
}
