import XCTest

final class PresenceRecorderRulesTests: XCTestCase {
    typealias R = PresenceRecorderRules

    func testDefaultIsOn() {
        XCTAssertTrue(R.visibleToRecorders(stored: nil))
        XCTAssertFalse(R.visibleToRecorders(stored: false))
    }

    func testSharingType() {
        XCTAssertEqual(R.sharing(visibleToRecorders: true), .readOnly)
        XCTAssertEqual(R.sharing(visibleToRecorders: false), .none)
    }

    func testMirrorOnlyWhenHiddenFromRecorders() {
        XCTAssertFalse(R.effectiveMirror(userMirror: true, visibleToRecorders: true))
        XCTAssertTrue(R.effectiveMirror(userMirror: true, visibleToRecorders: false))
        XCTAssertFalse(R.effectiveMirror(userMirror: false, visibleToRecorders: false))
        XCTAssertFalse(R.mirrorSettingEnabled(visibleToRecorders: true))
        XCTAssertTrue(R.mirrorSettingEnabled(visibleToRecorders: false))
    }

    func testFeedWidth() {
        XCTAssertEqual(R.feedWidth(visibleToRecorders: false, bubbleWidthPoints: 900, backingScale: 2), 640)
        XCTAssertEqual(R.feedWidth(visibleToRecorders: true, bubbleWidthPoints: 240, backingScale: 2), 480)
        XCTAssertEqual(R.feedWidth(visibleToRecorders: true, bubbleWidthPoints: 1200, backingScale: 2), 1920)
        XCTAssertEqual(R.feedWidth(visibleToRecorders: true, bubbleWidthPoints: 200.2, backingScale: 1), 201)
        XCTAssertEqual(R.feedWidth(visibleToRecorders: true, bubbleWidthPoints: 0, backingScale: 0), 1)
    }

    func testChrome() {
        XCTAssertTrue(R.showsChrome(visibleToRecorders: false, hovering: true, interacting: false))
        XCTAssertFalse(R.showsChrome(visibleToRecorders: true, hovering: true, interacting: false))
        XCTAssertTrue(R.showsChrome(visibleToRecorders: true, hovering: true, interacting: true))
        XCTAssertFalse(R.showsChrome(visibleToRecorders: false, hovering: false, interacting: false))
    }
}
