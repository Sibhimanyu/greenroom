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

    /// The clip's picture size once its own orientation is applied (zero
    /// until known; only the effects mapping needs it).
    var size: CGSize = .zero
    /// Clicks and keys recorded with this clip (its own sidecar), if any.
    var events: RecordingEvents?

    var trimmedDuration: Double { max(0, trimEnd - trimStart) }
    var isTrimmed: Bool { trimStart > 0.05 || trimEnd < duration - 0.05 }
}

@MainActor
final class EditorViewModel: ObservableObject {

    // MARK: source
    @Published private(set) var sourceURL: URL? {
        didSet { rebuildTimeline() }
    }
    @Published private(set) var duration: Double = 0 {
        didSet { rebuildTimeline() }
    }
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
    /// under the crop rectangle). The one crop covers every clip.
    var cropPreviewActive: Bool {
        cropRect != nil && !isCropping && previewEdits
    }
    @Published private(set) var fileSizeText = "—"

    // MARK: edit state
    /// The stretch dragged across the timeline bar, in timeline seconds.
    /// Remove, Speed and Blur act on it; nil means "at the playhead".
    @Published var selection: ClosedRange<Double>?
    @Published var selectedSpeedID: UUID?
    /// 1 = the whole bar fits the window; more zooms the bar in.
    @Published var timelineZoom: Double = 1
    /// ContentView's Back button asks; EditorView answers (it knows about edits).
    @Published var backRequests = 0
    @Published var cuts: [CutRegion] = [] {
        didSet { timelineInputsChanged() }
    }
    /// The ORIGINAL's trim (each joined clip carries its own).
    @Published var trimStart: Double = 0 {
        didSet { timelineInputsChanged() }
    }
    @Published var trimEnd: Double = 0 {
        didSet { timelineInputsChanged() }
    }
    @Published var cropRect: CGRect? {  // normalized 0…1, origin top-left of the video
        didSet { applyCropPreview() }
    }
    @Published var mergeClips: [MergeClip] = [] {
        didSet {
            timelineInputsChanged()
            if playhead > timelineDuration { playhead = timelineDuration }
            rebuildPreviewItemIfNeeded()
        }
    }
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
    /// nil = the playhead is on the original; otherwise the index of the
    /// joined clip it is in. One player item holds everything: the timeline
    /// is the item's own time.
    var playingMergeIndex: Int? {
        guard !mergeClips.isEmpty, let located = sequence.locate(timeline: playhead),
              located.index > 0 else { return nil }
        return located.index - 1
    }

    // MARK: the one timeline
    private static let mainSegmentID = UUID()
    /// The original plus every joined clip, with their trims.
    private(set) var sequence = EditSequence(segments: [])
    /// The sequence after cuts and speed: every time map goes through this.
    private(set) var timeline = EditTimeline(sequence: EditSequence(segments: []),
                                             pieces: [], speed: [])

    private func rebuildTimeline() {
        var segments: [EditSegment] = []
        if let sourceURL {
            segments.append(EditSegment(id: Self.mainSegmentID, url: sourceURL, fileDuration: duration,
                                        srcStart: trimStart, srcEnd: max(trimStart, trimEnd)))
        }
        for clip in mergeClips {
            segments.append(EditSegment(id: clip.id, url: clip.url, fileDuration: clip.duration,
                                        srcStart: clip.trimStart, srcEnd: max(clip.trimStart, clip.trimEnd)))
        }
        sequence = EditSequence(segments: segments)
        timeline = sequence.timeline(
            cuts: cuts.map { (start: $0.start, end: $0.end) },
            speed: speedSegments.map { EditSpeedSpan(start: $0.start, end: $0.end, factor: $0.factor) })
    }

    private func timelineInputsChanged() {
        rebuildTimeline()
        schedulePreviewComposition()
    }

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
    @Published private(set) var recordingEvents: RecordingEvents? {
        didSet { schedulePreviewComposition() }
    }
    @Published var showClickRipples = false {
        didSet { schedulePreviewComposition() }
    }
    @Published var showKeystrokes = false {
        didSet { schedulePreviewComposition() }
    }
    @Published var autoZoom = false {
        didSet { schedulePreviewComposition() }
    }

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
    @Published var speedSegments: [SpeedSegment] = [] {
        didSet { timelineInputsChanged() }
    }
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
        let start: Double
        let end: Double
        if let selection {
            // The selected stretch is the span (anywhere on the timeline).
            start = sequence.clampTimeline(selection.lowerBound)
            end = sequence.clampTimeline(selection.upperBound)
        } else {
            start = min(max(playhead, 0), max(timelineDuration - 0.5, 0))
            end = min(start + 4, timelineDuration)
        }
        pushUndo()
        let annotation = EditorAnnotation(
            id: UUID(), kind: kind, rect: shaped, start: start, end: max(end, start + 0.5),
            text: "")
        annotations.append(annotation)
        // Fresh annotations come up selected — text opens straight into
        // its inline field, arrows/boxes show their handles.
        selectedAnnotationID = annotation.id
        selection = nil
    }

    func removeAnnotation(id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
        if selectedAnnotationID == id { selectedAnnotationID = nil }
    }

    /// Moves or resizes an annotation's span. The timeline pushes undo once
    /// at the start of the drag.
    func setAnnotationRange(id: UUID, start: Double, end: Double) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let span = sequence.clampTimeline(start: start, end: end, minLength: 0.5)
        annotations[index].start = span.start
        annotations[index].end = span.end
    }

    // MARK: selection

    /// Whether Esc has anything to put away before it means Back.
    var hasSomethingToDismiss: Bool {
        selection != nil || selectedCutID != nil || selectedAnnotationID != nil
            || selectedSpeedID != nil || pendingAnnotationKind != nil || isCropping
    }

    func dismissSelections() {
        selection = nil
        selectedCutID = nil
        selectedAnnotationID = nil
        selectedSpeedID = nil
        pendingAnnotationKind = nil
        isCropping = false
    }

    /// I and O: set one end of the selection to the playhead.
    func setSelectionStart(to t: Double) {
        let limit = timelineDuration
        let lo = min(max(t, 0), limit)
        let hi = selection?.upperBound ?? limit
        selection = lo...max(hi, min(lo + 0.5, limit))
    }

    func setSelectionEnd(to t: Double) {
        let hi = min(max(t, 0), timelineDuration)
        let lo = selection?.lowerBound ?? 0
        selection = min(lo, max(hi - 0.5, 0))...hi
    }

    /// [ and ]: trim the start or the end of the clip under the playhead
    /// (the original, or a joined clip) to the playhead.
    func setTrimStartToPlayhead() {
        guard let located = sequence.locate(timeline: playhead) else { return }
        if located.index == 0 {
            guard located.source < trimEnd - 0.2 else { return }
            pushUndo()
            trimStart = max(0, located.source)
        } else if mergeClips.indices.contains(located.index - 1) {
            let clip = mergeClips[located.index - 1]
            guard located.source < clip.trimEnd - 0.2 else { return }
            pushUndo()
            setMergeTrimStart(index: located.index - 1, to: located.source)
        }
    }

    func setTrimEndToPlayhead() {
        guard let located = sequence.locate(timeline: playhead) else { return }
        if located.index == 0 {
            guard located.source > trimStart + 0.2 else { return }
            pushUndo()
            trimEnd = min(duration, located.source)
        } else if mergeClips.indices.contains(located.index - 1) {
            let clip = mergeClips[located.index - 1]
            guard located.source > clip.trimStart + 0.2 else { return }
            pushUndo()
            setMergeTrimEnd(index: located.index - 1, to: located.source)
        }
    }

    /// Takes the selected stretch out of the video (a removed stretch).
    func removeSelection() {
        guard let selection else { return }
        addCut(start: selection.lowerBound, end: selection.upperBound)
        self.selection = nil
    }

    /// The span a tool acts on: the selection, else from the playhead.
    func toolSpan(defaultLength: Double) -> (Double, Double) {
        if let selection { return (selection.lowerBound, selection.upperBound) }
        let start = sequence.clampTimeline(playhead)
        return (start, min(start + defaultLength, timelineDuration))
    }

    func applySpeedToSelection(factor: Double) {
        let span = toolSpan(defaultLength: 10)
        applySpeed(factor: factor, from: span.0, to: span.1)
        selection = nil
    }

    /// Moves or resizes a speed segment (undo pushed once at drag start).
    func setSpeedRange(id: UUID, start: Double, end: Double) {
        guard let index = speedSegments.firstIndex(where: { $0.id == id }) else { return }
        let span = sequence.clampTimeline(start: start, end: end, minLength: 0.3)
        speedSegments[index].start = span.start
        speedSegments[index].end = span.end
    }

    /// Moves or resizes a removed stretch (undo pushed once at drag start).
    func setCutRange(id: UUID, start: Double, end: Double) {
        guard let index = cuts.firstIndex(where: { $0.id == id }) else { return }
        let span = sequence.clampTimeline(start: start, end: end, minLength: 0.15)
        cuts[index].start = span.start
        cuts[index].end = span.end
    }

    /// Any segment, the original or a joined clip, has recorded clicks or keys.
    var hasRecordedEvents: Bool {
        (recordingEvents.map { !$0.isEmpty } ?? false)
            || mergeClips.contains { $0.events.map { !$0.isEmpty } ?? false }
    }

    var trimIsSet: Bool { trimStart > 0.05 || trimEnd < duration - 0.05 }

    func resetTrimStart() {
        pushUndo()
        trimStart = 0
    }

    func resetTrimEnd() {
        pushUndo()
        trimEnd = duration
    }

    /// Applies a speed to [from, to], REPLACING whatever overlaps — a second
    /// apply always wins over stale segments instead of silently no-opping.
    /// Works anywhere on the timeline, across joined clips too.
    func applySpeed(factor: Double, from rawFrom: Double, to rawTo: Double) {
        let factor = min(max(factor, 0.25), 8)
        let from = sequence.clampTimeline(rawFrom)
        let to = sequence.clampTimeline(rawTo)
        guard to - from > 0.3 else {
            errorMessage = "That stretch is too short for a speed change. Select a longer one."
            return
        }
        pushUndo()
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
        applySpeed(factor: factor, from: 0, to: timelineDuration)
    }

    func removeSpeedSegment(id: UUID) {
        guard speedSegments.contains(where: { $0.id == id }) else { return }
        pushUndo()
        speedSegments.removeAll { $0.id == id }
        if selectedSpeedID == id { selectedSpeedID = nil }
    }

    // MARK: timeline → edited → final time mapping

    /// Speed ranges on the EDITED domain, for the exporter.
    private func editedSpeedRanges() -> [ExportRecipe.SpeedRange] { timeline.speedRanges }

    /// Timeline time -> final exported time, from a snapshot of the cuts and
    /// speed (nil when the instant is cut or trimmed away). Safe to call from
    /// the preview's render thread. `identity` is the preview with "preview
    /// edits" off: the player shows everything at 1x, so times pass through.
    private func timelineToFinalMap(identity: Bool = false) -> @Sendable (Double) -> Double? {
        if identity { return { $0 } }
        let timeline = self.timeline
        return { timeline.finalTime(forTimeline: $0) }
    }

    /// Everything the effects pass draws, mapped to the final timeline.
    private func builtEffects() -> EditedEffects? {
        builtEffects(map: timelineToFinalMap(), crop: cropRect, includeAnnotations: true)
    }

    /// The recorded-input effects of EVERY segment (annotations stay with the
    /// preview overlay unless asked for), mapped to the final timeline via
    /// `map`. Each segment's events sit at its place on the timeline, and
    /// their positions follow its picture onto the render (fit, then crop).
    private func builtEffects(map: (Double) -> Double?, crop: CGRect?,
                              includeAnnotations: Bool) -> EditedEffects? {
        var effects = EditedEffects()

        let geometry = EditComposition.geometry(canvas: videoSize, crop: crop)
        var ripplePoints: [(t: Double, x: Double, y: Double)] = []
        var keyChips: [EditedEffects.KeyChip] = []
        for (index, segment) in sequence.segments.enumerated() {
            let events = index == 0 ? recordingEvents : mergeClips[index - 1].events
            guard let events else { continue }
            let offset = sequence.timelineOffset(of: index)
            let size = index == 0 ? videoSize : mergeClips[index - 1].size
            func place(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
                guard geometry.isValid, size.width > 0, size.height > 0 else { return (x, y) }
                return EditSequence.renderPoint(x: x, y: y, source: size, canvas: geometry.canvas,
                                                cropOrigin: geometry.cropOrigin,
                                                renderSize: geometry.renderSize)
            }
            if showClickRipples || autoZoom {
                for click in events.clicks {
                    guard let t = map(offset + click.t) else { continue }
                    let spot = place(click.x, click.y)
                    ripplePoints.append((t, spot.x, spot.y))
                }
            }
            if showKeystrokes {
                for key in events.keys {
                    guard let t = map(offset + key.t) else { continue }
                    keyChips.append(EditedEffects.KeyChip(t: t, text: key.text))
                }
            }
            _ = segment
        }
        ripplePoints.sort { $0.t < $1.t }
        if showClickRipples {
            effects.ripples = ripplePoints.map { EditedEffects.Ripple(t: $0.t, x: $0.x, y: $0.y) }
        }
        if showKeystrokes {
            effects.keyChips = keyChips.sorted { $0.t < $1.t }
        }
        if autoZoom {
            effects.zoomKeyframes = Self.zoomKeyframes(fromFinalClicks: ripplePoints)
        }
        if includeAnnotations {
            effects.annotations = annotations.compactMap { annotation in
                guard let span = timeline.finalSpan(timelineStart: annotation.start,
                                                    timelineEnd: annotation.end) else { return nil }
                return EditedEffects.Annotation(
                    kind: annotation.kind, rect: annotation.rect,
                    start: span.start, end: span.end,
                    text: annotation.text,
                    color: annotation.color)
            }
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

    /// What is kept, before any speed change: trims and cuts applied, across
    /// the original and every joined clip.
    var totalEditedDuration: Double { timeline.editedDuration }

    /// Timeline time -> edited time (flat across a cut or a trimmed-away stretch).
    func editedTime(forTimeline t: Double) -> Double {
        timeline.editedTime(forTimeline: t)
    }

    /// Inverse: edited time -> timeline time (for drawing on the timeline).
    func timelineTime(forEdited editedTarget: Double) -> Double {
        timeline.timelineTime(forEdited: editedTarget)
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

    /// Duration of the final exported video: kept pieces of every clip, speed applied.
    var editedDuration: Double { timeline.finalDuration }

    private struct Snapshot {
        var cuts: [CutRegion]
        var trimStart: Double
        var trimEnd: Double
        var cropRect: CGRect?
        var mergeClips: [MergeClip]
        var annotations: [EditorAnnotation]
        var speedSegments: [SpeedSegment]
    }

    private func snapshot() -> Snapshot {
        Snapshot(cuts: cuts, trimStart: trimStart, trimEnd: trimEnd, cropRect: cropRect,
                 mergeClips: mergeClips, annotations: annotations, speedSegments: speedSegments)
    }

    // MARK: loading

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
            selection = nil
            selectedSpeedID = nil
            timelineZoom = 1
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

            previewSignature = []
            previewBuildTask?.cancel()
            await buildPreviewItem()
            attachTimeObserverIfNeeded()
        } catch {
            errorMessage = "Could not load video: \(error.localizedDescription)"
        }
    }

    private static func fileSizeText(for url: URL) -> String {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: the preview item

    /// What the current preview composition was built from (file list and
    /// lengths); trims, cuts and speed do not change it.
    private var previewSignature: [String] = []
    private var previewBuilt: EditComposition.Built?
    private var previewBuildTask: Task<Void, Never>?

    private func currentPreviewSignature() -> [String] {
        sequence.segments.map { "\($0.url.path)|\($0.fileDuration)" }
    }

    /// The file list changed (a clip joined, removed or moved): build the one
    /// composition again, off the main flow.
    private func rebuildPreviewItemIfNeeded() {
        guard hasVideo, currentPreviewSignature() != previewSignature else { return }
        previewBuildTask?.cancel()
        previewBuildTask = Task { @MainActor [weak self] in
            await self?.buildPreviewItem()
        }
    }

    /// ONE AVPlayerItem for the original and every clip, each whole, end to
    /// end. Its time is the timeline's time, so a clip boundary is invisible
    /// to the player; cuts are skipped and speed is applied by the observer.
    private func buildPreviewItem() async {
        let signature = currentPreviewSignature()
        previewSignature = signature
        let segments = sequence.segments
        do {
            let built = try await EditComposition.build(
                urls: segments.map(\.url),
                pieces: EditComposition.wholeFilePieces(fileDurations: segments.map(\.fileDuration)))
            guard !Task.isCancelled, signature == currentPreviewSignature() else { return }
            previewBuilt = built
            let wasPlaying = player.timeControlStatus == .playing
            let item = AVPlayerItem(asset: built.composition)
            item.audioTimePitchAlgorithm = .spectral
            player.replaceCurrentItem(with: item)
            applyCropPreview()
            playhead = min(max(playhead, 0), timelineDuration)
            player.seek(to: CMTime(seconds: playhead, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
            if wasPlaying { player.play() }
        } catch {
            if signature == currentPreviewSignature() {
                previewSignature = []
                errorMessage = "Could not show the video: \(error.localizedDescription)"
            }
        }
    }

    private var lastSkip: (target: Double, at: Date)?

    private func attachTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = self.player.timeControlStatus == .playing
                defer { self.syncOverlayPreview() }
                guard self.previewBuilt != nil else { return }

                // The item's time IS the timeline's time.
                self.playhead = min(max(time.seconds, 0), self.timelineDuration)
                guard self.isPlaying else {
                    self.activePreviewRate = 1
                    return
                }
                guard self.previewEdits else {
                    if abs(Double(self.player.rate) - 1) > 0.01 {
                        self.player.defaultRate = 1
                        self.player.rate = 1
                    }
                    self.activePreviewRate = 1
                    return
                }

                // Live speed preview: the player runs faster inside a speed
                // span (pitch preserved via the item's algorithm).
                let playhead = self.playhead
                let factor = self.speedSegments.first(where: {
                    playhead >= $0.start && playhead < $0.end
                })?.factor ?? 1
                self.activePreviewRate = factor
                if abs(Double(self.player.rate) - factor) > 0.01 {
                    // defaultRate too, so play()/resume keeps the speed
                    // instead of snapping back to 1x.
                    self.player.defaultRate = Float(factor)
                    self.player.rate = Float(factor)
                }

                // Past the last kept frame: stop. In a cut or a trimmed-away
                // stretch: jump to where the video picks up again.
                let timeline = self.timeline
                guard let end = timeline.lastKeptEnd else {
                    self.player.pause()
                    return
                }
                if playhead >= end - 0.03 {
                    self.player.pause()
                    self.playhead = end
                    return
                }
                if let target = timeline.nextKeptStart(from: playhead), target > playhead + 0.02 {
                    if let last = self.lastSkip, last.target == target, Date().timeIntervalSince(last.at) < 0.4 {
                        return
                    }
                    self.lastSkip = (target, Date())
                    self.seek(to: target)
                }
            }
        }
    }

    // MARK: playback controls

    func togglePlay() {
        guard hasVideo else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            return
        }
        if isAtEffectiveEnd {
            // Finished everything: restart from the beginning.
            seek(to: previewEdits ? (timeline.firstKeptStart ?? 0) : 0)
        } else if previewEdits, let first = timeline.firstKeptStart, playhead < first {
            seek(to: first)
        }
        player.play()
    }

    /// True when playback stopped at the end of the last thing that would
    /// play (the last kept frame, whichever clip it is in). Restart from the
    /// top instead of resuming into a trimmed-away or cut stretch.
    private var isAtEffectiveEnd: Bool {
        let end = previewEdits ? (timeline.lastKeptEnd ?? timelineDuration) : timelineDuration
        return playhead >= end - 0.1
    }

    /// Seeks in timeline coordinates: the original first, joined clips after.
    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), timelineDuration)
        playhead = clamped
        // Drop any still-running earlier seek first: queued precise seeks on
        // long-GOP files each decode seconds of video, compounding the lag.
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(by seconds: Double) {
        seek(to: playhead + seconds)
    }

    // MARK: edits

    func pushUndo() {
        undoStack.append(snapshot())
        redoStack = []
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        apply(next)
    }

    private func apply(_ snapshot: Snapshot) {
        cuts = snapshot.cuts
        trimStart = snapshot.trimStart
        trimEnd = snapshot.trimEnd
        cropRect = snapshot.cropRect
        mergeClips = snapshot.mergeClips
        annotations = snapshot.annotations
        speedSegments = snapshot.speedSegments
        selection = nil
        if let selected = selectedCutID, !cuts.contains(where: { $0.id == selected }) {
            selectedCutID = nil
        }
        if let selected = selectedAnnotationID, !annotations.contains(where: { $0.id == selected }) {
            selectedAnnotationID = nil
        }
        if let selected = selectedSpeedID, !speedSegments.contains(where: { $0.id == selected }) {
            selectedSpeedID = nil
        }
    }

    func addCut(start: Double, end: Double) {
        let s = sequence.clampTimeline(start)
        let e = sequence.clampTimeline(end)
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

    private var previewCompositionTask: Task<Void, Never>?

    /// Rebuilds the preview composition ~150 ms after the last change to
    /// anything it depends on (toggles, events, cuts, trim, speed, merge).
    private func schedulePreviewComposition() {
        previewCompositionTask?.cancel()
        previewCompositionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.applyCropPreview()
        }
    }

    /// Applies (or clears) the video composition on the player item: the
    /// scale-to-fit of every clip after the first plus the live crop (the same
    /// transform the exporter bakes in, over the whole sequence) and, when a
    /// recorded-input toggle is on, the click ripples / key chips / auto-zoom
    /// drawn by the export's own compositor. Swapping a composition on the
    /// item keeps the playhead and play state. Annotations are NOT drawn here:
    /// `AnnotationPreviewOverlay` already shows them.
    private func applyCropPreview() {
        guard let item = player.currentItem, let built = previewBuilt else { return }
        let crop = cropPreviewActive ? cropRect : nil
        let geometry = EditComposition.geometry(canvas: videoSize, crop: crop)
        let validCrop = crop != nil && geometry.isValid

        // Recorded-input effects (never while cropping).
        if hasRecordedEvents, !isCropping, videoSize != .zero, geometry.isValid {
            let map = timelineToFinalMap(identity: !previewEdits)
            if let effects = builtEffects(map: map, crop: crop, includeAnnotations: false) {
                item.videoComposition = EffectsRenderer.previewComposition(
                    for: item.asset, effects: effects, geometry: geometry,
                    infos: built.infos, placements: built.placements, timeMap: map)
                return
            }
        }

        guard validCrop || built.infos.count > 1 else {
            if item.videoComposition != nil { item.videoComposition = nil }
            return
        }
        item.videoComposition = EditComposition.videoComposition(for: built, crop: validCrop ? crop : nil)
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
                guard let time = try? await asset.load(.duration),
                      let track = try? await asset.loadTracks(withMediaType: .video).first,
                      let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
                else { continue }
                let oriented = natural.applying(transform)
                var clip = MergeClip(id: UUID(), url: url, duration: time.seconds, trimEnd: time.seconds)
                clip.size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
                clip.events = RecordingEvents.load(for: url)
                clips.append(clip)
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
    }

    /// Reorder a merge clip one position up or down — clips are appended
    /// to the exported video in this list's order.
    func moveMergeClip(id: UUID, up: Bool) {
        guard let index = mergeClips.firstIndex(where: { $0.id == id }) else { return }
        let target = up ? index - 1 : index + 1
        guard mergeClips.indices.contains(target) else { return }
        pushUndo()
        mergeClips.swapAt(index, target)
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
    // MARK: export

    private func currentRecipe() -> ExportRecipe? {
        guard sourceURL != nil else { return nil }
        return ExportRecipe(
            segmentURLs: sequence.segments.map(\.url),
            pieces: timeline.pieces,
            cropRectNormalized: cropRect,
            overlayAudio: overlayAudioURL.map {
                // Placed where its picture is in the exported (sped-up) video.
                ExportRecipe.OverlayAudio(url: $0, volume: Float(overlayAudioVolume),
                                          start: timeline.finalTime(fromEdited: overlayAudioStart),
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
        previewBuildTask?.cancel()
        previewBuilt = nil
        previewSignature = []
        duration = 0
        videoSize = .zero
        fileSizeText = "—"
        cuts = []
        trimStart = 0
        trimEnd = 0
        cropRect = nil
        mergeClips = []
        selectedCutID = nil
        selection = nil
        selectedSpeedID = nil
        annotations = []
        speedSegments = []
        undoStack = []
        redoStack = []
        playhead = 0
        isCropping = false
        errorMessage = nil
        exportMessage = nil
        lastExportURL = nil
    }
}
