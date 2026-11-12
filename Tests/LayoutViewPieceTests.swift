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
            XCTAssertTrue(template([]).canAdd(view(v), to: .one), "\(v)")
            XCTAssertFalse(template([view(v)]).canAdd(view(v), to: .one), "\(v) twice")
        }
    }

    func testViewsCountAcrossBothDisplays() {
        var t = template([view(.people)])
        t.twoDisplays = TwoDisplay(main: [piece(view(.people))], second: [])
        XCTAssertFalse(t.canAdd(view(.people), to: .second))
        XCTAssertTrue(t.canAdd(view(.gallery), to: .second))
    }

    func testMeetingWindowExcludesGalleryAndSpeakerStrip() {
        let withMeeting = template([meeting])
        XCTAssertFalse(withMeeting.canAdd(view(.gallery), to: .one))
        XCTAssertFalse(withMeeting.canAdd(view(.speakerStrip), to: .one))
        for v in [MeetingView.activeSpeaker, .multiSpeaker, .selfView, .people, .sharedScreen, .spotlight, .handsUp] {
            XCTAssertTrue(withMeeting.canAdd(view(v), to: .one), "\(v)")
        }
        XCTAssertFalse(template([view(.gallery)]).canAdd(meeting, to: .one))
        XCTAssertFalse(template([view(.speakerStrip)]).canAdd(meeting, to: .one))
        XCTAssertTrue(template([view(.activeSpeaker), view(.people)]).canAdd(meeting, to: .one))
    }

    func testActiveSpeakerAndSpeakerStripExcludeEachOther() {
        XCTAssertFalse(template([view(.activeSpeaker)]).canAdd(view(.speakerStrip), to: .one))
        XCTAssertFalse(template([view(.speakerStrip)]).canAdd(view(.activeSpeaker), to: .one))
        XCTAssertTrue(template([view(.gallery)]).canAdd(view(.activeSpeaker), to: .one))
    }

    /// Every pair of the nine, and the Meeting window: only these are refused.
    func testExclusionsForAllNine() {
        let refused: Set<Set<String>> = [["meeting", "gallery"], ["meeting", "speakerStrip"], ["activeSpeaker", "speakerStrip"]]
        func name(_ k: LayoutPiece.Kind) -> String { k.isMeeting ? "meeting" : (k.view?.rawValue ?? "?") }
        var kinds: [LayoutPiece.Kind] = [meeting] + MeetingView.allCases.map { view($0) }
        XCTAssertEqual(kinds.count, 10)
        for a in kinds {
            for b in kinds where name(a) != name(b) {
                let allowed = template([a]).canAdd(b, to: .one)
                XCTAssertEqual(allowed, !refused.contains([name(a), name(b)]), "\(name(a)) then \(name(b))")
            }
        }
        kinds.removeAll()
    }

    func testHandsUpAndPeopleListCoexist() {
        XCTAssertTrue(template([view(.people)]).canAdd(view(.handsUp), to: .one))
        XCTAssertTrue(template([view(.handsUp)]).canAdd(view(.people), to: .one))
        XCTAssertTrue(template([view(.spotlight), view(.activeSpeaker)]).canAdd(view(.sharedScreen), to: .one))
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
        XCTAssertTrue(t.canAdd(.chat, to: .one))
        XCTAssertTrue(t.canAdd(.app(AppPiece(bundleID: "com.apple.Notes")), to: .one))
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
        t.twoDisplays = TwoDisplay(main: [piece(view(.selfView))], second: [piece(view(.people))])
        t.setMeetingStartsHidden(true)
        XCTAssertEqual(t.twoDisplays?.main.first?.kind, view(.selfView, hidden: true))
        XCTAssertEqual(t.twoDisplays?.second.first?.kind, view(.people, hidden: true))
    }

    // MARK: Two displays

    func testTwoDisplayVersionMovesOnlyTheMeetingWindow() {
        var t = template([meeting, view(.people), .chat])
        t.addTwoDisplayVersion()
        let main = t.twoDisplays?.main.map(\.kind) ?? []
        XCTAssertTrue(main.contains(view(.people)))
        XCTAssertFalse(main.contains { $0.isMeeting })
        XCTAssertTrue(t.twoDisplays?.second.first?.kind.isMeeting == true)
        XCTAssertEqual(t.twoDisplays?.second.count, 1)
    }

    func testViewsAreNotMeetingOrChatOrApp() {
        let k = view(.gallery)
        XCTAssertTrue(k.isView); XCTAssertTrue(k.isMeetingSurface)
        XCTAssertFalse(k.isMeeting); XCTAssertFalse(k.isChat); XCTAssertNil(k.app)
        XCTAssertFalse(LayoutPiece.Kind.chat.isMeetingSurface)
    }
}
