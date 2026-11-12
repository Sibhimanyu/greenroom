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
        XCTAssertEqual(lib.templates.map(\.name), ["Teach from a browser", "Meeting and chat"])
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
        XCTAssertEqual(lib.templates.map(\.name), ["Teach from a browser", "Meeting and chat", "Your previous layout"])
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

    func testStartersAreTheDocumentedShapes() {
        let s = LayoutLibrary.starters()
        let teach = s[0]
        XCTAssertEqual(teach.oneDisplay.map(\.rect.w).map { ($0 * 12).rounded() }, [8, 4, 4])
        XCTAssertEqual(teach.oneDisplay[1].rect.h * 12, 5, accuracy: 1e-9)
        XCTAssertEqual(s[1].oneDisplay.map(\.rect.w).map { ($0 * 12).rounded() }, [9, 3])
    }

    func testRestoreStartersBringsBackDeletedAndResetsEdited() {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let mine = lib.addBlank()
        lib.delete(lib.templates[0].id)
        lib.templates[0].oneDisplay = []
        lib.restoreStarters()
        XCTAssertEqual(lib.templates.filter { $0.starter != nil }.count, 2)
        XCTAssertFalse(lib.templates.first { $0.starter == LayoutLibrary.meetingAndChat }!.oneDisplay.isEmpty)
        XCTAssertNotNil(lib.template(id: mine), "your own layouts are untouched")
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
        XCTAssertEqual(copy.name, "Teach from a browser copy")
        XCTAssertNil(copy.starter)
        XCTAssertTrue(Set(copy.oneDisplay.map(\.id)).isDisjoint(with: lib.templates[0].oneDisplay.map(\.id)))
    }

    func testRenameIgnoresEmptyNames() {
        var lib = LayoutLibrary(templates: LayoutLibrary.starters())
        let id = lib.templates[0].id
        lib.rename(id, to: "   ")
        XCTAssertEqual(lib.templates[0].name, "Teach from a browser")
        lib.rename(id, to: "  Mine ")
        XCTAssertEqual(lib.templates[0].name, "Mine")
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
        var t = LayoutLibrary.starters()[0]
        t.addTwoDisplayVersion()
        let two = try XCTUnwrap(t.twoDisplays)
        XCTAssertFalse(two.main.contains { $0.kind.isMeeting })
        XCTAssertEqual(two.main.first { $0.kind.isChat }?.rect.h ?? 0, 1, accuracy: 1e-9, "chat takes the column")
        XCTAssertEqual(two.second.first?.kind, .meeting(fillsDisplay: true, startsHidden: false))
        XCTAssertFalse(t.canAdd(.meeting(fillsDisplay: false, startsHidden: false), to: .main), "one Meeting across the pair")
    }
}
