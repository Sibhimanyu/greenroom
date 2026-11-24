import Foundation

// The editor's one continuous timeline, as pure arithmetic (Foundation only,
// unit-tested in Tests/EditSequenceTests.swift).
//
// The original recording is segment 0; every joined clip follows with its own
// trim. Four time domains, each derived from the one before:
//
//   timeline  the stored domain. Every file sits at its FULL length, end to
//             end (this is what the bar draws). Cuts, speed spans,
//             annotations, the selection and the playhead live here, so
//             moving a trim handle never drags a cut off its picture.
//   sequence  timeline with each segment cut down to its trim, joined.
//   edited    sequence minus the cuts: what is kept, before any speed change.
//   final     edited after speed spans: the exported length.
//
// Cuts and speed spans may cross a clip boundary: pieces are split there.

/// One file in the sequence and the part of it that is kept.
struct EditSegment: Equatable, Sendable {
    var id: UUID
    var url: URL
    /// The file's whole length; it occupies this much of the timeline.
    var fileDuration: Double
    var srcStart: Double
    var srcEnd: Double

    var length: Double { max(0, srcEnd - srcStart) }
}

/// A stretch of the timeline played at `factor` (>1 faster, <1 slower).
struct EditSpeedSpan: Equatable, Sendable {
    var start: Double
    var end: Double
    var factor: Double
}

/// The same stretch on the EDITED domain, for the exporter.
struct EditSpeedRange: Equatable, Sendable {
    let start: Double
    let end: Double
    let factor: Double
}

struct EditSequence: Equatable, Sendable {
    var segments: [EditSegment]

    /// The smallest piece worth keeping.
    static let minPiece = 0.05

    init(segments: [EditSegment]) { self.segments = segments }

    // MARK: timeline (full files, end to end)

    var timelineDuration: Double { segments.reduce(0) { $0 + $1.fileDuration } }

    func timelineOffset(of index: Int) -> Double {
        segments.prefix(index).reduce(0) { $0 + $1.fileDuration }
    }

    func clampTimeline(_ t: Double) -> Double { min(max(t, 0), timelineDuration) }

    /// A span inside the timeline, `minLength` long at the least when it fits.
    func clampTimeline(start: Double, end: Double, minLength: Double = 0)
        -> (start: Double, end: Double) {
        let total = timelineDuration
        let s = min(max(start, 0), max(0, total - minLength))
        let e = min(max(end, s + minLength), total)
        return (s, e)
    }

    /// Timeline time -> (segment, time inside its file). A boundary belongs to
    /// the segment that ends there; times past the end land on the last file's
    /// end. Nil when there are no segments.
    func locate(timeline time: Double) -> (index: Int, source: Double)? {
        guard !segments.isEmpty else { return nil }
        let t = clampTimeline(time)
        var offset = 0.0
        for (index, segment) in segments.enumerated() {
            if t <= offset + segment.fileDuration || index == segments.count - 1 {
                return (index, min(max(t - offset, 0), segment.fileDuration))
            }
            offset += segment.fileDuration
        }
        return nil
    }

    /// (segment, time inside its file) -> timeline time. The file time is
    /// clamped to the file.
    func timelineTime(segment index: Int, source: Double) -> Double {
        guard segments.indices.contains(index) else { return timelineDuration }
        return timelineOffset(of: index) + min(max(source, 0), segments[index].fileDuration)
    }

    // MARK: sequence (trims applied, nothing cut)

    var sequenceDuration: Double { segments.reduce(0) { $0 + $1.length } }

    /// Timeline time -> sequence time: trimmed-away stretches are flat.
    func sequenceTime(forTimeline t: Double) -> Double {
        var acc = 0.0
        var offset = 0.0
        for segment in segments {
            let lo = offset + segment.srcStart
            let hi = offset + segment.srcEnd
            if t >= hi {
                acc += segment.length
            } else if t > lo {
                return acc + (t - lo)
            } else {
                return acc
            }
            offset += segment.fileDuration
        }
        return acc
    }

    /// Sequence time -> timeline time (a boundary resolves to the segment
    /// that ends there).
    func timelineTime(forSequence target: Double) -> Double {
        var remaining = max(0, target)
        var offset = 0.0
        for segment in segments {
            if remaining <= segment.length { return offset + segment.srcStart + remaining }
            remaining -= segment.length
            offset += segment.fileDuration
        }
        return timelineDuration
    }

    /// Sequence time -> (segment, time inside its file).
    func locate(sequence time: Double) -> (index: Int, source: Double)? {
        guard !segments.isEmpty else { return nil }
        var remaining = min(max(time, 0), sequenceDuration)
        for (index, segment) in segments.enumerated() {
            if remaining <= segment.length || index == segments.count - 1 {
                return (index, segment.srcStart + min(remaining, segment.length))
            }
            remaining -= segment.length
        }
        return nil
    }

    /// (segment, time inside its file) -> sequence time, clamped to the trim.
    func sequenceTime(segment index: Int, source: Double) -> Double {
        guard segments.indices.contains(index) else { return sequenceDuration }
        let segment = segments[index]
        let before = segments.prefix(index).reduce(0) { $0 + $1.length }
        return before + min(max(source, segment.srcStart), max(segment.srcStart, segment.srcEnd))
            - segment.srcStart
    }

    // MARK: kept pieces

    /// A kept stretch: one segment's trim minus the cuts, never crossing a
    /// boundary.
    struct Piece: Equatable, Sendable {
        let segmentIndex: Int
        let timelineStart: Double
        let timelineEnd: Double
        let srcStart: Double
        let srcEnd: Double
        var length: Double { timelineEnd - timelineStart }
    }

    /// What survives the trims and the cuts, in order, split at the segment
    /// boundaries. A segment that is empty, or wholly cut, adds nothing.
    func keptPieces(cuts: [(start: Double, end: Double)]) -> [Piece] {
        let sorted = cuts.sorted { $0.start < $1.start }
        var pieces: [Piece] = []
        var offset = 0.0
        for (index, segment) in segments.enumerated() {
            defer { offset += segment.fileDuration }
            let lo = offset + segment.srcStart
            let hi = offset + segment.srcEnd
            guard hi - lo > 0 else { continue }
            var cursor = lo
            func emit(_ from: Double, _ to: Double) {
                guard to - from > Self.minPiece else { return }
                pieces.append(Piece(segmentIndex: index, timelineStart: from, timelineEnd: to,
                                    srcStart: from - offset, srcEnd: to - offset))
            }
            for cut in sorted {
                let s = max(cut.start, lo)
                let e = min(cut.end, hi)
                guard e > s, e > cursor else { continue }
                if s > cursor { emit(cursor, s) }
                cursor = max(cursor, e)
            }
            if cursor < hi { emit(cursor, hi) }
        }
        return pieces
    }

    func timeline(cuts: [(start: Double, end: Double)],
                  speed: [EditSpeedSpan] = []) -> EditTimeline {
        EditTimeline(sequence: self, pieces: keptPieces(cuts: cuts), speed: speed)
    }

    // MARK: pictures

    /// Where a picture of `source` pixels lands on a canvas of `canvas` pixels
    /// when it is scaled to fit and centred (what the exporter does to every
    /// clip after the first).
    static func fit(source: CGSize, canvas: CGSize)
        -> (scale: Double, tx: Double, ty: Double) {
        guard source.width > 0, source.height > 0 else { return (1, 0, 0) }
        let scale = min(canvas.width / source.width, canvas.height / source.height)
        return (scale,
                (canvas.width - source.width * scale) / 2,
                (canvas.height - source.height * scale) / 2)
    }

    /// A normalised point of a segment's own picture -> the same spot on the
    /// rendered, cropped picture (both normalised, top-left origin).
    static func renderPoint(x: Double, y: Double, source: CGSize, canvas: CGSize,
                            cropOrigin: CGPoint, renderSize: CGSize) -> (x: Double, y: Double) {
        guard renderSize.width > 0, renderSize.height > 0 else { return (x, y) }
        let f = fit(source: source, canvas: canvas)
        let px = x * source.width * f.scale + f.tx - cropOrigin.x
        let py = y * source.height * f.scale + f.ty - cropOrigin.y
        return (px / renderSize.width, py / renderSize.height)
    }
}

/// The sequence after cuts and speed: the maps between the stored timeline,
/// the edited length and the final (exported) length. Sendable, so the
/// preview's render thread can hold one.
struct EditTimeline: Sendable {
    let sequence: EditSequence
    let pieces: [EditSequence.Piece]
    /// Speed spans on the EDITED domain, in order and not overlapping.
    let speedRanges: [EditSpeedRange]

    init(sequence: EditSequence, pieces: [EditSequence.Piece], speed: [EditSpeedSpan]) {
        self.sequence = sequence
        self.pieces = pieces
        var ranges: [EditSpeedRange] = []
        var floor = 0.0
        for span in speed.sorted(by: { $0.start < $1.start }) where abs(span.factor - 1) > 0.01 {
            let start = max(Self.editedTime(forTimeline: span.start, pieces: pieces), floor)
            let end = Self.editedTime(forTimeline: span.end, pieces: pieces)
            guard end - start > 0.15 else { continue }
            ranges.append(EditSpeedRange(start: start, end: end, factor: span.factor))
            floor = end
        }
        self.speedRanges = ranges
    }

    // MARK: lengths

    var editedDuration: Double { pieces.reduce(0) { $0 + $1.length } }
    var finalDuration: Double { finalTime(fromEdited: editedDuration) }
    var isEmpty: Bool { pieces.isEmpty }

    // MARK: timeline <-> edited

    private static func editedTime(forTimeline t: Double,
                                   pieces: [EditSequence.Piece]) -> Double {
        var edited = 0.0
        for piece in pieces {
            if t >= piece.timelineEnd {
                edited += piece.length
            } else if t > piece.timelineStart {
                return edited + (t - piece.timelineStart)
            } else {
                return edited
            }
        }
        return edited
    }

    /// Timeline -> edited time; a cut or a trimmed-away stretch is flat.
    func editedTime(forTimeline t: Double) -> Double {
        Self.editedTime(forTimeline: t, pieces: pieces)
    }

    /// Only when the instant survives the cuts and trims.
    func editedTimeIfKept(_ t: Double) -> Double? {
        var edited = 0.0
        for piece in pieces {
            if t >= piece.timelineEnd {
                edited += piece.length
            } else if t >= piece.timelineStart {
                return edited + (t - piece.timelineStart)
            } else {
                return nil
            }
        }
        return nil
    }

    /// Edited -> timeline time (the end of a piece, not the start of the next).
    func timelineTime(forEdited target: Double) -> Double {
        var remaining = max(0, target)
        for piece in pieces {
            if remaining <= piece.length { return piece.timelineStart + remaining }
            remaining -= piece.length
        }
        return pieces.last?.timelineEnd ?? sequence.timelineDuration
    }

    // MARK: edited <-> final

    func finalTime(fromEdited t: Double) -> Double {
        Self.finalTime(fromEdited: t, ranges: speedRanges)
    }

    static func finalTime(fromEdited t: Double, ranges: [EditSpeedRange]) -> Double {
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

    /// The inverse of `finalTime(fromEdited:)` (it only ever increases).
    func editedTime(fromFinal f: Double) -> Double {
        let total = editedDuration
        guard f > 0 else { return 0 }
        if f >= finalDuration { return total }
        var lo = 0.0, hi = total
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if finalTime(fromEdited: mid) < f { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    // MARK: timeline <-> final

    /// Timeline -> final time; nil when the instant is cut or trimmed away.
    func finalTime(forTimeline t: Double) -> Double? {
        editedTimeIfKept(t).map { finalTime(fromEdited: $0) }
    }

    /// Like `finalTime(forTimeline:)` but a cut stretch lands where it closes.
    func finalTimeClamped(forTimeline t: Double) -> Double {
        finalTime(fromEdited: editedTime(forTimeline: t))
    }

    func timelineTime(forFinal f: Double) -> Double {
        timelineTime(forEdited: editedTime(fromFinal: f))
    }

    /// A timeline span as a final-time span (annotations); nil when nothing of
    /// it is kept for at least `minimum` seconds.
    func finalSpan(timelineStart: Double, timelineEnd: Double,
                   minimum: Double = 0.1) -> (start: Double, end: Double)? {
        let s = editedTime(forTimeline: timelineStart)
        let e = editedTime(forTimeline: timelineEnd)
        guard e - s > minimum else { return nil }
        return (finalTime(fromEdited: s), finalTime(fromEdited: e))
    }

    // MARK: playback

    /// Where the timeline time `t` falls: the piece containing it, or the
    /// start of the next piece when it is in a gap; nil when nothing is left
    /// ahead of it.
    func nextKeptStart(from t: Double) -> Double? {
        for piece in pieces where t < piece.timelineEnd - 0.001 {
            return max(t, piece.timelineStart)
        }
        return nil
    }

    var firstKeptStart: Double? { pieces.first?.timelineStart }
    var lastKeptEnd: Double? { pieces.last?.timelineEnd }
}
