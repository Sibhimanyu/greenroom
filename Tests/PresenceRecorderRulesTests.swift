import XCTest

final class PresenceRecorderRulesTests: XCTestCase {
    typealias R = PresenceRecorderRules

    func testEveryWindowKindFollowsTheSwitchExceptCredentials() {
        for kind in R.WindowKind.allCases {
            if kind == .setupGuide {
                XCTAssertTrue(kind.alwaysHidden)
                XCTAssertEqual(R.sharing(for: kind, visibleToRecorders: true), .none, "\(kind)")
                XCTAssertEqual(R.sharing(for: kind, visibleToRecorders: false), .none, "\(kind)")
            } else {
                XCTAssertFalse(kind.alwaysHidden)
                XCTAssertEqual(R.sharing(for: kind, visibleToRecorders: true), .readOnly, "\(kind)")
                XCTAssertEqual(R.sharing(for: kind, visibleToRecorders: false), .none, "\(kind)")
            }
        }
        XCTAssertEqual(R.WindowKind.allCases.count, 10)
    }

    // R6.4, R6.5: Only me is a mirror for the owner alone. Other apps' recorders (QuickTime, Loom,
    // a native Zoom share) must never record the live camera bubble, whatever the switch says.
    func testOnlyMeNeverLetsOtherAppsRecordTheCameraBubble() {
        XCTAssertEqual(R.sharing(for: .cameraBubble, visibleToRecorders: true, cameraState: .onlyMe), .none)
        XCTAssertEqual(R.sharing(for: .cameraBubble, visibleToRecorders: false, cameraState: .onlyMe), .none)
        for state in CameraState.allCases where state != .onlyMe {
            XCTAssertEqual(R.sharing(for: .cameraBubble, visibleToRecorders: true, cameraState: state), .readOnly, "\(state)")
        }
    }

    // R6.4: Only me leaves the other windows (menus, whiteboard) as the switch has them.
    func testOnlyMeLeavesOtherWindowsToTheSwitch() {
        XCTAssertEqual(R.sharing(for: .whiteboard, visibleToRecorders: true, cameraState: .onlyMe), .readOnly)
        XCTAssertEqual(R.sharing(for: .cameraBubbleStrip, visibleToRecorders: true, cameraState: .onlyMe), .readOnly)
    }

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
