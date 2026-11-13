import XCTest

/// The tile look (App/UI/TileAppearance.swift) and the main-window matcher.
final class TileAppearanceTests: XCTestCase {

    func testBrowseTileHasNoBoxAtRest() {
        let a = TileAppearance.resolve(role: .browse, hovering: false, pressed: false, reduceMotion: false)
        XCTAssertEqual(a.fill, .none)
        XCTAssertEqual(a.offsetY, 0)
        XCTAssertFalse(a.showsSelectionRing)
    }

    func testBrowseTileGainsBackdropAndLiftsOnHover() {
        let a = TileAppearance.resolve(role: .browse, hovering: true, pressed: false, reduceMotion: false)
        XCTAssertEqual(a.fill, .quinary)
        XCTAssertEqual(a.offsetY, -1)
        XCTAssertEqual(a.shadowOpacity, 0.12)
    }

    func testChoiceTileRestsOnQuinaryAndHoverStepsUp() {
        let rest = TileAppearance.resolve(role: .choice(selected: false), hovering: false, pressed: false, reduceMotion: false)
        let hover = TileAppearance.resolve(role: .choice(selected: false), hovering: true, pressed: false, reduceMotion: false)
        XCTAssertEqual(rest.fill, .quinary)
        XCTAssertEqual(hover.fill, .quaternary)
    }

    func testOnlyAChosenChoiceTileShowsTheRing() {
        XCTAssertTrue(TileAppearance.resolve(role: .choice(selected: true), hovering: false, pressed: false, reduceMotion: false).showsSelectionRing)
        XCTAssertFalse(TileAppearance.resolve(role: .choice(selected: false), hovering: true, pressed: false, reduceMotion: false).showsSelectionRing)
        XCTAssertFalse(TileAppearance.resolve(role: .browse, hovering: true, pressed: true, reduceMotion: false).showsSelectionRing)
    }

    func testPressedScalesDown() {
        let a = TileAppearance.resolve(role: .browse, hovering: true, pressed: true, reduceMotion: false)
        XCTAssertEqual(a.scale, 0.98)
        XCTAssertEqual(a.offsetY, 0)
    }

    func testReduceMotionChangesFillOnly() {
        let a = TileAppearance.resolve(role: .browse, hovering: true, pressed: false, reduceMotion: true)
        XCTAssertEqual(a.fill, .quinary)
        XCTAssertEqual(a.offsetY, 0)
        XCTAssertEqual(a.shadowOpacity, 0)
        let p = TileAppearance.resolve(role: .browse, hovering: true, pressed: true, reduceMotion: true)
        XCTAssertEqual(p.scale, 1)
    }

    func testMainWindowIdentifierMatching() {
        XCTAssertTrue(MainWindow.matches(identifier: "main"))
        XCTAssertTrue(MainWindow.matches(identifier: "main-AppWindow-1"))
        XCTAssertFalse(MainWindow.matches(identifier: "mainframe"))
        XCTAssertFalse(MainWindow.matches(identifier: "editor-AppWindow-1"))
        XCTAssertFalse(MainWindow.matches(identifier: nil))
    }
}
