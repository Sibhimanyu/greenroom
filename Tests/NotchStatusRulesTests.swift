import XCTest

final class NotchStatusRulesTests: XCTestCase {
    private func steps(done: Int, active: Bool = true, total: Int = 5, recordingSkipped: Bool = false) -> [NotchStep] {
        let labels = ["Workspace", "Picture", "Meeting", "Recording", "Tiling windows"]
        return (0..<total).map { i in
            var state: NotchStepState = i < done ? .done : (i == done && active ? .active : .pending)
            if labels[i] == "Recording", recordingSkipped, i < done { state = .skipped }
            return NotchStep(label: labels[i], state: state)
        }
    }

    func testStepWords() {
        XCTAssertEqual(NotchStatusRules.words(forStep: "Picture"), "Opening your picture\u{2026}")
        XCTAssertEqual(NotchStatusRules.words(forStep: "Meeting"), "Joining the meeting\u{2026}")
        XCTAssertEqual(NotchStatusRules.words(forStep: "Recording"), "Starting the recording\u{2026}")
        XCTAssertEqual(NotchStatusRules.words(forStep: "Tiling windows"), "Tiling windows\u{2026}")
    }

    func testProgressCounterAndText() {
        guard case .working(let p) = NotchStatusRules.next(from: .hidden, input: NotchInput(steps: steps(done: 2))) else {
            return XCTFail("expected working")
        }
        XCTAssertEqual(p.counter, "3/5")
        XCTAssertEqual(p.text, "Joining the meeting\u{2026}")
        XCTAssertEqual(p.settled, 2)
        XCTAssertEqual(p.fraction, 0.4, accuracy: 0.0001)
    }

    func testFinishedStartBecomesLive() {
        let working = NotchStatusRules.next(from: .hidden, input: NotchInput(steps: steps(done: 5, active: false)))
        XCTAssertEqual(NotchStatusRules.next(from: working, input: NotchInput()), .live(recording: true))
    }

    func testLiveWithoutRecordingWhenSkipped() {
        let working = NotchStatusRules.next(from: .hidden,
            input: NotchInput(steps: steps(done: 5, active: false, recordingSkipped: true)))
        XCTAssertEqual(NotchStatusRules.next(from: working, input: NotchInput()), .live(recording: false))
        XCTAssertEqual(NotchStatusRules.liveText(recording: false), "Live")
        XCTAssertEqual(NotchStatusRules.liveText(recording: true), "Live \u{00B7} Recording")
    }

    func testAbandonedStartDoesNotClaimLive() {
        let working = NotchStatusRules.next(from: .hidden, input: NotchInput(steps: steps(done: 2)))
        XCTAssertEqual(NotchStatusRules.next(from: working, input: NotchInput()), .hidden)
    }

    func testLiveIsStableAndHiddenStaysHidden() {
        XCTAssertEqual(NotchStatusRules.next(from: .live(recording: true), input: NotchInput()), .live(recording: true))
        XCTAssertEqual(NotchStatusRules.next(from: .hidden, input: NotchInput()), .hidden)
    }

    func testFailureWinsAndClears() {
        let failed = NotchStatusRules.next(from: .hidden,
            input: NotchInput(steps: steps(done: 1), failure: "Camera access is off", detail: "x"))
        XCTAssertEqual(failed, .failed(NotchFailure(message: "Camera access is off", detail: "x")))
        XCTAssertEqual(NotchStatusRules.next(from: failed, input: NotchInput()), .hidden)
    }

    func testNotchRect() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = CGRect(x: 0, y: 944, width: 656, height: 38)
        let right = CGRect(x: 856, y: 944, width: 656, height: 38)
        let r = NotchGeometry.notchRect(screenFrame: screen, safeAreaTop: 38, leftArea: left, rightArea: right)
        XCTAssertEqual(r, CGRect(x: 656, y: 944, width: 200, height: 38))
        XCTAssertNil(NotchGeometry.notchRect(screenFrame: screen, safeAreaTop: 0, leftArea: nil, rightArea: nil))
        XCTAssertNil(NotchGeometry.notchRect(screenFrame: screen, safeAreaTop: 38, leftArea: nil, rightArea: right))
    }

    func testPanelIsFlushAndCentredOnTheNotch() {
        let screen = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        let notch = CGRect(x: 1512 + 656, y: 944, width: 200, height: 38)
        let panel = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: screen, notch: notch)
        XCTAssertEqual(panel.maxY, screen.maxY)
        XCTAssertEqual(panel.midX, notch.midX)
        XCTAssertEqual(panel.height, 38 + NotchGeometry.panelBodyHeight)
        let pill = NotchGeometry.pillFrame(panel: panel, notch: notch, content: .status(.live(recording: false)))
        XCTAssertEqual(pill.maxY, screen.maxY)
        XCTAssertEqual(pill.midX, notch.midX)
        XCTAssertEqual(pill.width, 360)
        let fail = NotchGeometry.pillFrame(panel: panel, notch: notch, content: .status(.failed(NotchFailure(message: "x", detail: nil))))
        XCTAssertEqual(fail.width, 460)
        XCTAssertEqual(fail.midX, notch.midX)
    }

    func testFallbackDropsBelowTheMenuBarCentred() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let panel = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: visible, notch: nil)
        XCTAssertEqual(panel.midX, visible.midX)
        XCTAssertEqual(visible.maxY - panel.maxY, NotchGeometry.fallbackGap)
        XCTAssertEqual(panel.height, NotchGeometry.panelBodyHeight)
    }

    // MARK: The island: sizes

    private func toast(_ title: String = "Saved", detail: String? = nil, kind: IslandToastKind = .success,
                       duration: TimeInterval? = 2.5, action: Bool = false) -> IslandToast {
        IslandToast(title: title, detail: detail, kind: kind, duration: duration, hasAction: action)
    }
    private func prompt(_ title: String = "Upload this recording to YouTube?") -> IslandPrompt {
        IslandPrompt(title: title, detail: "Class \u{00B7} 14 Nov \u{00B7} 982 KB \u{00B7} Unlisted")
    }

    func testEveryIslandStateIsFlushAndCentredAndFitsThePanel() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let notch = CGRect(x: 656, y: 944, width: 200, height: 38)
        let panel = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: screen, notch: notch)
        let all: [IslandContent] = [
            .status(.live(recording: true)), .status(.failed(NotchFailure(message: "x", detail: nil))),
            .countdown(.tick(3)), .countdown(.go), .prompt(prompt()),
            .toast(toast()), .toast(toast(detail: "More"))]
        for content in all {
            let pill = NotchGeometry.pillFrame(panel: panel, notch: notch, content: content)
            XCTAssertEqual(pill.maxY, screen.maxY, "\(content)")
            XCTAssertEqual(pill.midX, notch.midX, "\(content)")
            XCTAssertTrue(panel.contains(pill), "\(content)")
        }
        XCTAssertEqual(NotchGeometry.bodySize(for: .prompt(prompt())), CGSize(width: 540, height: 76))
        XCTAssertEqual(NotchGeometry.bodySize(for: .toast(toast())), CGSize(width: 360, height: 44))
        XCTAssertEqual(NotchGeometry.bodySize(for: .toast(toast(detail: "x"))).height, 58)
        XCTAssertEqual(NotchGeometry.bodySize(for: .countdown(.tick(2))), CGSize(width: 320, height: 56))
        XCTAssertEqual(NotchGeometry.bodySize(for: .countdown(.go)), CGSize(width: 220, height: 44))
    }

    // MARK: The island: durations and the countdown

    func testToastDurations() {
        XCTAssertEqual(IslandRules.toastDuration(kind: .success, hasAction: false), 2.5)
        XCTAssertEqual(IslandRules.toastDuration(kind: .failure, hasAction: false), 4)
        XCTAssertNil(IslandRules.toastDuration(kind: .failure, hasAction: true))
        XCTAssertEqual(IslandRules.toastDuration(kind: .success, hasAction: true), 2.5)
    }

    func testCountdownSequence() {
        XCTAssertEqual(IslandRules.countdownSequence(seconds: 3), [.tick(3), .tick(2), .tick(1), .go])
        XCTAssertEqual(IslandRules.countdownSequence(seconds: 10).count, 11)
        XCTAssertEqual(IslandRules.countdownSequence(seconds: 5).first, .tick(5))
        XCTAssertTrue(IslandRules.countdownSequence(seconds: 0).isEmpty)
        XCTAssertEqual(IslandRules.goHold, 1)
    }

    func testCountdownKeepsItsGoBeatAndIsClickable() {
        var q = IslandQueue()
        q.setCountdown(.tick(2))
        XCTAssertEqual(q.content, .countdown(.tick(2)))
        XCTAssertTrue(q.content.isInteractive)
        q.setCountdown(.go)
        XCTAssertEqual(q.content, .countdown(.go))
        XCTAssertFalse(q.content.isInteractive)
        q.setCountdown(nil)
        XCTAssertEqual(q.content, .none)
    }

    // MARK: The island: priority and the queue

    func testMessagesShowOneAtATimeInOrder() {
        var q = IslandQueue()
        let t = toast("One"), p = prompt(), t2 = toast("Two")
        q.enqueue(.toast(t)); q.promote()
        q.enqueue(.prompt(p)); q.enqueue(.toast(t2)); q.promote()
        XCTAssertEqual(q.content, .toast(t))
        XCTAssertEqual(q.pendingCount, 3)
        XCTAssertTrue(q.finish(t.id))
        XCTAssertEqual(q.content, .none, "the island retracts between messages")
        q.promote()
        XCTAssertEqual(q.content, .prompt(p))
        XCTAssertFalse(q.finish(t.id), "an old id changes nothing")
        q.finish(p.id); q.promote()
        XCTAssertEqual(q.content, .toast(t2))
        q.finish(t2.id); q.promote()
        XCTAssertEqual(q.content, .none)
        XCTAssertEqual(q.pendingCount, 0)
    }

    func testStatusAndCountdownComeBeforeMessages() {
        var q = IslandQueue()
        let t = toast()
        q.enqueue(.toast(t)); q.promote()
        let working = NotchPhase.working(NotchProgress(steps: steps(done: 1)))
        q.setStatus(working)
        XCTAssertEqual(q.content, .status(working))
        q.setCountdown(.tick(3))
        XCTAssertEqual(q.content, .countdown(.tick(3)), "the countdown beats getting ready")
        q.setCountdown(nil)
        q.setStatus(.hidden)
        XCTAssertEqual(q.content, .toast(t), "the message that waited comes back")
    }

    func testFailurePreemptsEverything() {
        var q = IslandQueue()
        q.enqueue(.prompt(prompt())); q.promote()
        q.setCountdown(.tick(2))
        let failed = NotchPhase.failed(NotchFailure(message: "No camera", detail: nil))
        q.setStatus(failed)
        XCTAssertEqual(q.content, .status(failed))
        XCTAssertTrue(q.content.isInteractive)
        q.setStatus(.hidden)
        XCTAssertEqual(q.content, .countdown(.tick(2)))
    }

    func testHeldWorkingToastIsReplacedByItsResult() {
        var q = IslandQueue()
        let working = toast("Saving\u{2026}", kind: .working, duration: nil)
        q.enqueue(.toast(working)); q.promote()
        let done = toast("Saved")
        q.enqueue(.toast(done))
        XCTAssertEqual(q.content, .toast(done))
        XCTAssertEqual(q.pendingCount, 1)
        // A timed toast is not replaced: the next one waits.
        let other = toast("Other")
        q.enqueue(.toast(other))
        XCTAssertEqual(q.content, .toast(done))
        XCTAssertEqual(q.pendingCount, 2)
    }

    func testRemovingToastsKeepsPrompts() {
        var q = IslandQueue()
        let p = prompt()
        q.enqueue(.toast(toast())); q.enqueue(.prompt(p)); q.enqueue(.toast(toast("B"))); q.promote()
        let gone = q.remove { if case .toast = $0 { return true } else { return false } }
        XCTAssertEqual(gone.count, 2)
        q.promote()
        XCTAssertEqual(q.content, .prompt(p))
    }

    func testOnlyAClickableMessageTakesClicks() {
        XCTAssertFalse(IslandContent.toast(toast()).isInteractive)
        XCTAssertTrue(IslandContent.toast(toast(kind: .failure, duration: nil, action: true)).isInteractive)
        XCTAssertTrue(IslandContent.prompt(prompt()).isInteractive)
        XCTAssertFalse(IslandContent.none.isInteractive)
    }

    func testAConfirmTakesTheFloorAndWhatWasShowingComesBack() {
        var q = IslandQueue()
        let t = toast("One"), p = prompt()
        q.enqueue(.toast(t)); q.promote()
        q.enqueue(.prompt(p))
        let end = IslandPrompt(title: "End the meeting for everyone?", detail: "", style: .confirm, dismissTitle: "Cancel")
        q.enqueueFirst(.prompt(end))
        XCTAssertEqual(q.content, .prompt(end), "End shows at once, ahead of the queue")
        q.finish(end.id); q.promote()
        XCTAssertEqual(q.content, .toast(t), "the toast it pushed aside shows again first")
        q.finish(t.id); q.promote()
        XCTAssertEqual(q.content, .prompt(p))
    }
}
