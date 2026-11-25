import XCTest

/// P8 / R11: the camera look (background, removal, mirror) in the camera piece's inspector.
final class CameraLookRulesTests: XCTestCase {
    // R11: Normal / Blur / Image only apply to the bubble shapes; Cutout and Presenter remove the
    // background themselves, so the background row folds away for them and the removal row appears.
    func testBackgroundAndRemovalRowsFollowTheShape() {
        for shape in WebcamShape.allCases {
            XCTAssertEqual(CameraLookRules.showsBackground(shape: shape), !shape.usesChromaKey, "\(shape)")
            XCTAssertEqual(CameraLookRules.showsRemoval(shape: shape), shape.usesChromaKey, "\(shape)")
        }
    }

    // R11: the folded group says what is set, and says it is the same in every layout.
    func testTheFoldedGroupNamesItsSettingsAndIsLabelledSameInEveryLayout() {
        XCTAssertEqual(CameraLookRules.sameInEveryLayout, "Same in every layout")
        XCTAssertEqual(CameraLookRules.summary(shape: .circle, backgroundName: "Blur", removal: .automatic, mirror: true),
                       "Blur \u{00B7} Mirror on")
        XCTAssertEqual(CameraLookRules.summary(shape: .cutout, backgroundName: "Normal", removal: .greenScreen, mirror: false),
                       "Green screen \u{00B7} Mirror off")
        XCTAssertEqual(CameraLookRules.summary(shape: .presenterLarge, backgroundName: "Image", removal: .automatic, mirror: true),
                       "Automatic removal \u{00B7} Mirror on")
    }

    // R11.4: Mirror flips only the owner's bubble. The Stage (the meeting's picture) and
    // Greenroom's recordings are never flipped, whatever the toggle says.
    func testMirrorFlipsOnlyTheBubble() {
        for on in [true, false] {
            XCTAssertEqual(CameraLookRules.mirrorsBubble(mirror: on), on)
        }
        XCTAssertFalse(CameraLookRules.stageMirrors)
        XCTAssertFalse(CameraLookRules.recordingsMirror)
    }

    // R11.4: one plain toggle, the same words in the inspector and on Home.
    func testMirrorToggleWords() {
        XCTAssertEqual(CameraLookRules.mirrorTitle, "Mirror my camera")
        XCTAssertEqual(CameraLookRules.mirrorHelp,
                       "Flips your camera on your screen only. The meeting and Greenroom\u{2019}s recordings always see you the right way round.")
    }
}
