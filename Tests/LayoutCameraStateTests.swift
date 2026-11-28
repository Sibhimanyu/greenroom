import XCTest

/// meeting-setup P2: each layout holds a camera state; existing layouts get the app-wide one once.
final class LayoutCameraStateTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "layout-camera-state-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func oldLayoutJSON() -> Data {
        Data(#"{"id":"11111111-1111-1111-1111-111111111111","name":"Mine","oneDisplay":[]}"#.utf8)
    }

    // Spec: meeting-setup R1.1
    func testALayoutRoundTripsItsCameraState() throws {
        for state in CameraState.allCases {
            let t = LayoutTemplate(name: "A", cameraState: state)
            let back = try JSONDecoder().decode(LayoutTemplate.self, from: try JSONEncoder().encode(t))
            XCTAssertEqual(back.cameraState, state)
        }
    }

    // Spec: meeting-setup R1.1, R1.2
    func testAnOldLayoutDecodesWithNoCameraStateAndNoDefaultInvented() throws {
        let t = try JSONDecoder().decode(LayoutTemplate.self, from: oldLayoutJSON())
        XCTAssertEqual(t.name, "Mine")
        XCTAssertNil(t.cameraState, "left for the migration, which needs to know it was missing")
        let junk = Data(#"{"name":"X","cameraState":"somethingNew"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LayoutTemplate.self, from: junk).cameraState)
    }

    // Spec: meeting-setup R1.2
    func testMigrationCopiesTheAppWideStateIntoEveryLayoutWithNone() {
        var lib = LayoutLibrary(templates: [LayoutTemplate(name: "One"), LayoutTemplate(name: "Two", twoDisplays: TwoDisplay()),
                                            LayoutTemplate(name: "Has", cameraState: .onlyEveryone)])
        let d = defaults()
        XCTAssertTrue(lib.migrateCameraState(saved: .onlyMe, defaults: d, save: { _ in true }))
        XCTAssertEqual(lib.templates.map(\.cameraState), [.onlyMe, .onlyMe, .onlyEveryone])
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.cameraStateMigratedKey))
    }

    // Spec: meeting-setup R1.2
    func testMigrationRunsOnceAndLaterEditsStay() {
        var lib = LayoutLibrary(templates: [LayoutTemplate(name: "One")])
        let d = defaults()
        _ = lib.migrateCameraState(saved: .onlyMe, defaults: d, save: { _ in true })
        lib.templates[0].cameraState = .off
        XCTAssertFalse(lib.migrateCameraState(saved: .everyoneAndMe, defaults: d, save: { _ in true }))
        XCTAssertEqual(lib.templates[0].cameraState, .off)
    }

    // Spec: meeting-setup R1.2: a failed save leaves the key unset so it runs again.
    func testAFailedSaveLeavesTheKeyUnset() {
        var lib = LayoutLibrary(templates: [LayoutTemplate(name: "One")])
        let d = defaults()
        XCTAssertFalse(lib.migrateCameraState(saved: .off, defaults: d, save: { _ in false }))
        XCTAssertFalse(d.bool(forKey: LayoutLibrary.cameraStateMigratedKey))
        XCTAssertTrue(lib.migrateCameraState(saved: .off, defaults: d, save: { _ in true }))
    }

    // Spec: meeting-setup R1.2: the two old keys read as one state, and a missing key means what it always did.
    func testTheOldKeysReadAsOneState() {
        XCTAssertEqual(CameraState.migrated(noCamera: true, shownOnMyScreen: false), .off)
        XCTAssertEqual(CameraState.migrated(noCamera: nil, shownOnMyScreen: nil), .everyoneAndMe)
    }

    // Spec: meeting-setup R1.2: an old library on disk loads through loadOrMigrate with no state, then migrates.
    func testALibrarySavedBeforeTheChangeMigratesOnLoad() {
        let d = defaults()
        var lib = LayoutLibrary(templates: LayoutLibrary.builtIns() + [LayoutTemplate(name: "Mine")])
        for i in lib.templates.indices { lib.templates[i].cameraState = nil }
        lib.save(to: d)
        var loaded = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: "https://example.test")
        XCTAssertTrue(loaded.migrateCameraState(saved: .onlyMe, defaults: d, save: { $0.save(to: d) }))
        XCTAssertEqual(loaded.templates.first { $0.name == "Mine" }?.cameraState, .onlyMe)
        XCTAssertEqual(LayoutLibrary.load(from: d)?.templates.first { $0.name == "Mine" }?.cameraState, .onlyMe, "written back")
    }

    // Spec: meeting-setup R1.2
    func testEveryBuiltInOriginalIsEveryoneAndMeExceptRajsOnlyTheMeeting() {
        for t in LayoutLibrary.builtIns() {
            XCTAssertEqual(t.cameraState, t.starter == LayoutLibrary.rajMode ? .onlyEveryone : .everyoneAndMe, t.name)
        }
    }

    // Spec: meeting-setup R1.2: a built-in added since keeps what it ships with.
    func testABuiltInThatShipsWithAStateKeepsIt() {
        var lib = LayoutLibrary(templates: LayoutLibrary.builtIns())
        _ = lib.migrateCameraState(saved: .off, defaults: defaults(), save: { _ in true })
        XCTAssertEqual(lib.templates.map(\.cameraState), LayoutLibrary.builtIns().map(\.cameraState))
    }

    // Spec: meeting-setup R1.2: Restore original puts Everyone & me back.
    func testRestoreOriginalBringsTheShippedStateBack() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.builtIns())
        let i = try XCTUnwrap(lib.templates.firstIndex { $0.starter == LayoutLibrary.rajMode })
        lib.templates[i].cameraState = .off
        XCTAssertTrue(lib.restoreOriginal(lib.templates[i].id))
        XCTAssertEqual(lib.templates[i].cameraState, .onlyEveryone, "Raj San Mode ships Only the meeting")
    }

    // MARK: Settings file (R1.3)

    // Spec: meeting-setup R1.3: a new file carries the state inside each layout.
    func testTheSettingsFileCarriesTheStateInsideEachLayout() throws {
        var t = SettingsTransfer()
        t.layoutLibrary = LayoutLibrary(templates: [LayoutTemplate(name: "A", cameraState: .onlyEveryone)])
        let back = try JSONDecoder().decode(SettingsTransfer.self, from: try JSONEncoder().encode(t))
        XCTAssertEqual(back.layoutLibrary?.templates.first?.cameraState, .onlyEveryone)
        XCTAssertNil(back.cameraShownOnMyScreen, "the old app-wide key is never written")
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(t)) as? [String: Any]
        XCTAssertNil(object?["cameraShownOnMyScreen"])
    }

    // Spec: meeting-setup R1.3: an old file's value goes to each layout that has none.
    func testAnOldFilesValueGoesToLayoutsWithNone() throws {
        let json = #"{"cameraShownOnMyScreen":false,"cameraDirector":{"noCamera":true},"layoutLibrary":{"templates":[{"name":"A"},{"name":"B","cameraState":"onlyEveryone"}]}}"#
        let t = try JSONDecoder().decode(SettingsTransfer.self, from: Data(json.utf8))
        let library = try XCTUnwrap(t.layoutLibrary)
        XCTAssertNil(library.templates[0].cameraState)
        let out = SettingsImportRules.applyingOldCameraState(library, noCamera: t.cameraDirector?.noCamera,
                                                             shownOnMyScreen: t.cameraShownOnMyScreen, fallback: .everyoneAndMe)
        XCTAssertEqual(out.templates.map(\.cameraState), [.off, .onlyEveryone])
    }

    // Spec: meeting-setup R1.3: what an old file omits keeps this Mac's state.
    func testAnOldFileThatOmitsTheValueUsesThisMacsState() {
        let library = LayoutLibrary(templates: [LayoutTemplate(name: "A")])
        let out = SettingsImportRules.applyingOldCameraState(library, noCamera: nil, shownOnMyScreen: nil, fallback: .onlyMe)
        XCTAssertEqual(out.templates[0].cameraState, .onlyMe)
        let half = SettingsImportRules.applyingOldCameraState(library, noCamera: false, shownOnMyScreen: nil, fallback: .onlyMe)
        XCTAssertEqual(half.templates[0].cameraState, .everyoneAndMe)
    }

    // Spec: meeting-setup R1.3: the layout an old file brings in carries the FILE's camera piece, share
    // and camera state (not this Mac's), so it is complete when it becomes active.
    func testTheLayoutAnOldFileBringsInCarriesTheFilesOwnCameraPieceShareAndState() throws {
        let json = #"{"webcamShape":"cutout","bubbleWidthFraction":0.3,"cutoutHeightFraction":0.45,"cutoutRightInset":0.07,"cameraShownOnMyScreen":false,"cameraDirector":{"noCamera":false}}"#
        var t = try JSONDecoder().decode(SettingsTransfer.self, from: Data(json.utf8))
        var wb = ShareTarget(); wb.kind = .whiteboard; t.shareTarget = wb
        var base = LayoutCamera(); base.bottomInset = 0.11
        let out = SettingsImportRules.completingOldFileLayout(LayoutTemplate(name: "Your previous layout"), from: t,
                                                              baseCamera: base, baseShare: ShareTarget(),
                                                              cameraFallback: .everyoneAndMe)
        XCTAssertEqual(out.camera?.shape, .cutout)
        XCTAssertEqual(out.camera?.widthFraction, 0.3)
        XCTAssertEqual(out.camera?.cutoutHeightFraction, 0.45)
        XCTAssertEqual(out.camera?.cutoutRightInset, 0.07)
        XCTAssertEqual(out.camera?.bottomInset, 0.11, "what the file omits keeps the base")
        XCTAssertEqual(out.share?.kind, .whiteboard)
        XCTAssertEqual(out.cameraState, .onlyEveryone, "the file's value, not this Mac's")
    }

    // Spec: meeting-setup R1.3: a file that says nothing keeps this Mac's state, piece and share.
    func testAnOldFileThatSaysNothingKeepsThisMacsValues() {
        var base = LayoutCamera(); base.shape = .roundedRectangle
        var share = ShareTarget(); share.kind = .whiteboard
        let out = SettingsImportRules.completingOldFileLayout(LayoutTemplate(name: "X"), from: SettingsTransfer(),
                                                              baseCamera: base, baseShare: share, cameraFallback: .onlyMe)
        XCTAssertEqual(out.camera, base)
        XCTAssertEqual(out.share, share)
        XCTAssertEqual(out.cameraState, .onlyMe)
    }

    // Spec: meeting-setup R1.1: a new blank layout has a camera state, like every other.
    func testANewBlankLayoutIsEveryoneAndMe() {
        var lib = LayoutLibrary(templates: [])
        let id = lib.addBlank()
        XCTAssertEqual(lib.template(id: id)?.cameraState, .everyoneAndMe)
    }

    // Spec: meeting-setup R1.3: the old key is import-only in the catalog.
    func testTheOldKeyIsImportOnly() {
        let entry = SettingsCatalog.entries.first { $0.key == "cameraShownOnMyScreen" }
        XCTAssertEqual(entry?.disposition, .importOnly(transferKey: "cameraShownOnMyScreen"))
    }
}
