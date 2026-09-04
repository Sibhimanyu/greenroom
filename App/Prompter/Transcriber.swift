//
//  Transcriber.swift
//  Greenroom
//
//  Speech to text, on this Mac, with Apple's SpeechAnalyzer.
//
//  Two modules on one analyzer: a SpeechTranscriber, whose finalised results
//  are the only text the rest of Prompter ever acts on, and a SpeechDetector
//  so the surfaces can show "hearing you" without a second audio tap. Volatile
//  (in-progress) results are passed through for the Settings test panel and
//  nothing else.
//
//  Input is either the microphone (MicStream) or an audio file, which is how
//  the pipeline is exercised deterministically - the same fixture through the
//  same code path, with `finishAfterFile` ending the run.
//
//  No speech-recognition permission is involved: SpeechAnalyzer works on audio
//  the app already holds, and that audio comes from the microphone permission
//  Greenroom has for the meeting.
//
import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class Transcriber {

    enum Event {
        case volatile(String)
        case final(String)
        case speech(Bool)
        case failed(String)
        case finished
    }

    enum Input {
        case microphone(MicStream)
        case file(AVAudioFile)
        /// Buffers already in the analyzer's preferred format, from any
        /// source - the test bench feeds a recording's audio as it plays.
        case buffers(AsyncStream<AnalyzerInput>)
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var detector: SpeechDetector?
    private var readers: [Task<Void, Never>] = []
    private var mic: MicStream?

    /// The locale to transcribe in, resolved against what the transcriber
    /// supports. Falls back to en_US, which is always installed.
    static func resolvedLocale(preferred identifier: String) async -> Locale {
        let wanted = identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) { return match }
        if let english = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_IN")) { return english }
        return Locale(identifier: "en_US")
    }

    /// Builds the modules for a locale. Shared with ModelAssets so the asset
    /// status is asked about the exact module configuration that will run.
    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults],
                          attributeOptions: [.audioTimeRange])
    }

    /// Starts transcribing and streams events until `stop()` or, for a file,
    /// the end of the file.
    func start(input: Input, locale: Locale) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        let transcriber = Self.makeTranscriber(locale: locale)
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        self.transcriber = transcriber
        self.detector = detector
        let analyzer = SpeechAnalyzer(modules: [transcriber, detector])
        self.analyzer = analyzer

        // Readers are attached BEFORE the analyzer starts, or the first result
        // can be produced with nobody listening.
        readers.append(Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    continuation.yield(result.isFinal ? .final(text) : .volatile(text))
                }
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
        })
        readers.append(Task {
            do {
                for try await result in detector.results {
                    continuation.yield(.speech(result.speechDetected))
                }
            } catch {
                // The detector is a convenience; its failure is not the
                // transcriber's.
            }
        })

        Task {
            do {
                switch input {
                case .microphone(let mic):
                    self.mic = mic
                    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                        continuation.yield(.failed("no audio format the speech model accepts"))
                        return
                    }
                    let buffers = try mic.start(format: format)
                    try await analyzer.start(inputSequence: buffers)
                case .buffers(let buffers):
                    try await analyzer.start(inputSequence: buffers)
                case .file(let file):
                    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                    // With finishAfterFile the analyzer finalises on its own;
                    // wait for the transcriber to drain so callers see every
                    // final result before `.finished`.
                    for reader in readers { await reader.value }
                    continuation.yield(.finished)
                }
            } catch {
                continuation.yield(.failed(error.localizedDescription))
            }
        }
        return stream
    }

    /// Finishes input, gives the analyzer two seconds to finalise what it has,
    /// then cancels whatever is left. Safe to call twice.
    func stop() async {
        mic?.stop()
        mic = nil
        guard let analyzer else { return }
        self.analyzer = nil
        let finalize = Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        let timeout = Task { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        _ = await Task.select(finalize, timeout)
        if !finalize.isCancelled { finalize.cancel() }
        timeout.cancel()
        await analyzer.cancelAndFinishNow()
        for reader in readers { reader.cancel() }
        readers.removeAll()
        transcriber = nil
        detector = nil
    }
}

private extension Task where Failure == Never {
    /// Whichever finishes first. The loser is left to its caller.
    static func select(_ a: Task<Success, Never>, _ b: Task<Success, Never>) async -> Success {
        await withTaskGroup(of: Success.self) { group in
            group.addTask { await a.value }
            group.addTask { await b.value }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }
}
