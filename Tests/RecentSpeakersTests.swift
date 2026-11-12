import XCTest

/// Multi-speaker: 1.5 s to join, 8 s minimum stay, one change per 2 s, slots keep their place.
final class RecentSpeakersTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// Someone talks from `from` for `length` seconds, polled each second.
    private func talk(_ r: inout RecentSpeakers, _ id: UInt32, from: TimeInterval, length: TimeInterval, present: Set<UInt32>) {
        var t = from
        while t <= from + length {
            r.heard([id], selfID: 1, now: at(t))
            r.update(present: present, now: at(t))
            t += 1
        }
    }

    func testAVoiceMustBeHeardForOneAndAHalfSeconds() {
        var r = RecentSpeakers()
        let present: Set<UInt32> = [2, 3]
        r.heard([2], selfID: 1, now: at(0))
        XCTAssertEqual(r.update(present: present, now: at(1.0)), [], "one second is not enough")
        r.heard([2], selfID: 1, now: at(1.0))
        XCTAssertEqual(r.update(present: present, now: at(1.6)), [2])
    }

    func testACoughDoesNotJoin() {
        var r = RecentSpeakers()
        r.heard([2], selfID: 1, now: at(0))
        r.heard([], selfID: 1, now: at(0.8))        // silence resets the clock
        r.heard([2], selfID: 1, now: at(1.2))
        XCTAssertEqual(r.update(present: [2], now: at(2.0)), [], "the 1.5 s starts again after silence")
    }

    func testSelfIsNeverShown() {
        var r = RecentSpeakers()
        talk(&r, 1, from: 0, length: 5, present: [1, 2])
        XCTAssertEqual(r.occupied.count, 0)
    }

    func testSlotsFillInOrderAndKeepTheirPlace() {
        var r = RecentSpeakers()
        let present: Set<UInt32> = [2, 3, 4]
        talk(&r, 2, from: 0, length: 3, present: present)
        talk(&r, 3, from: 4, length: 3, present: present)
        talk(&r, 4, from: 8, length: 3, present: present)
        XCTAssertEqual(r.occupied.map(\.slot), [0, 1, 2])
        XCTAssertEqual(r.occupied.map(\.userID), [2, 3, 4])
        // The first speaker talks again: their tile does not move.
        talk(&r, 2, from: 12, length: 3, present: present)
        XCTAssertEqual(r.occupied.map(\.userID), [2, 3, 4])
    }

    func testANewcomerReplacesTheLeastRecentSpeakerInThatSlot() {
        var r = RecentSpeakers()
        let present: Set<UInt32> = [2, 3, 4, 5]
        talk(&r, 2, from: 0, length: 3, present: present)
        talk(&r, 3, from: 4, length: 3, present: present)
        talk(&r, 4, from: 8, length: 3, present: present)
        talk(&r, 3, from: 12, length: 1, present: present)       // 3 talked recently; 2 least
        talk(&r, 5, from: 14, length: 3, present: present)
        XCTAssertEqual(r.occupied.first { $0.userID == 5 }?.slot, 0, "5 took the place of 2, the least recent")
        XCTAssertEqual(r.occupied.map(\.userID).sorted(), [3, 4, 5])
    }

    func testEveryoneStaysAtLeastEightSeconds() {
        var r = RecentSpeakers(limit: 1)
        let present: Set<UInt32> = [2, 3]
        talk(&r, 2, from: 0, length: 2, present: present)
        XCTAssertEqual(r.occupied.map(\.userID), [2])
        talk(&r, 3, from: 3, length: 3, present: present)       // heard for 3 s, but 2 has been there ~3 s
        XCTAssertEqual(r.occupied.map(\.userID), [2], "not replaced before the minimum stay")
        talk(&r, 3, from: 7, length: 4, present: present)
        XCTAssertEqual(r.occupied.map(\.userID), [3], "replaced once 8 s are up")
    }

    func testAtMostOneChangeEveryTwoSeconds() {
        var r = RecentSpeakers()
        let present: Set<UInt32> = [2, 3, 4]
        for id in [UInt32(2), 3, 4] { r.heard([id], selfID: 1, now: at(0)) }
        r.heard([2, 3, 4], selfID: 1, now: at(2))
        XCTAssertEqual(r.update(present: present, now: at(2)).count, 1, "three voices at once still join one at a time")
        r.heard([2, 3, 4], selfID: 1, now: at(3))
        XCTAssertEqual(r.update(present: present, now: at(3)).count, 1, "one second later: still one")
        r.heard([2, 3, 4], selfID: 1, now: at(4.1))
        XCTAssertEqual(r.update(present: present, now: at(4.1)).count, 2)
    }

    func testSomeoneWhoLeavesFreesTheirSlot() {
        var r = RecentSpeakers()
        talk(&r, 2, from: 0, length: 3, present: [2, 3])
        XCTAssertEqual(r.occupied.map(\.userID), [2])
        r.update(present: [3], now: at(4))
        XCTAssertEqual(r.occupied.count, 0)
    }

    func testAOneToOneShowsOneTile() {
        var r = RecentSpeakers()
        talk(&r, 2, from: 0, length: 4, present: [1, 2])
        XCTAssertEqual(r.occupied.count, 1)
    }

    func testResetEmptiesEverything() {
        var r = RecentSpeakers()
        talk(&r, 2, from: 0, length: 3, present: [2])
        r.reset()
        XCTAssertEqual(r.occupied.count, 0)
        XCTAssertEqual(r.limit, 3)
    }
}
