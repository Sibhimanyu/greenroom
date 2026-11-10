//
//  StageEncoder.swift
//  Greenroom
//
//  One AVAssetWriter, fed BGRA stage frames and microphone buffers.
//
//  Two shapes, one set of encoder settings:
//   - `.file`: a fragmented MP4 on disk. `movieFragmentInterval` makes the
//     writer lay down a header first and then a self-contained fragment every
//     couple of seconds, so a crash or a power cut loses only the last
//     fragment, not the file. The file plays everywhere a normal .mp4 does.
//   - `.segments`: no file at all. The writer hands out an initialisation
//     segment and then media segments as Data, which `ClipRing` keeps in
//     memory (the clip buffer).
//
//  Not thread safe: the recorder calls it from one serial queue.
//
//  Settings: hardware H.264 at 6 Mbps for a 1080p
//  picture, scaled up with the pixel count to at most 12 Mbps, so a larger
//  canvas does not go soft. High
//  profile, no B-frames (so every timestamp is a presentation timestamp and a
//  passthrough cut never needs a frame from after the cut), a keyframe every
//  two seconds, AAC at 160 kbps, 48 kHz stereo.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class StageEncoder {
    enum Output {
        case file(URL)
        /// The writer cuts a segment at the first keyframe after `interval`.
        /// (Cutting by hand with flushSegment is passthrough-only, so it would
        /// need an encoder of our own; not worth it for a one-second gap.)
        case segments(interval: TimeInterval, start: CMTime, delegate: AVAssetWriterDelegate)
    }

    let size: CGSize
    let frameRate: Int

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private let isSegmented: Bool

    private(set) var startTime: CMTime?
    private(set) var lastVideoTime: CMTime?
    private(set) var framesWritten = 0
    private(set) var videoNotReady = 0
    private(set) var audioNotReady = 0
    private(set) var audioWritten = 0
    private var finished = false

    var failure: String? {
        writer.status == .failed ? (writer.error?.localizedDescription ?? "the writer failed") : nil
    }

    static func videoBitrate(for size: CGSize) -> Int {
        let ratio = (size.width * size.height) / (1920 * 1080)
        return Int(6_000_000 * min(max(ratio, 1), 2))
    }

    /// Creates the writer; for `.file` also opens the file for writing. The
    /// session itself starts at the first video frame.
    init(output: Output, size: CGSize, frameRate: Int, withAudio: Bool) throws {
        self.size = size
        self.frameRate = frameRate
        switch output {
        case .file(let url):
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            isSegmented = false
        case .segments(let interval, let start, let delegate):
            writer = AVAssetWriter(contentType: .mpeg4Movie)
            writer.outputFileTypeProfile = .mpeg4AppleHLS
            writer.preferredOutputSegmentInterval = CMTime(seconds: interval, preferredTimescale: 600)
            writer.initialSegmentStartTime = start
            writer.delegate = delegate
            isSegmented = true
        }
        writer.shouldOptimizeForNetworkUse = false

        // Declared before `writer` is configured, but only read here: the
        // segment shape decides it (see `.segments`).
        let keyframeSeconds: Double = { if case .segments(let i, _, _) = output { return min(2, i) } else { return 2 } }()
        let keyframes = max(Int(Double(frameRate) * keyframeSeconds), 1)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.videoBitrate(for: size),
                AVVideoMaxKeyFrameIntervalKey: keyframes,
                AVVideoMaxKeyFrameIntervalDurationKey: keyframeSeconds,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        guard writer.canAdd(video) else { throw RecorderError.writerRejected("video input") }
        writer.add(video)

        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.writerRejected("audio input") }
            writer.add(input)
            audio = input
        } else {
            audio = nil
        }

        guard writer.startWriting() else {
            throw RecorderError.writerRejected(writer.error?.localizedDescription ?? "startWriting failed")
        }
    }

    /// Returns false when the frame was not written (and counts it).
    @discardableResult
    func appendVideo(_ frame: CVPixelBuffer, at time: CMTime) -> Bool {
        guard !finished, writer.status == .writing else { return false }
        if startTime == nil {
            startTime = time
            writer.startSession(atSourceTime: time)
        }
        // An earlier timestamp than the last is a clock hiccup; the writer
        // would fail the whole file over it.
        if let last = lastVideoTime, time <= last { videoNotReady += 1; return false }
        guard video.isReadyForMoreMediaData, adaptor.append(frame, withPresentationTime: time) else {
            videoNotReady += 1
            return false
        }
        lastVideoTime = time
        framesWritten += 1
        return true
    }

    /// Audio before the first video frame is not written: the file starts at
    /// the first picture, and a recording timecode is measured from there.
    func appendAudio(_ buffer: CMSampleBuffer) {
        guard !finished, let audio, let start = startTime, writer.status == .writing else { return }
        guard CMSampleBufferGetPresentationTimeStamp(buffer) >= start else { return }
        guard audio.isReadyForMoreMediaData, audio.append(buffer) else { audioNotReady += 1; return }
        audioWritten += 1
    }

    /// How long `finish` waits for the writer to close the file before it lets go.
    static let finishTimeout: TimeInterval = 20
    /// How long a retired writer may take before the log says so.
    static let retireWatchdog: TimeInterval = 10

    /// Test seam: stands in for a slow AVFoundation teardown (the harness sets
    /// it; the app never does).
    nonisolated(unsafe) static var testTeardownDelay: TimeInterval = 0

    /// Ends the file. Returns false when the writer had not finished within
    /// `timeout` (the caller carries on: the fragmented MP4 still plays).
    ///
    /// Nothing here can block the caller: `cancelWriting` (which joins a
    /// thread inside MediaToolbox and has been seen to take a minute) runs on
    /// a throwaway queue, and `finishWriting` is raced against a timer.
    @discardableResult
    func finish(timeout: TimeInterval = StageEncoder.finishTimeout) async -> Bool {
        guard !finished else { return true }
        finished = true
        guard writer.status == .writing else { return true }
        if startTime == nil {
            Self.tearDownOffQueue(writer, label: "empty recording", log: nil)
            return true
        }
        video.markAsFinished()
        audio?.markAsFinished()
        let writer = self.writer
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let once = Latch()
            writer.finishWriting { if once.trip() { cont.resume(returning: true) } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.trip() { cont.resume(returning: false) }
            }
        }
    }

    /// Drops the writer without waiting for it. The caller must already have
    /// stopped appending (it owns the encoder on the recorder's queue and is
    /// about to forget it). Safe to call from the recorder's serial queue: the
    /// blocking part happens elsewhere. `keepAlive` is held until the writer is
    /// gone (the clip buffer's ring, which is the writer's delegate).
    func cancel(label: String = "writer", keepAlive: AnyObject? = nil, log: ((String) -> Void)? = nil) {
        finished = true
        Self.tearDownOffQueue(writer, label: label, keepAlive: keepAlive, log: log)
    }

    private static func tearDownOffQueue(_ writer: AVAssetWriter, label: String,
                                         keepAlive: AnyObject? = nil, log: ((String) -> Void)?) {
        let started = Date()
        let latch = Latch()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + retireWatchdog) {
            if latch.trip() {
                log?("The old \(label) is still shutting down after \(Int(retireWatchdog)) s; nothing is waiting on it.")
            }
        }
        DispatchQueue(label: "greenroom.recorder.retire", qos: .utility).async {
            if testTeardownDelay > 0 { Thread.sleep(forTimeInterval: testTeardownDelay) }
            if writer.status == .writing { writer.cancelWriting() }
            latch.trip()
            let took = Date().timeIntervalSince(started)
            if took > 2 { log?("The old \(label) took \(Int(took.rounded())) s to shut down in the background.") }
            withExtendedLifetime(keepAlive) {}
        }
    }
}

/// Trips once; the first caller learns it was first.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    @discardableResult func trip() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if tripped { return false }
        tripped = true
        return true
    }
}

enum RecorderError: LocalizedError {
    case alreadyRecording
    case writerRejected(String)
    case clipBufferNotArmed
    case nothingBuffered
    case lowDisk
    case stillSaving
    case noFolder

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already running."
        case .writerRejected(let why): return "The video writer could not start (\(why))."
        case .clipBufferNotArmed: return "The clip buffer is not running."
        case .nothingBuffered: return "Nothing has been buffered yet."
        case .lowDisk: return "The disk is almost full."
        case .stillSaving: return "The last recording is still being saved."
        case .noFolder: return "There is no session folder to record into."
        }
    }
}
