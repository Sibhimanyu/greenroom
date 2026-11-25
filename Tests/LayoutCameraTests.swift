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
        XCTAssertTrue(lib.migrateCameraAndShare(camera: globalCamera(), share: globalShare(), defaults: d))
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
        _ = lib.migrateCameraAndShare(camera: globalCamera(), share: globalShare(), defaults: d)
        lib.templates[0].camera?.shape = .square
        lib.templates[0].share?.kind = .whiteboard
        var changedGlobals = globalCamera(); changedGlobals.shape = .cutout
        XCTAssertFalse(lib.migrateCameraAndShare(camera: changedGlobals, share: ShareTarget(), defaults: d))
        XCTAssertEqual(lib.templates[0].camera?.shape, .square)
        XCTAssertEqual(lib.templates[0].share?.kind, .whiteboard)
        XCTAssertEqual(lib.templates[1].camera, globalCamera())
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

    // MARK: Start

    func testStartTakesCameraAndShareFromTheLayout() {
        var t = LayoutTemplate(name: "A")
        t.camera = globalCamera()
        t.share = globalShare()
        let plan = LayoutPieceAdoption.atStart(t)
        XCTAssertEqual(plan?.camera, globalCamera())
        XCTAssertEqual(plan?.share, globalShare())
    }

    func testNoLayoutFallsBackToTheGlobals() {
        XCTAssertNil(LayoutPieceAdoption.atStart(nil))
        let fallback = globalCamera()
        XCTAssertEqual(LayoutTemplate(name: "Blank").resolvedCamera(fallback: fallback), fallback)
        XCTAssertEqual(LayoutTemplate(name: "Blank").resolvedShare(fallback: globalShare()), globalShare())
        var t = LayoutTemplate(name: "A"); t.camera = LayoutCamera()
        XCTAssertEqual(t.resolvedCamera(fallback: fallback), LayoutCamera())
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
