import XCTest

final class TimelineClipMapTests: XCTestCase {
    func testMainVideoRange() {
        let loc = TimelineClipMap.locate(2, mainDuration: 3, clipDurations: [52])
        XCTAssertEqual(loc, .init(clipIndex: nil, localTime: 2))
    }

    func testBoundaryBelongsToMain() {
        let loc = TimelineClipMap.locate(3, mainDuration: 3, clipDurations: [52])
        XCTAssertNil(loc.clipIndex)
    }

    func testInsideFirstClip() {
        let loc = TimelineClipMap.locate(10, mainDuration: 3, clipDurations: [52, 10])
        XCTAssertEqual(loc.clipIndex, 0)
        XCTAssertEqual(loc.localTime, 7, accuracy: 1e-9)
    }

    func testSecondClipAndEndClamp() {
        let second = TimelineClipMap.locate(60, mainDuration: 3, clipDurations: [52, 10])
        XCTAssertEqual(second.clipIndex, 1)
        XCTAssertEqual(second.localTime, 5, accuracy: 1e-9)
        let past = TimelineClipMap.locate(500, mainDuration: 3, clipDurations: [52, 10])
        XCTAssertEqual(past.clipIndex, 1)
        XCTAssertEqual(past.localTime, 10, accuracy: 1e-9)
        let before = TimelineClipMap.locate(-4, mainDuration: 3, clipDurations: [52])
        XCTAssertEqual(before, .init(clipIndex: nil, localTime: 0))
    }

    func testNoClips() {
        let loc = TimelineClipMap.locate(9, mainDuration: 3, clipDurations: [])
        XCTAssertEqual(loc, .init(clipIndex: nil, localTime: 3))
    }

    func testTimelineTimeClampsToTrim() {
        let t = TimelineClipMap.timelineTime(clipIndex: 1, local: 1, mainDuration: 3,
                                             clipDurations: [52, 10], trimStart: 2, trimEnd: 8)
        XCTAssertEqual(t, 3 + 52 + 2, accuracy: 1e-9)
        let u = TimelineClipMap.timelineTime(clipIndex: 0, local: 99, mainDuration: 3,
                                             clipDurations: [52], trimStart: 0, trimEnd: 40)
        XCTAssertEqual(u, 43, accuracy: 1e-9)
    }

    func testTileCountAndSamples() {
        XCTAssertEqual(TimelineClipMap.tileCount(width: 10, tileWidth: 135), 6)
        XCTAssertEqual(TimelineClipMap.tileCount(width: 1200, tileWidth: 135), 12)
        XCTAssertEqual(TimelineClipMap.tileCount(width: 1e9, tileWidth: 135), 120)
        XCTAssertEqual(TimelineClipMap.sampleTimes(duration: 10, count: 4), [1.25, 3.75, 6.25, 8.75])
        XCTAssertTrue(TimelineClipMap.sampleTimes(duration: 0, count: 4).isEmpty)
    }
}
