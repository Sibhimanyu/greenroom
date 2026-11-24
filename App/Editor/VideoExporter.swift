// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/VideoExporter.swift).
import AVFoundation
import Foundation

struct ExportRecipe {
    struct OverlayAudio {
        let url: URL
        let volume: Float
        /// Where the audio begins on the exported timeline, seconds.
        let start: Double
        /// The part of the audio FILE to use, seconds.
        let clipStart: Double
        let clipEnd: Double
        /// Repeat the clip until the video ends.
        let loops: Bool
        /// Gentle fade-in/out at the edges of the placed audio.
        let fades: Bool
    }

    /// A stretch of the EDITED timeline retimed: >1 speeds up, <1 slows down.
    typealias SpeedRange = EditSpeedRange

    /// The original (first) and every joined clip, by segment index.
    let segmentURLs: [URL]
    /// What is kept, in order, across all of them (trims and cuts applied).
    let pieces: [EditSequence.Piece]
    let cropRectNormalized: CGRect?
    let overlayAudio: OverlayAudio?
    var speedRanges: [SpeedRange] = []
    /// Visual effects, all times on the FINAL exported timeline.
    var effects: EditedEffects?

    /// A crop, or any clip after the first, needs a transform composition.
    var needsTransformComposition: Bool {
        cropRectNormalized != nil || pieces.contains { $0.segmentIndex != 0 }
    }
}

enum VideoExporter {

    enum ExportError: LocalizedError {
        case noVideoTrack(String)
        case nothingToExport
        case sessionFailed

        var errorDescription: String? {
            switch self {
            case .noVideoTrack(let name): return "\(name) has no video track."
            case .nothingToExport: return "Everything is cut away — nothing to export."
            case .sessionFailed: return "Could not create the export session."
            }
        }
    }

    static func export(recipe: ExportRecipe, to outputURL: URL,
                       preset: String, fileType: AVFileType,
                       onProgress: @escaping (Double) -> Void) async throws {
        let effects = (recipe.effects?.isEmpty ?? true) ? nil : recipe.effects
        let hevc = preset.contains("HEVC")
        let (composition, videoComposition) = try await buildComposition(recipe: recipe)
        let audioMix = try await overlayAudioMix(recipe: recipe, composition: composition)
        try? FileManager.default.removeItem(at: outputURL)

        // Everything renders through the hardware reader→writer engine now —
        // AVAssetExportSession (software, ~1x realtime, 3x the size) is gone.
        // Spectral pitch correction is expensive; only speed changes need it.
        let audioPitch: AVAudioTimePitchAlgorithm =
            recipe.speedRanges.isEmpty ? .timeDomain : .spectral
        let needsTransformComposition = recipe.needsTransformComposition

        // Single pass: either the effects handler composition, the crop/merge
        // transform composition, or no composition at all (plain cuts/trim).
        if !needsTransformComposition || effects == nil {
            let renderComposition: AVVideoComposition?
            if needsTransformComposition {
                renderComposition = videoComposition
            } else {
                renderComposition = effects.map {
                    EffectsRenderer.handlerComposition(for: composition, effects: $0,
                                                       size: videoComposition.renderSize)
                }
            }
            try await FastExportEngine.render(asset: composition,
                                              videoComposition: renderComposition,
                                              audioMix: audioMix,
                                              audioPitch: audioPitch,
                                              to: outputURL,
                                              fileType: fileType,
                                              hevc: hevc,
                                              onProgress: onProgress)
            onProgress(1.0)
            return
        }

        // Crop/merge AND effects: two hardware passes — the effects handler
        // draws in final-frame space, so the transform must land first.
        let editedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorditor-edit-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: editedURL) }
        try await FastExportEngine.render(asset: composition,
                                          videoComposition: videoComposition,
                                          audioMix: audioMix,
                                          audioPitch: audioPitch,
                                          to: editedURL,
                                          fileType: .mp4,
                                          hevc: hevc,
                                          onProgress: { onProgress($0 * 0.6) })
        try await EffectsRenderer.render(input: editedURL, output: outputURL,
                                         effects: effects!, hevc: hevc,
                                         fileType: fileType) { fraction in
            onProgress(0.6 + fraction * 0.4)
        }
        onProgress(1.0)
    }

    /// Predicted output size for the chosen preset/container — shown in the
    /// export dialog before the user commits.
    static func estimatedSize(recipe: ExportRecipe, preset: String, fileType: AVFileType) async throws -> Int64 {
        let (composition, videoComposition) = try await buildComposition(recipe: recipe)
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ExportError.sessionFailed
        }
        session.videoComposition = videoComposition
        session.audioMix = try await overlayAudioMix(recipe: recipe, composition: composition)
        session.outputFileType = fileType
        return try await session.estimatedOutputFileLengthInBytes
    }

    /// Mixes the optional background-audio file over the whole edited video
    /// (trimmed to the video's length, at the chosen volume).
    private static func overlayAudioMix(recipe: ExportRecipe,
                                        composition: AVMutableComposition) async throws -> AVAudioMix? {
        guard let overlay = recipe.overlayAudio else { return nil }
        let asset = AVURLAsset(url: overlay.url)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first,
              let overlayTrack = composition.addMutableTrack(withMediaType: .audio,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let audioDuration = try await asset.load(.duration)
        let clipStart = CMTime(seconds: max(0, overlay.clipStart), preferredTimescale: 600)
        let clipEnd = min(CMTime(seconds: overlay.clipEnd, preferredTimescale: 600), audioDuration)
        let clipLength = clipEnd - clipStart
        guard clipLength.seconds > 0.05 else { return nil }
        var cursor = CMTime(seconds: max(0, overlay.start), preferredTimescale: 600)
        guard (composition.duration - cursor).seconds > 0.05 else { return nil }
        repeat {
            let available = composition.duration - cursor
            let insertLength = min(clipLength, available)
            guard insertLength.seconds > 0.05 else { break }
            try overlayTrack.insertTimeRange(CMTimeRange(start: clipStart, duration: insertLength),
                                             of: sourceTrack, at: cursor)
            cursor = cursor + insertLength
        } while overlay.loops && cursor < composition.duration
        let parameters = AVMutableAudioMixInputParameters(track: overlayTrack)
        parameters.setVolume(overlay.volume, at: .zero)
        if overlay.fades {
            let overlayStart = CMTime(seconds: max(0, overlay.start), preferredTimescale: 600)
            let overlayEnd = min(cursor, composition.duration)
            let placed = (overlayEnd - overlayStart).seconds
            if placed > 0.6 {
                // Fades never eat more than a third of the placed audio each.
                let fade = CMTime(seconds: min(1.5, placed / 3), preferredTimescale: 600)
                parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: overlay.volume,
                                         timeRange: CMTimeRange(start: overlayStart, duration: fade))
                parameters.setVolumeRamp(fromStartVolume: overlay.volume, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: overlayEnd - fade, duration: fade))
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// The whole edit as one composition (kept pieces of every segment, speed
    /// baked in) and the layer-instruction composition that places each clip.
    private static func buildComposition(recipe: ExportRecipe) async throws
        -> (AVMutableComposition, AVMutableVideoComposition) {
        let built = try await EditComposition.build(urls: recipe.segmentURLs, pieces: recipe.pieces,
                                                    speed: recipe.speedRanges)
        guard let videoComposition = EditComposition.videoComposition(for: built,
                                                                      crop: recipe.cropRectNormalized)
        else { throw ExportError.nothingToExport }
        return (built.composition, videoComposition)
    }
}

// MARK: - Export options

enum ExportQuality: String, CaseIterable, Identifiable {
    case original = "Original"
    case fullHD = "1080p"
    case hd = "720p"

    var id: String { rawValue }

    func preset(hevc: Bool) -> String {
        switch self {
        case .original: return hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        case .fullHD: return hevc ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPreset1920x1080
        // AVFoundation has no 720p HEVC preset — 1080p HEVC is the closest.
        case .hd: return hevc ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPreset1280x720
        }
    }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4 · H.264 — most compatible"
    case mp4HEVC = "MP4 · HEVC — smaller file"
    case mov = "MOV · QuickTime"

    var id: String { rawValue }
    var isHEVC: Bool { self == .mp4HEVC }
    var fileType: AVFileType { self == .mov ? .mov : .mp4 }
    var fileExtension: String { self == .mov ? "mov" : "mp4" }
}


// MARK: - Fast export engine

/// Reader→writer export with the recorder's own encoder settings: hardware
/// HEVC/H.264 at EditorConfig.bitsPerPixel with a long GOP. AVAssetExportSession
/// with any videoComposition software-re-encodes at ~1× realtime and ~22Mbps;
/// this engine measured several times faster at a fraction of the size.
enum FastExportEngine {
    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    static func render(asset: AVAsset,
                       videoComposition: AVVideoComposition?,
                       audioMix: AVAudioMix?,
                       audioPitch: AVAudioTimePitchAlgorithm = .timeDomain,
                       to outputURL: URL,
                       fileType: AVFileType,
                       hevc: Bool,
                       onProgress: @escaping (Double) -> Void) async throws {
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw VideoExporter.ExportError.nothingToExport
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        var size = videoComposition?.renderSize ?? naturalSize
        size.width -= size.width.truncatingRemainder(dividingBy: 2)
        size.height -= size.height.truncatingRemainder(dividingBy: 2)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput: AVAssetReaderOutput
        if let videoComposition {
            // BGRA here: Core Image handler compositions render in RGB.
            let compositionOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks,
                                                                        videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            compositionOutput.videoComposition = videoComposition
            videoOutput = compositionOutput
        } else {
            // No composition: stay in the decoder's native 4:2:0 so neither
            // the decoder nor the encoder pays for an RGB round-trip.
            videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
        }
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
            ])
            output.audioMix = audioMix
            output.audioTimePitchAlgorithm = audioPitch   // spectral only for speed edits
            output.alwaysCopiesSampleData = false
            reader.add(output)
            audioOutput = output
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let bitrate = max(3_000_000, Int(size.width * size.height * EditorConfig.bitsPerPixel))
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : .h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                // 2s GOP, matching the recorder: exported files scrub fast.
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else {
            throw reader.error ?? VideoExporter.ExportError.sessionFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? VideoExporter.ExportError.sessionFailed
        }
        writer.startSession(atSourceTime: .zero)

        let readerBox = Box(reader)
        let writerBox = Box(writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()

            group.enter()
            let videoQueue = DispatchQueue(label: "export.video")
            let videoPair = Box((videoOutput, videoInput))
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                let (output, input) = videoPair.value
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        input.append(sample)
                        if duration > 0 {
                            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                            onProgress(min(0.98, t / duration))
                        }
                    } else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let audioOutput, let audioInput {
                group.enter()
                let audioQueue = DispatchQueue(label: "export.audio")
                let audioPair = Box((audioOutput, audioInput))
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    let (output, input) = audioPair.value
                    while input.isReadyForMoreMediaData {
                        if let sample = output.copyNextSampleBuffer() {
                            input.append(sample)
                        } else {
                            input.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue(label: "export.finish")) {
                let reader = readerBox.value
                let writer = writerBox.value
                if reader.status == .failed {
                    writer.cancelWriting()
                    continuation.resume(throwing: reader.error
                        ?? VideoExporter.ExportError.sessionFailed)
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: writer.error
                            ?? VideoExporter.ExportError.sessionFailed)
                    }
                }
            }
        }
    }
}
