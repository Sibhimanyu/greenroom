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

    func testRefusedElementWaitsThenRetriesOnceThenIsRebuilt() {
        var w = ElementWatch()
        let now = Date()
        w.refusedUntil = now.addingTimeInterval(8)
        XCTAssertFalse(ElementRecovery.mayAsk(watch: w, gaveUp: false, now: now.addingTimeInterval(10)))
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(1), rebuilds: 0), .wait)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(8), rebuilds: 0), .retry)
        w.readyToRetry()
        XCTAssertTrue(ElementRecovery.mayAsk(watch: w, gaveUp: false, now: now.addingTimeInterval(8)))
        w.subscribed = false
        w.refusedUntil = now.addingTimeInterval(20)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(20), rebuilds: 0), .rebuild)
    }

    func testRenderingElementIsNeverRetired() {
        var w = ElementWatch()
        let now = Date()
        w.refusedUntil = now
        w.retried = true
        for rebuilds in 0...ElementRecovery.maxRebuilds {
            XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(60), rebuilds: rebuilds, rendering: true),
                           .recovered)
        }
        w.recoveredByVideo()
        XCTAssertNil(w.refusedUntil)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now, rebuilds: 0), .fine)
    }

    func testRefusalIsWaitedOutAtLeastTheGrace() {
        XCTAssertEqual(ElementRecovery.refusalWait(2), ElementRecovery.refusalGrace)
        XCTAssertEqual(ElementRecovery.refusalWait(32), 32)
    }

    // MARK: SubscribeThrottle

    func testThrottleAdmitsOneCallPerSpacing() {
        var t = SubscribeThrottle()
        let now = Date()
        XCTAssertTrue(t.claim(at: now))
        XCTAssertFalse(t.claim(at: now))
        XCTAssertFalse(t.claim(at: now.addingTimeInterval(SubscribeThrottle.spacing - 0.01)))
        XCTAssertTrue(t.claim(at: now.addingTimeInterval(SubscribeThrottle.spacing)))
        XCTAssertFalse(t.claim(at: now.addingTimeInterval(SubscribeThrottle.spacing)))
    }

    func testRebuildsAreCapped() {
        var w = ElementWatch()
        let now = Date()
        w.refusedUntil = now
        w.retried = true
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
