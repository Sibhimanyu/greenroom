//
//  ZoomVideoSender.swift
//  Greenroom
//
//  Piece 2 of docs/drop-obs-plan.md: the class picture goes into the meeting
//  as Greenroom's own camera, through the SDK's external video source.
//
//  How it works:
//   - It is a `StageFrameSink`. `stageDidRender` only keeps the newest frame
//     (a lock and a pointer swap), so the compositor is never held up.
//   - A timer on its own queue runs at the rate the SDK suggested and sends
//     whatever the newest frame is. The picture's rate and the SDK's rate are
//     independent; nothing is queued. If the picture stalls, the last frame
//     keeps going out (black before the first one), so the meeting tile never
//     falls back to the SDK's placeholder.
//   - The SDK's offered sizes can change in the meeting (a live run went from
//     1080p to 640x480 about 4 s after joining). `onPropertyChange` adopts the
//     new suggestion, rebuilds the buffers and carries on without stopping.
//   - Conversion and letterboxing live in `I420Converter`, which has no SDK
//     dependency.
//
//  Every log line starts with "Meeting video:". `sendRawData` returns void,
//  so the only evidence of health is the achieved rate logged every 30 s.
//

import CoreMedia
import CoreVideo
import Foundation
import ZoomSDK

final class ZoomVideoSender: NSObject, StageFrameSink, ZoomSDKVirtualVideoSourceDelegate {
    private typealias Choice = StageVideoSizing.Choice

    static func log(_ message: String) {
        ZoomMeetingSDKClient.logLicenceLine("Meeting video: \(message)")
    }

    /// True while the SDK has asked for frames.
    var isSending: Bool { queue.sync { sending } }

    // The newest frame, shared between the render queue and the send queue.
    private let frameLock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestArrival: UInt64 = 0

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "greenroom.zoomvideosender", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var sender: ZoomSDKRawDataSender?
    private var sending = false
    private var supported: [Choice] = []
    private var chosen = Choice(width: 640, height: 360, fps: 30)
    private var converter: I420Converter?
    private var stalled = false
    private var sentAny = false
    private var statFrames = 0, statTotalNs: UInt64 = 0, statWorstNs: UInt64 = 0
    private var statStart = DispatchTime.now().uptimeNanoseconds

    private weak var source: StageFrameSource?

    /// Point the sender at a picture source, or at nothing (it then keeps
    /// sending the last frame). Safe to call at any time.
    func attach(_ newSource: StageFrameSource?) {
        source?.removeSink(self)
        source = newSource
        newSource?.addSink(self)
    }

    func detach() { attach(nil) }

    // MARK: StageFrameSink

    func stageDidRender(_ frame: CVPixelBuffer, at time: CMTime) {
        let now = DispatchTime.now().uptimeNanoseconds
        frameLock.lock()
        latest = frame
        latestArrival = now
        frameLock.unlock()
    }

    // MARK: ZoomSDKVirtualVideoSourceDelegate

    private static func describe(_ c: ZoomSDKVideoCapabilityItem) -> String {
        "\(c.getWidth())x\(c.getHeight())@\(c.getFrame())"
    }

    private static func choice(_ c: ZoomSDKVideoCapabilityItem) -> Choice {
        Choice(width: Int(c.getWidth()), height: Int(c.getHeight()), fps: Int(c.getFrame()))
    }

    func onInitialize(_ sender: ZoomSDKRawDataSender?, supportedCapabilityList capabilityList: [Any]?, suggestCapability suggestCap: ZoomSDKVideoCapabilityItem?) {
        let caps = (capabilityList ?? []).compactMap { $0 as? ZoomSDKVideoCapabilityItem }
        Self.log("the SDK set up our video source (sender \(sender == nil ? "MISSING" : "present")). Offered: \(caps.isEmpty ? "(none)" : caps.map(Self.describe).joined(separator: ", ")); suggested \(suggestCap.map(Self.describe) ?? "none").")
        let list = caps.map(Self.choice), sug = suggestCap.map(Self.choice)
        queue.async { [self] in
            self.sender = sender
            adopt(list, sug, why: "first setup")
        }
    }

    func onPropertyChange(_ supportedCapabilityList: [Any]?, suggestCapability suggestCap: ZoomSDKVideoCapabilityItem?) {
        let caps = (supportedCapabilityList ?? []).compactMap { $0 as? ZoomSDKVideoCapabilityItem }
        Self.log("the SDK changed its offered sizes: \(caps.isEmpty ? "(none)" : caps.map(Self.describe).joined(separator: ", ")); suggested \(suggestCap.map(Self.describe) ?? "none").")
        guard let suggestCap else { return }
        let list = caps.map(Self.choice), sug = Self.choice(suggestCap)
        queue.async { [self] in adopt(list, sug, why: "the SDK changed its suggestion") }
    }

    func onStartSend() {
        Self.log("start sending: the SDK wants frames now.")
        queue.async { [self] in
            sending = true
            startTimer()
        }
    }

    func onStopSend() {
        queue.async { [self] in
            Self.log("stop sending.")
            sending = false
            timer?.cancel(); timer = nil
        }
    }

    func onUninitialize() {
        queue.async { [self] in
            Self.log("the SDK let go of our video source.")
            sending = false
            timer?.cancel(); timer = nil
            sender = nil
            converter = nil
        }
    }

    // MARK: Size (on `queue`)

    private func adopt(_ list: [Choice], _ suggested: Choice?, why: String) {
        supported = list
        let pick = StageVideoSizing.choose(supported: list, suggested: suggested)
        let changed = pick.choice != chosen
        chosen = pick.choice
        Self.log("size \(pick.choice.width)x\(pick.choice.height) at \(pick.choice.fps) fps (\(why)): \(pick.reason).")
        // The converter notices the new size on the next frame. The SDK is never
        // told to stop; if it was already asking for frames the timer just re-times.
        if sending && (changed || timer == nil) { startTimer() }
    }

    private func startTimer() {
        timer?.cancel()
        resetStats()
        Self.log("sending \(chosen.width)x\(chosen.height) at \(chosen.fps) fps, I420 limited range.")
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / max(1, chosen.fps)), leeway: .microseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func resetStats() {
        statFrames = 0; statTotalNs = 0; statWorstNs = 0
        statStart = DispatchTime.now().uptimeNanoseconds
    }

    // MARK: One frame (on `queue`)

    private func tick() {
        guard let sender else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds

        frameLock.lock()
        let frame = latest, arrival = latestArrival
        frameLock.unlock()

        // Say so once when the picture stops and once when it comes back.
        let isStalled = frame != nil && t0 - arrival > 1_000_000_000
        if isStalled != stalled {
            stalled = isStalled
            Self.log(isStalled ? "the picture stopped for over 1 s; repeating the last frame." : "the picture is moving again.")
        }

        var data: UnsafeMutableRawPointer?
        var length = 0, w = chosen.width & ~1, h = chosen.height & ~1
        if let frame {
            let sw = CVPixelBufferGetWidth(frame), sh = CVPixelBufferGetHeight(frame)
            if converter == nil || converter!.sourceWidth != sw || converter!.sourceHeight != sh || converter!.width != w || converter!.height != h {
                let c = I420Converter(sourceWidth: sw, sourceHeight: sh, width: w, height: h)
                converter = c
                Self.log("converting \(sw)x\(sh) to \(c.width)x\(c.height): " + (c.isLetterboxed ? "picture \(c.fitWidth)x\(c.fitHeight) with black bars." : c.needsScale ? "scaled, no bars." : "no scaling needed."))
            }
            if let c = converter {
                CVPixelBufferLockBaseAddress(frame, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(frame) {
                    data = c.convert(base, rowBytes: CVPixelBufferGetBytesPerRow(frame))
                }
                CVPixelBufferUnlockBaseAddress(frame, .readOnly)
                w = c.width; h = c.height; length = c.byteCount
            }
        } else {
            // Nothing yet: black, so the tile shows a picture and not the SDK's placeholder.
            if converter == nil || converter!.width != w || converter!.height != h {
                converter = I420Converter(sourceWidth: 1920, sourceHeight: 1080, width: w, height: h)
            }
            if let c = converter { data = c.blackFrame; w = c.width; h = c.height; length = c.byteCount }
        }
        guard let data else { return }

        sender.sendRawData(data.assumingMemoryBound(to: CChar.self), width: UInt32(w), height: UInt32(h),
                           dataLength: UInt32(length), rotation: ZoomSDKLOCAL_DEVICE_ROTATION_ACTION_0)

        let spent = DispatchTime.now().uptimeNanoseconds - t0
        statFrames += 1; statTotalNs += spent; statWorstNs = max(statWorstNs, spent)
        if !sentAny { sentAny = true; Self.log("first frame handed to the SDK (\(frame == nil ? "black, no picture yet" : "from the stage"))") }

        let elapsed = DispatchTime.now().uptimeNanoseconds - statStart
        if elapsed >= 30_000_000_000 {
            let secs = Double(elapsed) / 1e9
            Self.log(String(format: "%dx%d: %.1f fps achieved (asked for %d), %.1f ms per frame on average, %.1f ms worst.",
                            w, h, Double(statFrames) / secs, chosen.fps, Double(statTotalNs) / Double(statFrames) / 1e6, Double(statWorstNs) / 1e6))
            resetStats()
        }
    }
}

#if DEBUG
extension ZoomVideoSender {
    /// Debug switch: UserDefaults bool `GreenroomRawVideoSpike` feeds a
    /// `StageTestPattern` into the meeting so the path can be tested end to end.
    static var debugTestPatternEnabled: Bool { UserDefaults.standard.bool(forKey: "GreenroomRawVideoSpike") }
}
#endif
