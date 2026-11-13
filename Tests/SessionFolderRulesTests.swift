import XCTest

final class SessionFolderRulesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func put(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }
    private var empty: Bool { SessionFolderRules.isEffectivelyEmpty(dir) }

    func testEmptyFolderIsEmpty() { XCTAssertTrue(empty) }

    func testLoneEventsSidecarIsEmpty() throws {
        try put("Green.events.json", "{}")
        XCTAssertTrue(empty)
    }

    func testEmptyNotesFileIsEmptyButNotesWithContentKeep() throws {
        try put("notes.jsonl", "")
        XCTAssertTrue(empty)
        try put("notes.jsonl", "{\"text\":\"hi\"}\n")
        XCTAssertFalse(empty)
    }

    func testVideoOrClipKeepsFolder() throws {
        try put("Green.events.json", "{}")
        try put("Green.mov", "x")
        XCTAssertFalse(empty)
    }

    func testTitledSessionKeepsButBareKindMarkerDoesNot() throws {
        try put("session.json", "{\"title\":\"Maths\"}")
        XCTAssertFalse(empty)
        try put("session.json", "{\"kind\":\"recording\"}")
        XCTAssertTrue(empty)
        try put("session.json", "{not json")
        XCTAssertFalse(empty)
    }

    func testUnknownFileOrSubfolderKeeps() throws {
        try put("report.html", "x")
        XCTAssertFalse(empty)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("report.html"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("clips"), withIntermediateDirectories: false)
        XCTAssertFalse(empty)
    }

    func testNonEmptyFileCheck() throws {
        try put("a.mov", "")
        try put("b.mov", "x")
        XCTAssertFalse(SessionFolderRules.isNonEmptyFile(dir.appendingPathComponent("a.mov")))
        XCTAssertTrue(SessionFolderRules.isNonEmptyFile(dir.appendingPathComponent("b.mov")))
        XCTAssertFalse(SessionFolderRules.isNonEmptyFile(dir.appendingPathComponent("none.mov")))
    }
}
