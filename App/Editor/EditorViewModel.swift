// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Editor/EditorViewModel.swift).
import AVFoundation
import AppKit
import Combine
import SwiftUI

struct CutRegion: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double

    var duration: Double { end - start }
}

struct MergeClip: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let duration: Double
    /// Per-clip trim — only [trimStart, trimEnd] plays and exports.
    var trimStart: Double = 0
    var trimEnd: Double

    var trimmedDuration: Double { max(0, trimEnd - trimStart) }
    var isTrimmed: Bool { trimStart > 0.05 || trimEnd < duration - 0.05 }
}

enum TimelineMode: String, CaseIterable {
    case trim = "Trim"
    case cut = "Cut"
}

@MainActor
final class EditorViewModel: ObservableObject {

    // MARK: source
    @Published private(set) var sourceURL: URL?
    @Published private(set) var duration: Double = 0
    @Published private(set) var videoSize: CGSize = .zero
    /// What the player is actually SHOWING: the cropped frame while the
    /// crop preview is live, the full frame otherwise. Overlays position
    /// against this so annotations land on the visible pixels.
    var displayVideoSize: CGSize {
        guard cropPreviewActive, let crop = cropRect else { return videoSize }
        return Self.croppedRenderSize(crop, of: videoSize)
    }

    /// iPhone-Photos behavior: once cropping is confirmed, the preview
    /// plays the cropped frame (while adjusting, the full frame shows
    /// under the crop rectangle). Merge-clip playback is never cropped —
    /// the exporter crops only the main clip.
    var cropPreviewActive: Bool {
        cropRect != nil && !isCropping && previewEdits && playingMergeIndex == nil
    }
    @Published private(set) var fileSizeText = "—"

    // MARK: edit state
    @Published var mode: TimelineMode = .trim
    @Published var cuts: [CutRegion] = []
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var cropRect: CGRect? {  // normalized 0…1, origin top-left of the video
        didSet { applyCropPreview() }
    }
    @Published var mergeClips: [MergeClip] = []
    @Published var selectedCutID: UUID?
    @Published var isCropping = false {
        didSet { applyCropPreview() }
    }
    @Published var previewEdits = true {
        didSet { applyCropPreview() }
    }

    // MARK: playback
    let player = AVPlayer()
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    /// nil = the main video is loaded in the player; otherwise the index of
    /// the merge clip currently playing. The timeline is virtual: merge clips
    /// live after the main video at `duration + prefix(durations)`.
    @Published private(set) var playingMergeIndex: Int?
    private var sourceAsset: AVURLAsset?
    private var sourceVideoTrack: AVAssetTrack?
    private var sourceTransform = CGAffineTransform.identity

    /// Full timeline length: main video + all merge clips.
    var timelineDuration: Double {
        duration + mergeClips.reduce(0) { $0 + $1.duration }
    }

    /// Timeline offset where merge clip `index` begins.
    func mergeOffset(upTo index: Int) -> Double {
        duration + mergeClips.prefix(index).reduce(0) { $0 + $1.duration }
    }

    // MARK: export
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportMessage: String?
    @Published var errorMessage: String?
    /// Set when an export completes — drives the post-export banner.
    @Published var lastExportURL: URL?
    /// The just-saved file, shown as a popup over the editor's start page.
    @Published var savedExportURL: URL?
    // Export options dialog state.
    @Published var showExportOptions = false
    @Published var exportFormat: ExportFormat = .mp4
    @Published var exportQuality: ExportQuality = .original
    /// File name for the export (no extension) — shown as "Save as" in the
    /// export sheet, prefilled from the source video.
    @Published var exportName = ""
    @Published var estimatedSizeText = "—"
    private var exportTask: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?

    /// Chat history for the prompt-based edit assistant (kept here so it
    /// survives tab switches).
    @Published var assistantMessages: [AssistantMessage] = []

    /// Any edit state worth warning about before closing the video.
    var hasUnsavedEdits: Bool {
        !cuts.isEmpty || cropRect != nil || !mergeClips.isEmpty
            || trimStart > 0.05 || trimEnd < duration - 0.05
            || overlayAudioURL != nil || hasAnyEnhancement
    }

    /// Background audio mixed over the export (nil = none).
    @Published var overlayAudioURL: URL?
    @Published var overlayAudioVolume: Double = 0.8
    /// Start position on the edited (exported) timeline, seconds.
    @Published var overlayAudioStart: Double = 0
    @Published var overlayAudioDuration: Double = 0
    /// The part of the audio file to use.
    @Published var overlayAudioClipStart: Double = 0
    @Published var overlayAudioClipEnd: Double = 0
    /// Repeat the clip until the video ends.
    @Published var overlayAudioLoops = false
    /// Fade the placed audio in and out at its edges.
    @Published var overlayAudioFades = true

    var overlayClipLength: Double { max(0, overlayAudioClipEnd - overlayAudioClipStart) }
    /// How long the audio occupies on the edited timeline.
    var overlayEffectiveLength: Double {
        guard overlayClipLength > 0 else { return 0 }
        return overlayAudioLoops
            ? max(0, totalEditedDuration - overlayAudioStart)
            : min(overlayClipLength, max(0, totalEditedDuration - overlayAudioStart))
    }
    /// Live preview player for the background audio, kept in sync with the
    /// main player so edits are heard while editing, not just after export.
    private let overlayPlayer = AVPlayer()

    // MARK: enhancements (applied on Save; times below live on the SOURCE
    // timeline like cuts, and are mapped through cuts + speed at export)

    /// Clicks/keystrokes captured with the recording (nil = no sidecar).
    @Published private(set) var recordingEvents: RecordingEvents?
    @Published var showClickRipples = false
    @Published var showKeystrokes = false
    @Published var autoZoom = false

    struct EditorAnnotation: Identifiable, Equatable {
        let id: UUID
        var kind: EditedEffects.Annotation.Kind
        var rect: CGRect      // normalized, top-left origin
        var start: Double
        var end: Double
        var text: String
        var color: AnnotationColor = .yellow
    }
    @Published var annotations: [EditorAnnotation] = []
    /// Non-nil while the user is drawing a box on the player for this kind.
    @Published var pendingAnnotationKind: EditedEffects.Annotation.Kind?
    /// The annotation currently selected on the player (move/reshape/edit).
    @Published var selectedAnnotationID: UUID?

    struct SpeedSegment: Identifiable, Equatable {
        let id: UUID
        var start: Double
        var end: Double
        var factor: Double
    }
    @Published var speedSegments: [SpeedSegment] = []
    /// What the preview is ACTUALLY playing at right now (drives the badge).
    @Published var activePreviewRate: Double = 1

    var hasAnyEnhancement: Bool {
        showClickRipples || showKeystrokes || autoZoom
            || !annotations.isEmpty || !speedSegments.isEmpty
    }

    func beginAnnotationPlacement(_ kind: EditedEffects.Annotation.Kind) {
        isCropping = false
        pendingAnnotationKind = kind
    }

    func placeAnnotation(rect: CGRect) {
        guard let kind = pendingAnnotationKind else { return }
        pendingAnnotationKind = nil
        // Blur/text boxes lose the drag direction; arrows keep it (tail→tip).
        let shaped = kind == .arrow ? rect : rect.standardized
        let start = min(max(playhead, trimStart), max(trimEnd - 0.5, trimStart))
        let end = min(start + 4, trimEnd)
        let annotation = EditorAnnotation(
            id: UUID(), kind: kind, rect: shaped, start: start, end: max(end, start + 0.5),
            text: "")
        annotations.append(annotation)
        // Fresh annotations come up selected — text opens straight into
        // its inline field, arrows/boxes show their handles.
        selectedAnnotationID = annotation.id
    }

    func removeAnnotation(id: UUID) {
        annotations.removeAll { $0.id == id }
    }

    /// Applies a speed to [from, to], REPLACING whatever overlaps — a second
    /// apply always wins over stale segments instead of silently no-opping.
    /// Speed and merge clips still don't combine (exporter limitation).
    func applySpeed(factor: Double, from rawFrom: Double, to rawTo: Double) {
        guard mergeClips.isEmpty else { return }
        let factor = min(max(factor, 0.25), 8)
        let from = min(max(rawFrom, trimStart), trimEnd)
        let to = min(max(rawTo, trimStart), trimEnd)
        guard to - from > 0.3 else {
            errorMessage = "The speed range is too short — check the From/To times."
            return
        }
        // Carve the new range out of existing segments.
        var carved: [SpeedSegment] = []
        for segment in speedSegments {
            if segment.end <= from || segment.start >= to {
                carved.append(segment)
                continue
            }
            if segment.start < from - 0.2 {
                carved.append(SpeedSegment(id: UUID(), start: segment.start, end: from, factor: segment.factor))
            }
            if segment.end > to + 0.2 {
                carved.append(SpeedSegment(id: UUID(), start: to, end: segment.end, factor: segment.factor))
            }
        }
        if abs(factor - 1) > 0.01 {
            carved.append(SpeedSegment(id: UUID(), start: from, end: to, factor: factor))
        }
        speedSegments = carved.sorted { $0.start < $1.start }
        if abs(factor - 1) > 0.01 {
            exportMessage = String(format: "%g× from %@ to %@ — press Play to preview; Save bakes it in.",
                                   factor, TimeFormatting.clock(from), TimeFormatting.clock(to))
        } else {
            exportMessage = "Speed reset to 1× for that range."
        }
    }

    func applySpeedToWholeVideo(factor: Double) {
        applySpeed(factor: factor, from: trimStart, to: trimEnd)
    }

    /// mm:ss (or plain seconds) → seconds.
    static func parseClock(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) {
            return minutes * 60 + seconds
        }
        if parts.count == 1, let seconds = Double(parts[0]) {
            return seconds
        }
        return nil
    }

    func removeSpeedSegment(id: UUID) {
        speedSegments.removeAll { $0.id == id }
    }

    // MARK: source → edited → final time mapping

    /// Edited time only when the source instant survives the cuts, else nil.
    private func editedTimeIfKept(_ t: Double) -> Double? {
        var edited: Double = 0
        for (start, end) in keptRanges() {
            if t >= end {
                edited += end - start
            } else if t >= start {
                return edited + (t - start)
            } else {
                return nil
            }
        }
        return nil
    }

    /// Speed ranges on the EDITED timeline, for the exporter.
    private func editedSpeedRanges() -> [ExportRecipe.SpeedRange] {
        guard mergeClips.isEmpty else { return [] }
        return speedSegments.compactMap { segment in
            let start = editedTime(forTimeline: max(segment.start, trimStart))
            let end = editedTime(forTimeline: min(segment.end, trimEnd))
            guard end - start > 0.15 else { return nil }
            return ExportRecipe.SpeedRange(start: start, end: end, factor: segment.factor)
        }
    }

    /// Edited time → final exported time (compressed by speed segments).
    private func finalTime(fromEdited t: Double, ranges: [ExportRecipe.SpeedRange]) -> Double {
        var result = t
        for range in ranges {
            let squeeze = 1 - 1 / range.factor
            if t > range.end {
                result -= (range.end - range.start) * squeeze
            } else if t > range.start {
                result -= (t - range.start) * squeeze
            }
        }
        return max(0, result)
    }

    private func finalTimeIfKept(_ sourceT: Double, ranges: [ExportRecipe.SpeedRange]) -> Double? {
        guard let edited = editedTimeIfKept(sourceT) else { return nil }
        return finalTime(fromEdited: edited, ranges: ranges)
    }

    /// Everything the effects pass draws, mapped to the final timeline.
    private func builtEffects() -> EditedEffects? {
        let ranges = editedSpeedRanges()
        var effects = EditedEffects()

        if let events = recordingEvents {
            if showClickRipples {
                effects.ripples = events.clicks.compactMap { click in
                    finalTimeIfKept(click.t, ranges: ranges).map {
                        EditedEffects.Ripple(t: $0, x: click.x, y: click.y)
                    }
                }
            }
            if showKeystrokes {
                effects.keyChips = events.keys.compactMap { key in
                    finalTimeIfKept(key.t, ranges: ranges).map {
                        EditedEffects.KeyChip(t: $0, text: key.text)
                    }
                }
            }
            if autoZoom {
                let clicks = events.clicks.compactMap { click -> (Double, Double, Double)? in
                    finalTimeIfKept(click.t, ranges: ranges).map { ($0, click.x, click.y) }
                }
                effects.zoomKeyframes = Self.zoomKeyframes(fromFinalClicks: clicks)
            }
        }
        effects.annotations = annotations.compactMap { annotation in
            let start = editedTime(forTimeline: max(annotation.start, trimStart))
            let end = editedTime(forTimeline: min(annotation.end, trimEnd))
            guard end - start > 0.1 else { return nil }
            return EditedEffects.Annotation(
                kind: annotation.kind, rect: annotation.rect,
                start: finalTime(fromEdited: start, ranges: ranges),
                end: finalTime(fromEdited: end, ranges: ranges),
                text: annotation.text,
                color: annotation.color)
        }
        return effects.isEmpty ? nil : effects
    }

    /// Clusters clicks (gaps > 3s split), zooms to 1.8× around their running
    /// center, follows, then eases back out.
    private static func zoomKeyframes(
        fromFinalClicks clicks: [(t: Double, x: Double, y: Double)]) -> [EditedEffects.ZoomKeyframe] {
        guard !clicks.isEmpty else { return [] }
        let zoom = 1.8
        var frames: [EditedEffects.ZoomKeyframe] = []

        var cluster: [(t: Double, x: Double, y: Double)] = []
        func flush() {
            guard let first = cluster.first, let last = cluster.last else { return }
            var center = CGPoint(x: first.x, y: first.y)
            frames.append(.init(t: first.t - 0.8, center: center, scale: 1))
            frames.append(.init(t: first.t - 0.05, center: center, scale: zoom))
            for click in cluster.dropFirst() {
                center = CGPoint(x: center.x * 0.55 + click.x * 0.45,
                                 y: center.y * 0.55 + click.y * 0.45)
                frames.append(.init(t: click.t, center: center, scale: zoom))
            }
            frames.append(.init(t: last.t + 0.9, center: center, scale: zoom))
            frames.append(.init(t: last.t + 1.8, center: center, scale: 1))
            cluster = []
        }
        for click in clicks {
            if let lastT = cluster.last?.t, click.t - lastT > 3.0 { flush() }
            cluster.append(click)
        }
        flush()

        // Overlapping ease-out/ease-in between close clusters: keep times
        // strictly increasing, dropping the frames that run backwards.
        var cleaned: [EditedEffects.ZoomKeyframe] = []
        for frame in frames.sorted(by: { $0.t < $1.t }) {
            if let previous = cleaned.last, frame.t <= previous.t + 0.01 { continue }
            cleaned.append(frame)
        }
        return cleaned
    }

    func setOverlayAudio(url: URL?) {
        overlayAudioURL = url
        overlayAudioStart = 0
        overlayAudioDuration = 0
        overlayAudioClipStart = 0
        overlayAudioClipEnd = 0
        overlayAudioLoops = false
        overlayAudioFades = true
        if let url {
            overlayPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
            Task { @MainActor in
                let seconds = (try? await AVURLAsset(url: url).load(.duration))?.seconds ?? 0
                overlayAudioDuration = seconds
                overlayAudioClipEnd = seconds
            }
        } else {
            overlayPlayer.pause()
            overlayPlayer.replaceCurrentItem(with: nil)
        }
    }

    /// Total length of the exported video (kept main ranges + trimmed clips).
    var totalEditedDuration: Double {
        keptRanges().reduce(0) { $0 + ($1.1 - $1.0) }
            + mergeClips.reduce(0) { $0 + $1.trimmedDuration }
    }

    /// Timeline (source) time → edited (exported) time, across cuts, trim
    /// and merge clips.
    func editedTime(forTimeline t: Double) -> Double {
        var edited: Double = 0
        for (start, end) in keptRanges() {
            if t >= end {
                edited += end - start
            } else if t > start {
                return edited + (t - start)
            } else {
                return edited
            }
        }
        for (index, clip) in mergeClips.enumerated() {
            let base = mergeOffset(upTo: index)
            let local = t - base
            if local >= clip.trimEnd {
                edited += clip.trimmedDuration
            } else if local > clip.trimStart {
                return edited + (local - clip.trimStart)
            } else {
                return edited
            }
        }
        return edited
    }

    /// Inverse: edited time → timeline time (for drawing on the timeline).
    func timelineTime(forEdited editedTarget: Double) -> Double {
        var remaining = editedTarget
        for (start, end) in keptRanges() {
            let length = end - start
            if remaining <= length { return start + remaining }
            remaining -= length
        }
        for (index, clip) in mergeClips.enumerated() {
            let base = mergeOffset(upTo: index)
            if remaining <= clip.trimmedDuration { return base + clip.trimStart + remaining }
            remaining -= clip.trimmedDuration
        }
        return timelineDuration
    }

    func editedTimeAtPlayhead() -> Double {
        editedTime(forTimeline: playhead)
    }

    /// Called from the periodic observer: keeps the audio preview at the
    /// right offset/volume, playing only inside its window (silent through
    /// cut regions, exactly like the export).
    func syncOverlayPreview() {
        guard overlayAudioURL != nil, overlayClipLength > 0.05 else { return }
        var target = editedTime(forTimeline: playhead) - overlayAudioStart
        // Live fade envelope, mirroring the exported ramps.
        var volume = Float(overlayAudioVolume)
        if overlayAudioFades {
            let length = overlayEffectiveLength
            let fade = min(1.5, max(0.2, length / 3))
            let envelope = min(1, max(0, target / fade)) * min(1, max(0, (length - target) / fade))
            volume *= Float(min(1, max(0, envelope)))
        }
        overlayPlayer.volume = volume
        let inWindow = target >= 0 && target < overlayEffectiveLength
        // Loop + clip-window mapping into the audio FILE's own timeline.
        if inWindow {
            target = overlayAudioClipStart + target.truncatingRemainder(dividingBy: overlayClipLength)
        }
        if isPlaying && inWindow {
            let current = overlayPlayer.currentTime().seconds
            if abs(current - target) > 0.25 {
                overlayPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                   toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if overlayPlayer.timeControlStatus != .playing { overlayPlayer.play() }
        } else if overlayPlayer.timeControlStatus == .playing {
            overlayPlayer.pause()
        }
    }

    func addAudioPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio file to mix over the video (applied on export)"
        if panel.runModal() == .OK, let url = panel.url {
            setOverlayAudio(url: url)
        }
    }

    private var timeObserver: Any?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var hasVideo: Bool { sourceURL != nil && duration > 0 }

    /// Duration of the final edited video (kept ranges + trimmed merge clips).
    var editedDuration: Double {
        keptRanges().reduce(0) { $0 + ($1.1 - $1.0) } + mergeClips.reduce(0) { $0 + $1.trimmedDuration }
    }

    private struct Snapshot {
        var cuts: [CutRegion]
        var trimStart: Double
        var trimEnd: Double
        var cropRect: CGRect?
        var mergeClips: [MergeClip]
    }

    // MARK: loading

    func openVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url: url) }
    }

    func load(url: URL) async {
        let mediaURL = url
        do {
            let asset = AVURLAsset(url: mediaURL)
            let durationTime = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = videoTracks.first else {
                errorMessage = "\(url.lastPathComponent) has no video track."
                return
            }
            let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
            let oriented = naturalSize.applying(transform)

            sourceURL = mediaURL
            duration = durationTime.seconds
            videoSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            fileSizeText = Self.fileSizeText(for: url)

            cuts = []
            trimStart = 0
            trimEnd = duration
            cropRect = nil
            mergeClips = []
            selectedCutID = nil
            undoStack = []
            redoStack = []
            playhead = 0
            errorMessage = nil
            exportMessage = nil
            lastExportURL = nil
            exportName = defaultExportName()
            recordingEvents = RecordingEvents.load(for: url)
            showClickRipples = false
            showKeystrokes = false
            autoZoom = false
            annotations = []
            pendingAnnotationKind = nil
            selectedAnnotationID = nil
            speedSegments = []

            sourceAsset = asset
            sourceVideoTrack = track
            sourceTransform = transform
            playingMergeIndex = nil
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
            attachTimeObserverIfNeeded()
        } catch {
            errorMessage = "Could not load video: \(error.localizedDescription)"
        }
    }

    private static func fileSizeText(for url: URL) -> String {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func attachTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = self.player.timeControlStatus == .playing
                defer { self.syncOverlayPreview() }

                // Live speed-segment preview: the player runs faster inside
                // a segment (pitch preserved via the item's algorithm).
                if self.isPlaying, self.playingMergeIndex == nil, self.previewEdits {
                    let factor = self.speedSegments.first(where: {
                        self.playhead >= $0.start && self.playhead < $0.end
                    })?.factor ?? 1
                    self.activePreviewRate = factor
                    if abs(Double(self.player.rate) - factor) > 0.01 {
                        // defaultRate too, so play()/resume keeps the speed
                        // instead of snapping back to 1x.
                        self.player.defaultRate = Float(factor)
                        self.player.rate = Float(factor)
                    }
                } else if !self.isPlaying {
                    self.activePreviewRate = 1
                }

                // Inside a merge clip: map to timeline coords, chain to the next.
                if let index = self.playingMergeIndex {
                    guard self.mergeClips.indices.contains(index) else {
                        self.returnToMain(at: self.trimStart)
                        return
                    }
                    let clip = self.mergeClips[index]
                    self.playhead = self.mergeOffset(upTo: index) + time.seconds
                    let clipEnd = self.previewEdits ? clip.trimEnd : clip.duration
                    if self.isPlaying, time.seconds >= clipEnd - 0.05 {
                        if self.mergeClips.indices.contains(index + 1) {
                            let next = self.mergeClips[index + 1]
                            self.switchToMerge(index + 1, at: self.previewEdits ? next.trimStart : 0)
                            self.player.play()
                        } else {
                            self.player.pause()
                        }
                    }
                    return
                }

                self.playhead = time.seconds
                guard self.isPlaying else { return }
                // End of the main video: flow into the merge clips.
                let mainEnd = self.previewEdits ? self.trimEnd : self.duration
                if self.playhead >= mainEnd - 0.05 {
                    if self.mergeClips.isEmpty {
                        self.player.pause()
                    } else {
                        let first = self.mergeClips[0]
                        self.switchToMerge(0, at: self.previewEdits ? first.trimStart : 0)
                        self.player.play()
                    }
                    return
                }
                guard self.previewEdits else { return }
                if let cut = self.cuts.first(where: { self.playhead >= $0.start && self.playhead < $0.end - 0.05 }) {
                    self.seek(to: cut.end)
                }
            }
        }
    }

    private func switchToMerge(_ index: Int, at localSeconds: Double) {
        guard mergeClips.indices.contains(index) else { return }
        if playingMergeIndex != index {
            playingMergeIndex = index
            player.replaceCurrentItem(with: AVPlayerItem(url: mergeClips[index].url))
        }
        playhead = mergeOffset(upTo: index) + localSeconds
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: localSeconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func returnToMain(at seconds: Double) {
        if playingMergeIndex != nil {
            playingMergeIndex = nil
            if let sourceAsset {
                player.replaceCurrentItem(with: AVPlayerItem(asset: sourceAsset))
                applyCropPreview()
            }
        }
        let clamped = min(max(seconds, 0), duration)
        playhead = clamped
        // Drop any still-running earlier seek first: queued precise seeks on
        // long-GOP files each decode seconds of video, compounding the lag.
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: playback controls

    func togglePlay() {
        guard hasVideo else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            return
        }
        if isAtEffectiveEnd || playhead >= timelineDuration - 0.05 {
            // Finished everything — restart from the beginning.
            seek(to: previewEdits ? trimStart : 0)
        } else if playingMergeIndex == nil, previewEdits, playhead < trimStart {
            seek(to: trimStart)
        }
        player.play()
    }

    /// True when playback stopped at the end of the last thing that would
    /// play — the trim-out of the final merge clip, or of the main video when
    /// there are no merge clips. Restart from the top instead of resuming
    /// into a trimmed-away region.
    private var isAtEffectiveEnd: Bool {
        if let index = playingMergeIndex {
            guard mergeClips.indices.contains(index) else { return true }
            guard index == mergeClips.count - 1 else { return false }
            let clip = mergeClips[index]
            let local = playhead - mergeOffset(upTo: index)
            return local >= (previewEdits ? clip.trimEnd : clip.duration) - 0.1
        }
        guard mergeClips.isEmpty else { return false }
        return playhead >= (previewEdits ? trimEnd : duration) - 0.1
    }

    /// Seeks in timeline coordinates — main video first, merge clips after.
    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), timelineDuration)
        if clamped <= duration || mergeClips.isEmpty {
            returnToMain(at: clamped)
            return
        }
        var offset = duration
        for (index, clip) in mergeClips.enumerated() {
            if clamped <= offset + clip.duration || index == mergeClips.count - 1 {
                switchToMerge(index, at: min(max(clamped - offset, 0), clip.duration))
                return
            }
            offset += clip.duration
        }
    }

    func step(by seconds: Double) {
        seek(to: playhead + seconds)
    }

    // MARK: edits

    func pushUndo() {
        undoStack.append(Snapshot(cuts: cuts, trimStart: trimStart, trimEnd: trimEnd, cropRect: cropRect, mergeClips: mergeClips))
        redoStack = []
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(cuts: cuts, trimStart: trimStart, trimEnd: trimEnd, cropRect: cropRect, mergeClips: mergeClips))
        apply(snapshot)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(cuts: cuts, trimStart: trimStart, trimEnd: trimEnd, cropRect: cropRect, mergeClips: mergeClips))
        apply(snapshot)
    }

    private func apply(_ snapshot: Snapshot) {
        cuts = snapshot.cuts
        trimStart = snapshot.trimStart
        trimEnd = snapshot.trimEnd
        cropRect = snapshot.cropRect
        mergeClips = snapshot.mergeClips
        if let selected = selectedCutID, !cuts.contains(where: { $0.id == selected }) {
            selectedCutID = nil
        }
        exitMergePlaybackIfNeeded()
    }

    /// Fresh start on the same video: wipes cuts, trim, crop and merge clips
    /// as one undoable step (post-export "Clear Edits").
    func clearAllEdits() {
        pushUndo()
        cuts = []
        trimStart = 0
        trimEnd = duration
        setOverlayAudio(url: nil)
        cropRect = nil
        mergeClips = []
        selectedCutID = nil
        exitMergePlaybackIfNeeded()
        lastExportURL = nil
        exportMessage = nil
    }

    /// Starts a brand-new edit session on the just-exported file.
    func editExportedVideo() {
        guard let url = lastExportURL else { return }
        lastExportURL = nil
        Task { await load(url: url) }
    }

    /// The merge list changed — indices are no longer valid, go back to main.
    private func exitMergePlaybackIfNeeded() {
        if playingMergeIndex != nil {
            player.pause()
            returnToMain(at: min(trimEnd, duration))
        }
    }

    func addCut(start: Double, end: Double) {
        let s = min(max(start, 0), duration)
        let e = min(max(end, 0), duration)
        guard e - s >= 0.15 else { return }
        pushUndo()
        let cut = CutRegion(id: UUID(), start: s, end: e)
        cuts.append(cut)
        cuts.sort { $0.start < $1.start }
        selectedCutID = cut.id
    }

    func deleteCut(id: UUID) {
        guard cuts.contains(where: { $0.id == id }) else { return }
        pushUndo()
        cuts.removeAll { $0.id == id }
        if selectedCutID == id { selectedCutID = nil }
    }

    func deleteSelectedCut() {
        if let id = selectedCutID { deleteCut(id: id) }
    }

    func setCrop(_ rect: CGRect?) {
        pushUndo()
        cropRect = rect
    }

    private static func croppedRenderSize(_ crop: CGRect, of videoSize: CGSize) -> CGSize {
        var size = CGSize(width: (crop.width * videoSize.width).rounded(),
                          height: (crop.height * videoSize.height).rounded())
        size.width -= size.width.truncatingRemainder(dividingBy: 2)
        size.height -= size.height.truncatingRemainder(dividingBy: 2)
        return size
    }

    /// Applies (or clears) the live crop on the player item — the same
    /// transform the exporter bakes in, so the preview IS the output.
    private func applyCropPreview() {
        guard let item = player.currentItem else { return }
        guard cropPreviewActive, let crop = cropRect,
              let track = sourceVideoTrack, videoSize != .zero else {
            if item.videoComposition != nil { item.videoComposition = nil }
            return
        }
        let renderSize = Self.croppedRenderSize(crop, of: videoSize)
        guard renderSize.width >= 16, renderSize.height >= 16 else {
            item.videoComposition = nil
            return
        }
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: 60)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: max(duration + 1, 1), preferredTimescale: 600))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let cropOrigin = CGPoint(x: (crop.origin.x * videoSize.width).rounded(),
                                 y: (crop.origin.y * videoSize.height).rounded())
        layer.setTransform(sourceTransform.concatenating(
            CGAffineTransform(translationX: -cropOrigin.x, y: -cropOrigin.y)), at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        item.videoComposition = composition
    }

    func addMergeClipPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addMergeClips(urls: panel.urls)
    }

    /// Appends clips directly (used by the Library picker in the merge menu).
    func addMergeClips(urls: [URL]) {
        Task {
            var clips: [MergeClip] = []
            for url in urls {
                let asset = AVURLAsset(url: url)
                guard let time = try? await asset.load(.duration) else { continue }
                clips.append(MergeClip(id: UUID(), url: url, duration: time.seconds, trimEnd: time.seconds))
            }
            guard !clips.isEmpty else { return }
            pushUndo()
            mergeClips.append(contentsOf: clips)
        }
    }

    func removeMergeClip(id: UUID) {
        guard mergeClips.contains(where: { $0.id == id }) else { return }
        pushUndo()
        mergeClips.removeAll { $0.id == id }
        exitMergePlaybackIfNeeded()
    }

    /// Reorder a merge clip one position up or down — clips are appended
    /// to the exported video in this list's order.
    func moveMergeClip(id: UUID, up: Bool) {
        guard let index = mergeClips.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard mergeClips.indices.contains(target) else { return }
        pushUndo()
        mergeClips.swapAt(index, target)
        exitMergePlaybackIfNeeded()
    }

    // Per-clip trim adjustments (undo is pushed once at drag start by the timeline).
    func setMergeTrimStart(index: Int, to value: Double) {
        guard mergeClips.indices.contains(index) else { return }
        mergeClips[index].trimStart = min(max(0, value), mergeClips[index].trimEnd - 0.1)
    }

    func setMergeTrimEnd(index: Int, to value: Double) {
        guard mergeClips.indices.contains(index) else { return }
        mergeClips[index].trimEnd = max(min(mergeClips[index].duration, value), mergeClips[index].trimStart + 0.1)
    }

    /// Ranges of the source that survive trim + cuts, in order.
    func keptRanges() -> [(Double, Double)] {
        var ranges: [(Double, Double)] = []
        var cursor = trimStart
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            let s = max(cut.start, trimStart)
            let e = min(cut.end, trimEnd)
            guard e > cursor else { continue }
            if s > cursor {
                ranges.append((cursor, s))
            }
            cursor = max(cursor, e)
        }
        if cursor < trimEnd {
            ranges.append((cursor, trimEnd))
        }
        return ranges.filter { $0.1 - $0.0 > 0.05 }
    }

    // MARK: export

    private func currentRecipe() -> ExportRecipe? {
        guard let sourceURL else { return nil }
        return ExportRecipe(
            sourceURL: sourceURL,
            keptRanges: keptRanges(),
            cropRectNormalized: cropRect,
            mergeSegments: mergeClips.map {
                ExportRecipe.MergeSegment(url: $0.url, start: $0.trimStart, end: $0.trimEnd)
            },
            overlayAudio: overlayAudioURL.map {
                ExportRecipe.OverlayAudio(url: $0, volume: Float(overlayAudioVolume),
                                          start: overlayAudioStart,
                                          clipStart: overlayAudioClipStart,
                                          clipEnd: overlayAudioClipEnd,
                                          loops: overlayAudioLoops,
                                          fades: overlayAudioFades)
            },
            speedRanges: editedSpeedRanges(),
            effects: builtEffects())
    }

    /// Recomputes the predicted output size for the selected format/quality.
    func updateExportEstimate() {
        estimateTask?.cancel()
        guard let recipe = currentRecipe() else { return }
        estimatedSizeText = "Estimating…"
        let preset = exportQuality.preset(hevc: exportFormat.isHEVC)
        let fileType = exportFormat.fileType
        estimateTask = Task { [weak self] in
            do {
                let bytes = try await VideoExporter.estimatedSize(recipe: recipe, preset: preset, fileType: fileType)
                guard !Task.isCancelled else { return }
                self?.estimatedSizeText = "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            } catch {
                guard !Task.isCancelled else { return }
                self?.estimatedSizeText = "Unavailable"
            }
        }
    }

    func exportPanelAndRun() {
        guard sourceURL != nil, let recipe = currentRecipe() else { return }
        let format = exportFormat
        let preset = exportQuality.preset(hevc: format.isHEVC)
        // The "Save as" name comes from the export sheet; the file lands in a
        // NEW session folder next to the original (EditorConfig), so the edit
        // is its own recording and the original is never touched.
        var name = exportName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        if name.isEmpty { name = defaultExportName() }
        guard let originalURL = sourceURL else { return }
        let folder: URL
        do {
            folder = try EditorConfig.makeEditedSessionFolder(for: originalURL)
        } catch {
            errorMessage = "Could not create the folder for the edit: \(error.localizedDescription)"
            return
        }
        let outputURL = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)

        isExporting = true
        exportProgress = 0
        exportMessage = nil
        errorMessage = nil

        exportTask = Task {
            do {
                try await VideoExporter.export(recipe: recipe, to: outputURL,
                                               preset: preset, fileType: format.fileType) { [weak self] fraction in
                    Task { @MainActor in
                        self?.exportProgress = fraction
                    }
                }
                isExporting = false
                EditorConfig.writeMetadata(forEditIn: folder, source: originalURL)
                // The editing session is finished: return to the editor's
                // start page, with the saved file offered in a popup card.
                closeVideo()
                savedExportURL = outputURL
            } catch is CancellationError {
                isExporting = false
                exportMessage = nil
                try? FileManager.default.removeItem(at: folder)
            } catch {
                isExporting = false
                try? FileManager.default.removeItem(at: folder)
                errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// "<source name> (edited)" — the prefill for the export's Save-as name.
    func defaultExportName() -> String {
        guard let sourceURL else { return "Recording (edited)" }
        return sourceURL.deletingPathExtension().lastPathComponent + " (edited)"
    }

    /// Closes the editing session entirely — back to the empty "Load a video"
    /// state. Callers confirm first when hasUnsavedEdits.
    func closeVideo() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        sourceURL = nil
        sourceAsset = nil
        duration = 0
        videoSize = .zero
        fileSizeText = "—"
        cuts = []
        trimStart = 0
        trimEnd = 0
        cropRect = nil
        mergeClips = []
        selectedCutID = nil
        undoStack = []
        redoStack = []
        playhead = 0
        playingMergeIndex = nil
        isCropping = false
        errorMessage = nil
        exportMessage = nil
        lastExportURL = nil
    }
}
