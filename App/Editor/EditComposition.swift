import AVFoundation
import Foundation

/// The edit as ONE AVMutableComposition: the kept pieces of the original and
/// of every joined clip, picture and sound, in order. The exporter and the
/// preview player both build it here, so they cannot drift apart.
///
/// Geometry: the render canvas is the FIRST segment's size. Every later clip
/// is scaled to fit and centred on it (each clip's own preferredTransform
/// honoured), and the one crop then applies to the whole sequence.
enum EditComposition {

    enum BuildError: LocalizedError {
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

    /// What one segment's file looks like once its own orientation is applied.
    struct SegmentInfo: Sendable {
        let url: URL
        let size: CGSize
        let transform: CGAffineTransform
    }

    /// Which segment is on screen over a stretch of the composition's time.
    struct Placement: Sendable {
        let start: Double
        let end: Double
        let segmentIndex: Int
    }

    struct Built {
        let composition: AVMutableComposition
        let infos: [SegmentInfo]
        let placements: [Placement]

        /// The segment on screen at composition time `t`.
        func segmentIndex(at t: Double) -> Int {
            Self.segmentIndex(at: t, in: placements)
        }

        static func segmentIndex(at t: Double, in placements: [Placement]) -> Int {
            for placement in placements where t < placement.end { return placement.segmentIndex }
            return placements.last?.segmentIndex ?? 0
        }
    }

    /// The canvas, the crop's pixel origin and the render size, all even.
    struct Geometry: Sendable {
        let canvas: CGSize
        let cropOrigin: CGPoint
        let renderSize: CGSize
        var isValid: Bool { renderSize.width >= 16 && renderSize.height >= 16 }
    }

    static func geometry(canvas: CGSize, crop: CGRect?) -> Geometry {
        var origin = CGPoint.zero
        var size = canvas
        if let crop {
            origin = CGPoint(x: (crop.origin.x * canvas.width).rounded(),
                             y: (crop.origin.y * canvas.height).rounded())
            size = CGSize(width: (crop.width * canvas.width).rounded(),
                          height: (crop.height * canvas.height).rounded())
        }
        size.width -= size.width.truncatingRemainder(dividingBy: 2)
        size.height -= size.height.truncatingRemainder(dividingBy: 2)
        return Geometry(canvas: canvas, cropOrigin: origin, renderSize: size)
    }

    /// Pieces that play every file whole, end to end: the preview's item, whose
    /// time IS the timeline's time. `fileDurations[i]` is segment i's length.
    static func wholeFilePieces(fileDurations: [Double]) -> [EditSequence.Piece] {
        var offset = 0.0
        var pieces: [EditSequence.Piece] = []
        for (index, length) in fileDurations.enumerated() {
            if length > 0 {
                pieces.append(.init(segmentIndex: index, timelineStart: offset,
                                    timelineEnd: offset + length, srcStart: 0, srcEnd: length))
            }
            offset += length
        }
        return pieces
    }

    /// Builds the tracks. `pieces` index into `urls`; `speed` is on the edited
    /// domain (what the pieces add up to) and is baked in with scaleTimeRange.
    static func build(urls: [URL], pieces: [EditSequence.Piece],
                      speed: [EditSpeedRange] = []) async throws -> Built {
        guard !pieces.isEmpty, !urls.isEmpty else { throw BuildError.nothingToExport }

        struct Loaded {
            let asset: AVURLAsset
            let video: AVAssetTrack
            let audio: AVAssetTrack?
            let duration: CMTime
            let info: SegmentInfo
        }
        var loaded: [Int: Loaded] = [:]
        var byURL: [URL: Loaded] = [:]
        func load(_ index: Int) async throws -> Loaded {
            if let existing = loaded[index] { return existing }
            let url = urls[index]
            if let known = byURL[url] {
                loaded[index] = known
                return known
            }
            let asset = AVURLAsset(url: url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw BuildError.noVideoTrack(url.lastPathComponent)
            }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let duration = try await asset.load(.duration)
            let (natural, transform) = try await video.load(.naturalSize, .preferredTransform)
            let oriented = natural.applying(transform)
            let info = SegmentInfo(url: url,
                                   size: CGSize(width: abs(oriented.width), height: abs(oriented.height)),
                                   transform: transform)
            let result = Loaded(asset: asset, video: video, audio: audio, duration: duration, info: info)
            loaded[index] = result
            byURL[url] = result
            return result
        }

        // The first segment sets the canvas even when none of it is kept.
        _ = try await load(0)
        for piece in pieces { _ = try await load(piece.segmentIndex) }

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.sessionFailed }
        // No sound track at all when none of the kept files has any; a file
        // without sound among files with sound gets silence.
        var hasSound = false
        for piece in pieces where try await load(piece.segmentIndex).audio != nil { hasSound = true }
        let compAudio = hasSound
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        var cursor = CMTime.zero
        var editedStarts: [Double] = []
        var editedLengths: [Double] = []
        var editedCursor = 0.0
        for piece in pieces {
            let source = try await load(piece.segmentIndex)
            let start = CMTime(seconds: max(0, piece.srcStart), preferredTimescale: 600)
            let wanted = CMTime(seconds: max(0.05, piece.srcEnd - piece.srcStart), preferredTimescale: 600)
            let available = CMTimeSubtract(source.duration, start)
            guard available.seconds > 0.01 else { continue }
            let range = CMTimeRange(start: start, duration: CMTimeMinimum(wanted, available))
            try compVideo.insertTimeRange(range, of: source.video, at: cursor)
            if let compAudio {
                if let audio = source.audio {
                    try compAudio.insertTimeRange(range, of: audio, at: cursor)
                } else {
                    compAudio.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
                }
            }
            editedStarts.append(editedCursor)
            editedLengths.append(range.duration.seconds)
            editedCursor += range.duration.seconds
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard !editedStarts.isEmpty else { throw BuildError.nothingToExport }
        // Each file's own orientation, for a player that uses no composition.
        compVideo.preferredTransform = try await load(0).info.transform

        // Speed: latest range first so earlier ones stay valid while scaling.
        for range in speed.sorted(by: { $0.start > $1.start }) where abs(range.factor - 1) > 0.01 {
            let length = range.end - range.start
            guard length > 0.1 else { continue }
            composition.scaleTimeRange(
                CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600),
                            duration: CMTime(seconds: length, preferredTimescale: 600)),
                toDuration: CMTime(seconds: length / range.factor, preferredTimescale: 600))
        }

        var placements: [Placement] = []
        for (position, piece) in pieces.enumerated() where position < editedStarts.count {
            let start = EditTimeline.finalTime(fromEdited: editedStarts[position], ranges: speed)
            let end = EditTimeline.finalTime(fromEdited: editedStarts[position] + editedLengths[position],
                                             ranges: speed)
            placements.append(Placement(start: start, end: end, segmentIndex: piece.segmentIndex))
        }
        // Segments with nothing kept were never opened; they just need a slot.
        let canvas = try await load(0).info.size
        let infos = urls.indices.map { index in
            loaded[index]?.info ?? SegmentInfo(url: urls[index], size: canvas, transform: .identity)
        }
        return Built(composition: composition, infos: infos, placements: placements)
    }

    /// Where a segment's picture goes on the render: its own orientation, then
    /// scale-to-fit on the canvas, then the crop's shift. Top-left pixel space.
    static func layerTransform(info: SegmentInfo, geometry: Geometry) -> CGAffineTransform {
        let f = EditSequence.fit(source: info.size, canvas: geometry.canvas)
        return info.transform
            .concatenating(CGAffineTransform(scaleX: f.scale, y: f.scale))
            .concatenating(CGAffineTransform(translationX: f.tx - geometry.cropOrigin.x,
                                             y: f.ty - geometry.cropOrigin.y))
    }

    /// The layer-instruction composition: one transform per stretch, switching
    /// at the pieces' boundaries. Nil when the crop leaves nothing to render.
    static func videoComposition(for built: Built, crop: CGRect?) -> AVMutableVideoComposition? {
        guard let first = built.infos.first else { return nil }
        let geometry = geometry(canvas: first.size, crop: crop)
        guard geometry.isValid,
              let track = built.composition.tracks(withMediaType: .video).first else { return nil }

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        var lastTransform: CGAffineTransform?
        for placement in built.placements {
            let transform = layerTransform(info: built.infos[placement.segmentIndex], geometry: geometry)
            if lastTransform == nil || transform != lastTransform! {
                layer.setTransform(transform, at: CMTime(seconds: placement.start, preferredTimescale: 6000))
                lastTransform = transform
            }
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: built.composition.duration)
        instruction.layerInstructions = [layer]

        let composition = AVMutableVideoComposition()
        composition.renderSize = geometry.renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        composition.instructions = [instruction]
        return composition
    }
}
