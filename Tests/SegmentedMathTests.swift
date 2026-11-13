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
}
