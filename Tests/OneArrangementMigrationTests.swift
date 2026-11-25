import XCTest

/// ADR 0002: R27 (the migration) on files as an older build wrote them.
final class OneArrangementMigrationTests: XCTestCase {
    private let site = "https://example.test/index.html"
    private let browser = LayoutPiece(kind: .app(AppPiece(bundleID: "com.example.browser")), rect: UnitRect(x: 0, y: 0, w: 0.75, h: 1))
    private let speaker = LayoutPiece(kind: .view(.activeSpeaker, startsHidden: false), rect: UnitRect(x: 0.75, y: 0, w: 0.25, h: 0.4))
    private let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0.75, y: 0.4, w: 0.25, h: 0.6))
    private let meeting = LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)

    /// Defaults holding an old library file, every other one-time migration already done.
    private func install(_ entries: [(LayoutTemplate, oldMain: [LayoutPiece]?)], active: UUID? = nil) -> UserDefaults {
        let name = "one-arrangement-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        d.set(LegacyFile.library(entries, activeID: active), forKey: LayoutLibrary.defaultsKey)
        d.set(true, forKey: LayoutLibrary.builtInsV2MigratedKey)
        d.set(true, forKey: LayoutLibrary.shownToEveryoneMigratedKey)
        d.set(true, forKey: LayoutLibrary.appsShownMigratedKey)
        d.set(true, forKey: LayoutLibrary.rajRenamedKey)
        d.set(LayoutLibrary.starters().compactMap(\.starter), forKey: LayoutLibrary.knownStartersKey)
        return d
    }

    /// A layout that had both versions: `oneDisplay` is the laptop-only one.
    private func both(_ name: String = "Mine", one: [LayoutPiece], second: [LayoutPiece]) -> LayoutTemplate {
        var t = LayoutTemplate(name: name, oneDisplay: one, camera: LayoutCamera(), share: ShareTarget())
        t.addSecondDisplay()
        t.setPieces(second, for: .second)
        return t
    }

    /// The same pieces with new ids, as the old two-display main held them.
    private func reissued(_ pieces: [LayoutPiece]) -> [LayoutPiece] {
        pieces.map { var p = $0; p.id = UUID(); return p }
    }

    private func load(_ d: UserDefaults) -> LayoutLibrary { LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site) }

    // R27.1, R27.3: an identical main makes no copy; one and second stay.
    func testAnIdenticalOldMainMakesNoCopy() throws {
        let t = both(one: [browser, chat], second: [meeting])
        let d = install([(t, oldMain: reissued([browser, chat]))])
        let lib = load(d)
        XCTAssertEqual(lib.templates.count, 1)
        XCTAssertEqual(lib.templates[0].pieces(for: .main).map(\.kind), [browser.kind, chat.kind])
        XCTAssertEqual(lib.templates[0].pieces(for: .second).map(\.kind), [meeting.kind])
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.oneArrangementMigratedKey))
    }

    // R27.2: a different main is saved as the owner's own layout, right after the original.
    func testADifferentOldMainIsKeptAsAnOldTwoDisplayCopy() throws {
        let t = both(one: [browser, speaker, chat], second: [meeting])
        let oldMain = [browser, LayoutPiece(kind: .chat, rect: UnitRect(x: 0.75, y: 0, w: 0.25, h: 1))]
        let other = LayoutTemplate(name: "After")
        let d = install([(t, oldMain: oldMain), (other, oldMain: nil)])
        let lib = load(d)
        XCTAssertEqual(lib.templates.map(\.name), ["Mine", "Mine (old two-display)", "After"])
        let original = lib.templates[0], copy = lib.templates[1]
        XCTAssertEqual(original.pieces(for: .main).map(\.kind), [browser.kind, speaker.kind, chat.kind], "oneDisplay stays main")
        XCTAssertEqual(original.pieces(for: .second).map(\.kind), [meeting.kind])
        XCTAssertNil(copy.starter)
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.pieces(for: .main).map(\.rect), oldMain.map(\.rect), "the old main is the copy's main")
        XCTAssertEqual(copy.pieces(for: .main).map(\.kind), oldMain.map(\.kind))
        XCTAssertEqual(copy.pieces(for: .second).map(\.kind), [meeting.kind], "the same second")
        XCTAssertEqual(copy.camera, original.camera)
        XCTAssertEqual(copy.share, original.share)
        XCTAssertEqual(lib.active?.id, lib.leaveAloneID, "the active layout is not moved")
    }

    // R27.2: "settings" count: an eye turned off in the old main is a difference.
    func testADifferentEyeInTheOldMainIsADifference() throws {
        let t = both(one: [browser, chat], second: [meeting])
        var hiddenChat = chat; hiddenChat.showsToEveryone = false
        let lib = load(install([(t, oldMain: [browser, hiddenChat])]))
        XCTAssertEqual(lib.templates.count, 2)
    }

    // R27.3: no second display, nothing to keep.
    func testALayoutWithNoTwoDisplayVersionMakesNoCopy() {
        let lib = load(install([(LayoutTemplate(name: "Solo", oneDisplay: [browser, chat]), oldMain: nil)]))
        XCTAssertEqual(lib.templates.count, 1)
        XCTAssertNil(lib.templates[0].twoDisplays)
    }

    // R27.5: once. The result is saved, a second launch does not copy again, and a later old-shaped
    // file does not either while the key is set.
    func testItRunsOnceAndSavesTheResult() throws {
        let t = both(one: [browser, speaker, chat], second: [meeting])
        let d = install([(t, oldMain: [browser, chat])])
        let first = load(d)
        XCTAssertEqual(first.templates.count, 2)
        XCTAssertEqual(LayoutLibrary.load(from: d), first, "saved")
        XCTAssertEqual(load(d), first, "a second launch changes nothing")
        d.set(LegacyFile.library([(t, oldMain: [browser, chat])], activeID: nil), forKey: LayoutLibrary.defaultsKey)
        XCTAssertEqual(load(d).templates.count, 1, "the key is set: nothing is copied again")
    }

    // R27.5: the key follows a successful save only.
    func testAFailedSaveLeavesTheKeyUnsetAndTheNextRunTriesAgain() {
        let t = both(one: [browser, speaker, chat], second: [meeting])
        let d = install([(t, oldMain: [browser, chat])])
        var lib = try! JSONDecoder().decode(LayoutLibrary.self, from: d.data(forKey: LayoutLibrary.defaultsKey)!)
        XCTAssertFalse(lib.migrateOneArrangement(defaults: d, save: { _ in false }))
        XCTAssertFalse(d.bool(forKey: LayoutLibrary.oneArrangementMigratedKey))
        XCTAssertEqual(load(d).templates.count, 2, "the file was not touched, so the next launch still has the old main")
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.oneArrangementMigratedKey))
    }

    // R27.4: Raj San Mode exactly as the last build shipped it becomes the new one in place.
    func testAnUntouchedOldRajSanModeIsReplacedInPlaceWithNoCopy() throws {
        let raj = oldShippedRaj()
        let d = install([(raj.template, oldMain: raj.oldMain)])
        let lib = load(d)
        XCTAssertEqual(lib.templates.count, 1)
        XCTAssertEqual(lib.templates[0].id, raj.template.id)
        XCTAssertTrue(lib.templates[0].isAsShipped)
    }

    // R27.4, R28.1: an edited Raj San Mode keeps its main, and its old two-display main is kept as a copy.
    func testAnEditedRajSanModeKeepsItsMainAndTheOldTwoDisplayCopy() throws {
        var raj = oldShippedRaj()
        raj.template.setPieces([raj.template.oneDisplay[0]], for: .main)
        let lib = load(install([(raj.template, oldMain: raj.oldMain)]))
        XCTAssertEqual(lib.templates.map(\.name), ["Raj San Mode", "Raj San Mode (old two-display)"])
        XCTAssertEqual(lib.templates[0].starter, LayoutLibrary.rajMode)
        XCTAssertNil(lib.templates[1].starter)
        XCTAssertEqual(lib.templates[0].pieces(for: .main).count, 1)
    }

    // R27.1: an existing install where the main differs, with the built-ins around it.
    func testAnExistingInstallWhereTheMainDiffersLosesNothing() throws {
        let raj = oldShippedRaj()
        let room = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.roomLaptop))
        let mine = both("Class", one: [browser, speaker, chat], second: [meeting])
        let lib = load(install([(raj.template, oldMain: raj.oldMain),
                                (room, oldMain: room.oneDisplay),
                                (mine, oldMain: [browser, chat])]))
        XCTAssertEqual(lib.templates.map(\.name), ["Raj San Mode", "Room + laptop", "Class", "Class (old two-display)"])
        XCTAssertTrue(lib.templates[1].isAsShipped, "Room + laptop's main was the same")
        let kept = lib.templates[3]
        XCTAssertEqual(kept.pieces(for: .main).map(\.kind), [browser.kind, chat.kind])
        XCTAssertEqual(kept.pieces(for: .second).map(\.kind), [meeting.kind])
    }

    // R27.6
    func testANewInstallHasNothingToMigrateAndTheKeySet() {
        let name = "one-arrangement-new-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let lib = load(d)
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.oneArrangementMigratedKey))
        XCTAssertFalse(lib.templates.contains { $0.name.contains("old two-display") })
    }

    /// Raj San Mode as the build before this one shipped it.
    private func oldShippedRaj() -> (template: LayoutTemplate, oldMain: [LayoutPiece]) {
        let third = 1.0 / 12
        let b = LayoutPiece(kind: .app(AppPiece(bundleID: LayoutLibrary.builtInBrowserBundleID)), rect: UnitRect(x: 0, y: 0, w: 9 * third, h: 1))
        let s = LayoutPiece(kind: .view(.activeSpeaker, startsHidden: false), rect: UnitRect(x: 9 * third, y: 0, w: 3 * third, h: 5 * third))
        let c = LayoutPiece(kind: .chat, rect: UnitRect(x: 9 * third, y: 5 * third, w: 3 * third, h: 7 * third))
        var t = LayoutTemplate(name: "Raj San Mode", starter: LayoutLibrary.rajMode, oneDisplay: [b, s, c],
                               camera: LayoutCamera(), share: ShareTarget())
        t.addSecondDisplay()
        t.setPieces([LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)], for: .second)
        let oldMain = [b, LayoutPiece(kind: .chat, rect: UnitRect(x: 9 * third, y: 0, w: 3 * third, h: 1))]
        return (t, oldMain)
    }
}
