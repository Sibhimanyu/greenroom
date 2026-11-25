import XCTest

/// P8 / R6.4: "Only me" is a true mirror. The camera keeps running for the owner's bubble while
/// the Stage leaves it out of everyone's picture. `Visibility` is the one place that decides.
final class CameraMirrorRuleTests: XCTestCase {
    // R6.4: Only me keeps the camera open (a mirror needs frames) and out of everyone's picture.
    func testOnlyMeKeepsTheCameraRunningButOutOfEveryonesPicture() {
        XCTAssertTrue(Visibility.cameraMirrorOnly(state: .onlyMe, target: .wholeScreen))
        XCTAssertTrue(Visibility.cameraRuns(state: .onlyMe, target: .wholeScreen))
        XCTAssertFalse(Visibility.cameraEveryoneSees(state: .onlyMe, target: .wholeScreen).isOn)
    }

    // R6.4: the other states. Off closes the camera; the two "everyone" states are not mirrors; Just my
    // camera keeps even Only me in (the camera is then the whole picture, so it is not a mirror either).
    // Characterisation: green on first run, the first rule already answers it.
    func testOnlyOffClosesTheCameraAndOnlyMeIsTheMirror() {
        XCTAssertFalse(Visibility.cameraRuns(state: .off, target: .wholeScreen))
        XCTAssertTrue(Visibility.cameraRuns(state: .everyoneAndMe, target: .wholeScreen))
        XCTAssertTrue(Visibility.cameraRuns(state: .onlyEveryone, target: .wholeScreen))
        XCTAssertFalse(Visibility.cameraMirrorOnly(state: .everyoneAndMe, target: .wholeScreen))
        XCTAssertFalse(Visibility.cameraMirrorOnly(state: .onlyEveryone, target: .wholeScreen))
        XCTAssertFalse(Visibility.cameraMirrorOnly(state: .off, target: .wholeScreen))
        XCTAssertFalse(Visibility.cameraMirrorOnly(state: .onlyMe, target: .justMe))
        XCTAssertTrue(Visibility.cameraRuns(state: .onlyMe, target: .justMe))
    }

    // R6.4: a mirror is opened and shown in the owner's bubble but not drawn into the picture.
    func testAMirrorOpensTheCameraAndHasABubbleButIsNotDrawn() {
        var layout = StageLayout()
        layout.showsCamera = false
        layout.mirrorsCamera = true
        XCTAssertTrue(layout.opensCamera)
        XCTAssertTrue(layout.isPresencePlaceable)
        layout.mirrorsCamera = false     // Off
        XCTAssertFalse(layout.opensCamera)
        XCTAssertFalse(layout.isPresencePlaceable)
    }
}
