import XCTest

/// Spec: docs/specs/meeting-surface.md (R1 to R12).
final class MeetingSurfaceTests: XCTestCase {
    typealias M = MeetingSurface

    private func model(_ events: M.Event..., small: Bool = true, grow: Bool = true) -> M {
        var m = M(startSmallWhileAlone: small, growIfSomeoneJoined: grow)
        for e in events { m.apply(e) }
        return m
    }
    /// Live with the window up, no morph or settle pending.
    private func liveWindow() -> M { model(.startBegan, .wentLiveWithOthers, .morphFinished, .settleElapsed) }

    // R1
    func testFreshModelShowsNothing() {
        let m = M()
        XCTAssertNil(m.surface)
        XCTAssertTrue(m.visible.isEmpty)
        XCTAssertFalse(m.isMorphing)
        XCTAssertNil(m.reopenTarget)
    }
    func testEnvironmentEventsAreIgnoredWhileIdle() {
        for e in M.Event.allCases where e != .startBegan && e != .wentLiveAlone && e != .wentLiveWithOthers {
            var m = M(); m.apply(e)
            XCTAssertEqual(m, M(), "\(e)")
        }
    }
    // R11
    func testSessionEndFromAnywhereShowsNothing() {
        var m = liveWindow()
        m.apply(.collapse); m.apply(.closeRequested); m.apply(.covered)
        m.apply(.sessionEnded)
        XCTAssertEqual(m, M())
    }
    // R2
    func testStartingShowsTheBar() {
        XCTAssertEqual(model(.startBegan).surface, .bar)
    }
    // R3
    func testGoLiveAloneStartsSmall() {
        XCTAssertEqual(model(.startBegan, .wentLiveAlone).surface, .bar)
    }
    func testGoLiveWithOthersShowsWindow() {
        XCTAssertEqual(model(.startBegan, .wentLiveWithOthers).surface, .window)
    }
    func testGoLiveAloneWithStartSmallOffShowsWindow() {
        XCTAssertEqual(model(.startBegan, .wentLiveAlone, small: false).surface, .window)
    }
    func testSomeoneJoiningGrowsAnAutoSmallBarWithAMorph() {
        let m = model(.startBegan, .wentLiveAlone, .morphFinished, .someoneJoined)
        XCTAssertEqual(m.surface, .window)
        XCTAssertTrue(m.isMorphing)
        XCTAssertEqual(m.visible, [.bar, .window])
    }
    func testGrowOffKeepsTheBar() {
        XCTAssertEqual(model(.startBegan, .wentLiveAlone, .someoneJoined, grow: false).surface, .bar)
    }
    func testUserCollapseBeforeJoinStopsTheGrow() {
        XCTAssertEqual(model(.startBegan, .wentLiveAlone, .expand, .collapse, .someoneJoined).surface, .bar)
        XCTAssertEqual(model(.startBegan, .wentLiveAlone, .toggle, .toggle, .someoneJoined).surface, .bar)
    }
    // R5
    func testCollapseExpandToggle() {
        var m = liveWindow()
        m.apply(.collapse)
        XCTAssertEqual(m.surface, .bar); XCTAssertTrue(m.isMorphing)
        m.apply(.morphFinished)
        XCTAssertEqual(m.visible, [.bar]); XCTAssertFalse(m.isMorphing)
        m.apply(.toggle); XCTAssertEqual(m.surface, .window)
        m.apply(.morphFinished)
        m.apply(.toggle); XCTAssertEqual(m.surface, .bar)
        m.apply(.expand); XCTAssertEqual(m.surface, .window)
    }
    func testExpandClearsEverythingKeepingTheWindowDown() {
        var m = liveWindow()
        for e in [M.Event.covered, .movedToOtherDesktop, .minimised, .tileHidden, .collapse, .settleElapsed, .morphFinished] { m.apply(e) }
        XCTAssertEqual(m.surface, .bar)
        m.apply(.expand)
        XCTAssertEqual(m.surface, .window)
    }
    // R6
    func testCoveredGivesTheBarAfterTheSettle() {
        var m = liveWindow()
        m.apply(.covered)
        XCTAssertEqual(m.visible, [.window, .bar])
        m.apply(.settleElapsed)
        XCTAssertEqual(m.surface, .bar); XCTAssertEqual(m.visible, [.bar])
        m.apply(.uncovered)
        XCTAssertEqual(m.visible, [.window, .bar])
        m.apply(.settleElapsed)
        XCTAssertEqual(m.visible, [.window])
    }
    func testOtherDesktopAndBack() {
        var m = liveWindow()
        m.apply(.movedToOtherDesktop); m.apply(.settleElapsed)
        XCTAssertEqual(m.visible, [.bar])
        m.apply(.backOnDesktop); m.apply(.settleElapsed)
        XCTAssertEqual(m.visible, [.window])
    }
    func testCoveredAndOtherDesktopBothMustClearForTheWindow() {
        var m = liveWindow()
        m.apply(.covered); m.apply(.movedToOtherDesktop); m.apply(.uncovered); m.apply(.settleElapsed)
        XCTAssertEqual(m.surface, .bar)
    }
    // R7
    func testTileHideGivesTheBarAtOnce() {
        var m = liveWindow()
        m.apply(.tileHidden)
        XCTAssertEqual(m.surface, .bar); XCTAssertEqual(m.visible, [.bar])
        m.apply(.tileShown)
        XCTAssertEqual(m.visible, [.window])
    }
    func testTileShownWhileCoveredStaysBar() {
        var m = liveWindow()
        m.apply(.tileHidden); m.apply(.covered); m.apply(.settleElapsed); m.apply(.tileShown); m.apply(.settleElapsed)
        XCTAssertEqual(m.surface, .bar)
    }
    // R8
    func testMinimiseAndRestore() {
        var m = liveWindow()
        m.apply(.minimised)
        XCTAssertEqual(m.surface, .bar); XCTAssertTrue(m.isMorphing)
        m.apply(.morphFinished)
        m.apply(.restored)
        XCTAssertEqual(m.surface, .window)
    }
    // R9
    func testCloseQuestionLeavesTheSurface() {
        var m = liveWindow()
        m.apply(.closeRequested)
        XCTAssertTrue(m.closePromptUp); XCTAssertEqual(m.visible, [.window])
        m.apply(.closeCancel)
        XCTAssertFalse(m.closePromptUp); XCTAssertEqual(m.visible, [.window])
    }
    func testCloseAnswers() {
        var a = liveWindow(); a.apply(.closeRequested); a.apply(.closeEnd)
        XCTAssertEqual(a, M())
        var b = liveWindow(); b.apply(.closeRequested); b.apply(.closeLeave)
        XCTAssertEqual(b, M())
        var c = liveWindow(); c.apply(.closeRequested); c.apply(.closeShrink)
        XCTAssertEqual(c.surface, .bar); XCTAssertFalse(c.closePromptUp)
    }
    func testWindowClosedByCodeLeavesTheBarWithoutAMorph() {
        var m = liveWindow()
        m.apply(.windowClosedByCode)
        XCTAssertEqual(m.visible, [.bar]); XCTAssertFalse(m.isMorphing)
        m.apply(.expand); XCTAssertEqual(m.surface, .window)
    }
    // R10
    func testReopenGoesToTheWindowWhenOnlyCoveredOrElsewhere() {
        for e in [M.Event.covered, .movedToOtherDesktop, .minimised] {
            var m = liveWindow()
            m.apply(e); m.apply(.settleElapsed); m.apply(.morphFinished)
            XCTAssertEqual(m.surface, .bar, "\(e)")
            XCTAssertEqual(m.reopenTarget, .window, "\(e)")
        }
    }
    func testReopenGoesToTheBarWhenThePersonChoseIt() {
        let chosen: [[M.Event]] = [[.collapse], [.toggle], [.closeRequested, .closeShrink], [.windowClosedByCode], [.tileHidden]]
        for events in chosen {
            var m = liveWindow()
            for e in events { m.apply(e) }
            XCTAssertEqual(m.reopenTarget, .bar, "\(events)")
        }
        var alone = model(.startBegan, .wentLiveAlone, .morphFinished)
        XCTAssertEqual(alone.reopenTarget, .bar)
        alone.apply(.covered)
        XCTAssertEqual(alone.reopenTarget, .bar)
    }
    func testReopenBringsTheWindowForwardAndClearsWhatCoveredIt() {
        var m = liveWindow()
        m.apply(.covered); m.apply(.movedToOtherDesktop); m.apply(.settleElapsed)
        XCTAssertEqual(m.surface, .bar)
        m.apply(.reopen)
        XCTAssertEqual(m.surface, .window)
        XCTAssertTrue(m.windowIsUp)
        XCTAssertTrue(m.visible.contains(.window))
        var mini = liveWindow()
        mini.apply(.minimised); mini.apply(.morphFinished); mini.apply(.reopen)
        XCTAssertEqual(mini.surface, .window)
    }
    func testReopenOfTheBarChangesNothing() {
        var m = liveWindow()
        m.apply(.collapse); m.apply(.morphFinished)
        let before = m
        m.apply(.reopen)
        XCTAssertEqual(m, before)
        var idle = M(); idle.apply(.reopen)
        XCTAssertEqual(idle, M())
    }
    // R12
    func testScreenMatches() {
        var m = liveWindow()
        XCTAssertTrue(m.screenMatches([.window]))
        XCTAssertFalse(m.screenMatches([.bar]))
        XCTAssertFalse(m.screenMatches([.window, .bar]))
        XCTAssertFalse(m.screenMatches([]))
        m.apply(.covered)
        XCTAssertTrue(m.screenMatches([.window, .bar]))
        XCTAssertTrue(m.screenMatches([.window]))
        XCTAssertFalse(M().screenMatches([.bar]))
        XCTAssertTrue(M().screenMatches([]))
    }

    // R4: every reachable state, every event, every order.
    func testNeverZeroAndExactlyOneOutsideSettleOrMorph() {
        var seen: Set<M> = [M()]
        var queue = [M()]
        var edges = 0
        while let s = queue.popLast() {
            for e in M.Event.allCases {
                var n = s; n.apply(e); edges += 1
                if let live = n.surface {
                    XCTAssertFalse(n.visible.isEmpty, "zero after \(e) from \(s)")
                    XCTAssertTrue(n.visible.contains(live), "target not visible after \(e)")
                    if !n.isMorphing && !n.isSettling { XCTAssertEqual(n.visible, [live], "not one after \(e) from \(s)") }
                    XCTAssertNotNil(n.reopenTarget)
                    if n.reopenTarget == .window { XCTAssertTrue(n.visible.contains(.window) || n.surface == .bar) }
                    XCTAssertTrue(n.screenMatches(n.visible))
                } else {
                    XCTAssertTrue(n.visible.isEmpty); XCTAssertNil(n.reopenTarget); XCTAssertFalse(n.isMorphing)
                    XCTAssertFalse(n.closePromptUp)
                }
                if seen.insert(n).inserted { queue.append(n) }
            }
        }
        XCTAssertGreaterThan(seen.count, 30)
        XCTAssertGreaterThan(edges, 500)
    }
    /// Settled states (no morph, no settle) with the window held down by any reason show the Bar; otherwise the Window.
    func testSettledAnswerFollowsTheReasons() {
        var seen: Set<M> = [M()]
        var queue = [M()]
        while let s = queue.popLast() {
            for e in M.Event.allCases {
                var n = s; n.apply(e)
                if seen.insert(n).inserted { queue.append(n) }
            }
        }
        for s in seen where s.isLive {
            var settled = s; settled.apply(.morphFinished); settled.apply(.settleElapsed)
            XCTAssertEqual(settled.visible.count, 1)
            XCTAssertEqual(settled.surface, settled.windowIsUp ? .window : .bar)
        }
    }
}
