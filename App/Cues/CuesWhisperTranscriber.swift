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
    private var ring: [Float] = []
    private var ringStartMs = 0
    private var elapsedMs = 0
    private let sampleRate: Double = 16_000

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
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(self.stepMs) * 1_000_000)
                    guard !Task.isCancelled else { break }
                    await self.runPass(into: continuation)
                }
            }

            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
        }
    }

    func stop() async {
        pump?.cancel(); pump = nil
        feed?.cancel(); feed = nil
        mic?.stop(); mic = nil
        try? FileManager.default.removeItem(at: work)
    }

    // MARK: Audio

    /// Keeps only the window. A class is an hour and the ring would otherwise
    /// be a gigabyte of Float by the end of it.
    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
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

    private func runPass(into continuation: AsyncStream<Transcriber.Event>.Continuation) async {
        let samples = ring
        let startMs = ringStartMs
        let now = elapsedMs
        // Under a second of audio is not worth a pass, and whisper pads it
        // out to thirty seconds internally either way.
        guard samples.count > Int(sampleRate * 0.8) else { return }

        let wav = work.appendingPathComponent("window.wav")
        guard writeWAV(samples, to: wav) else { return }

        guard let words = await transcribe(wav: wav, offsetMs: startMs) else { return }
        let settled = stabiliser.accept(words, now: now)

        if !settled.isEmpty {
            for sentence in CuesStabiliser.sentences(from: settled) {
                continuation.yield(.final(sentence))
            }
        }
        let tail = stabiliser.volatileWords.map(\.text).joined(separator: " ")
        if !tail.isEmpty { continuation.yield(.volatile(tail)) }
        continuation.yield(.speech(!words.isEmpty))
    }

    private func transcribe(wav: URL, offsetMs: Int) async -> [CuesHypothesisWord]? {
        let base = wav.deletingPathExtension()
        try? FileManager.default.removeItem(at: base.appendingPathExtension("json"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-m", model.path, "-f", wav.path, "-l", "en",
                             "-ml", "1", "-sow", "-oj", "-of", base.path, "-np", "-t", "4"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        // Both pipes are drained by being closed when the process exits; the
        // window is small enough that neither buffer fills.
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: base.appendingPathExtension("json")) else { return nil }

        return ScreenroomWhisper.parse(data).map {
            CuesHypothesisWord(text: $0.text,
                               atMs: offsetMs + $0.atMs,
                               endMs: offsetMs + $0.endMs)
        }
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
