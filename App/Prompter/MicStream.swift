//
//  MicStream.swift
//  Greenroom
//
//  The teacher's microphone as a stream of analyzer buffers.
//
//  Its own AVAudioEngine, not the level meter's: CoreAudio lets several
//  readers tap one input device (Zoom, OBS's "Greenroom Mic", the meter and
//  this all coexist), but one engine allows one tap per bus, and the meter's
//  engine lives and dies with the participants panel, which may not be open.
//  This one lives and dies with the Prompter.
//
//  Only the default INPUT device is read. Zoom's incoming audio is an output
//  and is never tapped, so what the students say never enters this pipeline
//  except as acoustic bleed through the teacher's speakers - a documented
//  limit, not a channel.
//
import AVFoundation
import Foundation
import Speech

@available(macOS 26.0, *)
final class MicStream {

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private(set) var isRunning = false

    /// Starts the tap and returns the buffers in the analyzer's preferred
    /// format. Throws when there is no usable input device.
    func start(format target: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        let input = engine.inputNode
        let source = input.inputFormat(forBus: 0)
        // Same guard as MicLevelMonitor: a zero sample rate means no device,
        // and installTap on that format traps inside CoreAudio.
        guard source.sampleRate > 0, source.channelCount > 0 else {
            throw NSError(domain: "Greenroom.Prompter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no microphone input"])
        }
        guard let converter = AVAudioConverter(from: source, to: target) else {
            throw NSError(domain: "Greenroom.Prompter", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "the microphone format could not be converted"])
        }
        self.converter = converter

        // Newest 64 buffers: if the analyzer falls behind, old audio is
        // dropped rather than piling up in memory. A quarter-second buffer at
        // 4096 frames means the window is about sixteen seconds - far more
        // than the analyzer ever needs.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation

        input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            let ratio = target.sampleRate / source.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var consumed = false
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard conversionError == nil, converted.frameLength > 0 else { return }
            self.continuation?.yield(AnalyzerInput(buffer: converted))
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            continuation.finish()
            self.continuation = nil
            throw error
        }
        isRunning = true
        return stream
    }

    /// Ends the stream (the analyzer sees end of input) and releases the tap.
    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        converter = nil
        isRunning = false
    }
}
