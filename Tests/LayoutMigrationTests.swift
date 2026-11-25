import XCTest

final class LayoutMigrationTests: XCTestCase {
    private let site = "https://example.test/index.html"

    private func defaults(_ values: [String: Any] = [:]) -> UserDefaults {
        let name = "layout-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }

    private func workspaceJSON(_ json: String) -> Data { Data(json.utf8) }

    // MARK: Migration

    // MARK: Shown-to-everyone flip

    private func hiddenLibrary() -> LayoutLibrary {
        let hidden = { (k: LayoutPiece.Kind) in LayoutPiece(kind: k, rect: .full, showsToEveryone: false) }
        let t = LayoutTemplate(name: "Mine",
                               oneDisplay: [hidden(.meeting(fillsDisplay: false, startsHidden: false)), hidden(.chat),
                                            hidden(.view(.activeSpeaker, startsHidden: false)),
                                            hidden(.app(AppPiece(bundleID: "com.apple.Safari")))],
                               twoDisplays: TwoDisplay(main: [hidden(.chat)], second: [hidden(.meeting(fillsDisplay: true, startsHidden: false))]))
        return LayoutLibrary(templates: [t])
    }

    // The Greenroom-window flip leaves other apps to their own migration (below); it no longer pins Safari to false.
    func testFlipShowsEveryPieceThatOffersTheSwitch() {
        var lib = hiddenLibrary()
        lib.showEverythingToEveryone()
        let t = lib.templates[0]
        for p in t.oneDisplay + t.twoDisplays!.main + t.twoDisplays!.second where p.kind.app == nil {
            XCTAssertTrue(p.showsToEveryone)
        }
    }

    // R7.1, R16: pieces saved before 02169d9 carry 📡 false for apps; once, every app piece goes on so day one looks the same.
    func testExistingAppPiecesGoOnceAndALaterOffSurvives() {
        let d = defaults()
        hiddenLibrary().save(to: d)
        d.set(true, forKey: LayoutLibrary.shownToEveryoneMigratedKey)   // the old flip already ran
        var lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        var mine = lib.templates.first { $0.name == "Mine" }!
        XCTAssertTrue(mine.oneDisplay[3].showsToEveryone, "Safari 📡 on after the migration")
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.appsShownMigratedKey))
        mine.oneDisplay[3].showsToEveryone = false
        lib.update(mine)
        lib.save(to: d)
        let again = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertFalse(again.templates.first { $0.name == "Mine" }!.oneDisplay[3].showsToEveryone)
    }

    func testFlipRunsOnceAndALaterHideSurvives() {
        let d = defaults()
        hiddenLibrary().save(to: d)
        var lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.shownToEveryoneMigratedKey))
        XCTAssertTrue(lib.templates.first { $0.name == "Mine" }!.oneDisplay[1].showsToEveryone)
        var mine = lib.templates.first { $0.name == "Mine" }!
        mine.oneDisplay[1].showsToEveryone = false
        lib.update(mine)
        lib.save(to: d)
        let again = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertFalse(again.templates.first { $0.name == "Mine" }!.oneDisplay[1].showsToEveryone)
    }

    func testFreshInstallRecordsTheFlipAsDone() {
        let d = defaults()
        _ = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertTrue(d.bool(forKey: LayoutLibrary.shownToEveryoneMigratedKey))
    }

    func testDefaultSettingsMakeOnlyStartersAndNoneIsActive() {
        let d = defaults()
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertEqual(lib.templates.map(\.name), ["Raj Mode", "Teach from a browser", "Meeting and chat"])
        XCTAssertNil(lib.activeID)
        XCTAssertNotNil(d.data(forKey: "layoutLibrary"), "written back so it runs once")
    }

    func testUntouchedSettingsKeysStillMeanDefault() {
        let d = defaults(["mainAppBundleID": "com.google.Chrome", "mainAppURL": site, "mainAppOnStart": true,
                          "peopleViewOnStart": false, "browserClosesOnStop": false])
        d.set(workspaceJSON(#"{"mainFraction":0.5,"mainOnLeft":true,"sideShowsZoomTile":true,"sideShowsChat":true,"zoomSlotRatio":0.4,"arrangeWindowsOnStart":false}"#),
              forKey: "workspaceLayout")
        XCTAssertNil(LegacyLayoutSettings.read(from: d, defaultSiteURL: site).asTemplate())
    }

    func testThisMacsSettings() throws {
        // What `defaults read` showed on the owner's Mac: a Primeum browser at
        // 75%, closes on stop, a participant view on start, arrange NOT on.
        let d = defaults(["mainAppBundleID": "com.primeum.Browser", "mainAppURL": "https://www.bookfusion.com",
                          "browserClosesOnStop": true, "peopleViewOnStart": true,
                          "peopleViewDisplayUUID": "", "speakerTileShortcutEnabled": true])
        d.set(workspaceJSON(#"{"zoomSlotRatio":0.29933763586956524,"sideShowsZoomTile":true,"mainOnLeft":true,"mainFraction":0.75,"sideShowsChat":true}"#),
              forKey: "workspaceLayout")
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertEqual(lib.templates.map(\.name), ["Raj Mode", "Teach from a browser", "Meeting and chat", "Your previous layout"])
        XCTAssertNil(lib.activeID, "arrange was off, so None")
        let t = try XCTUnwrap(lib.templates.last)

        XCTAssertEqual(t.oneDisplay.count, 3)
        let app = try XCTUnwrap(t.oneDisplay.first { $0.kind.app != nil })
        XCTAssertEqual(app.kind.app?.bundleID, "com.primeum.Browser")
        XCTAssertEqual(app.kind.app?.url, "https://www.bookfusion.com")
        XCTAssertEqual(app.kind.app?.closesOnStop, true)
        XCTAssertEqual(app.kind.app?.opensAtStart, true)
        XCTAssertEqual(app.rect, UnitRect(x: 0, y: 0, w: 0.75, h: 1))
        let meeting = try XCTUnwrap(t.oneDisplay.first { $0.kind.isMeeting })
        XCTAssertEqual(meeting.rect.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(meeting.rect.w, 0.25, accuracy: 1e-9)
        XCTAssertEqual(meeting.rect.h, 0.29933763586956524, accuracy: 1e-9)
        let chat = try XCTUnwrap(t.oneDisplay.first { $0.kind.isChat })
        XCTAssertEqual(chat.rect.y, meeting.rect.maxY, accuracy: 1e-9)
        XCTAssertEqual(chat.rect.maxY, 1, accuracy: 1e-9)

        let two = try XCTUnwrap(t.twoDisplays)
        XCTAssertEqual(two.main.count, 2)   // app + full-column chat
        XCTAssertEqual(two.main.first { $0.kind.isChat }?.rect, UnitRect(x: 0.75, y: 0, w: 0.25, h: 1))
        XCTAssertEqual(two.second.count, 1)
        XCTAssertEqual(two.second.first?.kind, .meeting(fillsDisplay: true, startsHidden: false))
    }

    func testArrangeOnMakesThePreviousLayoutActive() {
        let d = defaults(["mainAppBundleID": "com.apple.Safari"])
        d.set(workspaceJSON(#"{"arrangeWindowsOnStart":true,"mainOnLeft":false,"mainFraction":0.6}"#), forKey: "workspaceLayout")
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertEqual(lib.active?.name, "Your previous layout")
        let app = lib.active?.oneDisplay.first { $0.kind.app != nil }
        XCTAssertEqual(app?.rect.x ?? -1, 0.4, accuracy: 1e-9)   // app on the right
    }

    func testSideColumnToggles() throws {
        var s = LegacyLayoutSettings()
        s.sideShowsZoomTile = false
        let t = try XCTUnwrap(s.asTemplate())
        XCTAssertFalse(t.oneDisplay.contains { $0.kind.isMeeting })
        XCTAssertEqual(t.oneDisplay.first { $0.kind.isChat }?.rect.h ?? 0, 1, accuracy: 1e-9)
    }

    func testOldKeysAreLeftInPlace() {
        let d = defaults(["mainAppBundleID": "com.apple.Safari", "peopleViewOnStart": true])
        _ = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertEqual(d.string(forKey: "mainAppBundleID"), "com.apple.Safari")
        XCTAssertEqual(d.bool(forKey: "peopleViewOnStart"), true)
    }

    func testMigrationRunsOnce() {
        let d = defaults(["mainAppBundleID": "com.apple.Safari"])
        var lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        lib.delete(lib.templates.last!.id)
        lib.save(to: d)
        d.set("com.apple.Notes", forKey: "mainAppBundleID")
        XCTAssertEqual(LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site), lib)
    }

    // MARK: Storage

    func testRoundTrip() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        lib.templates[0].addTwoDisplayVersion()
        lib.select(lib.templates[0].id)
        let data = try JSONEncoder().encode(lib)
        XCTAssertEqual(try JSONDecoder().decode(LayoutLibrary.self, from: data), lib)
    }

    func testPartialJSONDecodesWhatItCan() throws {
        let json = #"{"templates":[{"name":"Only a name"},{"id":"not-a-uuid","oneDisplay":[{"kind":{"type":"chat"}},{"kind":{"type":"mystery"}},{"rect":{"x":0.1}}]}],"activeID":"00000000-0000-0000-0000-000000000000"}"#
        let lib = try JSONDecoder().decode(LayoutLibrary.self, from: Data(json.utf8))
        XCTAssertEqual(lib.templates.count, 2)
        XCTAssertEqual(lib.templates[0].name, "Only a name")
        XCTAssertEqual(lib.templates[1].name, "Untitled layout")
        XCTAssertEqual(lib.templates[1].oneDisplay.count, 1, "unknown and kind-less pieces are dropped")
        XCTAssertNil(lib.activeID, "an active id that matches nothing means None")
        XCTAssertEqual(try JSONDecoder().decode(LayoutLibrary.self, from: Data("{}".utf8)).templates.count, 0)
    }

    // MARK: Editing

    private func starter(_ key: String) -> LayoutTemplate {
        LayoutLibrary.starters().first { $0.starter == key }!
    }

    func testStartersAreTheDocumentedShapes() {
        let s = LayoutLibrary.starters()
        XCTAssertEqual(s.compactMap(\.starter), [LayoutLibrary.rajMode, LayoutLibrary.teachFromBrowser, LayoutLibrary.meetingAndChat])
        let teach = starter(LayoutLibrary.teachFromBrowser)
        XCTAssertEqual(teach.oneDisplay.map(\.rect.w).map { ($0 * 12).rounded() }, [8, 4, 4])
        XCTAssertEqual(teach.oneDisplay[1].rect.h * 12, 5, accuracy: 1e-9)
        XCTAssertEqual(starter(LayoutLibrary.meetingAndChat).oneDisplay.map(\.rect.w).map { ($0 * 12).rounded() }, [9, 3])
        // The one-display speaker is the Active speaker view, never a Meeting window.
        for t in s {
            XCTAssertFalse(t.oneDisplay.contains { $0.kind.isMeeting }, t.name)
            XCTAssertEqual(t.oneDisplay.filter { $0.kind.view == .activeSpeaker }.count, 1, t.name)
        }
    }

    func testRajModeGeometryIsValid() throws {
        let raj = starter(LayoutLibrary.rajMode)
        func cells(_ r: UnitRect) -> [Int] { [r.x, r.y, r.w, r.h].map { Int(($0 * 12).rounded()) } }
        XCTAssertEqual(raj.oneDisplay.map { cells($0.rect) }, [[0, 0, 9, 12], [9, 0, 3, 5], [9, 5, 3, 7]])
        XCTAssertEqual(raj.oneDisplay.first?.kind.app?.bundleID, LayoutLibrary.builtInBrowserBundleID)
        XCTAssertEqual(raj.oneDisplay.first?.kind.app?.opensAtStart, true)
        XCTAssertEqual(raj.oneDisplay[1].kind, .view(.activeSpeaker, startsHidden: false))
        XCTAssertTrue(raj.oneDisplay[2].kind.isChat)
        let two = try XCTUnwrap(raj.twoDisplays)
        XCTAssertEqual(two.main.map { cells($0.rect) }, [[0, 0, 9, 12], [9, 0, 3, 12]])
        XCTAssertEqual(two.second.first?.kind, .meeting(fillsDisplay: true, startsHidden: false))
        XCTAssertEqual(two.second.first?.rect, .full)

        // No overlap and the minimums hold, on a laptop and a large display.
        let versions = [raj.oneDisplay, two.main, two.second]
        for display in [CGSize(width: 1280, height: 720), CGSize(width: 1440, height: 900), CGSize(width: 2560, height: 1440)] {
            for pieces in versions {
                for (i, p) in pieces.enumerated() {
                    let min = LayoutGeometry.minimumUnitSize(for: p.kind, display: display)
                    XCTAssertGreaterThanOrEqual(p.rect.w + 1e-9, min.w, "\(p.kind) too narrow on \(display)")
                    XCTAssertGreaterThanOrEqual(p.rect.h + 1e-9, min.h, "\(p.kind) too short on \(display)")
                    XCTAssertLessThanOrEqual(p.rect.maxX, 1 + 1e-9)
                    XCTAssertLessThanOrEqual(p.rect.maxY, 1 + 1e-9)
                    for q in pieces[(i + 1)...] {
                        XCTAssertFalse(LayoutGeometry.overlaps(p.rect, q.rect))
                    }
                }
            }
        }
    }

    func testResetToDefaultsReplacesEverythingAndMeansNone() {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let mine = lib.addBlank()
        var previous = LayoutTemplate(name: "Your previous layout")
        previous.starter = nil
        lib.templates.append(previous)
        lib.templates[0].oneDisplay = []
        lib.delete(lib.templates[1].id)
        lib.select(mine)
        XCTAssertEqual(lib.userLayoutCount, 2)
        lib.resetToDefaults()
        XCTAssertEqual(lib.userLayoutCount, 0)
        XCTAssertNil(lib.activeID)
        XCTAssertNil(lib.template(id: mine))
        XCTAssertEqual(lib.templates.map(\.starter), LayoutLibrary.starters().map(\.starter))
        XCTAssertEqual(lib.templates.map(\.oneDisplay.count), LayoutLibrary.starters().map(\.oneDisplay.count))
        XCTAssertNotNil(lib.templates.first { $0.starter == LayoutLibrary.rajMode }, "Raj Mode is back")
    }

    func testRajModeIsAppendedOnceToAnExistingLibrary() throws {
        // A library saved before Raj Mode: the two original starters, one deleted, one of yours.
        var old = LayoutLibrary(templates: LayoutLibrary.starters().filter { $0.starter != LayoutLibrary.rajMode })
        old.delete(old.templates.first { $0.starter == LayoutLibrary.meetingAndChat }!.id)
        let mine = old.addBlank()
        old.select(mine)
        let d = defaults()
        old.save(to: d)

        let first = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertEqual(first.templates.first?.starter, LayoutLibrary.rajMode, "right after None")
        XCTAssertEqual(first.templates.compactMap(\.starter), [LayoutLibrary.rajMode, LayoutLibrary.teachFromBrowser])
        XCTAssertEqual(first.activeID, mine, "the Start layout is not changed")
        XCTAssertNil(first.templates.first { $0.starter == LayoutLibrary.meetingAndChat }, "a deleted starter stays deleted")

        // Deleting Raj Mode sticks across launches.
        var again = first
        again.delete(again.templates.first { $0.starter == LayoutLibrary.rajMode }!.id)
        again.save(to: d)
        let second = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertNil(second.templates.first { $0.starter == LayoutLibrary.rajMode })
        XCTAssertEqual(second, again)
    }

    func testFreshInstallRecordsKnownStartersSoDeletedOnesStayGone() {
        let d = defaults()
        var lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        XCTAssertEqual(lib.templates.compactMap(\.starter).count, 3)
        lib.delete(lib.templates.first { $0.starter == LayoutLibrary.rajMode }!.id)
        lib.save(to: d)
        XCTAssertNil(LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site).templates.first { $0.starter == LayoutLibrary.rajMode })
    }

    func testDeletingTheActiveTemplateMeansNone() {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        lib.select(lib.templates[0].id)
        lib.delete(lib.templates[0].id)
        XCTAssertNil(lib.activeID)
    }

    func testDuplicateGivesFreshIDs() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let copyID = try XCTUnwrap(lib.duplicate(lib.templates[0].id))
        let copy = try XCTUnwrap(lib.template(id: copyID))
        XCTAssertEqual(copy.name, "Raj Mode copy")
        XCTAssertNil(copy.starter)
        XCTAssertTrue(Set(copy.oneDisplay.map(\.id)).isDisjoint(with: lib.templates[0].oneDisplay.map(\.id)))
    }

    func testRenameIgnoresEmptyNames() {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let id = lib.templates[1].id   // rename an ordinary one
        lib.rename(id, to: "   ")
        XCTAssertEqual(lib.templates[1].name, "Teach from a browser")
        lib.rename(id, to: "  Mine ")
        XCTAssertEqual(lib.templates[1].name, "Mine")
    }

    func testPieceLimits() {
        var t = LayoutTemplate(name: "t")
        XCTAssertTrue(t.canAdd(.meeting(fillsDisplay: false, startsHidden: false), to: .one))
        t.oneDisplay.append(LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: false), rect: .full))
        XCTAssertFalse(t.canAdd(.meeting(fillsDisplay: false, startsHidden: false), to: .one))
        t.oneDisplay.append(LayoutPiece(kind: .app(AppPiece(bundleID: "a")), rect: .full))
        XCTAssertFalse(t.canAdd(.app(AppPiece(bundleID: "a")), to: .one), "one piece per app")
        for id in ["b", "c", "d"] { t.oneDisplay.append(LayoutPiece(kind: .app(AppPiece(bundleID: id)), rect: .full)) }
        XCTAssertFalse(t.canAdd(.app(AppPiece(bundleID: "e")), to: .one), "four apps at most")
    }

    func testTwoDisplayVersionMovesMeetingToTheSecond() throws {
        var t = LayoutLibrary.starters().first { $0.starter == LayoutLibrary.teachFromBrowser }!
        t.addTwoDisplayVersion()
        let two = try XCTUnwrap(t.twoDisplays)
        XCTAssertFalse(two.main.contains { $0.kind.isMeeting })
        XCTAssertEqual(two.main.first { $0.kind.isChat }?.rect.h ?? 0, 1, accuracy: 1e-9, "chat takes the column")
        XCTAssertEqual(two.second.first?.kind, .meeting(fillsDisplay: true, startsHidden: false))
        XCTAssertFalse(t.canAdd(.meeting(fillsDisplay: false, startsHidden: false), to: .main), "one Meeting across the pair")
    }

    func testReplaceAppSwapsOnlyThatAppInEveryVersion() {
        var t = LayoutLibrary.starters().first { $0.starter == LayoutLibrary.teachFromBrowser }!
        t.addTwoDisplayVersion()
        XCTAssertEqual(t.firstAppBundleID, LayoutLibrary.builtInBrowserBundleID)
        t.replaceApp(LayoutLibrary.builtInBrowserBundleID, with: "com.apple.Safari")
        let all = t.oneDisplay + (t.twoDisplays?.main ?? []) + (t.twoDisplays?.second ?? [])
        XCTAssertEqual(all.compactMap { $0.kind.app?.bundleID }, ["com.apple.Safari", "com.apple.Safari"])
        XCTAssertEqual(all.filter { $0.kind.isChat }.count, 2, "other pieces untouched")
    }

    func testChromeOnlyEraLayoutKeyStillMigrates() {
        let d = defaults(["chromeLayout": "rightHalf", "mainAppBundleID": "com.apple.Safari"])
        let lib = LayoutLibrary.loadOrMigrate(from: d, defaultSiteURL: site)
        let previous = lib.templates.first { $0.name == "Your previous layout" }
        let app = previous?.oneDisplay.first { $0.kind.app != nil }
        XCTAssertEqual(app?.rect.x ?? 0, 0.5, accuracy: 1e-9, "main pane on the right half")
    }

    // MARK: Raj Mode is editable

    func testRajModeCanBeRenamedAndRearranged() {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let id = lib.templates.first { $0.starter == LayoutLibrary.rajMode }!.id
        lib.rename(id, to: "Mine")
        XCTAssertEqual(lib.template(id: id)?.name, "Mine")

        var t = lib.template(id: id)!
        var moved = t.oneDisplay
        moved[0].rect = UnitRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2)
        t.setPieces(moved, for: .one)
        XCTAssertEqual(t.oneDisplay[0].rect, moved[0].rect)
        t.setPieces(Array(t.oneDisplay.dropFirst()), for: .one)
        XCTAssertEqual(t.oneDisplay.count, moved.count - 1)
        t.removeTwoDisplayVersion()
        XCTAssertNil(t.twoDisplays)
        t.addTwoDisplayVersion()
        XCTAssertNotNil(t.twoDisplays)
        lib.update(t)
        XCTAssertEqual(lib.template(id: id), t)
        XCTAssertEqual(t.starter, LayoutLibrary.rajMode, "edits keep the tag, so a reset can restore it")
    }

    func testDuplicateOfRajModeIsAnEditableCopy() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let raj = lib.templates.first { $0.starter == LayoutLibrary.rajMode }!
        let copyID = try XCTUnwrap(lib.duplicate(raj.id))
        var copy = try XCTUnwrap(lib.template(id: copyID))
        XCTAssertEqual(copy.name, "Raj Mode copy")
        lib.rename(copyID, to: "Mine")
        XCTAssertEqual(lib.template(id: copyID)?.name, "Mine")
        copy.setPieces(Array(copy.oneDisplay.dropFirst()), for: .one)
        XCTAssertEqual(copy.oneDisplay.count, raj.oneDisplay.count - 1)
        XCTAssertEqual(lib.template(id: raj.id), raj, "the original is untouched")
    }

    func testResetRestoresAnEditedRajMode() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let id = lib.templates.first { $0.starter == LayoutLibrary.rajMode }!.id
        lib.rename(id, to: "Mine")
        lib.resetToDefaults()
        XCTAssertEqual(lib.templates.first { $0.starter == LayoutLibrary.rajMode }?.name, "Raj Mode")
    }
}

final class LayoutShareSwitchDecodeTests: XCTestCase {
    func testNewPiecesShowByDefault() {
        XCTAssertTrue(LayoutPiece.defaultShowsToEveryone)
        for kind: LayoutPiece.Kind in [.meeting(fillsDisplay: false, startsHidden: false), .chat, .view(.activeSpeaker, startsHidden: false), .view(.selfView, startsHidden: false), .view(.people, startsHidden: false)] {
            XCTAssertTrue(LayoutPiece(kind: kind, rect: .full).showsToEveryone)
        }
    }

    func testSavedChoiceIsKeptOverTheDefault() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":{"type":"chat"},"rect":{"x":0,"y":0,"w":0.5,"h":0.5},"showsToEveryone":false}"#
        XCTAssertFalse(try JSONDecoder().decode(LayoutPiece.self, from: Data(json.utf8)).showsToEveryone)
    }

    func testPieceWithNoSavedChoiceDecodesAsShown() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":{"type":"chat"},"rect":{"x":0,"y":0,"w":0.5,"h":0.5}}"#
        let piece = try JSONDecoder().decode(LayoutPiece.self, from: Data(json.utf8))
        XCTAssertTrue(piece.showsToEveryone)   // no saved choice: the new default
        XCTAssertTrue(piece.offersShareSwitch)
    }

    func testSwitchRoundTripsAndAppsNeverOfferIt() throws {
        var piece = LayoutPiece(kind: .chat, rect: .full)
        piece.showsToEveryone = true
        let back = try JSONDecoder().decode(LayoutPiece.self, from: try JSONEncoder().encode(piece))
        XCTAssertTrue(back.showsToEveryone)
        XCTAssertFalse(LayoutPiece(kind: .app(AppPiece(bundleID: "com.apple.Safari")), rect: .full).offersShareSwitch)
    }
}


final class LayoutShareRuleTests: XCTestCase {
    func testOnlyAPlacedWindowFollowsItsPiece() {
        XCTAssertFalse(LayoutShareRule.startsShown(placedBy: nil))   // no layout, or not placed
        XCTAssertTrue(LayoutShareRule.startsShown(placedBy: LayoutPiece(kind: .chat, rect: .full)))
        XCTAssertFalse(LayoutShareRule.startsShown(placedBy: LayoutPiece(kind: .chat, rect: .full, showsToEveryone: false)))
    }
}
