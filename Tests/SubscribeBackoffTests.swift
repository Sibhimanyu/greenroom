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

    /// An avatar means the camera is off: a fresh element would draw the same
    /// avatar, so a refusal there is forgotten, never retried or rebuilt.
    func testAvatarElementIsNeverRetired() {
        var w = ElementWatch()
        let now = Date()
        w.refusedUntil = now
        w.retried = true
        for rebuilds in 0...ElementRecovery.maxRebuilds {
            XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(60), rebuilds: rebuilds, showing: .avatar),
                           .recovered)
        }
        w.recoveredByVideo()
        XCTAssertNil(w.refusedUntil)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now, rebuilds: 0), .fine)
    }

    /// 2026-11-26 02:14-02:15Z: four Active speaker elements in a row reported
    /// data type Video, setResolution(720p) on them was refused with code 7, and
    /// "video is showing despite the refusal" kept each one. The owner saw a
    /// dark tile with only the name every time. The data type follows the
    /// person's camera, not the frames reaching the element, so it is no proof
    /// of drawing: a refused element that reports Video waits out the grace,
    /// then gets its one retry, then a fresh element.
    func testVideoDataTypeIsNotRecoveryFromARefusal() {
        var w = ElementWatch()
        let now = Date()
        w.noteSubscribedByUserID(showing: .video)
        w.refusedUntil = now.addingTimeInterval(8)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(1), rebuilds: 0, showing: .video), .wait)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(8), rebuilds: 0, showing: .video), .retry)
        w.readyToRetry()
        w.refusedUntil = now.addingTimeInterval(20)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(20), rebuilds: 0, showing: .video), .rebuild)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: now.addingTimeInterval(20),
                                              rebuilds: ElementRecovery.maxRebuilds, showing: .video), .giveUp)
    }

    /// On an element subscribed by `userid` the only request the pass made is
    /// setResolution, and that is what Zoom refused (every code 7 in the log
    /// follows a setResolution that returned 0; none follows one that returned
    /// 1). The retry asks for the resolution again, after the slow-down.
    func testRetryOnAUseridSubscribeAsksForTheResolutionAgain() {
        var w = ElementWatch()
        w.resolutionSet = true
        w.resolutionTries = 1
        w.noteSubscribedByUserID(showing: .video)
        w.refusedUntil = Date()
        w.readyToRetry()
        XCTAssertFalse(w.resolutionSet)
        XCTAssertEqual(w.resolutionTries, 0)
        XCTAssertTrue(ElementRecovery.mayAsk(watch: w, gaveUp: false, now: Date()))
    }

    /// An explicit subscribe (asked at None) retries the subscribe only; the
    /// resolution already in force stays.
    func testRetryOnAnExplicitSubscribeKeepsTheResolution() {
        var w = ElementWatch()
        w.resolutionSet = true
        w.refusedUntil = Date()
        w.readyToRetry()
        XCTAssertTrue(w.resolutionSet)
    }

    /// Only an element with no picture at all (None) or video goes on to retry
    /// and rebuild; an avatar is forgotten even once the grace has passed.
    func testAvatarRecoversButNoneAndVideoRetryThenRebuild() {
        var w = ElementWatch()
        let now = Date()
        w.refusedUntil = now
        let later = now.addingTimeInterval(60)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: later, rebuilds: 0, showing: .avatar), .recovered)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: later, rebuilds: 0, showing: .none), .retry)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: later, rebuilds: 0, showing: .video), .retry)
        w.retried = true
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: later, rebuilds: 0, showing: .none), .rebuild)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: later, rebuilds: 0, showing: .video), .rebuild)
        XCTAssertEqual(ElementRecovery.decide(watch: w, now: later, rebuilds: 0, showing: .avatar), .recovered)
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

    // MARK: VideoArrival: an element subscribed while it showed an avatar

    /// 2026-11-25 20:18:00Z: the stage was made for "Sibhi -8A" 3 s after the
    /// admit, subscribed by userid while the SDK still drew an avatar
    /// (dataType 2), then turned to video (dataType 1) a second later and
    /// stayed a blank tile for minutes. A fresh element made while the video
    /// was flowing (20:21:12Z) drew at once.
    func testVideoArrivingOnAnElementSubscribedAtAvatarGetsAFreshElement() {
        var w = ElementWatch()
        w.noteSubscribedByUserID(showing: .avatar)
        XCTAssertEqual(w.noteDataType(.video), .freshElement)
        XCTAssertTrue(w.freshPending)
    }

    func testElementSubscribedWhileVideoFlowsIsKept() {
        var w = ElementWatch()
        w.noteSubscribedByUserID(showing: .video)
        XCTAssertEqual(w.noteDataType(.video), .keep)
        XCTAssertFalse(w.freshPending)
    }

    /// A camera turned off and on again on an element that has drawn video
    /// keeps the element: it drew before, it draws again.
    func testCameraToggleAfterVideoKeepsTheElement() {
        var w = ElementWatch()
        w.noteSubscribedByUserID(showing: .video)
        XCTAssertEqual(w.noteDataType(.avatar), .keep)
        XCTAssertEqual(w.noteDataType(.video), .keep)
        XCTAssertFalse(w.freshPending)
    }

    /// Only the first video on an avatar-subscribed element asks for a fresh
    /// one; a second report on the same element changes nothing.
    func testOnlyOneFreshElementPerArrival() {
        var w = ElementWatch()
        w.noteSubscribedByUserID(showing: .avatar)
        XCTAssertEqual(w.noteDataType(.video), .freshElement)
        XCTAssertEqual(w.noteDataType(.avatar), .keep)
        XCTAssertEqual(w.noteDataType(.video), .keep)
    }

    /// Before its subscribe the element is not judged: the subscribe on
    /// screen records what it shows then.
    func testDataTypeBeforeTheSubscribeIsNotJudged() {
        var w = ElementWatch()
        XCTAssertEqual(w.noteDataType(.avatar), .keep)
        XCTAssertEqual(w.noteDataType(.video), .keep)
        w.noteSubscribedByUserID(showing: .video)
        XCTAssertEqual(w.noteDataType(.video), .keep)
    }

    /// An explicit subscribe (data type None when asked) is the path that
    /// carries its resolution in; it is not refreshed.
    func testExplicitSubscribeIsNotRefreshed() {
        var w = ElementWatch()
        w.subscribed = true
        XCTAssertEqual(w.noteDataType(.video), .keep)
    }

    // MARK: ElementWatch.merged: a callback during the pass is not lost

    func testACallbackThatSetFreshPendingDuringThePassIsKept() {
        var before = ElementWatch()
        before.subscribedByUserID = true   // subscribed by userid while it drew an avatar
        var pass = before
        pass.resolutionSet = true
        var stored = before
        XCTAssertEqual(stored.noteDataType(.video), .freshElement, "onRenderDataTypeChanged inside the SDK call")
        let m = ElementWatch.merged(pass: pass, stored: stored)
        XCTAssertTrue(m.freshPending, "the fresh element the callback asked for")
        XCTAssertTrue(m.sawVideo)
        XCTAssertTrue(m.resolutionSet, "and the pass's own work")
    }

    func testARefusalDuringThePassIsKept() {
        let now = Date()
        var pass = ElementWatch()
        pass.subscribed = true
        var stored = ElementWatch()
        stored.subscribed = false
        stored.refusedUntil = now.addingTimeInterval(10)
        stored.lastRefusalAt = now
        let m = ElementWatch.merged(pass: pass, stored: stored)
        XCTAssertFalse(m.subscribed)
        XCTAssertEqual(m.refusedUntil, now.addingTimeInterval(10))
        XCTAssertEqual(m.lastRefusalAt, now)
    }

    func testWithNoCallbackThePassWins() {
        let now = Date()
        var before = ElementWatch()
        before.refusedUntil = now
        before.lastRefusalAt = now.addingTimeInterval(-5)
        var pass = before
        pass.readyToRetry()
        pass.resolutionSet = true
        pass.lastSublayers = 3
        let m = ElementWatch.merged(pass: pass, stored: before)
        XCTAssertNil(m.refusedUntil, "an older refusal does not come back")
        XCTAssertTrue(m.retried)
        XCTAssertTrue(m.resolutionSet)
        XCTAssertEqual(m.lastSublayers, 3)
        XCTAssertFalse(m.freshPending)
    }
}
