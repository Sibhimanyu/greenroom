import XCTest

/// P3: each layout owns the camera's spot, size and shape and what it shares.
final class LayoutCameraTests: XCTestCase {
    private func defaults(_ values: [String: Any] = [:]) -> UserDefaults {
        let name = "layout-camera-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }

    private func globalCamera() -> LayoutCamera {
        var c = LayoutCamera()
        c.shape = .roundedRectangle
        c.widthFraction = 0.3
        c.rightInset = 0.1
        c.bottomInset = 0.2
        c.cutoutHeightFraction = 0.7
        c.cutoutRightInset = 0.05
        return c
    }

    private func globalShare() -> ShareTarget {
        var s = ShareTarget()
        s.kind = .window
        s.appBundleID = "com.apple.Keynote"
        s.followsSlideShow = false
        return s
    }

    private func library() -> LayoutLibrary {
        let two = LayoutTemplate(name: "Two", twoDisplays: TwoDisplay())
        return LayoutLibrary(templates: [LayoutTemplate(name: "One"), two])
    }

    // MARK: Migration

    func testMigrationCopiesGlobalsIntoEveryLayoutAndVersion() {
        var lib = library()
        let d = defaults()
        XCTAssertTrue(lib.migrateCameraAndShare(camera: globalCamera(), share: globalShare(), defaults: d, save: { _ in true }))
        for t in lib.templates {
            XCTAssertEqual(t.camera, globalCamera())
            XCTAssertEqual(t.share, globalShare())
        }
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.cameraMigratedKey))
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.shareMigratedKey))
    }

    func testMigrationRunsOnceAndKeepsLaterEdits() {
        var lib = library()
        let d = defaults()
        _ = lib.migrateCameraAndShare(camera: globalCamera(), share: globalShare(), defaults: d, save: { _ in true })
        lib.templates[0].camera?.shape = .square
        lib.templates[0].share?.kind = .whiteboard
        var changedGlobals = globalCamera(); changedGlobals.shape = .cutout
        XCTAssertFalse(lib.migrateCameraAndShare(camera: changedGlobals, share: ShareTarget(), defaults: d, save: { _ in true }))
        XCTAssertEqual(lib.templates[0].camera?.shape, .square)
        XCTAssertEqual(lib.templates[0].share?.kind, .whiteboard)
        XCTAssertEqual(lib.templates[1].camera, globalCamera())
    }

    // R16.1: a migration writes its key only after its save worked, so a failed save runs again next launch.
    func testAFailedSaveLeavesTheMigrationKeysUnset() {
        var lib = library()
        let d = defaults()
        XCTAssertFalse(lib.migrateCameraAndShare(camera: globalCamera(), share: globalShare(), defaults: d, save: { _ in false }))
        XCTAssertFalse(d.bool(forKey: LayoutLibrary.cameraMigratedKey))
        XCTAssertFalse(d.bool(forKey: LayoutLibrary.shareMigratedKey))
        XCTAssertTrue(lib.migrateCameraAndShare(camera: globalCamera(), share: globalShare(), defaults: d, save: { _ in true }))
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.cameraMigratedKey))
    }

    // R4.2: a layout made after the migration owns a camera and a share from the start.
    func testANewBlankLayoutOwnsItsCameraAndShare() {
        var lib = library()
        let id = lib.addBlank()
        let t = lib.template(id: id)
        XCTAssertEqual(t?.camera, LayoutCamera())
        XCTAssertEqual(t?.share, ShareTarget())
    }

    // R4.2: a duplicate carries the original's camera, not the defaults.
    func testADuplicateKeepsTheOriginalsCamera() {
        var lib = library()
        lib.templates[0].camera = globalCamera()
        let id = lib.duplicate(lib.templates[0].id)!
        XCTAssertEqual(lib.template(id: id)?.camera, globalCamera())
    }

    // R4.2: a starter added by a later version also owns its camera.
    func testAStarterAddedLaterOwnsItsCamera() {
        var lib = LayoutLibrary(templates: [])
        XCTAssertTrue(lib.addStarters(notIn: []))
        XCTAssertTrue(lib.templates.allSatisfy { $0.camera != nil && $0.share != nil })
    }

    func testGlobalsReadFromDefaultsWithShippedFallbacks() {
        XCTAssertEqual(LayoutCamera.global(from: defaults()), LayoutCamera())
        let d = defaults(["webcamShape": "cutout", "bubbleWidthFraction": 0.4, "cutoutRightInset": 0.3])
        let c = LayoutCamera.global(from: d)
        XCTAssertEqual(c.shape, .cutout)
        XCTAssertEqual(c.widthFraction, 0.4)
        XCTAssertEqual(c.cutoutRightInset, 0.3)
        XCTAssertEqual(c.rightInset, PresenceBox().rightInset)
    }

    // MARK: Codable

    func testOldFileDecodesWithNoCameraOrShare() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Old","oneDisplay":[]}"#
        let t = try JSONDecoder().decode(LayoutTemplate.self, from: Data(json.utf8))
        XCTAssertNil(t.camera)
        XCTAssertNil(t.share)
    }

    func testCameraDefaultsEqualTodaysGlobals() throws {
        let c = try JSONDecoder().decode(LayoutCamera.self, from: Data("{}".utf8))
        let shipped = PresenceBox()
        XCTAssertEqual(c.shape, .circle)
        XCTAssertEqual(c.widthFraction, shipped.widthFraction)
        XCTAssertEqual(c.rightInset, shipped.rightInset)
        XCTAssertEqual(c.bottomInset, shipped.bottomInset)
        XCTAssertEqual(c.cutoutHeightFraction, shipped.cutoutHeightFraction)
        XCTAssertEqual(c.cutoutRightInset, shipped.cutoutRightInset)
        let odd = try JSONDecoder().decode(LayoutCamera.self, from: Data(#"{"shape":"nonsense","widthFraction":0.3}"#.utf8))
        XCTAssertEqual(odd.shape, .circle)
        XCTAssertEqual(odd.widthFraction, 0.3)
    }

    func testCameraAndShareRoundTripThroughTheLibrary() throws {
        var lib = library()
        lib.templates[0].camera = globalCamera()
        lib.templates[0].share = globalShare()
        let back = try JSONDecoder().decode(LayoutLibrary.self, from: JSONEncoder().encode(lib))
        XCTAssertEqual(back.templates[0].camera, globalCamera())
        XCTAssertEqual(back.templates[0].share, globalShare())
        XCTAssertNil(back.templates[1].camera)
    }


    // MARK: Who may write the saved layout

    // R4.3, R6.2: Home, the bar and a drag in the meeting change the running meeting only.
    // R11: with the Webcam tab gone, Settings -> Layouts is the only writer.
    func testOnlySettingsLayoutsWritesTheSavedLayout() {
        XCTAssertEqual(LayoutEditSource.allCases.filter(\.writesSavedLayout), [.settingsLayouts])
        XCTAssertTrue(LayoutEditSource.settingsLayouts.writesSavedLayout)
        XCTAssertFalse(LayoutEditSource.home.writesSavedLayout)
        XCTAssertFalse(LayoutEditSource.bar.writesSavedLayout)
        XCTAssertFalse(LayoutEditSource.meeting.writesSavedLayout)
    }

    // R5.1: the Layouts tab's edits land in the active layout and nowhere else.
    func testWritingTheActiveLayoutTouchesOnlyIt() {
        var lib = library()
        lib.select(lib.templates[1].id)
        var cam = globalCamera(); cam.shape = .square
        XCTAssertTrue(lib.updateActive(camera: cam, share: globalShare()))
        XCTAssertEqual(lib.templates[1].camera, cam)
        XCTAssertEqual(lib.templates[1].share, globalShare())
        XCTAssertNil(lib.templates[0].camera)
        lib.select(nil)
        XCTAssertFalse(lib.updateActive(camera: cam, share: nil))
    }

    // R5.2: a share chosen on Home before Start survives into that meeting; the layout's camera still applies.
    func testStartKeepsAShareChosenBeforeStart() {
        var t = LayoutTemplate(name: "A"); t.camera = globalCamera(); t.share = globalShare()
        let kept = LayoutPieceAdoption.atStart(t, keepingLiveShare: true)
        XCTAssertNil(kept?.share)
        XCTAssertEqual(kept?.camera, globalCamera())
        XCTAssertEqual(LayoutPieceAdoption.atStart(t, keepingLiveShare: false)?.share, globalShare())
        var onlyShare = LayoutTemplate(name: "B"); onlyShare.share = globalShare()
        XCTAssertNil(LayoutPieceAdoption.atStart(onlyShare, keepingLiveShare: true))
    }

    // R5.3: Snap Back loads the layout's share again, and leaves the camera spot alone.
    func testSnapBackLoadsTheLayoutsShareOnly() {
        var t = LayoutTemplate(name: "A"); t.camera = globalCamera(); t.share = globalShare()
        let plan = LayoutPieceAdoption.atSnapBack(t)
        XCTAssertEqual(plan?.share, globalShare())
        XCTAssertNil(plan?.camera)
        XCTAssertNil(LayoutPieceAdoption.atSnapBack(LayoutTemplate(name: "none")))
        XCTAssertNil(LayoutPieceAdoption.atSnapBack(nil))
    }

    // R4.1: the camera defaults keys have one home, shared by the global read and the adoption.
    func testTheCameraDefaultsKeysAreListedOnce() {
        let d = defaults(["webcamShape": "square", "bubbleWidthFraction": 0.31])
        XCTAssertTrue(LayoutCamera.defaultsKeys.contains("webcamShape"))
        XCTAssertTrue(LayoutCamera.defaultsKeys.contains("cutoutRightInset"))
        XCTAssertEqual(Set(LayoutCamera.defaultsKeys).count, 6)
        XCTAssertEqual(LayoutCamera.global(from: d).widthFraction, 0.31)
    }

    // R4.1: a layout's description says where its camera sits.
    func testTheCameraCornerIsSpokenFromItsSpot() {
        XCTAssertEqual(LayoutCamera().cornerPhrase, "bottom right")
        var c = LayoutCamera(); c.rightInset = 0.8
        XCTAssertEqual(c.cornerPhrase, "bottom left")
        c.bottomInset = 0.8
        XCTAssertEqual(c.cornerPhrase, "top left")
        c.rightInset = 0.02
        XCTAssertEqual(c.cornerPhrase, "top right")
    }

    // MARK: Start

    func testStartTakesCameraAndShareFromTheLayout() {
        var t = LayoutTemplate(name: "A")
        t.camera = globalCamera()
        t.share = globalShare()
        let plan = LayoutPieceAdoption.atStart(t)
        XCTAssertEqual(plan?.camera, globalCamera())
        XCTAssertEqual(plan?.share, globalShare())
    }

    // resolvedCamera / resolvedShare were removed (nothing called them); no layout means no plan, the globals stand.
    func testNoLayoutFallsBackToTheGlobals() {
        XCTAssertNil(LayoutPieceAdoption.atStart(nil))
        XCTAssertNil(LayoutPieceAdoption.atStart(LayoutTemplate(name: "Blank")))
    }

    // MARK: Live changes never reach the layout

    func testAnUnrelatedEditLeavesLiveValuesAlone() {
        var old = LayoutTemplate(name: "A"); old.camera = globalCamera(); old.share = globalShare()
        var new = old; new.name = "Renamed"
        XCTAssertNil(LayoutPieceAdoption.plan(old: old, new: new))
    }

    func testOnlyAChangedPieceIsAdopted() {
        var old = LayoutTemplate(name: "A"); old.camera = globalCamera(); old.share = globalShare()
        var new = old; new.camera?.shape = .square
        let plan = LayoutPieceAdoption.plan(old: old, new: new)
        XCTAssertEqual(plan?.camera?.shape, .square)
        XCTAssertNil(plan?.share)
    }

    func testPickingAnotherLayoutAdoptsItsPieces() {
        var a = LayoutTemplate(name: "A"); a.camera = globalCamera()
        var b = LayoutTemplate(name: "B"); b.share = globalShare()
        let plan = LayoutPieceAdoption.plan(old: a, new: b)
        XCTAssertNil(plan?.camera)
        XCTAssertEqual(plan?.share, globalShare())
    }

    func testBoxCarriesTheShape() {
        var c = globalCamera(); c.shape = .cutout
        XCTAssertTrue(c.box.isCutout)
        XCTAssertEqual(c.box.widthFraction, 0.3)
    }
}
