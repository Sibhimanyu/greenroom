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
}
