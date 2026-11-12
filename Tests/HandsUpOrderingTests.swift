import XCTest

/// The Hands up list: first hand up first, a lowered hand loses its place.
final class HandsUpOrderingTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func person(_ id: UInt32, _ name: String, muted: Bool = false) -> (id: UInt32, name: String, muted: Bool) {
        (id, name, muted)
    }

    func testOrderIsTheOrderTheHandsWentUp() {
        var stamps = HandStamps()
        stamps.update(raised: [3], now: at(0))
        stamps.update(raised: [3, 1], now: at(5))
        stamps.update(raised: [3, 1, 2], now: at(9))
        let rows = stamps.ordered([person(1, "Asha"), person(2, "Ben"), person(3, "Chen")])
        XCTAssertEqual(rows.map(\.id), [3, 1, 2])
    }

    func testOnlyRaisedHandsAreListed() {
        var stamps = HandStamps()
        stamps.update(raised: [2], now: at(0))
        XCTAssertEqual(stamps.ordered([person(1, "Asha"), person(2, "Ben")]).map(\.id), [2])
    }

    func testALoweredHandGoesToTheBackWhenItGoesUpAgain() {
        var stamps = HandStamps()
        stamps.update(raised: [1, 2], now: at(0))
        stamps.update(raised: [2], now: at(3))          // 1 lowers
        stamps.update(raised: [1, 2], now: at(6))       // 1 raises again
        XCTAssertEqual(stamps.ordered([person(1, "Asha"), person(2, "Ben")]).map(\.id), [2, 1])
    }

    func testSomeoneWhoLeavesIsForgotten() {
        var stamps = HandStamps()
        stamps.update(raised: [1, 2], now: at(0))
        stamps.update(raised: [2], now: at(1))
        XCTAssertNil(stamps.raisedAt[1])
    }

    func testAPollThatSeesTwoHandsAtOnceOrdersByNameThenID() {
        var stamps = HandStamps()
        stamps.update(raised: [7, 5, 6], now: at(0))
        let rows = stamps.ordered([person(7, "Zed"), person(5, "Amy"), person(6, "Amy")])
        XCTAssertEqual(rows.map(\.id), [5, 6, 7], "Amy and Amy by id, then Zed; the same every refresh")
        XCTAssertEqual(rows.map(\.id), stamps.ordered([person(6, "Amy"), person(7, "Zed"), person(5, "Amy")]).map(\.id))
    }

    func testMutedIsCarriedForAskToUnmute() {
        var stamps = HandStamps()
        stamps.update(raised: [1], now: at(0))
        XCTAssertEqual(stamps.ordered([person(1, "Asha", muted: true)]).first?.muted, true)
    }

    func testARepeatedStampKeepsTheFirstTime() {
        var stamps = HandStamps()
        stamps.update(raised: [1], now: at(0))
        stamps.update(raised: [1], now: at(30))
        XCTAssertEqual(stamps.raisedAt[1], at(0))
    }
}
