import XCTest

final class EditSequenceTests: XCTestCase {
    private func segment(_ file: Double, _ lo: Double? = nil, _ hi: Double? = nil) -> EditSegment {
        EditSegment(id: UUID(), url: URL(fileURLWithPath: "/tmp/x.mp4"), fileDuration: file,
                    srcStart: lo ?? 0, srcEnd: hi ?? file)
    }

    /// Original 10 s (trim 1...9), clip A 6 s (trim 2...5), clip B 4 s untrimmed.
    private var sequence: EditSequence {
        EditSequence(segments: [segment(10, 1, 9), segment(6, 2, 5), segment(4)])
    }

    func testDurations() {
        XCTAssertEqual(sequence.timelineDuration, 20, accuracy: 1e-9)
        XCTAssertEqual(sequence.sequenceDuration, 8 + 3 + 4, accuracy: 1e-9)
        XCTAssertEqual(sequence.timelineOffset(of: 2), 16, accuracy: 1e-9)
    }

    func testLocateTimelineAndBack() {
        let inClip = sequence.locate(timeline: 12.5)
        XCTAssertEqual(inClip?.index, 1)
        XCTAssertEqual(inClip!.source, 2.5, accuracy: 1e-9)
        // A boundary belongs to the clip that ends there.
        XCTAssertEqual(sequence.locate(timeline: 10)?.index, 0)
        XCTAssertEqual(sequence.locate(timeline: 99)?.index, 2)
        XCTAssertEqual(sequence.timelineTime(segment: 1, source: 2.5), 12.5, accuracy: 1e-9)
        XCTAssertEqual(sequence.timelineTime(segment: 1, source: 99), 16, accuracy: 1e-9)
    }

    func testSequenceTimeSkipsTrimmedAway() {
        // Before the original's trim, and in its trimmed tail: flat.
        XCTAssertEqual(sequence.sequenceTime(forTimeline: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(sequence.sequenceTime(forTimeline: 5), 4, accuracy: 1e-9)
        XCTAssertEqual(sequence.sequenceTime(forTimeline: 9.5), 8, accuracy: 1e-9)
        // 12 s on the timeline is 2 s into clip A, its trim start.
        XCTAssertEqual(sequence.sequenceTime(forTimeline: 12), 8, accuracy: 1e-9)
        XCTAssertEqual(sequence.sequenceTime(forTimeline: 13), 9, accuracy: 1e-9)
        XCTAssertEqual(sequence.timelineTime(forSequence: 9), 13, accuracy: 1e-9)
        let located = sequence.locate(sequence: 9)
        XCTAssertEqual(located?.index, 1)
        XCTAssertEqual(located!.source, 3, accuracy: 1e-9)
        XCTAssertEqual(sequence.sequenceTime(segment: 2, source: 1), 12, accuracy: 1e-9)
    }

    func testKeptPiecesHonourTrims() {
        let pieces = sequence.keptPieces(cuts: [])
        XCTAssertEqual(pieces.map(\.segmentIndex), [0, 1, 2])
        XCTAssertEqual(pieces[0].timelineStart, 1, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].timelineStart, 12, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].srcStart, 2, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].srcEnd, 5, accuracy: 1e-9)
        XCTAssertEqual(pieces[2].timelineStart, 16, accuracy: 1e-9)
    }

    func testCutAcrossABoundaryIsSplitPerSegment() {
        // 8...13 covers the original's tail, its trimmed-away end and the
        // start of clip A.
        let timeline = sequence.timeline(cuts: [(8, 13)])
        let pieces = timeline.pieces
        XCTAssertEqual(pieces.map(\.segmentIndex), [0, 1, 2])
        XCTAssertEqual(pieces[0].timelineEnd, 8, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].timelineStart, 13, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].srcStart, 3, accuracy: 1e-9)
        XCTAssertEqual(timeline.editedDuration, 7 + 2 + 4, accuracy: 1e-9)
    }

    func testCutCoveringAWholeClipDropsIt() {
        let timeline = sequence.timeline(cuts: [(10, 16)])
        XCTAssertEqual(timeline.pieces.map(\.segmentIndex), [0, 2])
        XCTAssertEqual(timeline.editedDuration, 8 + 4, accuracy: 1e-9)
        // A cut that extends beyond the clip into its neighbours.
        let wide = sequence.timeline(cuts: [(7, 17)])
        XCTAssertEqual(wide.pieces.map(\.segmentIndex), [0, 2])
        XCTAssertEqual(wide.pieces[1].timelineStart, 17, accuracy: 1e-9)
    }

    func testEmptyClipAddsNothing() {
        let seq = EditSequence(segments: [segment(10), segment(5, 2, 2), segment(3)])
        XCTAssertEqual(seq.sequenceDuration, 13, accuracy: 1e-9)
        let timeline = seq.timeline(cuts: [])
        XCTAssertEqual(timeline.pieces.map(\.segmentIndex), [0, 2])
        XCTAssertEqual(timeline.editedDuration, 13, accuracy: 1e-9)
    }

    func testTinyPiecesAreDropped() {
        let timeline = sequence.timeline(cuts: [(1.03, 9)])
        XCTAssertEqual(timeline.pieces.map(\.segmentIndex), [1, 2])
    }

    func testEditedAndTimelineMapsThroughCuts() {
        let timeline = sequence.timeline(cuts: [(8, 13)])
        // Kept: 1...8 | 13...15 | 16...20 -> edited 0...7 | 7...9 | 9...13
        XCTAssertEqual(timeline.editedTimeIfKept(2)!, 1, accuracy: 1e-9)
        XCTAssertNil(timeline.editedTimeIfKept(10))
        XCTAssertNil(timeline.editedTimeIfKept(15.5))
        XCTAssertEqual(timeline.editedTimeIfKept(13.5)!, 7.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.editedTime(forTimeline: 10), 7, accuracy: 1e-9)
        XCTAssertEqual(timeline.timelineTime(forEdited: 7.5), 13.5, accuracy: 1e-9)
        XCTAssertEqual(timeline.timelineTime(forEdited: 10), 17, accuracy: 1e-9)
    }

    func testSpeedAcrossABoundary() {
        // 2x over timeline 6...14: edited 5...7 is outside... compute exactly.
        let seq = EditSequence(segments: [segment(10), segment(10)])
        let timeline = seq.timeline(cuts: [], speed: [EditSpeedSpan(start: 8, end: 14, factor: 2)])
        XCTAssertEqual(timeline.speedRanges.count, 1)
        XCTAssertEqual(timeline.editedDuration, 20, accuracy: 1e-9)
        XCTAssertEqual(timeline.finalDuration, 17, accuracy: 1e-9)
        XCTAssertEqual(timeline.finalTime(forTimeline: 8)!, 8, accuracy: 1e-9)
        XCTAssertEqual(timeline.finalTime(forTimeline: 10)!, 9, accuracy: 1e-9)
        XCTAssertEqual(timeline.finalTime(forTimeline: 14)!, 11, accuracy: 1e-9)
        XCTAssertEqual(timeline.finalTime(forTimeline: 18)!, 15, accuracy: 1e-9)
        // And back.
        XCTAssertEqual(timeline.timelineTime(forFinal: 9), 10, accuracy: 1e-6)
        XCTAssertEqual(timeline.timelineTime(forFinal: 15), 18, accuracy: 1e-6)
        XCTAssertEqual(timeline.timelineTime(forFinal: 100), 20, accuracy: 1e-6)
    }

    func testSpeedAndCutTogether() {
        let seq = EditSequence(segments: [segment(10), segment(10)])
        // Cut 4...6, 2x over 8...14 (all on the timeline).
        let timeline = seq.timeline(cuts: [(4, 6)],
                                    speed: [EditSpeedSpan(start: 8, end: 14, factor: 2)])
        // Edited: 18 s; the speed range is edited 6...12 (6 s -> 3 s).
        XCTAssertEqual(timeline.speedRanges.first!.start, 6, accuracy: 1e-9)
        XCTAssertEqual(timeline.speedRanges.first!.end, 12, accuracy: 1e-9)
        XCTAssertEqual(timeline.finalDuration, 15, accuracy: 1e-9)
        XCTAssertNil(timeline.finalTime(forTimeline: 5))
        XCTAssertEqual(timeline.finalTimeClamped(forTimeline: 5), 4, accuracy: 1e-9)
        XCTAssertEqual(timeline.finalTime(forTimeline: 16)!, 16 - 2 - 3, accuracy: 1e-9)
    }

    func testOverlappingSpeedSpansDoNotDoubleCount() {
        let seq = EditSequence(segments: [segment(20)])
        let timeline = seq.timeline(cuts: [], speed: [
            EditSpeedSpan(start: 2, end: 10, factor: 2),
            EditSpeedSpan(start: 8, end: 14, factor: 4),
        ])
        XCTAssertEqual(timeline.speedRanges.count, 2)
        XCTAssertGreaterThanOrEqual(timeline.speedRanges[1].start, timeline.speedRanges[0].end)
    }

    func testFinalSpanForAnAnnotation() {
        let seq = EditSequence(segments: [segment(10), segment(10)])
        let timeline = seq.timeline(cuts: [(4, 6)])
        let span = timeline.finalSpan(timelineStart: 3, timelineEnd: 12)
        XCTAssertEqual(span!.start, 3, accuracy: 1e-9)
        XCTAssertEqual(span!.end, 10, accuracy: 1e-9)
        XCTAssertNil(timeline.finalSpan(timelineStart: 4.2, timelineEnd: 5.8))
    }

    func testNextKeptStartSkipsGaps() {
        let timeline = sequence.timeline(cuts: [(3, 5)])
        XCTAssertEqual(timeline.nextKeptStart(from: 0), 1)
        XCTAssertEqual(timeline.nextKeptStart(from: 4), 5)
        XCTAssertEqual(timeline.nextKeptStart(from: 9.5), 12)
        XCTAssertNil(timeline.nextKeptStart(from: 20))
        XCTAssertEqual(timeline.firstKeptStart, 1)
        XCTAssertEqual(timeline.lastKeptEnd, 20)
    }

    func testClamps() {
        let seq = sequence
        XCTAssertEqual(seq.clampTimeline(-3), 0)
        XCTAssertEqual(seq.clampTimeline(99), 20)
        let span = seq.clampTimeline(start: 19.9, end: 25, minLength: 0.5)
        XCTAssertEqual(span.start, 19.5, accuracy: 1e-9)
        XCTAssertEqual(span.end, 20, accuracy: 1e-9)
    }

    func testPicturePlacement() {
        // A 4:3 clip on a 16:9 canvas is centred with bars at the sides.
        let f = EditSequence.fit(source: CGSize(width: 400, height: 300),
                                 canvas: CGSize(width: 1600, height: 900))
        XCTAssertEqual(f.scale, 3, accuracy: 1e-9)
        XCTAssertEqual(f.tx, 200, accuracy: 1e-9)
        XCTAssertEqual(f.ty, 0, accuracy: 1e-9)
        // Its centre stays the canvas centre; with a crop of the right half
        // the centre moves to the left edge of the cropped picture.
        let centre = EditSequence.renderPoint(
            x: 0.5, y: 0.5, source: CGSize(width: 400, height: 300),
            canvas: CGSize(width: 1600, height: 900),
            cropOrigin: CGPoint(x: 800, y: 0), renderSize: CGSize(width: 800, height: 900))
        XCTAssertEqual(centre.x, 0, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 0.5, accuracy: 1e-9)
    }
}
