//
//  CuesWhisperTranscriber.swift
//  Greenroom
//
//  Cues, listening through whisper instead of Apple's recogniser.
//
//  Built because the cards were not useful. Apple's SpeechAnalyzer is fast and
//  it is the reason Cues could exist at all, but it is a dictation recogniser:
//  it tidies, and it mis-hears exactly the words Cues is looking for. A
//  mention detector can only find a book title the transcript actually
//  contains, and "Ikigai" heard as "icky guy" is a card that never gets made.
//
//  **It does not use `whisper-stream`.** That binary opens its own microphone,
//  which would be a second capture device competing with the tap Cues already
//  has and with Zoom's. Cues' own `MicStream` already holds the mic, the
//  permission and the format conversion, so the audio comes from there and
//  whisper is run over rolling windows of it with `whisper-cli`. That also
//  buys control of the step, which is the whole latency budget.
//
//  WHAT THIS COSTS. Apple's recogniser finalises a phrase a second or so
//  after it is said. Here a word is settled when two consecutive windows agree
//  on it, so the floor is one step plus inference plus one more step. Measured
//  on this Mac: base.en runs at about 22x realtime, so a 6-second window costs
//  ~0.27s of compute and the step dominates. At a 1-second step that is
//  roughly 2-2.5s to a settled word, against Apple's ~1-1.5s. Slower, and
//  right more often. Which of those matters more is a judgement about the
//  class, so it is a setting rather than a replacement.
//
import AVFoundation
import Foundation
// AnalyzerInput, the type MicStream's tap emits. Weak-linked and macOS 26
// only, which is what keeps this class behind the same gate.
import Speech

/// macOS 26 only, and only because of what it borrows.
///
/// whisper needs none of it - it is a binary reading a WAV, and it would run
/// on macOS 14 perfectly well. The gate comes from `MicStream`, whose tap
/// emits `AnalyzerInput`, a Speech-framework type. Decoupling the mic from
/// that type would let whisper-backed Cues run on every Mac this app supports
/// rather than on the one OS that also has Apple Intelligence, which is worth
/// doing and is not this change.
@available(macOS 26.0, *)
final class CuesWhisperTranscriber {

    /// How much audio each pass looks at, and how often a pass runs.
    ///
    /// Six seconds is enough context for whisper to hear a name properly and
    /// short enough to transcribe in a quarter of a second. One second of step
    /// is the latency floor; it is not free, because every step is a whole
    /// pass over the window, but at 22x realtime the machine is idle most of
    /// the second anyway.
    var windowMs = 6_000
    var stepMs = 1_000

    private var stabiliser = CuesStabiliser()
    /// The ring and its clock are written by the microphone's task and read
    /// by the pass's, which run at the same time on different threads. This
    /// lock is the only thing between them. Without it a copy of the ring
    /// could catch the array mid-growth and retain a buffer that had just been
    /// freed - a crash, and the meeting runs in this process.
    private let lock = NSLock()
    private var ring: [Float] = []
    private var ringStartMs = 0
    private var elapsedMs = 0
    /// Passes in a row that whisper could not run. A model that will not load
    /// fails every pass the same way, and would otherwise leave Cues silent
    /// for a whole class with nothing said about why.
    private var failuresInARow = 0
    private let failuresBeforeGivingUp = 3
    /// One window takes well under a second on Apple silicon (measured: 0.5 s
    /// for the small model on an M5 Pro). A pass still running after this has
    /// hung, and the next one would queue behind it forever.
    private let passTimeout: TimeInterval = 20
    private let sampleRate: Double = 16_000
    /// The room's recent levels, thirty seconds of them, for telling a quiet
    /// voice from a quiet room. See SpeechActivity.
    private var roomLevels: [Float] = []
    /// Settled words whose sentence has not ended yet. See
    /// CuesStabiliser.completeSentences.
    private var unfinished: [CuesHypothesisWord] = []

    private var mic: MicStream?
    private var pump: Task<Void, Never>?
    private var feed: Task<Void, Never>?
    private let model: URL
    private let binary: String
    private let work: URL

    /// Nil when this Mac cannot run it, which is the caller's cue to stay on
    /// Apple's.
    init?() {
        guard let binary = ScreenroomWhisper.resolvedBinary,
              let model = ScreenroomTranscriberSettings.resolvedModel() else { return nil }
        self.binary = binary
        self.model = model
        self.work = FileManager.default.temporaryDirectory
            .appendingPathComponent("greenroom-cues-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    static var isAvailable: Bool {
        ScreenroomWhisper.resolvedBinary != nil
            && ScreenroomTranscriberSettings.resolvedModel() != nil
    }

    // MARK: The stream

    func start(input: Transcriber.Input, locale: Locale) -> AsyncStream<Transcriber.Event> {
        AsyncStream { continuation in
            guard case .microphone(let mic) = input else {
                // A file or a buffer sequence is the bench's path, and the
                // bench scores the detector on text rather than on audio.
                continuation.yield(.failed("whisper listening needs the microphone"))
                continuation.finish()
                return
            }
            self.mic = mic

            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: sampleRate,
                                             channels: 1, interleaved: false) else {
                continuation.yield(.failed("this Mac could not open a 16 kHz mono format"))
                continuation.finish()
                return
            }

            let buffers: AsyncStream<AnalyzerInput>
            do { buffers = try mic.start(format: format) }
            catch {
                continuation.yield(.failed(error.localizedDescription))
                continuation.finish()
                return
            }

            feed = Task { [weak self] in
                for await item in buffers {
                    guard let self, !Task.isCancelled else { return }
                    self.append(item.buffer)
                }
            }

            pump = Task { [weak self] in
                while !Task.isCancelled {
                    guard let step = self?.stepMs else { return }
                    try? await Task.sleep(nanoseconds: UInt64(step) * 1_000_000)
                    guard !Task.isCancelled, let self else { return }
                    guard await self.runPass(into: continuation) else {
                        // whisper cannot run here. Saying so is what lets
                        // CuesController switch to Apple's recogniser.
                        continuation.finish()
                        return
                    }
                }
            }

            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
        }
    }

    /// Safe to call more than once and from any thread: the stream's end and
    /// CuesController can both ask.
    func stop() async {
        let (pump, feed, mic) = lock.withLock {
            defer { self.pump = nil; self.feed = nil; self.mic = nil }
            return (self.pump, self.feed, self.mic)
        }
        pump?.cancel()
        feed?.cancel()
        mic?.stop()
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: Audio

    /// Keeps only the window. A class is an hour and the ring would otherwise
    /// be a gigabyte of Float by the end of it.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        lock.lock(); defer { lock.unlock() }
        ring.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        elapsedMs += Int(Double(count) / sampleRate * 1000)

        let keep = Int(Double(windowMs) / 1000 * sampleRate)
        if ring.count > keep {
            let drop = ring.count - keep
            ring.removeFirst(drop)
            ringStartMs += Int(Double(drop) / sampleRate * 1000)
        }
    }

    // MARK: One pass

    /// False when whisper has failed too many passes in a row to keep trying.
    private func runPass(into continuation: AsyncStream<Transcriber.Event>.Continuation) async -> Bool {
        let (samples, startMs, now) = lock.withLock { (ring, ringStartMs, elapsedMs) }
        // Under a second of audio is not worth a pass, and whisper pads it
        // out to thirty seconds internally either way.
        guard samples.count > Int(sampleRate * 0.8) else { return true }

        // Nobody talking, no pass. whisper given a quiet room writes
        // "[BLANK_AUDIO]" at best and whole sentences nobody said at worst,
        // and one of those made a card ("Second language") in a test. The
        // floor comes from the last thirty seconds, so a window that is all
        // speech is still judged against the room rather than against itself.
        let levels = SpeechActivity.levels(samples, sampleRate: sampleRate)
        roomLevels.append(contentsOf: levels.suffix(max(1, stepMs / SpeechActivity.frameMs)))
        if roomLevels.count > 1_500 { roomLevels.removeFirst(roomLevels.count - 1_500) }
        let voiced = SpeechActivity.voiced(levels, threshold: SpeechActivity.threshold(floorFrom: roomLevels + levels))
        guard !voiced.isEmpty else {
            // The room went quiet: whatever sentence was left open is over.
            if !unfinished.isEmpty {
                for sentence in CuesStabiliser.sentences(from: unfinished) {
                    continuation.yield(.final(sentence))
                }
                unfinished = []
            }
            continuation.yield(.speech(false))
            return true
        }

        let wav = work.appendingPathComponent("window.wav")
        guard writeWAV(samples, to: wav) else { return true }

        let heard: [CuesHypothesisWord]
        switch transcribe(wav: wav, offsetMs: startMs) {
        case .heard(let words):
            failuresInARow = 0
            heard = words
        case .failed(let reason):
            failuresInARow += 1
            guard failuresInARow < failuresBeforeGivingUp else {
                continuation.yield(.failed("\(Self.failurePrefix)\(reason)"))
                return false
            }
            return true
        }
        // And no words from the quiet parts of a window that has a voice in
        // it somewhere. A second of slack, because whisper's word timings
        // wander by about that much.
        let words = heard.filter {
            SpeechActivity.overlaps(($0.atMs - startMs)...max($0.atMs - startMs, $0.endMs - startMs),
                                    voiced, slackMs: 1_000)
        }
        let settled = stabiliser.accept(words, now: now, windowStartMs: startMs)

        let (sentences, rest) = CuesStabiliser.completeSentences(from: unfinished + settled, now: now)
        unfinished = rest
        for sentence in sentences {
            continuation.yield(.final(sentence))
        }
        let tail = (unfinished + stabiliser.volatileWords).map(\.text).joined(separator: " ")
        if !tail.isEmpty { continuation.yield(.volatile(tail)) }
        continuation.yield(.speech(!words.isEmpty))
        return true
    }

    /// What a `.failed` event from here starts with, so CuesController can
    /// tell whisper giving up from the microphone going away.
    static let failurePrefix = "whisper could not run: "

    private enum Pass {
        case heard([CuesHypothesisWord])
        case failed(String)
    }

    /// Blocks the pump's task, never the main thread: whisper is a separate
    /// process, so whatever goes wrong inside it stays there, and this only
    /// has to notice.
    private func transcribe(wav: URL, offsetMs: Int) -> Pass {
        let base = wav.deletingPathExtension()
        let json = base.appendingPathExtension("json")
        try? FileManager.default.removeItem(at: json)

        // stderr to a file, not a pipe. A pipe nobody reads fills at 64 KB and
        // stops whisper dead; a file also keeps the last lines for the log.
        let errors = work.appendingPathComponent("whisper-stderr.txt")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let errorHandle = try? FileHandle(forWritingTo: errors)
        defer { try? errorHandle?.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-m", model.path, "-f", wav.path, "-l", "en",
                             "-ml", "1", "-sow", "-oj", "-of", base.path, "-np", "-t", "4"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            return .failed("whisper-cli would not start (\(error.localizedDescription))")
        }
        if exited.wait(timeout: .now() + passTimeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            return .failed("whisper-cli took over \(Int(passTimeout)) seconds on one \(windowMs / 1000)-second window")
        }
        guard process.terminationStatus == 0, process.terminationReason == .exit else {
            // A model that will not load ends in an abort and a stack trace,
            // so the last line is a stack frame. The line that says what went
            // wrong is the first one that says "error" or "failed".
            let said = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            let lines = said.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let why = lines.first { $0.range(of: #"error|failed"#, options: [.regularExpression, .caseInsensitive]) != nil }
                ?? lines.last ?? "no message"
            let how = process.terminationReason == .uncaughtSignal
                ? "crashed (signal \(process.terminationStatus))" : "exited with \(process.terminationStatus)"
            return .failed("whisper-cli \(how): \(why)")
        }
        guard let data = try? Data(contentsOf: json) else {
            return .failed("whisper-cli wrote no transcript")
        }
        return .heard(ScreenroomWhisper.parse(data).map {
            CuesHypothesisWord(text: $0.text,
                               atMs: offsetMs + $0.atMs,
                               endMs: offsetMs + $0.endMs)
        })
    }

    /// 16-bit PCM WAV, which is the only thing whisper-cli reads.
    private func writeWAV(_ samples: [Float], to url: URL) -> Bool {
        var data = Data()
        let bytes = samples.count * 2
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate) * 2)
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * 32_767))
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
