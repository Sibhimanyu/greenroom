#if DEBUG
import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Probes B and C of the meeting-audio investigation (2026-11-27). Debug builds only.
///
/// B: a separate audio-only SCStream that includes just Greenroom's own process, to
///    see whether ScreenCaptureKit hands us the meeting playback (and the Greenroom
///    Browser's sound) from inside the app. Logs only; nothing is recorded. It is a
///    second stream, so the screen-capture stream and its audio are untouched.
/// C: one line listing the WebKit / Zoom helper processes ScreenCaptureKit can see,
///    to learn who plays the sound.
///
/// Every line starts "Audio probe:" in ~/Library/Logs/Greenroom-session.log.
final class OwnAudioProbe: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = OwnAudioProbe()

    private let queue = DispatchQueue(label: "greenroom.audio-probe.sck")
    private let lock = NSLock()
    private var stream: SCStream?
    private var generation = 0
    private var logging = false
    private var buffers = 0
    private var meter = AudioLevelMeter()
    private var format = ""
    private var timer: DispatchSourceTimer?
    private var ticks = 0

    private static func log(_ m: String) { MeetingAudioProbe.log(m) }

    func start() {
        guard AudioProbeSwitch.enabled else { return }
        lock.lock(); generation += 1; let mine = generation; lock.unlock()
        Task { await self.run(generation: mine) }
    }

    func stop() {
        lock.lock()
        generation += 1
        logging = false
        let s = stream; stream = nil
        let t = timer; timer = nil
        lock.unlock()
        t?.cancel()
        guard let s else { return }
        Task {
            do { try await s.stopCapture(); Self.log("B: stream stopped at meeting end.") }
            catch { Self.log("B: stopping the stream failed: \(error.localizedDescription)") }
        }
    }

    private func current(_ g: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return g == generation }

    private func run(generation g: Int) async {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        catch {
            Self.log("B: cannot list shareable content (\(error.localizedDescription)); Screen Recording permission is probably missing. Skipping B and C.")
            return
        }

        // C: which processes exist.
        let interesting = content.applications.filter { app in
            let id = app.bundleIdentifier
            return id.hasPrefix("com.apple.WebKit") || id == Bundle.main.bundleIdentifier
                || id.lowercased().contains("zoom") || id.lowercased().contains("greenroom")
                || ["capHost", "CptHost", "aomhost", "airhost"].contains(where: { app.applicationName.contains($0) })
        }
        let list = interesting.map { "\($0.applicationName) [\($0.bundleIdentifier) pid \($0.processID)]" }
        Self.log("C: \(content.applications.count) apps visible to ScreenCaptureKit; WebKit/Greenroom/Zoom ones: \(list.isEmpty ? "none" : list.joined(separator: "; ")).")

        // B: own-process audio stream.
        guard CGPreflightScreenCaptureAccess() else {
            Self.log("B: Screen Recording permission is not granted; skipping B.")
            return
        }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let own = content.applications.first(where: { $0.processID == me }) else {
            Self.log("B: Greenroom (pid \(me)) is not in ScreenCaptureKit's application list; skipping B.")
            return
        }
        guard let display = content.displays.first else { Self.log("B: no display; skipping B."); return }
        let filter = SCContentFilter(display: display, including: [own], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)   // ignored; avoids SCK complaining
            try await s.startCapture()
        } catch {
            Self.log("B: starting the audio stream FAILED: \(error.localizedDescription)")
            return
        }
        guard current(g) else { try? await s.stopCapture(); return }
        lock.lock(); stream = s; logging = true; ticks = 0; buffers = 0; meter.reset(); format = ""; lock.unlock()
        Self.log("B: audio-only stream of Greenroom's own process STARTED.")

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }

    private func tick() {
        lock.lock()
        guard logging else { lock.unlock(); return }
        ticks += 1
        let n = ticks, count = buffers, m = meter, f = format
        buffers = 0; meter.reset()
        if n >= 6 { logging = false; timer?.cancel(); timer = nil }
        lock.unlock()
        Self.log("B @\(n * 5)s: \(count) audio buffers\(count > 0 ? " (\(f))" : ""), \(count > 0 ? m.summary : "nothing arrived").")
        if n >= 6 { Self.log("B: 30 s window over; stream stays up, no more logging.") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        lock.lock(); let on = logging; lock.unlock()
        guard on else { return }

        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard st == noErr, let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }

        var local = AudioLevelMeter()
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        for b in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = b.mData else { continue }
            if isFloat {
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                local.add(float32: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: n))
            } else {
                let n = Int(b.mDataByteSize) / MemoryLayout<Int16>.size
                local.add(int16: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: n))
            }
        }
        lock.lock()
        buffers += 1
        format = "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, \(isFloat ? "float" : "int16")"
        // Merge: keep the loudest peak and a running mean-square across buffers.
        meter.merge(local)
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Self.log("B: the stream stopped by itself: \(error.localizedDescription)")
    }
}
#endif
