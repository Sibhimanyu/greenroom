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
    }

    func testRajModeGeometryIsValid() throws {
        let raj = starter(LayoutLibrary.rajMode)
        func cells(_ r: UnitRect) -> [Int] { [r.x, r.y, r.w, r.h].map { Int(($0 * 12).rounded()) } }
        XCTAssertEqual(raj.oneDisplay.map { cells($0.rect) }, [[0, 0, 9, 12], [9, 0, 3, 5], [9, 5, 3, 7]])
        XCTAssertEqual(raj.oneDisplay.first?.kind.app?.bundleID, LayoutLibrary.builtInBrowserBundleID)
        XCTAssertEqual(raj.oneDisplay.first?.kind.app?.opensAtStart, true)
        XCTAssertEqual(raj.oneDisplay[1].kind, .meeting(fillsDisplay: false, startsHidden: false))
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
        let id = lib.templates[1].id   // Raj Mode is locked; rename an ordinary one
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

    // MARK: Raj Mode is locked

    func testRajModeIsLockedAndOthersAreNot() {
        XCTAssertTrue(starter(LayoutLibrary.rajMode).isLocked)
        XCTAssertFalse(starter(LayoutLibrary.teachFromBrowser).isLocked)
        XCTAssertFalse(starter(LayoutLibrary.meetingAndChat).isLocked)
        XCTAssertFalse(LayoutTemplate(name: "Mine").isLocked)
    }

    func testLockedTemplateRefusesRenameMoveRemoveAndTheRest() {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let id = lib.templates.first { $0.starter == LayoutLibrary.rajMode }!.id
        let before = lib.template(id: id)!

        lib.rename(id, to: "Mine")
        XCTAssertEqual(lib.template(id: id), before, "rename refused")

        var t = before
        var moved = t.oneDisplay
        moved[0].rect = UnitRect(x: 0.1, y: 0.1, w: 0.2, h: 0.2)
        t.setPieces(moved, for: .one)
        XCTAssertEqual(t, before, "move and resize refused")
        t.setPieces(Array(t.oneDisplay.dropFirst()), for: .one)
        XCTAssertEqual(t, before, "remove refused")
        t.setPieces(t.oneDisplay + [LayoutPiece(kind: .app(AppPiece(bundleID: "x")), rect: .full)], for: .one)
        XCTAssertEqual(t, before, "add refused")
        t.replaceApp(LayoutLibrary.builtInBrowserBundleID, with: "com.google.Chrome")
        XCTAssertEqual(t, before, "app swap refused")
        t.setMeetingStartsHidden(true)
        XCTAssertEqual(t, before, "starts hidden refused")
        t.removeTwoDisplayVersion()
        XCTAssertEqual(t, before, "removing the two-display version refused")

        var edited = before
        edited.name = "Edited"
        lib.update(edited)
        XCTAssertEqual(lib.template(id: id), before, "a whole-template write is refused too")

        var noTwo = before
        noTwo.twoDisplays = nil
        noTwo.starter = LayoutLibrary.rajMode
        noTwo.addTwoDisplayVersion()
        XCTAssertNil(noTwo.twoDisplays, "adding a two-display version refused")
    }

    func testDuplicateOfRajModeIsAnEditableCopy() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let raj = lib.templates.first { $0.starter == LayoutLibrary.rajMode }!
        let copyID = try XCTUnwrap(lib.duplicate(raj.id))
        var copy = try XCTUnwrap(lib.template(id: copyID))
        XCTAssertFalse(copy.isLocked)
        XCTAssertEqual(copy.name, "Raj Mode copy")
        lib.rename(copyID, to: "Mine")
        XCTAssertEqual(lib.template(id: copyID)?.name, "Mine")
        copy.setPieces(Array(copy.oneDisplay.dropFirst()), for: .one)
        XCTAssertEqual(copy.oneDisplay.count, raj.oneDisplay.count - 1)
        XCTAssertEqual(lib.template(id: raj.id), raj, "the original is untouched")
    }

    func testResetAndAppendKeepRajModeLocked() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        lib.resetToDefaults()
        XCTAssertTrue(try XCTUnwrap(lib.templates.first { $0.starter == LayoutLibrary.rajMode }).isLocked)

        var old = LayoutLibrary(templates: LayoutLibrary.starters().filter { $0.starter != LayoutLibrary.rajMode })
        XCTAssertTrue(old.addStarters(notIn: Set(LayoutLibrary.originalStarterKeys)))
        XCTAssertTrue(try XCTUnwrap(old.templates.first { $0.starter == LayoutLibrary.rajMode }).isLocked)

        var restored = LayoutLibrary(templates: [])
        let id = try XCTUnwrap(restored.starterID(LayoutLibrary.rajMode))
        XCTAssertTrue(try XCTUnwrap(restored.template(id: id)).isLocked)
    }

    func testLockSurvivesEncodeAndOldFilesDecode() throws {
        let raj = starter(LayoutLibrary.rajMode)
        let round = try JSONDecoder().decode(LayoutTemplate.self, from: JSONEncoder().encode(raj))
        XCTAssertEqual(round, raj)
        XCTAssertTrue(round.isLocked)
        // A file written before locking existed has no lock key at all.
        let json = #"{"name":"Raj Mode","starter":"raj","oneDisplay":[]}"#
        XCTAssertTrue(try JSONDecoder().decode(LayoutTemplate.self, from: Data(json.utf8)).isLocked)
        XCTAssertFalse(try JSONDecoder().decode(LayoutTemplate.self, from: Data(#"{"name":"Mine"}"#.utf8)).isLocked)
    }
}
