//
//  StageFrames.swift
//  Greenroom
//
//  The one seam between the picture and everything that uses it.
//
//  Greenroom used to hand the class picture to OBS and read it back as a
//  system camera (docs/drop-obs-plan.md). Now `StageCompositor` makes the
//  picture itself, and three things consume it: the meeting
//  (`ZoomVideoSender`), the recorder (`SessionRecorder`) and the Settings
//  preview. They meet here, and only here, so each side can be built and
//  tested against `StageTestPattern` without the others existing.
//
//  The contract:
//   - Frames are `kCVPixelFormatType_32BGRA`, IOSurface-backed, at the
//     source's `outputSize` (1920x1080 by default). One format keeps the
//     compositor simple. Each sink converts for itself: the meeting to I420
//     at whatever size the SDK asks for, and the recorder through
//     VideoToolbox, which takes BGRA directly.
//   - `stageDidRender` is called on the compositor's render queue, at the
//     source's frame rate. A sink must not block it. Retain the buffer and
//     hand it to your own queue. Drop frames rather than queue them up.
//   - Timestamps are host-clock `CMTime` (`CMClockGetHostTimeClock`), so the
//     recorder can line video up with microphone audio from AVFoundation.
//   - The source holds sinks weakly. Whoever creates a sink keeps it alive.
//

import CoreMedia
import CoreVideo
import Foundation

protocol StageFrameSink: AnyObject {
    /// Called on the source's render queue. Must return quickly.
    func stageDidRender(_ frame: CVPixelBuffer, at time: CMTime)
}

protocol StageFrameSource: AnyObject {
    var outputSize: CGSize { get }
    var frameRate: Int { get }
    func addSink(_ sink: StageFrameSink)
    func removeSink(_ sink: StageFrameSink)
}

/// Weak list of sinks with a lock, shared by every source so fan-out is
/// written once.
final class StageSinkList {
    private struct Weak { weak var sink: StageFrameSink? }
    private var sinks: [Weak] = []
    private let lock = NSLock()

    func add(_ sink: StageFrameSink) {
        lock.lock(); defer { lock.unlock() }
        sinks.removeAll { $0.sink == nil || $0.sink === sink }
        sinks.append(Weak(sink: sink))
    }

    func remove(_ sink: StageFrameSink) {
        lock.lock(); defer { lock.unlock() }
        sinks.removeAll { $0.sink == nil || $0.sink === sink }
    }

    func deliver(_ frame: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        let live = sinks.compactMap(\.sink)
        lock.unlock()
        for sink in live { sink.stageDidRender(frame, at: time) }
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return sinks.allSatisfy { $0.sink == nil }
    }
}

/// Makes BGRA IOSurface-backed buffers of one size, reused through a pool.
final class StageBufferPool {
    let size: CGSize
    private let pool: CVPixelBufferPool

    init?(size: CGSize, minimumBuffers: Int = 6) {
        self.size = size
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width),
            kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttrs: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: minimumBuffers]
        var made: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &made) == kCVReturnSuccess,
              let made else { return nil }
        pool = made
    }

    func make() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}

/// A moving test picture at a fixed clock: a stand-in for the compositor,
/// so a sink can be built and measured before the real picture exists.
/// Kept in all builds because the tests and the debug engine switch use it.
/// It draws nothing a user can see unless a debug path wires it up.
final class StageTestPattern: StageFrameSource {
    let outputSize: CGSize
    let frameRate: Int
    private let sinks = StageSinkList()
    private let queue = DispatchQueue(label: "greenroom.stage.testpattern", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: StageBufferPool?
    private var frameIndex = 0

    init(size: CGSize = CGSize(width: 1920, height: 1080), frameRate: Int = 30) {
        outputSize = size
        self.frameRate = frameRate
        pool = StageBufferPool(size: size)
    }

    func addSink(_ sink: StageFrameSink) { sinks.add(sink) }
    func removeSink(_ sink: StageFrameSink) { sinks.remove(sink) }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(frameRate))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in timer?.cancel(); timer = nil }
    }

    private func tick() {
        guard let pool, let buffer = pool.make() else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let bar = (frameIndex % frameRate) * w / frameRate
            let barWidth = max(w / 20, 1)
            for y in 0..<h {
                let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
                for x in 0..<w {
                    // BGRA little-endian: 0xAARRGGBB. Navy, with a yellow bar.
                    row[x] = (x >= bar && x < bar + barWidth) ? 0xFFFF_D400 : 0xFF14_2850
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        frameIndex += 1
        sinks.deliver(buffer, at: CMClockGetTime(CMClockGetHostTimeClock()))
    }
}
