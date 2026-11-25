//
//  StagePreviewSink.swift
//  Greenroom
//
//  Two small sinks for the class picture (see StageFrames.swift).
//
//  `StagePreviewSink` keeps the newest frame as a small picture for SwiftUI,
//  at `PreviewRate` (30 a second on Home), so Settings can show what the class gets without the
//  compositor doing anything extra: it takes the buffer, drops it unless a
//  picture is due, and does the downscale on its own queue.
//
//  `StageFrameProbe` only answers "has a frame arrived yet?", which Start
//  waits on before the meeting starts.
//
import AppKit
import CoreImage
import CoreMedia
import CoreVideo

final class StagePreviewSink: StageFrameSink {
    /// Called on the main thread with each new picture, and a mask that is
    /// opaque everywhere the cameras did not draw (nil when none drew over
    /// shared content).
    var onPicture: ((NSImage, NSImage?) -> Void)?
    /// The camera alpha of the frame being delivered; read on the render
    /// queue inside `stageDidRender`, so it matches that frame.
    var coverage: (() -> CIImage?)?

    /// Set by whoever knows the session; picks the rate (`PreviewRate`).
    /// Read on the render queue, so it is under the lock.
    var meetingLive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return live }
        set { lock.lock(); live = newValue; lock.unlock() }
    }
    private var live = false
    private let fixedRate: Double?
    private let width: CGFloat
    private let queue = DispatchQueue(label: "greenroom.stage.preview", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var lastTaken: UInt64 = 0
    private var busy = false

    /// `framesPerSecond` nil: the rate follows `meetingLive`.
    init(framesPerSecond: Double? = nil, width: CGFloat = 960) {
        self.fixedRate = framesPerSecond
        self.width = width
    }

    func stageDidRender(_ frame: CVPixelBuffer, at time: CMTime) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let rate = fixedRate ?? PreviewRate.framesPerSecond(meetingLive: live)
        let due = !busy && Double(now &- lastTaken) / 1e9 >= 1 / rate
        if due { busy = true; lastTaken = now }
        lock.unlock()
        guard due else { return }
        let cameras = coverage?()
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            let image = CIImage(cvPixelBuffer: frame)
            let scale = width / image.extent.width
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(small, from: small.extent) else { return }
            let picture = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            // Everything but the cameras: white, with the cameras' alpha cut
            // out. Built at the picture's size (scale first, then cut), so the
            // cutout chain is not run at canvas size for every frame.
            var mask: NSImage?
            if let cameras {
                let area = small.extent
                let all = CIImage(color: .white).cropped(to: area)
                let open = all.applyingFilter("CISourceOutCompositing",
                                              parameters: [kCIInputBackgroundImageKey:
                                                            cameras.transformed(by: CGAffineTransform(scaleX: scale, y: scale))])
                if let m = context.createCGImage(open, from: area) {
                    mask = NSImage(cgImage: m, size: picture.size)
                }
            }
            #if DEBUG
            PreviewFpsLog.count(.picture)
            #endif
            DispatchQueue.main.async { [weak self] in self?.onPicture?(picture, mask) }
        }
    }
}

final class StageFrameProbe: StageFrameSink {
    private let lock = NSLock()
    private var seen = false
    var hasFrame: Bool { lock.lock(); defer { lock.unlock() }; return seen }
    func stageDidRender(_ frame: CVPixelBuffer, at time: CMTime) {
        lock.lock(); seen = true; lock.unlock()
    }
}
