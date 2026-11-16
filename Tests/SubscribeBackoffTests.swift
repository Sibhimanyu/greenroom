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
        // The camera coming on is not a reason to subscribe again.
        w.expectingVideoSince = now
        XCTAssertFalse(ElementRecovery.mayAsk(watch: w, gaveUp: false, now: now.addingTimeInterval(60)))
    }

    func testRefusedElementIsRebuiltNotRetried() {
        var w = ElementWatch()
        let now = Date()
        w.refusedUntil = now.addingTimeInterval(2)
        XCTAssertFalse(ElementRecovery.mayAsk(watch: w, gaveUp: false, now: now.addingTimeInterval(10)))
        XCTAssertEqual(ElementRecovery.decide(drawing: false, watch: w, now: now.addingTimeInterval(1), rebuilds: 0), .wait)
        XCTAssertEqual(ElementRecovery.decide(drawing: false, watch: w, now: now.addingTimeInterval(2), rebuilds: 0), .rebuild)
    }

    func testRefusalOnADrawingElementIsIgnored() {
        var w = ElementWatch()
        let now = Date()
        w.refusedUntil = now
        XCTAssertEqual(ElementRecovery.decide(drawing: true, watch: w, now: now.addingTimeInterval(5), rebuilds: 0), .fine)
    }

    func testVideoReportedButNothingDrawnRebuildsAfterGrace() {
        var w = ElementWatch()
        let now = Date()
        w.subscribed = true
        w.expectingVideoSince = now
        XCTAssertEqual(ElementRecovery.decide(drawing: false, watch: w, now: now.addingTimeInterval(1), rebuilds: 0), .wait)
        XCTAssertEqual(ElementRecovery.decide(drawing: false, watch: w, now: now.addingTimeInterval(ElementRecovery.grace), rebuilds: 0), .rebuild)
        XCTAssertEqual(ElementRecovery.decide(drawing: true, watch: w, now: now.addingTimeInterval(10), rebuilds: 0), .fine)
    }

    func testCameraOffIsFine() {
        var w = ElementWatch()
        w.subscribed = true
        XCTAssertEqual(ElementRecovery.decide(drawing: false, watch: w, now: Date(), rebuilds: 0), .fine)
    }

    func testRebuildsAreCapped() {
        var w = ElementWatch()
        let now = Date()
        w.refusedUntil = now
        XCTAssertEqual(ElementRecovery.decide(drawing: false, watch: w, now: now, rebuilds: ElementRecovery.maxRebuilds), .giveUp)
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
