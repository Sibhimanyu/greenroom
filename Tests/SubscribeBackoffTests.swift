import XCTest

final class SubscribeBackoffTests: XCTestCase {
    func testBackoffDoublesThenHolds() {
        var b = SubscribeBackoff()
        let t = Date()
        let delays = (0..<7).map { b.failed(at: t.addingTimeInterval(Double($0))).delay }
        XCTAssertEqual(delays, [2, 4, 8, 16, 32, 32, 32])
    }

    func testQuietMinuteStartsOver() {
        var b = SubscribeBackoff()
        let t = Date()
        _ = b.failed(at: t)
        _ = b.failed(at: t.addingTimeInterval(1))
        XCTAssertEqual(b.failed(at: t.addingTimeInterval(120)).delay, 2)
    }

    func testResetClearsAttempts() {
        var b = SubscribeBackoff()
        _ = b.failed(at: Date())
        b.reset()
        XCTAssertEqual(b.attempts, 0)
    }

    // MARK: ElementRecovery: subscribe once, recover with a fresh element

    func testSubscribedElementIsNeverAskedAgain() {
        var w = ElementWatch()
        let now = Date()
        XCTAssertTrue(ElementRecovery.mayAsk(watch: w, gaveUp: false, now: now))
        w.subscribed = true
        w.subscribedAt = now
        XCTAssertFalse(ElementRecovery.mayAsk(watch: w, gaveUp: false, now: now.addingTimeInterval(60)))
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(60), rebuilds: 0), .fine)
    }

    func testRefusedElementIsRebuiltNotRetried() {
        var w = ElementWatch()
        let now = Date()
        w.refusedUntil = now.addingTimeInterval(2)
        XCTAssertFalse(ElementRecovery.mayAsk(watch: w, gaveUp: false, now: now.addingTimeInterval(10)))
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(1), rebuilds: 0), .wait)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(2), rebuilds: 0), .rebuild)
    }

    func testRebuildsAreCapped() {
        var w = ElementWatch()
        let now = Date()
        w.refusedUntil = now
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now, rebuilds: ElementRecovery.maxRebuilds), .giveUp)
        XCTAssertFalse(ElementRecovery.mayAsk(watch: ElementWatch(), gaveUp: true, now: now))
    }

    func testFreshElementWaitsBeforeAsking() {
        let now = Date()
        let w = ElementWatch(notBefore: now.addingTimeInterval(ElementRecovery.freshDelay))
        XCTAssertFalse(ElementRecovery.mayAsk(watch: w, gaveUp: false, now: now))
        XCTAssertTrue(ElementRecovery.mayAsk(watch: w, gaveUp: false, now: now.addingTimeInterval(2)))
    }

    func testSimultaneousRefusalsAreOne() {
        var w = ElementWatch()
        let now = Date()
        XCTAssertFalse(w.isRepeatRefusal(at: now))
        w.lastRefusalAt = now
        XCTAssertTrue(w.isRepeatRefusal(at: now.addingTimeInterval(0.2)))
        XCTAssertFalse(w.isRepeatRefusal(at: now.addingTimeInterval(3)))
    }
}
