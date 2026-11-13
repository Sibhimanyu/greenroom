//
//  SessionRecorder.swift
//  Greenroom
//
//  Records the stage and keeps the clip buffer, with no outside program.
//
//  A `StageFrameSink` (see StageFrames.swift): BGRA frames in, a fragmented
//  H.264/AAC .mp4 out, with the chosen microphone.
//
//  Two writers, because the two jobs differ: the recording is one file on
//  disk that must survive a crash, and the clip buffer is segments in memory
//  that must leave nothing behind. While both run, the picture is encoded
//  twice on the hardware encoder, which a Mac does without noticing at 1080p.
//  The coordinator marks clips on the master while recording (as it does
//  today), so the buffer is for when nothing is recording; it still works
//  during a recording if asked.
//
//  Never blocks the render queue: `stageDidRender` takes a lock, bumps a
//  counter and hands the frame to a private serial queue. If two frames are
//  already waiting, or the encoder is not ready, the frame is dropped and
//  counted, and the counts are logged in plain words at stop.
//
//  Pause (phase 4 of the Recorditor port): the writer is never stopped. While
//  paused, frames and audio are dropped, and everything after is moved back by
//  the paused time (`PauseClock`), so the file is one continuous take. The
//  clip buffer skips paused time too: the pause means "do not keep this", and
//  the buffer is what a clip shortcut would otherwise hand back. System sound
//  (`appendSystemAudio`) is mixed with the microphone into the one audio
//  track by `AudioMixer`.
//
//  No app-only dependencies: this file and its siblings compile with
//  StageFrames.swift alone, which is how they are measured.
//

import AVFoundation
import CoreMedia
import Foundation

final class SessionRecorder: StageFrameSink {

    // MARK: Configuration

    /// The microphone, as a CoreAudio uid (`AVCaptureDevice.uniqueID`); empty
    /// is the system's input, nil is no audio at all. Read when a recording
    /// or the buffer starts,, like the other sources.
    var microphoneUID: String?
    /// Also record the Mac's own sound (the coordinator feeds it through
    /// `appendSystemAudio`). Read when a recording or the buffer starts.
    var recordsSystemAudio = false
    /// Where a clip-buffer save lands. Defaults to the recording's folder,
    /// then the temporary folder. Set it to the session folder.
    var clipBufferFolder: URL?
    /// One line of plain words for the coordinator's log.
    var log: (String) -> Void
    /// The recording ended without being asked to (disk full, writer failure).
    /// The file so far is kept. Called on an arbitrary queue.
    var onUnexpectedStop: ((String) -> Void)?
    /// A recording has begun (its file is chosen; the first frame may not have
    /// been written yet). On the main thread. For `InputEventTracker`.
    var onRecordingStarted: (@MainActor () -> Void)?
    /// A recording has ended, for any reason, with the finished file or nil
    /// when nothing was kept. On the main thread, after the file is closed.
    var onRecordingEnded: (@MainActor (URL?) -> Void)?

    /// One second, so a saved clip is at most a second behind the moment it was
    /// asked for (the buffer's keyframes are one second apart to match).
    static let segmentInterval: TimeInterval = 1
    /// Below this the recording stops itself rather than write into a full disk.
    static let minimumFreeBytes: Int64 = 200_000_000

    private let source: StageFrameSource
    private let queue = DispatchQueue(label: "greenroom.recorder.writer", qos: .userInitiated)
    private let mic = MicrophoneTap()

    // MARK: State
    // `lock` guards the flags the render queue reads. Everything else lives on `queue`.

    private let lock = NSLock()
    private var recordingActive = false
    /// stop() has taken the recording and is still closing the file.
    private var stopping = false
    private var bufferActive = false
    private var pendingFrames = 0
    private var droppedBusy = 0
    /// The file's first frame, in the paused-adjusted clock (its own timestamp
    /// minus the pauses before it), so `now - paused - firstFrameTime` is the
    /// position in the file.
    private var firstFrameTime: CMTime?
    /// Pauses as the recording sees them (reset at each start) and as the clip
    /// buffer sees them (reset when the buffer is armed; it outlives recordings).
    private let recordingClock = PauseClock()
    private let bufferClock = PauseClock()
    /// Present while system sound is on; owns the mix of it and the microphone.
    private var mixer: AudioMixer?
    private var mixerLogged = false

    private var recording: StageEncoder?
    private var recordingURL_: URL?
    private var bufferEncoder: StageEncoder?
    private var ring: ClipRing?
    private var bufferSeconds = 300
    private var lastDiskCheck = Date.distantPast
    private var micRunning = false
    private var attached = false
    private var recordingHadAudio = false
    private var sizeMismatches = 0
    private var bufferFailedAt = Date.distantPast

    init(source: StageFrameSource, microphoneUID: String? = "", log: @escaping (String) -> Void = { _ in }) {
        self.source = source
        self.microphoneUID = microphoneUID
        self.log = log
        mic.onSamples = { [weak self] buffer in
            self?.queue.async { [weak self] in self?.handleMicrophone(buffer) }
        }
    }

    private static func hostSeconds() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    // MARK: Observable state

    /// A recording is being written.
    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recordingActive }
    var isClipBufferArmed: Bool { lock.lock(); defer { lock.unlock() }; return bufferActive }
    /// The file being written (or just finished).
    var recordingURL: URL? { lock.lock(); defer { lock.unlock() }; return recordingURL_ }

    /// Where the recording is, in seconds from the start of the file: what
    /// a clip mark is taken against. Measured against the host clock from the
    /// first frame written, minus the time spent paused, so it keeps counting if
    /// the picture stalls (the file's own timeline does) but not through a
    /// pause. While paused it holds the moment the pause began.
    var elapsed: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard recordingActive, let first = firstFrameTime else { return 0 }
        return fileSeconds(first: first)
    }
    /// `elapsed` in whole milliseconds, nil when not recording or no frame has
    /// been written yet (`SessionClip.startMs/endMs` are milliseconds).
    var elapsedMilliseconds: Int? {
        lock.lock(); defer { lock.unlock() }
        guard recordingActive, let first = firstFrameTime else { return nil }
        return Int(fileSeconds(first: first) * 1000)
    }
    /// Called with `lock` held.
    private func fileSeconds(first: CMTime) -> Double {
        let at = recordingClock.currentPauseBegin ?? Self.hostSeconds()
        return max(0, at - recordingClock.pausedSeconds(at: at) - first.seconds)
    }

    /// The recording is paused (the file is not growing; the meeting, if any, is untouched).
    var isPaused: Bool { recordingClock.isPaused }
    /// Seconds spent paused so far in this recording, a pause in progress included.
    var pausedSeconds: TimeInterval { recordingClock.pausedSeconds(at: Self.hostSeconds()) }

    /// Pauses the recording file. False when nothing is recording or it is already paused.
    @discardableResult
    func pause() -> Bool {
        guard isRecording else { return false }
        let now = Self.hostSeconds()
        guard recordingClock.pause(at: now) else { return false }
        bufferClock.pause(at: now)
        return true
    }

    /// Carries on after a pause.
    @discardableResult
    func resume() -> Bool {
        let now = Self.hostSeconds()
        guard recordingClock.resume(at: now) else { return false }
        bufferClock.resume(at: now)
        return true
    }

    /// Frames lost so far in this recording because the encoder was behind.
    var droppedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedBusy
    }

    /// The name of a recording (`yyyy-MM-dd HH-mm-ss`), the same shape the
    /// folders have always held.
    static func fileName(for date: Date, prefix: String = "") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return "\(prefix)\(f.string(from: date)).mp4"
    }

    // MARK: Recording

    /// Starts the recording. Throws if a recording is
    /// already running, the folder cannot be made, or the writer refuses.
    func start(in folder: URL) throws {
        lock.lock()
        if recordingActive { lock.unlock(); throw RecorderError.alreadyRecording }
        if stopping { lock.unlock(); throw RecorderError.stillSaving }
        lock.unlock()

        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(Self.fileName(for: Date()))
        var counter = 2
        while manager.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(Self.fileName(for: Date())
                .replacingOccurrences(of: ".mp4", with: " (\(counter)).mp4"))
            counter += 1
        }
        let withAudio = wantsAudio
        let encoder = try StageEncoder(output: .file(url), size: source.outputSize,
                                       frameRate: source.frameRate, withAudio: withAudio)
        if microphoneUID != nil, !MicrophoneTap.isAuthorized {
            log(recordsSystemAudio
                ? "Recording without the microphone \u{2014} Greenroom does not have microphone permission. The Mac\u{2019}s sound is still recorded."
                : "Recording without sound \u{2014} Greenroom does not have microphone permission.")
        }
        recordingClock.reset()

        // Async, never sync: this is called from the main thread, and the
        // queue may be busy. Frames only start once `recordingActive` is set
        // below, and their handlers queue behind this block.
        queue.async { [self] in
            recording = encoder
            recordingHadAudio = withAudio
            lastDiskCheck = .distantPast
            sizeMismatches = 0
        }
        lock.lock()
        recordingActive = true
        recordingURL_ = url
        firstFrameTime = nil
        droppedBusy = 0
        lock.unlock()
        syncPlumbing()
        if let started = onRecordingStarted {
            if Thread.isMainThread { MainActor.assumeIsolated { started() } }
            else { DispatchQueue.main.async { MainActor.assumeIsolated { started() } } }
        }
    }

    /// Sound is wanted when the microphone can be heard or the Mac's sound is on.
    private var wantsAudio: Bool {
        (microphoneUID != nil && MicrophoneTap.isAuthorized) || recordsSystemAudio
    }

    /// A pause still open when the recording ends must not carry on into the clip buffer.
    private func closePause() {
        let now = Self.hostSeconds()
        recordingClock.resume(at: now)
        bufferClock.resume(at: now)
    }

    private func announceEnd(_ url: URL?) async {
        guard let ended = onRecordingEnded else { return }
        await MainActor.run { ended(url) }
    }

    /// Stops the recording and returns the finished file. Nil when nothing was
    /// recording or no frame ever arrived (the empty file is removed).
    @discardableResult
    func stop() async -> URL? {
        let (was, url): (Bool, URL?) = lock.withLock {
            let was = recordingActive
            recordingActive = false
            if was { stopping = true }
            return (was, recordingURL_)
        }
        guard was else { return nil }
        defer { lock.withLock { stopping = false } }
        guard let url else { await announceEnd(nil); return nil }
        closePause()
        syncPlumbing()

        let encoder: StageEncoder? = await withCheckedContinuation { cont in
            queue.async { [self] in
                // The mixer holds back the last 150 ms; hand them over first.
                mixer?.flush()
                let e = recording; recording = nil; cont.resume(returning: e)
            }
        }
        guard let encoder else { await announceEnd(nil); return nil }
        let closed = await encoder.finish()
        if !closed {
            log("The recording file did not finish closing within \(Int(StageEncoder.finishTimeout)) s; carrying on. The file is written in fragments, so it still plays.")
        }

        let written = encoder.framesWritten
        let busy = lock.withLock { droppedBusy }
        let notReady = encoder.videoNotReady
        let seconds = encoder.startTime.flatMap { start in encoder.lastVideoTime.map { $0.seconds - start.seconds } } ?? 0
        if let failure = encoder.failure { log("The recording hit a problem (\(failure)); what was written so far is kept.") }
        guard written > 0 else {
            try? FileManager.default.removeItem(at: url)
            log("Recording stopped before any picture arrived; nothing was saved.")
            await announceEnd(nil)
            return nil
        }
        var line = "Recording stopped: \(written) frames over \(Int(seconds.rounded())) s."
        let lost = busy + notReady
        if lost == 0 {
            line += " No frames were dropped."
        } else {
            line += " Dropped \(lost) frame\(lost == 1 ? "" : "s")"
            var why: [String] = []
            if busy > 0 { why.append("\(busy) because the picture arrived faster than it could be handed over") }
            if notReady > 0 { why.append("\(notReady) because the encoder was not ready") }
            line += " (\(why.joined(separator: ", ")))."
        }
        if recordingHadAudio, encoder.audioWritten == 0 {
            line += " No microphone sound arrived, so the file is silent."
        }
        log(line)
        await announceEnd(url)
        return url
    }

    // MARK: Clip buffer

    /// Starts keeping the last few minutes in memory.
    func armClipBuffer(seconds: Int = 300) {
        lock.lock()
        if bufferActive { lock.unlock(); return }
        bufferActive = true
        lock.unlock()
        bufferClock.reset()
        queue.async { [self] in
            bufferSeconds = seconds
            ring = ClipRing(window: TimeInterval(seconds), segmentInterval: Self.segmentInterval)
            bufferEncoder = nil // made at the first frame, which sets its clock
        }
        syncPlumbing()
    }

    /// Stops the clip buffer. Forgets everything buffered.
    func disarmClipBuffer() {
        lock.lock()
        let was = bufferActive
        bufferActive = false
        lock.unlock()
        guard was else { return }
        syncPlumbing()
        // Detach at once, then let the writer die elsewhere: cancelling the
        // segmented writer joins a MediaToolbox thread and has taken a minute,
        // and everything else (the next start, stop) queues behind this block.
        queue.async { [self] in
            let old = bufferEncoder, oldRing = ring
            bufferEncoder = nil
            ring = nil
            old?.cancel(label: "clip buffer", keepAlive: oldRing, log: log)
            oldRing?.reset()
        }
    }

    /// Writes the newest
    /// `lastSeconds` (default: all of it) as `Replay <stamp>.mp4` and returns
    /// it. The file is whole segments, so it can be a few seconds longer than
    /// asked, never shorter (unless less is buffered); `SessionClipExporter
    /// .exportTail` then trims it.
    func saveClipBuffer(lastSeconds: Int? = nil) async throws -> URL {
        guard isClipBufferArmed else { throw RecorderError.clipBufferNotArmed }
        let ring: ClipRing? = await withCheckedContinuation { cont in
            queue.async { [self] in cont.resume(returning: self.ring) }
        }
        guard let ring else { throw RecorderError.clipBufferNotArmed }
        let folder = clipBufferFolder ?? recordingURL?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(Self.fileName(for: Date(), prefix: "Replay "))
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(Self.fileName(for: Date(), prefix: "Replay ")
                .replacingOccurrences(of: ".mp4", with: " (\(counter)).mp4"))
            counter += 1
        }
        let wanted = Double(lastSeconds ?? bufferSeconds)
        let covered = try ring.write(lastSeconds: wanted, to: url)
        log("Clip buffer saved: \(Int(covered.rounded())) s.")
        return url
    }

    // MARK: Plumbing

    /// Attach to the stage and start the microphone while either job needs
    /// them; let both go when neither does.
    private func syncPlumbing() {
        // The flags are decided under the lock and the (possibly slow) calls
        // made outside it, so a start on the main thread never waits on a
        // stop that is closing the microphone on another thread.
        lock.lock()
        let needed = recordingActive || bufferActive
        var attach = false, detach = false, micOn = false, micOff = false
        if needed, !attached { attached = true; attach = true }
        else if !needed, attached { attached = false; detach = true }
        if needed, !micRunning, microphoneUID != nil { micRunning = true; micOn = true }
        else if !needed, micRunning { micRunning = false; micOff = true }
        let uid = microphoneUID
        let wantsMixer = needed && recordsSystemAudio
        lock.unlock()
        queue.async { [self] in
            if wantsMixer, mixer == nil {
                let m = AudioMixer()
                m.onChunk = { [weak self] chunk in self?.handleMixed(chunk) }
                mixer = m
            } else if !wantsMixer, mixer != nil {
                mixer = nil
            }
        }
        if attach { source.addSink(self) }
        if detach { source.removeSink(self) }
        if micOn, let uid {
            mic.start(uid: uid) { [weak self] result in
                switch result {
                case .running: break
                case .denied: self?.log("Microphone permission is off, so recordings and clips have no sound.")
                case .noDevice: self?.log("No microphone found, so recordings and clips have no sound.")
                case .failed(let why): self?.log("The microphone would not start (\(why)).")
                }
            }
        }
        if micOff { mic.stop() }
    }

    // MARK: StageFrameSink

    func stageDidRender(_ frame: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        guard recordingActive || bufferActive else { lock.unlock(); return }
        if pendingFrames >= 2 {
            if recordingActive { droppedBusy += 1 }
            lock.unlock()
            return
        }
        pendingFrames += 1
        lock.unlock()
        queue.async { [self] in
            handle(frame, at: time)
            lock.lock(); pendingFrames -= 1; lock.unlock()
        }
    }

    private func handle(_ frame: CVPixelBuffer, at time: CMTime) {
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        guard CGFloat(width) == source.outputSize.width, CGFloat(height) == source.outputSize.height else {
            sizeMismatches += 1
            return
        }

        if let encoder = recording {
            // Paused: the frame is dropped; after a pause it is moved back by
            // the time paused so the file has no gap (PauseClock).
            if let moved = recordingClock.offset(at: time.seconds) {
                let mapped = PauseClock.shifted(time, by: moved)
                let first = encoder.startTime == nil
                if encoder.appendVideo(frame, at: mapped), first {
                    lock.lock(); firstFrameTime = mapped; lock.unlock()
                }
            }
            if let failure = encoder.failure {
                recording = nil
                endUnexpectedly("The recording stopped: \(failure). What was written so far is kept.", encoder: encoder)
            } else if Date().timeIntervalSince(lastDiskCheck) > 5 {
                lastDiskCheck = Date()
                if let free = freeBytes(), free < Self.minimumFreeBytes {
                    recording = nil
                    endUnexpectedly("The recording stopped: the disk is almost full. What was written so far is kept.",
                                    encoder: encoder)
                }
            }
        }

        // The clip buffer follows its own copy of the pauses (it outlives a recording).
        if bufferActive_(), let ring, let moved = bufferClock.offset(at: time.seconds) {
            let mapped = PauseClock.shifted(time, by: moved)
            if bufferEncoder == nil, Date().timeIntervalSince(bufferFailedAt) > 5 {
                ring.reset()
                bufferEncoder = try? StageEncoder(
                    output: .segments(interval: Self.segmentInterval, start: mapped, delegate: ring),
                    size: source.outputSize, frameRate: source.frameRate,
                    withAudio: wantsAudio)
                if bufferEncoder == nil {
                    bufferFailedAt = Date()
                    log("The clip buffer could not start; it will try again in a few seconds.")
                }
            }
            bufferEncoder?.appendVideo(frame, at: mapped)
            if let failure = bufferEncoder?.failure {
                log("The clip buffer hit a problem (\(failure)); it is starting over.")
                bufferEncoder?.cancel(label: "clip buffer", keepAlive: ring, log: log)
                bufferEncoder = nil
                bufferFailedAt = Date()
            }
        }
    }

    // MARK: Audio

    /// The Mac's own sound, from the screen capture. Any queue; cheap when
    /// nothing is recording. Needs `recordsSystemAudio`.
    func appendSystemAudio(_ buffer: CMSampleBuffer) {
        guard recordsSystemAudio else { return }
        lock.lock(); let wanted = recordingActive || bufferActive; lock.unlock()
        guard wanted else { return }
        queue.async { [weak self] in
            guard let self, let mixer = self.mixer else { return }
            guard let converted = AudioMixer.floats(from: buffer) else {
                if !self.mixerLogged {
                    self.mixerLogged = true
                    self.log("The Mac\u{2019}s sound arrived in a format Greenroom cannot mix (not 48 kHz float), so it is left out.")
                }
                return
            }
            mixer.add(converted.samples, at: converted.time, from: .system)
        }
    }

    /// Microphone buffer, on `queue`. With system sound on it goes through the
    /// mixer; without, straight to the writers as it always did.
    private func handleMicrophone(_ buffer: CMSampleBuffer) {
        if let mixer {
            if let converted = AudioMixer.floats(from: buffer) {
                mixer.add(converted.samples, at: converted.time, from: .microphone)
            }
            return
        }
        route(audio: buffer)
    }

    /// A 10 ms piece of the mix, on `queue`.
    private func handleMixed(_ chunk: AudioMixer.Chunk) {
        let stamp = CMTime(value: Int64((chunk.start * AudioMixer.sampleRate).rounded()),
                           timescale: Int32(AudioMixer.sampleRate))
        guard let buffer = AudioMixer.sampleBuffer(samples: chunk.samples, at: stamp) else { return }
        route(audio: buffer)
    }

    /// Hands a buffer to each writer, moved for that writer's pauses, or not
    /// at all while it is paused.
    private func route(audio buffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        if let recording, let moved = recordingClock.offset(at: pts),
           let adjusted = PauseClock.retimed(buffer, by: moved) {
            recording.appendAudio(adjusted)
        }
        if let bufferEncoder, let moved = bufferClock.offset(at: pts),
           let adjusted = PauseClock.retimed(buffer, by: moved) {
            bufferEncoder.appendAudio(adjusted)
        }
    }

    private func bufferActive_() -> Bool { lock.lock(); defer { lock.unlock() }; return bufferActive }

    private func freeBytes() -> Int64? {
        guard let url = recordingURL else { return nil }
        let values = try? url.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func endUnexpectedly(_ message: String, encoder: StageEncoder) {
        lock.lock(); recordingActive = false; lock.unlock()
        closePause()
        log(message)
        Task { [weak self] in
            await encoder.finish()
            self?.syncPlumbing()
            await self?.announceEnd(self?.recordingURL)
            self?.onUnexpectedStop?(message)
        }
    }
}
