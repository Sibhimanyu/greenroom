import XCTest

final class MainPersonSelectorTests: XCTestCase {

    private let w = 40, h = 30

    private func blank() -> [UInt8] { [UInt8](repeating: 0, count: 40 * 30) }

    private func fill(_ m: inout [UInt8], x: ClosedRange<Int>, y: ClosedRange<Int>, value: UInt8 = 255) {
        for yy in y { for xx in x { m[yy * 40 + xx] = value } }
    }

    private func on(_ m: [UInt8], _ x: Int, _ y: Int) -> Bool { m[y * 40 + x] > 0 }

    func testTwoBlobsKeepsTheBigCentralOne() {
        var m = blank()
        fill(&m, x: 14...25, y: 6...25)   // central
        fill(&m, x: 1...5, y: 2...6)      // smaller, far corner
        MainPersonSelector().select(&m, width: w, height: h)
        XCTAssertTrue(on(m, 20, 15))
        XCTAssertFalse(on(m, 3, 4))
    }

    func testEdgeFragmentIsDropped() {
        var m = blank()
        fill(&m, x: 12...27, y: 4...27)
        fill(&m, x: 38...39, y: 10...24)  // sliver on the right edge
        MainPersonSelector().select(&m, width: w, height: h)
        XCTAssertTrue(on(m, 20, 15))
        XCTAssertFalse(on(m, 39, 15))
    }

    func testDetachedHandNearTheBodyIsKept() {
        var m = blank()
        fill(&m, x: 12...24, y: 6...28)
        fill(&m, x: 27...29, y: 8...11)   // raised hand, a gap away
        MainPersonSelector().select(&m, width: w, height: h)
        XCTAssertTrue(on(m, 20, 15))
        XCTAssertTrue(on(m, 28, 9))
    }

    func testHysteresisHoldsThePreviousBlobWhenSizesAreClose() {
        let s = MainPersonSelector()
        var first = blank()
        fill(&first, x: 2...11, y: 8...21)     // left, 140
        s.select(&first, width: w, height: h)
        XCTAssertTrue(on(first, 5, 10))
        // Now the right blob is a touch bigger and more central.
        var second = blank()
        fill(&second, x: 2...11, y: 8...21)    // 140
        fill(&second, x: 26...36, y: 8...21)   // 154
        s.select(&second, width: w, height: h)
        XCTAssertTrue(on(second, 5, 10))
        XCTAssertFalse(on(second, 30, 10))
    }

    func testMuchLargerBlobWinsDespiteHysteresis() {
        let s = MainPersonSelector()
        var first = blank()
        fill(&first, x: 2...7, y: 8...13)
        s.select(&first, width: w, height: h)
        var second = blank()
        fill(&second, x: 2...7, y: 8...13)
        fill(&second, x: 18...37, y: 2...27)
        s.select(&second, width: w, height: h)
        XCTAssertTrue(on(second, 25, 15))
        XCTAssertFalse(on(second, 4, 10))
    }

    func testEmptyMaskStaysEmpty() {
        var m = blank()
        MainPersonSelector().select(&m, width: w, height: h)
        XCTAssertEqual(m, blank())
    }

    func testSpecksAloneAreLeftAsTheyAre() {
        var m = blank()
        m[5 * 40 + 5] = 255
        let before = m
        MainPersonSelector().select(&m, width: w, height: h)
        XCTAssertEqual(m, before)
    }

    func testSoftEdgeOfTheMainBlobSurvives() {
        var m = blank()
        fill(&m, x: 14...25, y: 6...25)
        fill(&m, x: 13...13, y: 6...25, value: 20)   // feathered halo
        fill(&m, x: 1...5, y: 2...6)
        MainPersonSelector().select(&m, width: w, height: h)
        XCTAssertEqual(m[10 * 40 + 13], 20)
        XCTAssertFalse(on(m, 3, 4))
    }
}
