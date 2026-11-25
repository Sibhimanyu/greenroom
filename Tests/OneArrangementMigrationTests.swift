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
        d.set(true, forKey: LayoutLibrary.threeBuiltInsMigratedKey)
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

    // R27.4: Raj exactly as an earlier build shipped it becomes the new one in place: main's Meeting window
    // piece (origin/main) or the Active speaker view (the build in between).
    func testAnUntouchedOldRajSanModeIsReplacedInPlaceWithNoCopy() throws {
        for middle in [OldRajMiddle.meetingWindow, .activeSpeaker] {
            let raj = oldShippedRaj(middle)
            let d = install([(raj.template, oldMain: raj.oldMain)])
            let lib = load(d)
            XCTAssertEqual(lib.templates.count, 1, "\(middle)")
            XCTAssertEqual(lib.templates[0].id, raj.template.id)
            var asShipped = lib.templates[0]
            asShipped.name = "Raj San Mode"   // the rename is its own migration, done already here
            asShipped.camera = LayoutLibrary.shipped(LayoutLibrary.rajMode)?.camera   // the owner's own camera shape is kept (R43)
            XCTAssertTrue(asShipped.isAsShipped, "the pieces are the new Raj San Mode (\(middle))")
        }
    }

    // R27.4 on a real upgrade: the library exactly as origin/main wrote it. The untouched Raj Mode becomes the
    // new Raj San Mode with no extra layout; the owner's own edited layouts keep their old two-display copies.
    func testALibraryAsOriginMainWroteItMigratesRajWithNoExtraLayout() throws {
        let suite = "one-arrangement-origin-main-\(UUID().uuidString)"
        let d = OriginMainLibraryFixture.install(suite: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let lib = load(d)
        XCTAssertEqual(lib.templates.map(\.name), [
            "Leave my windows alone", "Raj San Mode", "Room + laptop",
            "My teaching", "My teaching (old two-display)", "Mine two", "Mine two (old two-display)", "Just meeting",
        ])
        let raj = try XCTUnwrap(lib.templates.first { $0.starter == LayoutLibrary.rajMode })
        XCTAssertEqual(raj.id, UUID(uuidString: "6DE73CCD-5DDF-4E08-AEAD-3869B2BBC49B"), "replaced in place")
        let fresh = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.rajMode))
        func shown(_ p: [LayoutPiece]) -> [LayoutPiece] { p.map { var q = $0; q.showsToEveryone = true; return q } }
        XCTAssertTrue(LayoutLibrary.sameArrangement(shown(raj.pieces(for: .main)), shown(fresh.oneDisplay)), "the new Raj San Mode's main")
        XCTAssertTrue(LayoutLibrary.sameArrangement(shown(raj.pieces(for: .second)), shown(fresh.twoDisplays?.second ?? [])))
        XCTAssertEqual(lib.activeID, UUID(uuidString: "E629DAD6-93AE-4234-BD4A-5F0246FEB5AB"), "the active layout is kept")
    }

    // R27.4, R28.1: an edited Raj San Mode keeps its main, and its old two-display main is kept as a copy.
    func testAnEditedRajSanModeKeepsItsMainAndTheOldTwoDisplayCopy() throws {
        var raj = oldShippedRaj()
        raj.template.setPieces([raj.template.oneDisplay[0]], for: .main)
        let lib = load(install([(raj.template, oldMain: raj.oldMain)]))
        XCTAssertEqual(lib.templates.map(\.name), ["Raj Mode", "Raj Mode (old two-display)"])
        XCTAssertEqual(lib.templates[0].starter, LayoutLibrary.rajMode)
        XCTAssertNil(lib.templates[1].starter)
        XCTAssertEqual(lib.templates[0].pieces(for: .main).count, 1)
    }

    // ADR 0002: the active layout stays active, whether it is kept with a copy beside it or replaced in place.
    func testTheActiveLayoutSurvivesTheMigration() throws {
        let mine = both("Class", one: [browser, speaker, chat], second: [meeting])
        let withCopy = load(install([(mine, oldMain: [browser, chat])], active: mine.id))
        XCTAssertEqual(withCopy.templates.count, 2, "a copy was made")
        XCTAssertEqual(withCopy.activeID, mine.id)
        XCTAssertEqual(withCopy.active?.name, "Class")

        let raj = oldShippedRaj()
        let replaced = load(install([(raj.template, oldMain: raj.oldMain)], active: raj.template.id))
        XCTAssertEqual(replaced.activeID, raj.template.id)
    }

    // R27.1: an existing install where the main differs, with the built-ins around it.
    func testAnExistingInstallWhereTheMainDiffersLosesNothing() throws {
        let raj = oldShippedRaj()
        let room = try XCTUnwrap(LayoutLibrary.shipped(LayoutLibrary.roomLaptop))
        let mine = both("Class", one: [browser, speaker, chat], second: [meeting])
        let lib = load(install([(raj.template, oldMain: raj.oldMain),
                                (room, oldMain: room.oneDisplay),
                                (mine, oldMain: [browser, chat])]))
        XCTAssertEqual(lib.templates.map(\.name), ["Raj Mode", "Room + laptop", "Class", "Class (old two-display)"])
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

    /// What sat top right on main in an old shipped Raj: origin/main's Meeting window, or the Active speaker
    /// view of the build in between.
    private enum OldRajMiddle { case meetingWindow, activeSpeaker }

    /// Raj Mode as origin/main (a2a8e99) shipped it, with the literal values its builder wrote (5 / 12 for the
    /// top right piece's height and Chat's top, every eye off), not the detector's own arithmetic.
    private func oldShippedRaj(_ middle: OldRajMiddle = .meetingWindow) -> (template: LayoutTemplate, oldMain: [LayoutPiece]) {
        let third = 1.0 / 12
        let b = LayoutPiece(kind: .app(AppPiece(bundleID: LayoutLibrary.builtInBrowserBundleID)), rect: UnitRect(x: 0, y: 0, w: 9 * third, h: 1))
        let kind: LayoutPiece.Kind = middle == .meetingWindow
            ? .meeting(fillsDisplay: false, startsHidden: false) : .view(.activeSpeaker, startsHidden: false)
        let s = LayoutPiece(kind: kind, rect: UnitRect(x: 9 * third, y: 0, w: 3 * third, h: 5 * third))
        let c = LayoutPiece(kind: .chat, rect: UnitRect(x: 9 * third, y: 5 * third, w: 3 * third, h: 7 * third))
        var t = LayoutTemplate(name: "Raj Mode", starter: LayoutLibrary.rajMode, oneDisplay: [b, s, c],
                               camera: LayoutCamera(), share: ShareTarget())
        t.addSecondDisplay()
        t.setPieces([LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)], for: .second)
        let oldMain = [b, LayoutPiece(kind: .chat, rect: UnitRect(x: 9 * third, y: 0, w: 3 * third, h: 1))]
        func off(_ p: [LayoutPiece]) -> [LayoutPiece] { p.map { var q = $0; q.showsToEveryone = false; return q } }
        t.oneDisplay = off(t.oneDisplay)
        t.setPieces(off(t.pieces(for: .second)), for: .second)
        return (t, off(oldMain))
    }
}
