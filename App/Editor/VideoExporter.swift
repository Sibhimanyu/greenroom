// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/VideoExporter.swift).
import AVFoundation
import Foundation

struct ExportRecipe {
    struct MergeSegment {
        let url: URL
        let start: Double
        let end: Double
    }

    struct OverlayAudio {
        let url: URL
        let volume: Float
        /// Where the audio begins on the EDITED (exported) timeline, seconds.
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
    struct SpeedRange {
        let start: Double
        let end: Double
        let factor: Double
    }

    let sourceURL: URL
    let keptRanges: [(Double, Double)]
    let cropRectNormalized: CGRect?
    let mergeSegments: [MergeSegment]
    let overlayAudio: OverlayAudio?
    var speedRanges: [SpeedRange] = []
    /// Visual effects, all times on the FINAL exported timeline.
    var effects: EditedEffects?
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
        applySpeedRanges(recipe.speedRanges, to: composition, videoComposition: videoComposition)
        let audioMix = try await overlayAudioMix(recipe: recipe, composition: composition)
        try? FileManager.default.removeItem(at: outputURL)

        // Everything renders through the hardware reader→writer engine now —
        // AVAssetExportSession (software, ~1x realtime, 3x the size) is gone.
        // Spectral pitch correction is expensive; only speed changes need it.
        let audioPitch: AVAudioTimePitchAlgorithm =
            recipe.speedRanges.isEmpty ? .timeDomain : .spectral
        let needsTransformComposition = recipe.cropRectNormalized != nil
            || !recipe.mergeSegments.isEmpty

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

    /// Compresses the given edited-timeline stretches (latest first, so
    /// earlier ranges stay valid while scaling) and re-stretches the video
    /// composition instruction over the new, shorter duration.
    private static func applySpeedRanges(_ ranges: [ExportRecipe.SpeedRange],
                                         to composition: AVMutableComposition,
                                         videoComposition: AVMutableVideoComposition) {
        guard !ranges.isEmpty else { return }
        for range in ranges.sorted(by: { $0.start > $1.start }) where abs(range.factor - 1) > 0.01 {
            let start = CMTime(seconds: range.start, preferredTimescale: 600)
            let duration = CMTime(seconds: range.end - range.start, preferredTimescale: 600)
            guard duration.seconds > 0.1 else { continue }
            composition.scaleTimeRange(CMTimeRange(start: start, duration: duration),
                                       toDuration: CMTime(seconds: duration.seconds / range.factor,
                                                          preferredTimescale: 600))
        }
        if let instruction = videoComposition.instructions.first as? AVMutableVideoCompositionInstruction {
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        }
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

    private static func buildComposition(recipe: ExportRecipe) async throws -> (AVMutableComposition, AVMutableVideoComposition) {
        guard !recipe.keptRanges.isEmpty || !recipe.mergeSegments.isEmpty else {
            throw ExportError.nothingToExport
        }

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.sessionFailed
        }

        // ---- main clip
        let mainAsset = AVURLAsset(url: recipe.sourceURL)
        guard let mainVideoTrack = try await mainAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack(recipe.sourceURL.lastPathComponent)
        }
        let mainAudioTrack = try await mainAsset.loadTracks(withMediaType: .audio).first
        let (mainNaturalSize, mainTransform) = try await mainVideoTrack.load(.naturalSize, .preferredTransform)
        let orientedMain = mainNaturalSize.applying(mainTransform)
        let mainSize = CGSize(width: abs(orientedMain.width), height: abs(orientedMain.height))

        var cursor = CMTime.zero
        for (start, end) in recipe.keptRanges {
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: end - start, preferredTimescale: 600))
            try compVideo.insertTimeRange(range, of: mainVideoTrack, at: cursor)
            if let mainAudioTrack {
                try compAudio.insertTimeRange(range, of: mainAudioTrack, at: cursor)
            } else {
                compAudio.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        let mainEnd = cursor

        // ---- render size (crop applies to the main clip's coordinates)
        var renderSize = mainSize
        var cropOriginPixels = CGPoint.zero
        if let crop = recipe.cropRectNormalized {
            cropOriginPixels = CGPoint(x: (crop.origin.x * mainSize.width).rounded(),
                                       y: (crop.origin.y * mainSize.height).rounded())
            renderSize = CGSize(width: (crop.width * mainSize.width).rounded(),
                                height: (crop.height * mainSize.height).rounded())
        }
        renderSize.width -= renderSize.width.truncatingRemainder(dividingBy: 2)
        renderSize.height -= renderSize.height.truncatingRemainder(dividingBy: 2)
        guard renderSize.width >= 16, renderSize.height >= 16 else {
            throw ExportError.nothingToExport
        }

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
        let mainFinalTransform = mainTransform.concatenating(
            CGAffineTransform(translationX: -cropOriginPixels.x, y: -cropOriginPixels.y))
        layerInstruction.setTransform(mainFinalTransform, at: .zero)

        // ---- merge clips appended after the main clip (each clip's own trim
        // range only), scaled to fit
        for segment in recipe.mergeSegments {
            let asset = AVURLAsset(url: segment.url)
            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw ExportError.noVideoTrack(segment.url.lastPathComponent)
            }
            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            let assetDuration = try await asset.load(.duration)
            let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
            let oriented = naturalSize.applying(transform)
            let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))

            let start = CMTime(seconds: max(0, segment.start), preferredTimescale: 600)
            let requested = CMTime(seconds: max(0.05, segment.end - segment.start), preferredTimescale: 600)
            let range = CMTimeRange(start: start, duration: CMTimeMinimum(requested, CMTimeSubtract(assetDuration, start)))
            try compVideo.insertTimeRange(range, of: videoTrack, at: cursor)
            if let audioTrack {
                try compAudio.insertTimeRange(range, of: audioTrack, at: cursor)
            } else {
                compAudio.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            }

            let scale = min(renderSize.width / size.width, renderSize.height / size.height)
            let tx = (renderSize.width - size.width * scale) / 2
            let ty = (renderSize.height - size.height * scale) / 2
            let clipTransform = transform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: tx, y: ty))
            layerInstruction.setTransform(clipTransform, at: cursor)

            cursor = CMTimeAdd(cursor, range.duration)
        }
        _ = mainEnd

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 60)
        videoComposition.instructions = [instruction]

        return (composition, videoComposition)
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
