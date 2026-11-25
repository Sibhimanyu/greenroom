import XCTest

/// The meeting-view pieces (.context/meeting-views-plan.md, phase 1): codec,
/// what a version may hold, minimums and the Starts hidden flag.
final class LayoutViewPieceTests: XCTestCase {
    private func piece(_ kind: LayoutPiece.Kind, _ rect: UnitRect = .full) -> LayoutPiece {
        LayoutPiece(kind: kind, rect: rect)
    }
    private func view(_ v: MeetingView, hidden: Bool = false) -> LayoutPiece.Kind { .view(v, startsHidden: hidden) }
    private let meeting = LayoutPiece.Kind.meeting(fillsDisplay: false, startsHidden: false)

    // MARK: Codec

    func testEveryViewRoundTrips() throws {
        for v in MeetingView.allCases {
            for hidden in [false, true] {
                let p = piece(view(v, hidden: hidden), UnitRect(x: 0.25, y: 0, w: 0.5, h: 0.5))
                let back = try JSONDecoder().decode(LayoutPiece.self, from: JSONEncoder().encode(p))
                XCTAssertEqual(back, p)
            }
        }
    }

    func testEncodedShape() throws {
        let data = try JSONEncoder().encode(view(.gallery, hidden: true))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "view")
        XCTAssertEqual(json["view"] as? String, "gallery")
        XCTAssertEqual(json["startsHidden"] as? Bool, true)
    }

    func testMissingStartsHiddenIsFalse() throws {
        let k = try JSONDecoder().decode(LayoutPiece.Kind.self, from: Data(#"{"type":"view","view":"people"}"#.utf8))
        XCTAssertEqual(k, view(.people))
    }

    func testUnknownViewDropsOnlyThatPiece() throws {
        let good = piece(view(.selfView))
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let json = """
        {"id":"\(UUID())","name":"X","oneDisplay":[
          {"id":"\(UUID())","kind":{"type":"view","view":"hologram","startsHidden":false},"rect":{"x":0,"y":0,"w":1,"h":1}},
          \(goodJSON),
          {"id":"\(UUID())","kind":{"type":"chat"},"rect":{"x":0,"y":0,"w":0.2,"h":1}}]}
        """
        let t = try JSONDecoder().decode(LayoutTemplate.self, from: Data(json.utf8))
        XCTAssertEqual(t.oneDisplay.count, 2)
        XCTAssertEqual(t.oneDisplay.first?.kind, view(.selfView))
    }

    func testSavedMeetingPiecesAreUntouched() throws {
        let k = try JSONDecoder().decode(LayoutPiece.Kind.self,
                                         from: Data(#"{"type":"meeting","fillsDisplay":false,"startsHidden":true}"#.utf8))
        XCTAssertEqual(k, .meeting(fillsDisplay: false, startsHidden: true))
        XCTAssertEqual(LayoutLibrary().version, 1)
    }

    // MARK: canAdd

    private func template(_ kinds: [LayoutPiece.Kind]) -> LayoutTemplate {
        LayoutTemplate(name: "T", oneDisplay: kinds.map { piece($0) })
    }

    func testOneOfEachView() {
        for v in MeetingView.allCases {
            XCTAssertTrue(template([]).canAdd(view(v), to: .main), "\(v)")
            XCTAssertFalse(template([view(v)]).canAdd(view(v), to: .main), "\(v) twice")
        }
    }

    func testViewsCountAcrossBothDisplays() {
        var t = template([view(.people)])
        t.twoDisplays = TwoDisplay(second: [])
        XCTAssertFalse(t.canAdd(view(.people), to: .second))
        XCTAssertTrue(t.canAdd(view(.gallery), to: .second))
    }

    func testMeetingWindowExcludesGalleryAndSpeakerStrip() {
        let withMeeting = template([meeting])
        XCTAssertFalse(withMeeting.canAdd(view(.gallery), to: .main))
        XCTAssertFalse(withMeeting.canAdd(view(.speakerStrip), to: .main))
        for v in [MeetingView.activeSpeaker, .multiSpeaker, .selfView, .people, .sharedScreen, .spotlight, .handsUp] {
            XCTAssertTrue(withMeeting.canAdd(view(v), to: .main), "\(v)")
        }
        XCTAssertFalse(template([view(.gallery)]).canAdd(meeting, to: .main))
        XCTAssertFalse(template([view(.speakerStrip)]).canAdd(meeting, to: .main))
        XCTAssertTrue(template([view(.activeSpeaker), view(.people)]).canAdd(meeting, to: .main))
    }

    func testActiveSpeakerAndSpeakerStripExcludeEachOther() {
        XCTAssertFalse(template([view(.activeSpeaker)]).canAdd(view(.speakerStrip), to: .main))
        XCTAssertFalse(template([view(.speakerStrip)]).canAdd(view(.activeSpeaker), to: .main))
        XCTAssertTrue(template([view(.gallery)]).canAdd(view(.activeSpeaker), to: .main))
    }

    /// Every pair of the nine, and the Meeting window: only these are refused.
    func testExclusionsForAllNine() {
        let refused: Set<Set<String>> = [["meeting", "gallery"], ["meeting", "speakerStrip"], ["activeSpeaker", "speakerStrip"]]
        func name(_ k: LayoutPiece.Kind) -> String { k.isMeeting ? "meeting" : (k.view?.rawValue ?? "?") }
        var kinds: [LayoutPiece.Kind] = [meeting] + MeetingView.allCases.map { view($0) }
        XCTAssertEqual(kinds.count, 10)
        for a in kinds {
            for b in kinds where name(a) != name(b) {
                let allowed = template([a]).canAdd(b, to: .main)
                XCTAssertEqual(allowed, !refused.contains([name(a), name(b)]), "\(name(a)) then \(name(b))")
            }
        }
        kinds.removeAll()
    }

    func testHandsUpAndPeopleListCoexist() {
        XCTAssertTrue(template([view(.people)]).canAdd(view(.handsUp), to: .main))
        XCTAssertTrue(template([view(.handsUp)]).canAdd(view(.people), to: .main))
        XCTAssertTrue(template([view(.spotlight), view(.activeSpeaker)]).canAdd(view(.sharedScreen), to: .main))
    }

    func testNewKindsRoundTrip() throws {
        for v in [MeetingView.sharedScreen, .spotlight, .handsUp] {
            let p = piece(view(v, hidden: true), UnitRect(x: 0.1, y: 0.2, w: 0.3, h: 0.4))
            let data = try JSONEncoder().encode(p)
            XCTAssertEqual(try JSONDecoder().decode(LayoutPiece.self, from: data), p)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((json["kind"] as? [String: Any])?["view"] as? String, v.rawValue)
        }
        XCTAssertEqual(MeetingView.sharedScreen.rawValue, "sharedScreen")
        XCTAssertEqual(MeetingView.spotlight.rawValue, "spotlight")
        XCTAssertEqual(MeetingView.handsUp.rawValue, "handsUp")
    }

    func testOnlyListsAndNoVideoViewsAreMarked() {
        XCTAssertEqual(Set(MeetingView.allCases.filter { !$0.drawsVideo }), [.people, .handsUp])
    }

    func testChatAndAppsUnaffectedByViews() {
        let t = template([view(.gallery), view(.people)])
        XCTAssertTrue(t.canAdd(.chat, to: .main))
        XCTAssertTrue(t.canAdd(.app(AppPiece(bundleID: "com.apple.Notes")), to: .main))
    }

    // MARK: Minimums and defaults

    func testMinimumPoints() {
        let expected: [MeetingView: CGSize] = [
            .activeSpeaker: CGSize(width: 240, height: 135), .gallery: CGSize(width: 320, height: 200),
            .multiSpeaker: CGSize(width: 360, height: 120), .speakerStrip: CGSize(width: 320, height: 240),
            .selfView: CGSize(width: 160, height: 90), .people: CGSize(width: 220, height: 240),
            .sharedScreen: CGSize(width: 320, height: 200), .spotlight: CGSize(width: 240, height: 135),
            .handsUp: CGSize(width: 240, height: 200)]
        XCTAssertEqual(Set(expected.keys), Set(MeetingView.allCases))
        for (v, size) in expected {
            XCTAssertEqual(LayoutGeometry.minimumPoints(for: view(v)), size, "\(v)")
        }
    }

    func testMinimumCellsAndDefaultsFit() {
        let display = CGSize(width: 1512, height: 944)
        for v in MeetingView.allCases {
            let min = LayoutGeometry.minimumCells(for: view(v), display: display)
            let def = LayoutGeometry.defaultCells(for: view(v))
            XCTAssertGreaterThanOrEqual(def.cols, min.cols, "\(v) default width below its minimum")
            XCTAssertGreaterThanOrEqual(def.rows, min.rows, "\(v) default height below its minimum")
            XCTAssertNotNil(LayoutGeometry.placeNew(view(v), avoiding: [], display: display), "\(v)")
        }
    }

    // MARK: Starts hidden

    func testStartsHiddenCoversViews() {
        var t = template([meeting, view(.gallery), .chat])
        XCTAssertEqual(t.meetingStartsHidden, false)
        t.setMeetingStartsHidden(true)
        XCTAssertEqual(t.meetingStartsHidden, true)
        XCTAssertEqual(t.oneDisplay[0].kind, .meeting(fillsDisplay: false, startsHidden: true))
        XCTAssertEqual(t.oneDisplay[1].kind, view(.gallery, hidden: true))
        XCTAssertEqual(t.oneDisplay[2].kind, .chat)
    }

    func testStartsHiddenReadsAViewAlone() {
        var t = template([view(.people, hidden: true)])
        XCTAssertEqual(t.meetingStartsHidden, true)
        t.setMeetingStartsHidden(false)
        XCTAssertEqual(t.oneDisplay[0].kind, view(.people))
        XCTAssertNil(template([.chat]).meetingStartsHidden)
    }

    func testStartsHiddenReachesTheSecondDisplay() {
        var t = template([])
        t.oneDisplay = [piece(view(.selfView))]
        t.twoDisplays = TwoDisplay(second: [piece(view(.people))])
        t.setMeetingStartsHidden(true)
        XCTAssertEqual(t.oneDisplay.first?.kind, view(.selfView, hidden: true))
        XCTAssertEqual(t.twoDisplays?.second.first?.kind, view(.people, hidden: true))
    }

    // MARK: Two displays

    func testViewsAreNotMeetingOrChatOrApp() {
        let k = view(.gallery)
        XCTAssertTrue(k.isView); XCTAssertTrue(k.isMeetingSurface)
        XCTAssertFalse(k.isMeeting); XCTAssertFalse(k.isChat); XCTAssertNil(k.app)
        XCTAssertFalse(LayoutPiece.Kind.chat.isMeetingSurface)
    }

    // MARK: Fallback where views cannot open

    func testActiveSpeakerBecomesTheMeetingWindowWhereViewsCannotOpen() {
        let raj = LayoutLibrary.starters().first { $0.starter == LayoutLibrary.present }!
        let rect = raj.oneDisplay.first { $0.kind.view == .activeSpeaker }!.rect
        let out = LayoutResolver.substitutingMeetingForActiveSpeaker(raj, viewsCanOpen: false)
        let m = out.oneDisplay.first { $0.kind.isMeeting }
        XCTAssertEqual(m?.rect, rect, "same rectangle")
        XCTAssertEqual(m?.kind, .meeting(fillsDisplay: false, startsHidden: false))
        XCTAssertFalse(out.oneDisplay.contains { $0.kind.isView })
        XCTAssertEqual(out.twoDisplays, raj.twoDisplays, "nothing on a second display to touch")
        XCTAssertEqual(out.oneDisplay.count, raj.oneDisplay.count)
    }

    func testNothingChangesWhenViewsCanOpen() {
        for t in LayoutLibrary.starters() {
            XCTAssertEqual(LayoutResolver.substitutingMeetingForActiveSpeaker(t, viewsCanOpen: true), t)
        }
    }

    func testStartsHiddenCarriesOverAndAnExistingMeetingWins() {
        var t = LayoutTemplate(name: "x", oneDisplay: [piece(view(.activeSpeaker, hidden: true), UnitRect(x: 0, y: 0, w: 0.5, h: 1))])
        let out = LayoutResolver.substitutingMeetingForActiveSpeaker(t, viewsCanOpen: false)
        XCTAssertEqual(out.oneDisplay[0].kind, .meeting(fillsDisplay: false, startsHidden: true))

        t.oneDisplay.append(piece(meeting, UnitRect(x: 0.5, y: 0, w: 0.5, h: 1)))
        XCTAssertEqual(LayoutResolver.substitutingMeetingForActiveSpeaker(t, viewsCanOpen: false), t,
                       "a version with its own Meeting piece keeps its view")
        let other = LayoutTemplate(name: "y", oneDisplay: [piece(view(.gallery))])
        XCTAssertEqual(LayoutResolver.substitutingMeetingForActiveSpeaker(other, viewsCanOpen: false), other,
                       "only the Active speaker stands in")
    }

    func testActiveSpeakerStaysOutWhenAnotherDisplayHoldsTheMeeting() {
        var t = LayoutTemplate(name: "x", oneDisplay: [piece(view(.activeSpeaker))])
        t.twoDisplays = TwoDisplay(second: [piece(meeting)])
        let out = LayoutResolver.substitutingMeetingForActiveSpeaker(t, viewsCanOpen: false)
        XCTAssertEqual(out.oneDisplay, t.oneDisplay, "no second Meeting while the second display holds it")
        XCTAssertEqual(out.twoDisplays?.second, t.twoDisplays?.second)
        // R26.4: with no second display connected, main's Active speaker stands in.
        let alone = LayoutResolver.substitutingMeetingForActiveSpeaker(t, viewsCanOpen: false, secondConnected: false)
        XCTAssertTrue(alone.oneDisplay[0].kind.isMeeting)
    }

    func testRuntimeCustomUIBeatsTheSavedSetting() {
        func can(_ saved: Bool, _ runtime: Bool?, only: Bool = false) -> Bool {
            LayoutResolver.viewsCanOpen(viewsEnabled: true, customUISaved: saved, customUIRuntime: runtime, meetingWindowOnly: only)
        }
        XCTAssertTrue(can(true, nil)); XCTAssertFalse(can(false, nil))
        XCTAssertFalse(can(true, false), "saved on, SDK fell back to Zoom's UI")
        XCTAssertTrue(can(false, true))
        XCTAssertFalse(can(true, true, only: true))
        XCTAssertFalse(LayoutResolver.viewsCanOpen(viewsEnabled: false, customUISaved: true, customUIRuntime: true, meetingWindowOnly: false))
    }
}
