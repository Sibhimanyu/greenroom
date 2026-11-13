//
//  SlideShowFollowTests.swift
//  Phase 6 of the Recorditor port: the full-screen detection and the follow rule.
//

import XCTest

final class SlideShowFollowTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    private var displays: [CGRect] { [display, second] }

    private func win(_ id: CGWindowID, pid: pid_t = 10, layer: Int = 0, _ frame: CGRect) -> SlideShowFollow.Window {
        .init(id: id, pid: pid, layer: layer, frame: frame)
    }
    private let normal = CGRect(x: 100, y: 80, width: 900, height: 600)

    func testFullScreenMatchesADisplayFrame() {
        XCTAssertTrue(SlideShowFollow.isFullScreen(frame: display, displayFrames: displays))
        XCTAssertTrue(SlideShowFollow.isFullScreen(frame: second, displayFrames: displays))
        XCTAssertTrue(SlideShowFollow.isFullScreen(frame: display.insetBy(dx: 1, dy: 1), displayFrames: displays))
    }

    func testMaximisedBelowTheMenuBarIsNotFullScreen() {
        let maximised = CGRect(x: 0, y: 30, width: 1512, height: 952)
        XCTAssertFalse(SlideShowFollow.isFullScreen(frame: maximised, displayFrames: displays))
        XCTAssertFalse(SlideShowFollow.isFullScreen(frame: normal, displayFrames: displays))
    }

    func testShowOfTheSameAppIsFollowed() {
        let list = [win(2, display), win(1, normal)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10, onScreen: list,
                                              existing: [], displayFrames: displays), .follow(2))
    }

    func testAnotherAppsFullScreenWindowIsNeverFollowed() {
        let list = [win(2, pid: 99, display), win(1, normal)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10, onScreen: list,
                                              existing: [], displayFrames: displays), .stay)
    }

    func testOtherLayersAreIgnored() {
        let list = [win(2, layer: 25, display), win(1, normal)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10, onScreen: list,
                                              existing: [], displayFrames: displays), .stay)
    }

    func testAFullScreenWindowBehindTheSharedOneIsNotAShow() {
        let list = [win(1, normal), win(2, display)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10, onScreen: list,
                                              existing: [], displayFrames: displays), .stay)
    }

    func testOriginalOnAnotherSpaceStillFindsTheShowHere() {
        let list = [win(2, display)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10, onScreen: list,
                                              existing: [], displayFrames: displays), .follow(2))
    }

    func testTheSharedWindowGoingFullScreenItselfIsNotASwitch() {
        let list = [win(1, display)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10, onScreen: list,
                                              existing: [], displayFrames: displays), .stay)
    }

    func testShowEndsWhenItsWindowIsGone() {
        let list = [win(1, normal)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 2, pid: 10, onScreen: list,
                                              existing: [1], displayFrames: displays), .backToOriginal)
    }

    func testShowMovedOffScreenWhileOriginalIsBackReturns() {
        let list = [win(1, normal)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 2, pid: 10, onScreen: list,
                                              existing: [1, 2], displayFrames: displays), .backToOriginal)
    }

    func testShowOnAnotherSpaceWhileOriginalIsAlsoAwayIsKept() {
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 2, pid: 10, onScreen: [],
                                              existing: [1, 2], displayFrames: displays), .stay)
    }

    func testShowStaysWhileItIsOnScreen() {
        let list = [win(2, display), win(1, normal)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 2, pid: 10, onScreen: list,
                                              existing: [1, 2], displayFrames: displays), .stay)
    }

    func testNothingToReturnToStays() {
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 2, pid: 10, onScreen: [],
                                              existing: [], displayFrames: displays), .stay)
    }

    // MARK: Notched displays

    private var notchInsets: [CGRect: CGFloat] { [display: 32] }
    private var notchShow: CGRect { CGRect(x: 0, y: 32, width: 1512, height: 950) }

    func testNotchGapNeedsASecondSignal() {
        XCTAssertFalse(SlideShowFollow.isFullScreen(frame: notchShow, displayFrames: displays, notchInsets: notchInsets))
        XCTAssertTrue(SlideShowFollow.isFullScreen(frame: notchShow, displayFrames: displays,
                                                   notchInsets: notchInsets, allowNotchGap: true))
        XCTAssertTrue(SlideShowFollow.isFullScreen(frame: notchShow.offsetBy(dx: 0, dy: 1.5), displayFrames: displays,
                                                   notchInsets: notchInsets, allowNotchGap: true))
        // A different gap is not this display's notch.
        XCTAssertFalse(SlideShowFollow.isFullScreen(frame: CGRect(x: 0, y: 40, width: 1512, height: 942),
                                                    displayFrames: displays, notchInsets: notchInsets, allowNotchGap: true))
        // A display with no inset gets no gap allowance.
        XCTAssertFalse(SlideShowFollow.isFullScreen(frame: notchShow, displayFrames: displays,
                                                    notchInsets: [:], allowNotchGap: true))
    }

    func testNewNotchGapWindowIsFollowed() {
        let list = [win(2, notchShow), win(1, normal)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10, onScreen: list, existing: [],
                                              displayFrames: displays, notchInsets: notchInsets,
                                              knownWindowIDs: [1]), .follow(2))
    }

    func testPreExistingMaximisedNotchGapWindowIsNotFollowed() {
        let list = [win(2, notchShow), win(1, normal)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10, onScreen: list, existing: [],
                                              displayFrames: displays, notchInsets: notchInsets,
                                              knownWindowIDs: [1, 2]), .stay)
    }

    func testNotchGapWindowWhileOriginalWentOffScreenIsFollowed() {
        let list = [win(2, notchShow)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10, onScreen: list, existing: [],
                                              displayFrames: displays, notchInsets: notchInsets,
                                              knownWindowIDs: [1, 2]), .follow(2))
    }

    func testNoHistoryAndOriginalStillHereDoesNotFollowNotchGap() {
        let list = [win(2, notchShow), win(1, normal)]
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10, onScreen: list, existing: [],
                                              displayFrames: displays, notchInsets: notchInsets), .stay)
    }

    func testNonNotchedDisplaysBehaveAsBefore() {
        // Exact display frame still follows, known or not; the gap frame never does.
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10,
                                              onScreen: [win(2, display), win(1, normal)], existing: [],
                                              displayFrames: displays, knownWindowIDs: [1, 2]), .follow(2))
        XCTAssertEqual(SlideShowFollow.decide(original: 1, current: 1, pid: 10,
                                              onScreen: [win(2, notchShow), win(1, normal)], existing: [],
                                              displayFrames: displays, knownWindowIDs: [1]), .stay)
    }
}
