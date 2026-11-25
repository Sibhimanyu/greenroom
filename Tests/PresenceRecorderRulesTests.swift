import XCTest

// Owner bug list R14 (decision 2026-11-25): the "Show Greenroom on screen in other apps' recordings"
// switch is gone. Every Greenroom window is visible to other apps' captures; the one exception is the
// camera bubble while the camera state is Only me (R6.4, R6.5).
final class PresenceRecorderRulesTests: XCTestCase {
    typealias R = PresenceRecorderRules

    // R14.6: the bubble is recordable in every state but Only me, a mirror for the owner alone.
    func testOnlyMeIsTheOnlyStateThatHidesTheCameraBubble() {
        for state in CameraState.allCases {
            XCTAssertEqual(R.cameraBubbleSharing(cameraState: state), state == .onlyMe ? .none : .readOnly, "\(state)")
        }
    }

    // R14.6: the bubble always feeds at its real pixel size, at least 1 and at most the compositor's 1920.
    func testFeedWidthIsTheBubblesRealPixelSize() {
        XCTAssertEqual(R.feedWidth(bubbleWidthPoints: 240, backingScale: 2), 480)
        XCTAssertEqual(R.feedWidth(bubbleWidthPoints: 1200, backingScale: 2), 1920)
        XCTAssertEqual(R.feedWidth(bubbleWidthPoints: 200.2, backingScale: 1), 201)
        XCTAssertEqual(R.feedWidth(bubbleWidthPoints: 0, backingScale: 0), 1)
    }

    // R14.6: nothing in the rules is a stored switch any more.
    func testChromeFadeStaysHalfASecond() {
        XCTAssertEqual(R.chromeFade, 0.5)
    }
}
