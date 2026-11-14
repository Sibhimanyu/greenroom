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
        XCTAssertEqual(panel.height, 38 + 44)
        let pill = NotchGeometry.pillFrame(panel: panel, notch: notch, phase: .live(recording: false))
        XCTAssertEqual(pill.maxY, screen.maxY)
        XCTAssertEqual(pill.midX, notch.midX)
        XCTAssertEqual(pill.width, 360)
        let fail = NotchGeometry.pillFrame(panel: panel, notch: notch, phase: .failed(NotchFailure(message: "x", detail: nil)))
        XCTAssertEqual(fail.width, 460)
        XCTAssertEqual(fail.midX, notch.midX)
    }

    func testFallbackDropsBelowTheMenuBarCentred() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let panel = NotchGeometry.panelFrame(screenFrame: screen, visibleFrame: visible, notch: nil)
        XCTAssertEqual(panel.midX, visible.midX)
        XCTAssertEqual(visible.maxY - panel.maxY, NotchGeometry.fallbackGap)
        XCTAssertEqual(panel.height, 44)
    }

    func testOtherMessagesStackBelowThePill() {
        let visible = CGRect(x: 0, y: 70, width: 1440, height: 805)
        let pill = CGRect(x: 540, y: 800, width: 360, height: 44)
        let cleared = BannerLayout.clearing(visible, pill: pill)
        XCTAssertEqual(cleared.maxY, 800)
        XCTAssertEqual(cleared.minY, 70)
        XCTAssertEqual(BannerLayout.clearing(visible, pill: nil), visible)
        XCTAssertEqual(BannerLayout.clearing(visible, pill: CGRect(x: 0, y: 900, width: 10, height: 10)), visible)
    }
}
