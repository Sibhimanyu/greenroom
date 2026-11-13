import XCTest
import CoreGraphics

final class SegmentedMathTests: XCTestCase {
    func testSegmentWidthIsWidestLabelPlusPadding() {
        XCTAssertEqual(SegmentedMath.segmentWidth(labelWidths: [30, 52, 40], padding: 10), 72)
        XCTAssertEqual(SegmentedMath.segmentWidth(labelWidths: [], padding: 10), 20)
    }

    func testStepClampsAtTheEnds() {
        XCTAssertEqual(SegmentedMath.step(from: 0, by: -1, count: 3), 0)
        XCTAssertEqual(SegmentedMath.step(from: 2, by: 1, count: 3), 2)
        XCTAssertEqual(SegmentedMath.step(from: 1, by: 1, count: 3), 2)
        XCTAssertEqual(SegmentedMath.step(from: 1, by: -1, count: 3), 0)
        XCTAssertEqual(SegmentedMath.step(from: 0, by: 1, count: 0), 0)
    }

    func testToolbarInsetIsUniform() {
        let h = SegmentedMath.capsuleHeight(pillHeight: SegmentedMath.toolbarPillHeight)
        XCTAssertEqual(h, 34)
        let pill = SegmentedMath.pillSize(capsule: CGSize(width: 300, height: h))
        XCTAssertEqual(pill.height, SegmentedMath.toolbarPillHeight)
        XCTAssertEqual(pill.width, 294)
        XCTAssertEqual(300 - pill.width, h - pill.height)
    }

    func testPillRadiusIsConcentric() {
        XCTAssertEqual(SegmentedMath.pillRadius(capsuleRadius: 17), 14)
        XCTAssertEqual(SegmentedMath.pillRadius(capsuleRadius: 2), 0)
    }
}
