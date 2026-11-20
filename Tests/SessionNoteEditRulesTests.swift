import XCTest

final class SessionNoteEditRulesTests: XCTestCase {

    private func note(_ ms: Int, _ text: String) -> ScreenroomNote {
        ScreenroomNote(atMs: ms, text: text, markedAt: Date(timeIntervalSince1970: 1_700_000_000),
                       timedFrom: "session")
    }

    func testAClickSeeksToExactlyTheNotesOwnTime() {
        XCTAssertEqual(SessionNoteEditRules.seekTime(forAtMs: 4_000), 4, accuracy: 0.0001)
        XCTAssertEqual(SessionNoteEditRules.seekTime(forAtMs: 15_250), 15.25, accuracy: 0.0001)
        XCTAssertEqual(SessionNoteEditRules.seekTime(forAtMs: -5), 0)
    }

    func testCurrentNoteIsTheLastOneAtOrBeforeThePlayhead() {
        let notes = [(id: "a", at: 0.0), (id: "b", at: 4.0), (id: "c", at: 15.0)]
        XCTAssertEqual(SessionNoteEditRules.currentNoteID(notes, playhead: 4.0), "b")
        XCTAssertEqual(SessionNoteEditRules.currentNoteID(notes, playhead: 3.97), "b")
        XCTAssertEqual(SessionNoteEditRules.currentNoteID(notes, playhead: 14.9), "b")
        XCTAssertEqual(SessionNoteEditRules.currentNoteID(notes, playhead: 99), "c")
        XCTAssertNil(SessionNoteEditRules.currentNoteID([(id: "x", at: 5)], playhead: 1))
        XCTAssertNil(SessionNoteEditRules.currentNoteID([], playhead: 1))
    }

    func testMomentIDRoundTrip() {
        let id = UUID()
        XCTAssertEqual(SessionNoteEditRules.noteID(fromMomentID: "n-\(id.uuidString)"), id)
        XCTAssertNil(SessionNoteEditRules.noteID(fromMomentID: "c-\(id.uuidString)"))
        XCTAssertNil(SessionNoteEditRules.noteID(fromMomentID: "n-nope"))
    }

    func testEditChangesOnlyTheNamedNotesTextAndKeepsItsOtherFields() throws {
        let a = note(0, "a"), b = note(4_000, "b")
        let out = try XCTUnwrap(SessionNoteEditRules.edited([a, b], id: b.id, text: "  better  "))
        XCTAssertEqual(out[0], a)
        XCTAssertEqual(out[1].text, "better")
        XCTAssertEqual(out[1].id, b.id)
        XCTAssertEqual(out[1].atMs, 4_000)
        XCTAssertEqual(out[1].timedFrom, "session")
        XCTAssertEqual(out[1].markedAt, b.markedAt)
    }

    func testBlankOrUnknownEditIsRefused() {
        let a = note(0, "a")
        XCTAssertNil(SessionNoteEditRules.edited([a], id: a.id, text: "   "))
        XCTAssertNil(SessionNoteEditRules.edited([a], id: UUID(), text: "x"))
    }

    func testRetimeMovesOneNoteAndClampsAtZero() throws {
        let a = note(1_000, "a"), b = note(4_000, "b")
        let out = try XCTUnwrap(SessionNoteEditRules.retimed([a, b], id: a.id, atMs: 9_000))
        XCTAssertEqual(out.map(\.atMs), [9_000, 4_000])
        XCTAssertEqual(try XCTUnwrap(SessionNoteEditRules.retimed([a], id: a.id, atMs: -3)).first?.atMs, 0)
        XCTAssertNil(SessionNoteEditRules.retimed([a], id: UUID(), atMs: 1))
    }

    func testRemoveAndRestoreByID() {
        let a = note(0, "a"), b = note(4_000, "b")
        let gone = SessionNoteEditRules.removed([a, b], id: a.id)
        XCTAssertEqual(gone, [b])
        let back = SessionNoteEditRules.restored(gone, note: a)
        XCTAssertEqual(Set(back.map(\.id)), [a.id, b.id])
        XCTAssertEqual(SessionNoteEditRules.restored(back, note: a).count, 2)
    }

    func testEditsRoundTripThroughTheFileKeepingIdsAndOrder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = note(0, "a"), b = note(4_000, "b"), c = note(15_000, "c")
        ScreenroomNotesFile.replace([a, b, c], in: dir)
        let edited = try XCTUnwrap(SessionNoteEditRules.edited(ScreenroomNotesFile.load(in: dir), id: b.id, text: "b2"))
        ScreenroomNotesFile.replace(edited, in: dir)
        let loaded = ScreenroomNotesFile.load(in: dir)
        XCTAssertEqual(loaded.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(loaded.map(\.text), ["a", "b2", "c"])
    }
}
