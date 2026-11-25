import XCTest

/// P9, Q28: the three built-in layouts, Leave my windows alone, Restore original and the existing-install migration.
final class BuiltInLayoutsTests: XCTestCase {
    private func starter(_ key: String) -> LayoutTemplate {
        LayoutLibrary.starters().first { $0.starter == key }!
    }

    // R12.1: each built-in owns its camera and share.
    func testEveryBuiltInOwnsACameraAndAShare() {
        for t in LayoutLibrary.starters() {
            XCTAssertNotNil(t.camera, t.name)
            XCTAssertNotNil(t.share, t.name)
        }
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

        lib.select(lib.templates[1].id)
        lib.delete(lib.templates[1].id)
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
        lib.select(lib.templates[1].id)
        XCTAssertNil(lib.forkLeaveAlone(), "only Leave my windows alone forks")
    }

    // R13.1 (Q6): Restore original puts back one built-in and leaves every other layout alone.
    func testRestoreOriginalResetsOnlyThatLayout() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let mine = lib.addBlank()
        var talk = try XCTUnwrap(lib.templates.first { $0.starter == LayoutLibrary.roomLaptop })
        let talkID = talk.id
        talk.oneDisplay = []
        talk.name = "Renamed"
        talk.camera?.shape = .square
        lib.update(talk)
        var teach = try XCTUnwrap(lib.templates.first { $0.starter == LayoutLibrary.rajMode })
        teach.name = "My teach"
        lib.update(teach)
        lib.select(talkID)
        let before = lib

        XCTAssertTrue(lib.canRestore(talkID))
        XCTAssertFalse(lib.canRestore(mine), "your own layout has no original")
        XCTAssertTrue(lib.restoreOriginal(talkID))

        let restored = try XCTUnwrap(lib.template(id: talkID))
        XCTAssertEqual(restored.name, "Room + laptop")
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

    // R14.1, R12.2, R16.1: once, Raj stays, Teach and Meeting and chat become yours,
    // the new built-ins are added, None becomes Leave my windows alone, and nothing is deleted.
    func testExistingInstallGetsTheBuiltInsOnce() throws {
        let (d, old) = savedOldInstall()
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)

        XCTAssertEqual(lib.template(id: old.templates[0].id), old.templates[0], "Raj stays as the owner edited it")
        let teach = try XCTUnwrap(lib.template(id: old.templates[1].id))
        XCTAssertNil(teach.starter, "Teach is the owner's own now (Q28)")
        XCTAssertEqual(teach.oneDisplay, old.templates[1].oneDisplay, "unchanged")
        let mine = try XCTUnwrap(lib.template(id: old.templates[2].id))
        XCTAssertNil(mine.starter)
        XCTAssertEqual(mine.name, "Meeting and chat")
        XCTAssertEqual(mine.oneDisplay, old.templates[2].oneDisplay, "kept as the owner's own")
        for key in [LayoutLibrary.roomLaptop, LayoutLibrary.leaveAlone] {
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
        XCTAssertEqual(lib.templates.first { $0.starter == LayoutLibrary.roomLaptop }?.camera?.shape, .roundedRectangle)
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
        XCTAssertTrue(lib.canDelete(lib.templates[1].id))
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
        XCTAssertTrue(starter(LayoutLibrary.rajMode).canAdd(.view(.people, startsHidden: false), to: .main))
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
}

// MARK: - Three built-ins (Q28, R39 to R42)

extension BuiltInLayoutsTests {
    private func suite() -> UserDefaults {
        let name = "three-builtins-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func markEarlierMigrationsDone(_ d: UserDefaults) {
        for k in [LayoutLibrary.oneArrangementMigratedKey, LayoutLibrary.builtInsV2MigratedKey, LayoutLibrary.shownToEveryoneMigratedKey,
                  LayoutLibrary.appsShownMigratedKey, LayoutLibrary.rajRenamedKey] { d.set(true, forKey: k) }
    }

    private func old(_ name: String, _ key: String?, chatAt x: Double) -> LayoutTemplate {
        LayoutTemplate(name: name, starter: key,
                       oneDisplay: [LayoutPiece(kind: .chat, rect: UnitRect(x: x, y: 0, w: 0.2, h: 1))],
                       camera: LayoutCamera(), share: ShareTarget())
    }

    // R39.1: Leave my windows alone, Raj San Mode, Room + laptop, in that order.
    func testTheThreeBuiltInsInOrder() {
        XCTAssertEqual(LayoutLibrary.builtIns().map(\.name), ["Leave my windows alone", "Raj San Mode", "Room + laptop"])
        XCTAssertEqual(LayoutLibrary.builtIns().compactMap(\.starter), ["leave-alone", "raj", "room-laptop"])
    }

    // R39.2: Reset to defaults gives exactly the three, Leave my windows alone active.
    func testResetGivesTheThreeWithLeaveMyWindowsAloneActive() {
        var lib = LayoutLibrary(templates: [old("Mine", nil, chatAt: 0.1)])
        lib.resetToDefaults()
        XCTAssertEqual(lib.templates.map(\.name), ["Leave my windows alone", "Raj San Mode", "Room + laptop"])
        XCTAssertEqual(lib.active?.starter, LayoutLibrary.leaveAlone)
    }

    // R39.3: Restore original and isAsShipped work for each of the three; a former Teach has no original.
    func testRestoreAndIsAsShippedWorkForTheThree() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.builtIns() + [old("Teach from a browser", nil, chatAt: 0.3)])
        for t in Array(lib.templates.prefix(3)) {
            XCTAssertTrue(t.isAsShipped, t.name)
            var edited = t
            edited.camera?.shape = .square
            edited.name = "Edited"
            lib.update(edited)
            XCTAssertFalse(try XCTUnwrap(lib.template(id: t.id)).isAsShipped)
            XCTAssertTrue(lib.canRestore(t.id), t.name)
            XCTAssertTrue(lib.restoreOriginal(t.id))
            XCTAssertTrue(try XCTUnwrap(lib.template(id: t.id)).isAsShipped, t.name)
        }
        XCTAssertFalse(lib.canRestore(lib.templates[3].id))
    }

    // R39.1: the New layout card stays at the end.
    func testTheNewLayoutCardIsLast() {
        let lib = LayoutLibrary(templates: LayoutLibrary.builtIns() + [old("Mine", nil, chatAt: 0.1)])
        let items = LayoutStripRules.items(for: lib)
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items.last, .newLayout)
        XCTAssertEqual(items.first, .layout(lib.templates[0].id))
    }

    // R40.1, R40.2: an install that had the six. The three built-ins first; Teach, Talk and Present are the
    // owner's own, unchanged; nothing is deleted; the active layout is kept.
    func testAnInstallWithTheSixKeepsTheRemovedThreeAsYours() throws {
        let d = suite()
        markEarlierMigrationsDone(d)
        let teach = old("Teach from a browser", "teach-browser", chatAt: 0.1)
        var talk = old("Talk to the meeting", "talk-to-meeting", chatAt: 0.2)
        talk.camera?.shape = .square
        let present = old("Present", "present", chatAt: 0.3)
        let room = LayoutLibrary.shipped(LayoutLibrary.roomLaptop)!
        let leave = LayoutLibrary.shipped(LayoutLibrary.leaveAlone)!
        let raj = LayoutLibrary.shipped(LayoutLibrary.rajMode)!
        let mine = old("Mine", nil, chatAt: 0.5)
        let before = LayoutLibrary(templates: [teach, talk, present, room, leave, raj, mine], activeID: talk.id)
        before.save(to: d)

        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: "https://example.test")
        XCTAssertEqual(lib.templates.map(\.name),
                       ["Leave my windows alone", "Raj San Mode", "Room + laptop",
                        "Teach from a browser", "Talk to the meeting", "Present", "Mine"])
        for original in [teach, talk, present] {
            var expected = original
            expected.starter = nil
            XCTAssertEqual(lib.template(id: original.id), expected, original.name)
        }
        XCTAssertEqual(lib.activeID, talk.id, "the active layout is kept")
        XCTAssertTrue(Set(before.templates.map(\.id)).isSubset(of: Set(lib.templates.map(\.id))), "nothing deleted")
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.threeBuiltInsMigratedKey))
        XCTAssertEqual(LayoutLibrary.load(from: d), lib, "saved")
    }

    // R40.3: an install that never ran the P9 migration ends the same way: no Talk or Present appear, the
    // old Teach is the owner's as it was, and the three built-ins lead.
    func testAnInstallFromBeforeP9EndsWithTheThreeToo() throws {
        let d = suite()
        let teach = old("Teach from a browser", "teach-browser", chatAt: 0.1)
        let meeting = old("Meeting and chat", "meeting-chat", chatAt: 0.7)
        LayoutLibrary(templates: [teach, meeting], activeID: teach.id).save(to: d)
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: "https://example.test")
        XCTAssertEqual(lib.templates.compactMap(\.starter), ["leave-alone", "raj", "room-laptop"], "only the three are tagged")
        XCTAssertEqual(lib.templates.map(\.name), ["Leave my windows alone", "Raj San Mode", "Room + laptop",
                                                    "Teach from a browser", "Meeting and chat"])
        var kept = teach
        kept.starter = nil
        XCTAssertEqual(lib.template(id: teach.id), kept)
        XCTAssertEqual(lib.activeID, teach.id)
    }

    // R40.3: a fresh install has the three and every key set.
    func testAFreshInstallHasTheThreeAndTheKeySet() {
        let d = suite()
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: "https://example.test")
        XCTAssertEqual(lib.templates.compactMap(\.starter), ["leave-alone", "raj", "room-laptop"])
        XCTAssertEqual(lib.active?.starter, LayoutLibrary.leaveAlone)
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.threeBuiltInsMigratedKey))
    }

    // R40.1, R40.3: the key follows a successful save; a second run changes nothing; a Raj the owner deleted stays gone.
    func testTheThreeBuiltInsMigrationFollowsASuccessfulSaveAndRunsOnce() {
        let d = suite()
        var lib = LayoutLibrary(templates: [old("Present", "present", chatAt: 0.3), LayoutLibrary.shipped(LayoutLibrary.leaveAlone)!])
        XCTAssertFalse(lib.migrateThreeBuiltIns(defaults: d, save: { _ in false }))
        XCTAssertFalse(d.bool(forKey: LayoutLibrary.threeBuiltInsMigratedKey))
        XCTAssertTrue(lib.migrateThreeBuiltIns(defaults: d, save: { _ in true }))
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.threeBuiltInsMigratedKey))
        XCTAssertEqual(lib.templates.map(\.name), ["Leave my windows alone", "Present"], "a deleted Raj stays deleted")
        let after = lib
        XCTAssertFalse(lib.migrateThreeBuiltIns(defaults: d, save: { _ in true }))
        XCTAssertEqual(lib, after)
    }

    // R41.1: only Leave my windows alone draws the camera, at its saved spot and shape's box.
    func testOnlyLeaveMyWindowsAloneDrawsACameraOnItsCard() throws {
        let leave = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.leaveAlone))
        XCTAssertEqual(LayoutStripRules.thumbnailCamera(for: leave), leave.camera)
        XCTAssertNil(LayoutStripRules.thumbnailCamera(for: try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.rajMode))))
        let size = CGSize(width: 112, height: 70)
        let r = LayoutStripRules.cameraRect(try XCTUnwrap(leave.camera), in: size)
        XCTAssertGreaterThan(r.width, 4)
        XCTAssertEqual(r.width / r.height, 16.0 / 9.0, accuracy: 0.15, "Rounded keeps the 16:9 box")
        XCTAssertGreaterThan(r.minX, size.width / 2, "right side")
        XCTAssertGreaterThan(r.minY, size.height / 2, "bottom")
        XCTAssertLessThanOrEqual(r.maxX, size.width)
        XCTAssertLessThanOrEqual(r.maxY, size.height)
    }

    // R42.1: a fade only on the side that has more.
    func testTheStripFadesOnlyWhereThereIsMore() {
        XCTAssertEqual(LayoutStripRules.fades(offset: 0, content: 500, viewport: 600), .init(leading: false, trailing: false), "all fits")
        XCTAssertEqual(LayoutStripRules.fades(offset: 0, content: 840, viewport: 700), .init(leading: false, trailing: true))
        XCTAssertEqual(LayoutStripRules.fades(offset: 70, content: 840, viewport: 700), .init(leading: true, trailing: true))
        XCTAssertEqual(LayoutStripRules.fades(offset: 140, content: 840, viewport: 700), .init(leading: true, trailing: false))
    }
}

// MARK: - Rounded camera by default (owner, 2026-11-26)

extension BuiltInLayoutsTests {
    // R43.1, R43.2: every built-in has the Rounded camera and keeps its own spot and size; Restore and Reset bring it back.
    func testTheBuiltInsDefaultToTheRoundedCameraAtTheirOwnSpots() throws {
        let spots = LayoutLibrary.builtIns().map { [$0.camera!.widthFraction, $0.camera!.rightInset, $0.camera!.bottomInset] }
        XCTAssertEqual(spots, [[0.12, 0.04, 0.06], [0.24, 0.045, 0.06], [0.12, 0.30, 0.06]], "spot and size unchanged")
        XCTAssertEqual(LayoutLibrary.builtIns().map { $0.camera?.shape }, [.roundedRectangle, .cutout, .roundedRectangle],
                       "Raj San Mode is the Cutout (owner correction)")
        let raj = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.rajMode)?.camera)
        XCTAssertEqual(raj.cutoutHeightFraction, 0.4)
        XCTAssertEqual(raj.cutoutRightInset, 0.02)
        XCTAssertLessThan(1 - raj.cutoutHeightFraction, 1.0, "bottom right")
        XCTAssertGreaterThanOrEqual(1 - raj.cutoutHeightFraction, 5.0 / 12, "clear of Chat's top, where its caption is")
        var lib = LayoutLibrary(templates: LayoutLibrary.builtIns())
        var edited = lib.templates[0]
        edited.camera?.shape = .square
        lib.update(edited)
        XCTAssertTrue(lib.restoreOriginal(edited.id))
        XCTAssertEqual(lib.template(id: edited.id)?.camera?.shape, .roundedRectangle)
        lib.resetToDefaults()
        XCTAssertEqual(lib.templates.map { $0.camera?.shape }, [.roundedRectangle, .cutout, .roundedRectangle])
    }

    // R43.3: a new blank layout is Rounded; a fork keeps the camera it was forked from; an old saved file keeps its circle.
    func testNewLayoutsAreRoundedButSavedOnesAndForksKeepTheirShape() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.builtIns())
        let blank = lib.addBlank()
        XCTAssertEqual(lib.template(id: blank)?.camera?.shape, .roundedRectangle)
        var circle = LayoutTemplate(name: "Mine", camera: LayoutCamera(), share: ShareTarget())
        circle.camera?.shape = .circle
        lib.templates.append(circle)
        let copy = try XCTUnwrap(lib.duplicate(circle.id))
        XCTAssertEqual(lib.template(id: copy)?.camera?.shape, .circle, "a duplicate keeps its source's camera")
        lib.select(lib.leaveAloneID)
        let fork = try XCTUnwrap(lib.forkLeaveAlone())
        XCTAssertEqual(lib.template(id: fork)?.camera, lib.template(id: lib.leaveAloneID!)?.camera)
        let old = try JSONDecoder().decode(LayoutCamera.self, from: Data("{}".utf8))
        XCTAssertEqual(old.shape, .circle, "saved layouts with no shape are not changed")
    }
}
