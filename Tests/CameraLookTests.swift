import XCTest

/// The Look: one value for background, picture, removal and mirror (docs/specs/camera-look.md).
final class CameraLookTests: XCTestCase {

    private func store() -> UserDefaults {
        let name = "CameraLookTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // Spec: camera-look R1.1
    func testDefaults() {
        let look = CameraLook()
        XCTAssertEqual(look.removal, .automatic)
        XCTAssertEqual(look.background, .normal)
        XCTAssertEqual(look.backgroundImage, CameraBackgroundPreset.defaultChoice)
        XCTAssertTrue(look.mirror)
    }

    // Spec: camera-look R1.2
    func testEquatable() {
        var a = CameraLook(), b = CameraLook()
        XCTAssertEqual(a, b)
        a.mirror = false
        XCTAssertNotEqual(a, b)
        b.mirror = false
        XCTAssertEqual(a, b)
    }

    // Spec: camera-look R2.1
    func testLoadsTheKeysOfAnOldInstall() {
        let d = store()
        d.set("greenScreen", forKey: "backgroundRemoval")
        d.set("Image", forKey: "cameraBackground")
        d.set("sunset", forKey: "cameraBackgroundImage")
        d.set(false, forKey: "camera.mirrorSelfView")
        let look = CameraLook.load(from: d)
        XCTAssertEqual(look.removal, .greenScreen)
        XCTAssertEqual(look.background, .image)
        XCTAssertEqual(look.backgroundImage, "sunset")
        XCTAssertFalse(look.mirror)
    }

    // Spec: camera-look R2.2
    func testMissingOrUnknownValuesAreDefaultsAndTheRestStillLoad() {
        let d = store()
        XCTAssertEqual(CameraLook.load(from: d), CameraLook())
        d.set("nonsense", forKey: "backgroundRemoval")
        d.set("Blur", forKey: "cameraBackground")
        d.set("not a bool", forKey: "camera.mirrorSelfView")
        let look = CameraLook.load(from: d)
        XCTAssertEqual(look.removal, .automatic)
        XCTAssertEqual(look.background, .blur)
        XCTAssertTrue(look.mirror)
    }

    // Spec: camera-look R2.3, R2.4
    func testSaveWritesTheSameKeysAndRoundTrips() {
        let d = store()
        var look = CameraLook()
        look.removal = .greenScreen
        look.background = .blur
        look.backgroundImage = "custom-1760000000"
        look.mirror = false
        look.save(to: d)
        XCTAssertEqual(d.string(forKey: "backgroundRemoval"), "greenScreen")
        XCTAssertEqual(d.string(forKey: "cameraBackground"), "Blur")
        XCTAssertEqual(d.string(forKey: "cameraBackgroundImage"), "custom-1760000000")
        XCTAssertEqual(d.object(forKey: "camera.mirrorSelfView") as? Bool, false)
        XCTAssertEqual(CameraLook.load(from: d), look)
    }

    // Spec: camera-look R3.1
    func testOnlyBackgroundPictureAndRemovalReachTheStage() {
        let base = CameraLook()
        XCTAssertFalse(CameraLook.reachesStage(from: base, to: base))
        var mirror = base; mirror.mirror = false
        XCTAssertFalse(CameraLook.reachesStage(from: base, to: mirror))
        var removal = base; removal.removal = .greenScreen
        XCTAssertTrue(CameraLook.reachesStage(from: base, to: removal))
        var background = base; background.background = .blur
        XCTAssertTrue(CameraLook.reachesStage(from: base, to: background))
        var picture = base; picture.backgroundImage = "ocean"
        XCTAssertTrue(CameraLook.reachesStage(from: base, to: picture))
    }

    // Spec: camera-look R4.1
    func testExportedStrings() {
        var look = CameraLook()
        look.removal = .greenScreen; look.background = .image; look.backgroundImage = "forest"
        XCTAssertEqual(look.exportedRemoval, "greenScreen")
        XCTAssertEqual(look.exportedBackground, "Image")
        XCTAssertEqual(look.exportedBackgroundImage, "forest")
    }

    // Spec: camera-look R4.2
    func testImportingAppliesPresentKnownFieldsOnly() {
        var look = CameraLook()
        look.background = .blur
        let same = look.importing(removal: nil, background: nil, picture: nil)
        XCTAssertEqual(same, look)
        let changed = look.importing(removal: "greenScreen", background: "nonsense", picture: nil)
        XCTAssertEqual(changed.removal, .greenScreen)
        XCTAssertEqual(changed.background, .blur, "an unknown mode is ignored")
        let bad = look.importing(removal: "nonsense", background: nil, picture: nil)
        XCTAssertEqual(bad.removal, .automatic)
    }

    // Spec: camera-look R4.3
    func testImportingTheModeComesWithItsPicture() {
        let look = CameraLook().importing(removal: nil, background: "Image", picture: "custom-1")
        XCTAssertEqual(look.background, .image)
        XCTAssertEqual(look.backgroundImage, "custom-1")
    }
}
