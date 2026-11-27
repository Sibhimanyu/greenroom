import XCTest
@testable import GreenroomTests

/// R5: the page reader only reads, finds fields by label, and never logs a value.
final class ZoomKeyReaderScriptTests: XCTestCase {
    func testTheReaderFindsFieldsByTheirLabelsWithTheInputOrderAsFallback() {
        let js = ZoomKeyReaderScript.source
        for label in ["Account ID", "Client ID", "Client Secret"] { XCTAssertTrue(js.contains(label), label) }
        XCTAssertTrue(js.contains("input"))
        XCTAssertTrue(js.contains("password"))
    }

    func testTheReaderNeverActsOnThePageOrLogs() {
        let js = ZoomKeyReaderScript.source
        for banned in [".click(", ".focus(", "dispatchEvent", ".submit(", "console.", "fetch(", "XMLHttpRequest", "postMessage",
                       "localStorage", "document.cookie", "alert(", "print", "NSLog", "setAttribute", ".value ="] {
            XCTAssertFalse(js.contains(banned), banned)
        }
    }

    /// No print, log or NSLog in the Swift that reads or applies the values (and the window, which hands them on).
    func testNoLoggingNearTheValues() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["App/Zoom/ZoomKeyReaderScript.swift", "App/Zoom/ZoomGuideFollowRules.swift",
                     "App/UI/ZoomMarketplaceWindow.swift", "App/UI/ZoomSetupAssist.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for banned in ["print(", "NSLog(", "os_log", "Logger(", "debugPrint(", "dump(", ".log("] {
                XCTAssertFalse(code.contains(banned), "\(file) has \(banned)")
            }
        }
    }
}
