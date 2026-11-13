import XCTest
@testable import GreenroomTests

final class MainWindowTests: XCTestCase {
    func testMatchesExactSceneID() {
        XCTAssertTrue(MainWindow.matches(identifier: "main"))
    }

    func testMatchesSuffixedSceneID() {
        XCTAssertTrue(MainWindow.matches(identifier: "main-AppWindow-1"))
    }

    func testRejectsOtherWindows() {
        XCTAssertFalse(MainWindow.matches(identifier: nil))
        XCTAssertFalse(MainWindow.matches(identifier: ""))
        XCTAssertFalse(MainWindow.matches(identifier: "editor"))
        XCTAssertFalse(MainWindow.matches(identifier: "mainframe"))
        XCTAssertFalse(MainWindow.matches(identifier: "Greenroom"))
    }

    @MainActor
    func testWindowOverloadUsesIdentifierNotTitle() {
        let w = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        w.title = "Greenroom"
        XCTAssertFalse(MainWindow.matches(w))
        w.title = "Sessions"
        w.identifier = NSUserInterfaceItemIdentifier("main")
        XCTAssertTrue(MainWindow.matches(w))
    }
}
