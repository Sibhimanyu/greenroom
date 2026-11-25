import XCTest

/// P9: the six built-in layouts, Leave my windows alone, Restore original and the existing-install migration.
final class BuiltInLayoutsTests: XCTestCase {
    private func starter(_ key: String) -> LayoutTemplate {
        LayoutLibrary.starters().first { $0.starter == key }!
    }

    // R12.1 (Q4): the six built-ins, in the order the strip shows them.
    func testTheSixBuiltInsInOrder() {
        XCTAssertEqual(LayoutLibrary.starters().map(\.name),
                       ["Teach from a browser", "Talk to the meeting", "Present", "Room + laptop",
                        "Leave my windows alone", "Raj San Mode"])
        XCTAssertEqual(LayoutLibrary.starters().compactMap(\.starter),
                       ["teach-browser", "talk-to-meeting", "present", "room-laptop", "leave-alone", "raj"])
    }

    // R12.1, Q20, Q21: each built-in owns its camera and share. Talk shares Nothing with the camera filling the picture;
    // Present shares one window, following the slide show, with the camera small.
    func testEveryBuiltInOwnsACameraAndAShare() {
        for t in LayoutLibrary.starters() {
            XCTAssertNotNil(t.camera, t.name)
            XCTAssertNotNil(t.share, t.name)
        }
        let talk = starter(LayoutLibrary.talkToMeeting)
        XCTAssertEqual(talk.share?.kind, .nothing)
        XCTAssertEqual(talk.camera?.widthFraction, PresenceGeometry.widthFractions.upperBound, "the camera fills the picture")
        XCTAssertTrue(talk.oneDisplay.contains { $0.kind.view == .activeSpeaker }, "Active speaker on my screen")
        let present = starter(LayoutLibrary.present)
        XCTAssertEqual(present.share?.kind, .display)
        XCTAssertLessThanOrEqual(present.camera?.widthFraction ?? 1, 0.2, "small, in a corner")
    }

    // R15.1 (Q9): Room + laptop shares Main and puts the Room screen on Second.
    func testRoomPlusLaptopSharesMainAndPutsTheRoomScreenOnSecond() {
        let room = starter(LayoutLibrary.roomLaptop)
        XCTAssertEqual(room.twoDisplays?.sharedSlot, .main)
        XCTAssertEqual(room.twoDisplays?.second.map(\.kind), [.roomScreen])
        XCTAssertFalse(room.oneDisplay.isEmpty, "the one-display version runs with no second display")
    }

    // R12.1: every built-in has a one-line description for the inspector's empty state.
    func testEveryBuiltInHasAOneLineDescription() {
        for t in LayoutLibrary.starters() {
            let d = LayoutLibrary.description(forStarter: t.starter ?? "")
            XCTAssertNotNil(d, t.name)
            XCTAssertFalse(d?.contains("\n") ?? true, t.name)
        }
        XCTAssertNil(LayoutLibrary.description(forStarter: LayoutLibrary.meetingAndChat), "the retired starter has none")
    }

    // R12.3: Leave my windows alone moves no windows; every other layout does.
    func testOnlyLeaveMyWindowsAloneMovesNothing() {
        for t in LayoutLibrary.starters() {
            XCTAssertEqual(t.movesWindows, t.starter != LayoutLibrary.leaveAlone, t.name)
        }
        XCTAssertTrue(LayoutTemplate(name: "Mine").movesWindows)
    }

    // R12.2 (Q3): there is no None. Nil, a missing id and a stale id all mean Leave my windows alone.
    func testThereIsAlwaysAnActiveLayout() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let leaveID = lib.templates.first { $0.starter == LayoutLibrary.leaveAlone }!.id
        lib.select(nil)
        XCTAssertEqual(lib.activeID, leaveID)

        let stale = #"{"templates":\#(String(data: try JSONEncoder().encode(LayoutLibrary.starters()), encoding: .utf8)!),"activeID":"00000000-0000-0000-0000-000000000000"}"#
        let decoded = try JSONDecoder().decode(LayoutLibrary.self, from: Data(stale.utf8))
        XCTAssertEqual(decoded.active?.starter, LayoutLibrary.leaveAlone)

        lib.select(lib.templates[0].id)
        lib.delete(lib.templates[0].id)
        XCTAssertEqual(lib.active?.starter, LayoutLibrary.leaveAlone, "deleting the active layout falls back to it")

        lib.select(lib.templates[1].id)
        lib.resetToDefaults()
        XCTAssertEqual(lib.active?.starter, LayoutLibrary.leaveAlone, "Reset all too")
        XCTAssertEqual(LayoutLibrary.firstRun(legacy: LegacyLayoutSettings()).active?.starter, LayoutLibrary.leaveAlone)
    }

    // R12.4 (Q22): + on Leave my windows alone copies it into "My layout", "My layout 2"...; the built-in stays clean.
    func testPlusOnLeaveMyWindowsAloneMakesMyLayout() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        lib.ensureActive()
        let leaveID = lib.activeID!
        let first = try XCTUnwrap(lib.forkLeaveAlone())
        let copy = try XCTUnwrap(lib.template(id: first))
        XCTAssertEqual(copy.name, "My layout")
        XCTAssertNil(copy.starter)
        XCTAssertEqual(copy.camera, starter(LayoutLibrary.leaveAlone).camera)
        XCTAssertTrue(copy.movesWindows)
        XCTAssertEqual(lib.activeID, first, "it is selected")
        XCTAssertEqual(lib.template(id: leaveID)?.oneDisplay.count, 0, "the built-in stays clean")
        lib.select(leaveID)
        let second = try XCTUnwrap(lib.forkLeaveAlone())
        XCTAssertEqual(lib.template(id: second)?.name, "My layout 2")
        lib.select(lib.templates[0].id)
        XCTAssertNil(lib.forkLeaveAlone(), "only Leave my windows alone forks")
    }

    // R13.1 (Q6): Restore original puts back one built-in and leaves every other layout alone.
    func testRestoreOriginalResetsOnlyThatLayout() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let mine = lib.addBlank()
        var talk = try XCTUnwrap(lib.templates.first { $0.starter == LayoutLibrary.talkToMeeting })
        let talkID = talk.id
        talk.oneDisplay = []
        talk.name = "Renamed"
        talk.camera?.shape = .square
        lib.update(talk)
        var teach = try XCTUnwrap(lib.templates.first { $0.starter == LayoutLibrary.teachFromBrowser })
        teach.name = "My teach"
        lib.update(teach)
        lib.select(talkID)
        let before = lib

        XCTAssertTrue(lib.canRestore(talkID))
        XCTAssertFalse(lib.canRestore(mine), "your own layout has no original")
        XCTAssertTrue(lib.restoreOriginal(talkID))

        let restored = try XCTUnwrap(lib.template(id: talkID))
        XCTAssertEqual(restored.name, "Talk to the meeting")
        XCTAssertTrue(restored.isAsShipped)
        XCTAssertEqual(lib.templates.map(\.id), before.templates.map(\.id), "same place, same id")
        XCTAssertEqual(lib.activeID, talkID)
        for t in before.templates where t.id != talkID { XCTAssertEqual(lib.template(id: t.id), t) }
        XCTAssertFalse(lib.restoreOriginal(mine))
    }

    // MARK: Existing installs (Q8)

    private let site = "https://example.test/index.html"

    private func defaults() -> UserDefaults {
        let name = "builtins-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// What the last release saved: Raj Mode (edited), the old Teach from a browser, Meeting and chat (edited), None.
    private func oldInstall() -> LayoutLibrary {
        func piece(_ kind: LayoutPiece.Kind, _ x: Double, _ w: Double) -> LayoutPiece {
            LayoutPiece(kind: kind, rect: UnitRect(x: x, y: 0, w: w, h: 1))
        }
        let third = 1.0 / 12
        let raj = LayoutTemplate(name: "Raj Mode", starter: "raj", oneDisplay: [piece(.chat, 0.4, 0.2)])
        let teach = LayoutTemplate(
            name: "Teach from a browser", starter: "teach-browser",
            oneDisplay: [
                LayoutPiece(kind: .app(AppPiece(bundleID: LayoutLibrary.builtInBrowserBundleID)), rect: UnitRect(x: 0, y: 0, w: 8 * third, h: 1)),
                LayoutPiece(kind: .view(.activeSpeaker, startsHidden: false), rect: UnitRect(x: 8 * third, y: 0, w: 4 * third, h: 5 * third)),
                LayoutPiece(kind: .chat, rect: UnitRect(x: 8 * third, y: 5 * third, w: 4 * third, h: 7 * third)),
            ], camera: LayoutCamera(), share: ShareTarget())
        let meeting = LayoutTemplate(name: "Meeting and chat", starter: "meeting-chat",
                                     oneDisplay: [piece(.chat, 0.7, 0.3)])
        return LayoutLibrary(templates: [raj, teach, meeting], activeID: nil)
    }

    private func savedOldInstall() -> (UserDefaults, LayoutLibrary) {
        let d = defaults()
        let old = oldInstall()
        old.save(to: d)
        d.set(true, forKey: LayoutLibrary.shownToEveryoneMigratedKey)
        d.set(true, forKey: LayoutLibrary.appsShownMigratedKey)
        d.set(true, forKey: LayoutLibrary.rajRenamedKey)   // the Raj rename has its own once-only test (LayoutMigrationTests)
        return (d, old)
    }

    // R14.1, R12.2, R16.1: once, Raj stays, Teach is replaced, Meeting and chat becomes yours,
    // the new built-ins are added, None becomes Leave my windows alone, and nothing is deleted.
    func testExistingInstallGetsTheBuiltInsOnce() throws {
        let (d, old) = savedOldInstall()
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)

        XCTAssertEqual(lib.template(id: old.templates[0].id), old.templates[0], "Raj stays as the owner edited it")
        let teach = try XCTUnwrap(lib.template(id: old.templates[1].id))
        XCTAssertTrue(teach.isAsShipped, "Teach is replaced in place")
        let mine = try XCTUnwrap(lib.template(id: old.templates[2].id))
        XCTAssertNil(mine.starter)
        XCTAssertEqual(mine.name, "Meeting and chat")
        XCTAssertEqual(mine.oneDisplay, old.templates[2].oneDisplay, "kept as the owner's own")
        for key in [LayoutLibrary.talkToMeeting, LayoutLibrary.present, LayoutLibrary.roomLaptop, LayoutLibrary.leaveAlone] {
            XCTAssertNotNil(lib.templates.first { $0.starter == key }, key)
        }
        XCTAssertEqual(lib.active?.starter, LayoutLibrary.leaveAlone, "None maps to Leave my windows alone")
        XCTAssertTrue(Set(old.templates.map(\.id)).isSubset(of: Set(lib.templates.map(\.id))), "nothing deleted")
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.builtInsV2MigratedKey))
        XCTAssertEqual(LayoutLibrary.load(from: d), lib, "saved")
    }

    // R16.1: a second launch changes nothing, and the owner's later edits to the new Teach survive.
    func testTheMigrationRunsOnceAndKeepsLaterEdits() throws {
        let (d, old) = savedOldInstall()
        var lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        var teach = try XCTUnwrap(lib.template(id: old.templates[1].id))
        teach.oneDisplay = []
        lib.update(teach)
        lib.select(old.templates[0].id)
        lib.save(to: d)
        let again = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertEqual(again, lib)
        XCTAssertEqual(again.templates.count, lib.templates.count, "no second copy")
    }

    // R14.1: an edited Teach from a browser is kept as the owner's own layout.
    func testAnEditedTeachFromABrowserIsKeptAsYours() throws {
        let d = defaults()
        var old = oldInstall()
        old.templates[1].oneDisplay.removeLast()
        old.save(to: d)
        d.set(true, forKey: LayoutLibrary.shownToEveryoneMigratedKey)
        d.set(true, forKey: LayoutLibrary.appsShownMigratedKey)
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        let kept = try XCTUnwrap(lib.templates.first { $0.starter == nil && $0.oneDisplay == old.templates[1].oneDisplay })
        XCTAssertNotEqual(kept.id, old.templates[1].id)
        XCTAssertTrue(lib.template(id: old.templates[1].id)?.isAsShipped ?? false)
    }

    // R16.1: the key is set only after the save worked.
    func testAFailedSaveLeavesTheBuiltInsKeyUnset() {
        let d = defaults()
        var lib = oldInstall()
        lib.addStarters(notIn: Set(LayoutLibrary.originalStarterKeys))
        XCTAssertFalse(lib.migrateBuiltInsV2(defaults: d, save: { _ in false }))
        XCTAssertFalse(d.bool(forKey: LayoutLibrary.builtInsV2MigratedKey))
        XCTAssertTrue(lib.migrateBuiltInsV2(defaults: d, save: { _ in true }))
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.builtInsV2MigratedKey))
        XCTAssertFalse(lib.migrateBuiltInsV2(defaults: d, save: { _ in true }), "already done")
    }

    // R4.2, R12.1: the camera migration fills only layouts with no camera, so a new built-in keeps its own.
    func testTheCameraMigrationDoesNotOverwriteABuiltInsCamera() {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters() + [LayoutTemplate(name: "Old")])
        var global = LayoutCamera()
        global.shape = .square
        lib.migrateCameraAndShare(camera: global, share: ShareTarget(), defaults: defaults(), save: { _ in true })
        XCTAssertEqual(lib.templates.first { $0.starter == LayoutLibrary.talkToMeeting }?.camera?.shape, .roundedRectangle)
        XCTAssertEqual(lib.templates.last?.camera?.shape, .square)
    }

    // R12.2, R13.1: Leave my windows alone can't be deleted (there is always one active); the others can be restored.
    func testTheMenuOffersRestoreAndNeverDeletesTheFallback() {
        XCTAssertEqual(LayoutEditorRules.layoutMenu(isBuiltIn: true, canRestore: true, canDelete: false),
                       [.rename, .duplicate, .restoreOriginal])
        XCTAssertEqual(LayoutEditorRules.layoutMenu(isBuiltIn: true, canRestore: true),
                       [.rename, .duplicate, .restoreOriginal, .delete])
        let lib = LayoutLibrary(templates: LayoutLibrary.starters())
        XCTAssertFalse(lib.canDelete(lib.leaveAloneID!))
        XCTAssertTrue(lib.canDelete(lib.templates[0].id))
    }

    // R12.1: no built-in overlaps itself or breaks a minimum size, on a laptop and a large display.
    func testBuiltInGeometryIsValid() {
        for t in LayoutLibrary.starters() {
            var versions = [t.oneDisplay]
            if let two = t.twoDisplays { versions += [two.second] }
            for display in [CGSize(width: 1280, height: 720), CGSize(width: 2560, height: 1440)] {
                for pieces in versions {
                    for (i, p) in pieces.enumerated() {
                        let min = LayoutGeometry.minimumUnitSize(for: p.kind, display: display)
                        XCTAssertGreaterThanOrEqual(p.rect.w + 1e-9, min.w, "\(t.name) \(p.kind) too narrow")
                        XCTAssertGreaterThanOrEqual(p.rect.h + 1e-9, min.h, "\(t.name) \(p.kind) too short")
                        XCTAssertLessThanOrEqual(p.rect.maxX, 1 + 1e-9)
                        XCTAssertLessThanOrEqual(p.rect.maxY, 1 + 1e-9)
                        for q in pieces[(i + 1)...] { XCTAssertFalse(LayoutGeometry.overlaps(p.rect, q.rect), t.name) }
                    }
                }
            }
        }
    }

    // R13.2: Reset all falls back to Leave my windows alone (the view asks first).
    // R12.4 (Q22): the built-in stays clean; nothing can be added to it.
    func testNothingIsAddedToLeaveMyWindowsAlone() {
        let leave = starter(LayoutLibrary.leaveAlone)
        XCTAssertFalse(leave.canAdd(.chat, to: .main))
        XCTAssertTrue(starter(LayoutLibrary.present).canAdd(.view(.people, startsHidden: false), to: .main))
    }
}

// MARK: - Review fixes

extension BuiltInLayoutsTests {
    // R16, Q7: a former None user's own camera and share go to Leave my windows alone, which replaces None.
    func testNoneUsersKeepTheirCameraAndShareOnLeaveMyWindowsAlone() throws {
        let (d, _) = savedOldInstall()
        d.set("square", forKey: "webcamShape")
        d.set(0.31, forKey: "bubbleWidthFraction")
        d.set(0.07, forKey: "bubbleRightInset")
        d.set(0.55, forKey: "bubbleBottomInset")
        var share = ShareTarget()
        share.kind = .window
        share.appBundleID = "com.apple.Keynote"
        d.set(try JSONEncoder().encode(share), forKey: LayoutCamera.shareDefaultsKey)
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        let leave = try XCTUnwrap(lib.active)
        XCTAssertEqual(leave.starter, LayoutLibrary.leaveAlone)
        XCTAssertEqual(leave.camera, LayoutCamera.global(from: d))
        XCTAssertEqual(leave.camera?.shape, .square)
        XCTAssertEqual(leave.share, share)
    }

    private func oldTeachLibrary(_ edit: (inout LayoutTemplate) -> Void) -> (UserDefaults, LayoutLibrary) {
        let (d, old) = savedOldInstall()
        var lib = old
        edit(&lib.templates[1])
        lib.save(to: d)
        return (d, lib)
    }

    private func keptAsYours(_ d: UserDefaults, _ edited: LayoutLibrary) -> Bool {
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        return lib.templates.contains { $0.starter == nil && $0.name == "My " + edited.templates[1].name }
    }

    // R14.1: a renamed Teach from a browser is the owner's, not unedited.
    func testARenamedTeachIsKept() {
        let (d, lib) = oldTeachLibrary { $0.name = "Teach from a browser" + " (mine)" }
        let kept = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertTrue(kept.templates.contains { $0.starter == nil && $0.name.contains("(mine)") }, "\(lib.templates[1].name)")
    }

    // R14.1: a Teach with a changed share is the owner's.
    func testATeachWithAChangedShareIsKept() {
        let (d, lib) = oldTeachLibrary { $0.share?.kind = .whiteboard }
        XCTAssertTrue(keptAsYours(d, lib))
    }

    // R14.1: a Teach with a piece's eye turned off (hidden from everyone) is the owner's.
    func testATeachWithAnEyeTurnedOffIsKept() {
        let (d, lib) = oldTeachLibrary { $0.oneDisplay[2].showsToEveryone = false }
        XCTAssertTrue(keptAsYours(d, lib))
    }
}
