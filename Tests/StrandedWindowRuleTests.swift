import XCTest
import CoreGraphics

/// R45.7: the stranded-window rescue moves only a window that is on no screen at
/// all. From the owner's log, 2026-11-26: while AirPlay renegotiated, "Display
/// settings changed" came with both screens still listed, and a window on the
/// AirPlay screen was "moved onto Built-in Retina Display", then back again.
final class StrandedWindowRuleTests: XCTestCase {

    private let builtIn = StrandedWindowRule.Screen(
        name: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
    private let airPlay = StrandedWindowRule.Screen(
        name: "Sibhimanyu's MacBook Pro (AirPlay)",
        frame: CGRect(x: 1512, y: 0, width: 1728, height: 1117),
        visibleFrame: CGRect(x: 1512, y: 0, width: 1728, height: 1084))

    /// The logged case: mid-renegotiation the AirPlay screen is still listed but
    /// its usable area reads as nothing. The window is on it; it stays.
    func testAWindowOnTheAirPlayScreenStaysWhileItsUsableAreaFlickers() {
        var flicker = airPlay
        flicker.visibleFrame = .zero
        let window = CGRect(x: 1700, y: 300, width: 900, height: 600)
        XCTAssertNil(StrandedWindowRule.rescuedFrame(for: window, screens: [builtIn, flicker], preferred: builtIn))
    }

    func testAWindowOnAListedScreenNeverMoves() {
        // Half under the menu bar, title bar out of reach: still on a listed screen.
        let tucked = CGRect(x: 100, y: 900, width: 600, height: 400)
        XCTAssertNil(StrandedWindowRule.rescuedFrame(for: tucked, screens: [builtIn, airPlay], preferred: builtIn))
        // Straddling the two screens.
        let straddle = CGRect(x: 1300, y: 200, width: 600, height: 400)
        XCTAssertNil(StrandedWindowRule.rescuedFrame(for: straddle, screens: [builtIn, airPlay], preferred: builtIn))
    }

    func testAWindowOnNoScreenGoesOntoThePreferredOneCentredAndFitted() {
        // The AirPlay screen really went: its window is on nothing now.
        let lost = CGRect(x: 1700, y: 300, width: 2000, height: 600)
        let moved = StrandedWindowRule.rescuedFrame(for: lost, screens: [builtIn], preferred: builtIn)
        XCTAssertEqual(moved, CGRect(x: 0, y: 210, width: 1512, height: 600))
    }

    func testNoScreensMovesNothing() {
        XCTAssertNil(StrandedWindowRule.rescuedFrame(for: CGRect(x: 0, y: 0, width: 10, height: 10), screens: [], preferred: nil))
    }

    func testTheLogLineNamesTheWindowItsFrameAndTheScreens() {
        let line = StrandedWindowRule.logLine(windowTitle: "Self view", frame: CGRect(x: 1700, y: 300, width: 900, height: 600),
                                              movedTo: CGRect(x: 306, y: 210, width: 900, height: 600),
                                              onto: "Built-in Retina Display", screens: [builtIn, airPlay])
        XCTAssertTrue(line.contains("\u{201C}Self view\u{201D}"), line)
        XCTAssertTrue(line.contains("1700,300 900\u{00D7}600"), line)
        XCTAssertTrue(line.contains("Built-in Retina Display 0,0 1512\u{00D7}982"), line)
        XCTAssertTrue(line.contains("Sibhimanyu's MacBook Pro (AirPlay) 1512,0 1728\u{00D7}1117"), line)
    }

    func testTheRescueWaitsForTheDisplaysToSettle() {
        XCTAssertEqual(StrandedWindowRule.settleSeconds, 1.5)
    }
}
