//
//  ScreenroomAudio.swift
//  Greenroom
//
//  Pulling a plain 16 kHz mono WAV out of the recording.
//
//  Every speech recogniser worth using wants exactly this, and
//  presentation.mov is an H.264/AAC container that none of them read. The
//  obvious answer is to shell out to ffmpeg, which is one line and is what
//  most things do.
//
//  This does it through AVFoundation instead, deliberately. ffmpeg is already
//  on the author's Mac and on a lot of developers' Macs, and on none of the
//  Macs this is actually for. A feature that silently requires a Homebrew
//  install is a feature that works in testing and fails in a classroom. The
//  external tool that Screenroom DOES require - whisper - earns it by being the
//  thing that cannot be replaced; a format conversion does not.
//
import AVFoundation
import Foundation

enum ScreenroomAudio {

    enum Failure: LocalizedError {
        case noAudioTrack
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "That recording has no sound in it, so there is nothing to transcribe."
            case .failed(let reason): return reason
            }
        }
    }

    /// 16 kHz mono, 16-bit signed little-endian. Whisper's native rate, so
    /// nothing downstream resamples; mono because a presentation is one
    /// person and a second channel is a second copy of them.
    static let sampleRate: Double = 16_000

    /// Writes the recording's audio beside it as a WAV and returns the path.
    ///
    /// Not kept afterwards. A ten-minute talk is about twenty megabytes at
    /// this rate, which is not much next to the video, but it is a file with
    /// no reader once the transcript exists and the folder is meant to hold
    /// things a person would open.
    static func extractWAV(from recording: URL, to output: URL) async throws -> URL {
        let asset = AVURLAsset(url: recording)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw Failure.failed("This Mac could not open a WAV writer.") }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw Failure.failed(writer.error?.localizedDescription ?? "The WAV could not be started.")
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            throw Failure.failed(reader.error?.localizedDescription ?? "The recording could not be read.")
        }

        let queue = DispatchQueue(label: "com.sibhimanyu.greenroom.screenroom.audio")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard reader.status == .reading,
                          let buffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        writer.finishWriting { continuation.resume() }
                        return
                    }
                    if !writerInput.append(buffer) {
                        writerInput.markAsFinished()
                        writer.finishWriting { continuation.resume() }
                        return
                    }
                }
            }
        }

        guard writer.status == .completed else {
            throw Failure.failed(writer.error?.localizedDescription ?? "The WAV did not finish writing.")
        }
        return output
    }
}
