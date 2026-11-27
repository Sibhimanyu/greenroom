import XCTest
@testable import GreenroomTests

/// R17: a key copied with Zoom's own copy button is picked up and assigned to the field the coach points at.
final class ZoomClipboardRulesTests: XCTestCase {
    private let secret = "SecretCCCCC33xyZ", client = "ClientBBBBB22abc", account = "AccountAAAA11def"

    private func assign(_ copied: String, found: [ZoomKeyField: String] = [:], missing: [ZoomKeyField], pointed: ZoomKeyField? = nil) -> ZoomKeyField? {
        ZoomClipboardRules.assign(copied: copied, found: found, missing: missing, pointedAt: pointed)
    }

    func testTheSecretOnBasicInformation() {
        XCTAssertEqual(assign(secret, found: [.clientID: client], missing: [.clientSecret], pointed: .clientSecret), .clientSecret)
        XCTAssertEqual(assign(secret, found: [.clientID: client], missing: [.clientSecret]), .clientSecret)
    }

    func testTheFieldPointedAtWins() {
        XCTAssertEqual(assign(client, missing: [.accountID, .clientID, .clientSecret], pointed: .clientID), .clientID)
    }

    func testWithoutAPointerTheFirstMissingInOrder() {
        XCTAssertEqual(assign(account, missing: [.clientSecret, .accountID, .clientID]), .accountID)
        XCTAssertEqual(assign(client, found: [.accountID: account], missing: [.clientSecret, .clientID]), .clientID)
        XCTAssertEqual(assign(secret, found: [.accountID: account, .clientID: client], missing: [.clientSecret]), .clientSecret)
    }

    func testAPointerThatIsNotMissingFallsBackToTheFirstMissing() {
        XCTAssertEqual(assign(secret, missing: [.clientSecret], pointed: .accountID), .clientSecret)
    }

    func testNothingIsAssignedWhenItIsNotAKeyOrIsAlreadyKnownOrNothingIsMissing() {
        XCTAssertNil(assign("hello world", missing: [.clientSecret]))
        XCTAssertNil(assign("short", missing: [.clientSecret]))
        XCTAssertNil(assign("", missing: [.clientSecret]))
        XCTAssertNil(assign(" \(secret) \n x", missing: [.clientSecret]))
        XCTAssertNil(assign(client, found: [.clientID: client], missing: [.clientSecret]))   // the ID read from the page, copied again
        XCTAssertNil(assign(secret, found: [.clientID: client, .clientSecret: secret], missing: []))
        XCTAssertNil(assign(secret, missing: []))
    }

    func testSurroundingWhitespaceIsTrimmedBeforeTheCheck() {
        XCTAssertEqual(ZoomClipboardRules.clean("  \(secret)\n"), secret)
        XCTAssertEqual(assign("  \(secret)\n", missing: [.clientSecret]), .clientSecret)
        XCTAssertNil(ZoomClipboardRules.clean("a b c d e f g h i j k"))
    }

    func testTheWatchRunsOnlyOnACredentialsPageAndSixtySecondsAfter() {
        let w = { (on: Bool, s: TimeInterval?) in ZoomClipboardRules.isWatching(onCredentialsPage: on, secondsSinceLeaving: s) }
        XCTAssertTrue(w(true, nil))
        XCTAssertTrue(w(false, 0))
        XCTAssertTrue(w(false, 59.9))
        XCTAssertFalse(w(false, 60))
        XCTAssertFalse(w(false, nil))
    }

    func testTheClipboardSourceNeverLogs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("App/Zoom/ZoomClipboardRules.swift"), encoding: .utf8)
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for banned in ["print(", "NSLog(", "os_log", "Logger(", "debugPrint("] { XCTAssertFalse(code.contains(banned), banned) }
    }
}
