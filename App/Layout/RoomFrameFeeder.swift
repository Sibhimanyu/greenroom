//
//  RoomFrameFeeder.swift
//  Greenroom
//
//  Hands the Room screen's frames (the compositor's output, or its own display
//  capture) to the layer on the big screen in the room. RoomScreenWindow.swift
//  makes it a `StageFrameSink`.
//
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import os
import QuartzCore

/// Puts the newest frame on one layer, as its contents (the frame's IOSurface:
/// zero copy, the GPU shows it straight from the surface).
///
/// Called from the compositor's render queue or the capture queue. It keeps only
/// the newest frame and sets it on the main thread, once per main-queue turn, so
/// a busy main thread drops frames instead of queueing them.
///
/// Not an AVSampleBufferDisplayLayer: its image queue stopped being shown on the
/// room display after 15 to 106 s while frames kept arriving (2026-11-26, system
/// stats "enqueued: 180, displayed: 0, evicted: 180"), and the room saw one
/// frozen picture. Contents set in a CA transaction are part of the window's own
/// layer tree, which the window server always draws.
final class RoomFrameFeeder: @unchecked Sendable {   // lock-guarded; `applied` is main-only
    private let layer: CALayer
    private let lock = NSLock()
    private var pending: CVPixelBuffer?    // under lock
    private var drainQueued = false        // under lock
    private var received = 0               // under lock
    private var applied = 0                // main thread
    #if DEBUG
    private let stats = DeliveryStats()
    /// The latest capture frame's own host-clock stamp (capture queue only).
    var captureStamp = CMTime.invalid
    #endif

    init(layer: CALayer) {
        self.layer = layer
    }

    func show(_ pixels: CVPixelBuffer, stampedAt time: CMTime) {
        #if DEBUG
        stats.record(frameTime: time)
        #endif
        guard CVPixelBufferGetIOSurface(pixels) != nil else { return }
        lock.lock()
        pending = pixels
        received += 1
        let queue = !drainQueued
        drainQueued = true
        lock.unlock()
        if queue { DispatchQueue.main.async { [self] in drain() } }
    }

    /// Frames handed in and frames put on the layer since the last call (main thread).
    /// Room screen health: frames arriving but none applied means the main thread is stuck.
    func takeCounts() -> (received: Int, applied: Int) {
        lock.lock()
        let r = received
        received = 0
        lock.unlock()
        let a = applied
        applied = 0
        return (r, a)
    }

    private func drain() {
        lock.lock()
        let frame = pending
        pending = nil
        drainQueued = false
        lock.unlock()
        guard let frame, let surface = CVPixelBufferGetIOSurface(frame)?.takeUnretainedValue() else { return }
        // Untagged surfaces would be shown in the display's colour space; the picture is sRGB.
        if IOSurfaceCopyValue(surface, kIOSurfaceColorSpace) == nil {
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, CGColorSpace.sRGB)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = surface
        CATransaction.commit()
        applied += 1
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

