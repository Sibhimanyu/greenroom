//
//  StagePreviewSink.swift
//  Greenroom
//
//  Two small sinks for the class picture (see StageFrames.swift).
//
//  `StagePreviewSink` keeps the newest frame as a small picture for SwiftUI,
//  a few times a second, so Settings can show what the class gets without the
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
    /// Called on the main thread with each new picture.
    var onPicture: ((NSImage) -> Void)?

    private let framesPerSecond: Double
    private let width: CGFloat
    private let queue = DispatchQueue(label: "greenroom.stage.preview", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var lastTaken: UInt64 = 0
    private var busy = false

    init(framesPerSecond: Double = 8, width: CGFloat = 960) {
        self.framesPerSecond = framesPerSecond
        self.width = width
    }

    func stageDidRender(_ frame: CVPixelBuffer, at time: CMTime) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let due = !busy && Double(now &- lastTaken) / 1e9 >= 1 / framesPerSecond
        if due { busy = true; lastTaken = now }
        lock.unlock()
        guard due else { return }
        queue.async { [self] in
            defer { lock.lock(); busy = false; lock.unlock() }
            let image = CIImage(cvPixelBuffer: frame)
            let scale = width / image.extent.width
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(small, from: small.extent) else { return }
            let picture = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async { [weak self] in self?.onPicture?(picture) }
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
