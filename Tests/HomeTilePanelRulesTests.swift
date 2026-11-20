import XCTest

final class HomeTilePanelRulesTests: XCTestCase {
    func testKeyMovementClampsAtEnds() {
        XCTAssertEqual(HomeTileKeyRules.moved(from: 0, by: -1, count: 5), 0)
        XCTAssertEqual(HomeTileKeyRules.moved(from: 4, by: 1, count: 5), 4)
        XCTAssertEqual(HomeTileKeyRules.moved(from: 2, by: 1, count: 5), 3)
        XCTAssertEqual(HomeTileKeyRules.moved(from: 0, by: 1, count: 0), 0)
        XCTAssertEqual(HomeTileKeyRules.startIndex(selected: 3, count: 5), 3)
        XCTAssertEqual(HomeTileKeyRules.startIndex(selected: nil, count: 5), 0)
        XCTAssertEqual(HomeTileKeyRules.startIndex(selected: 9, count: 5), 4)
    }

    func testSwitchingSectionNeedsTwoChosenAndSwitchOn() {
        XCTAssertEqual(CameraPanelRules.sections(switchOn: true, chosenCount: 2), [.cameras, .switching])
        XCTAssertEqual(CameraPanelRules.sections(switchOn: true, chosenCount: 1), [.cameras])
        XCTAssertEqual(CameraPanelRules.sections(switchOn: false, chosenCount: 3), [.cameras])
        XCTAssertTrue(CameraPanelRules.showsPickAnotherHint(switchOn: true, chosenCount: 1))
        XCTAssertFalse(CameraPanelRules.showsPickAnotherHint(switchOn: true, chosenCount: 2))
        XCTAssertFalse(CameraPanelRules.showsPickAnotherHint(switchOn: false, chosenCount: 0))
    }

    func testSwitchToggleNeedsTwoCameras() {
        XCTAssertFalse(CameraPanelRules.showsSwitchToggle(availableCount: 1))
        XCTAssertTrue(CameraPanelRules.showsSwitchToggle(availableCount: 2))
    }

    func testTapPicksOneWhenSwitchOff() {
        XCTAssertEqual(CameraPanelRules.tapped(uid: "b", switchOn: false, order: ["a", "b"]), ["b", "a"])
        XCTAssertEqual(CameraPanelRules.tapped(uid: "c", switchOn: false, order: []), ["c"])
    }

    func testTapTogglesWhenSwitchOn() {
        XCTAssertEqual(CameraPanelRules.tapped(uid: "b", switchOn: true, order: ["a"]), ["a", "b"])
        XCTAssertEqual(CameraPanelRules.tapped(uid: "a", switchOn: true, order: ["a", "b"]), ["b"])
    }

    func testSelectionAndPosition() {
        XCTAssertTrue(CameraPanelRules.isSelected(uid: "a", switchOn: false, order: ["a", "b"], single: "a", noCamera: false))
        XCTAssertFalse(CameraPanelRules.isSelected(uid: "a", switchOn: false, order: ["a"], single: "a", noCamera: true))
        XCTAssertTrue(CameraPanelRules.isSelected(uid: "b", switchOn: true, order: ["a", "b"], single: "a", noCamera: false))
        XCTAssertEqual(CameraPanelRules.position(of: "b", switchOn: true, order: ["a", "b"]), 2)
        XCTAssertNil(CameraPanelRules.position(of: "b", switchOn: false, order: ["a", "b"]))
    }

    func testSwitchingOnKeepsCurrentCamera() {
        XCTAssertEqual(CameraPanelRules.orderWhenSwitchingOn(order: ["b"], single: "a"), ["a", "b"])
        XCTAssertEqual(CameraPanelRules.orderWhenSwitchingOn(order: ["a", "b"], single: "a"), ["a", "b"])
        XCTAssertEqual(CameraPanelRules.orderWhenSwitchingOn(order: [], single: nil), [])
    }

    func testChosenIgnoresUnplugged() {
        XCTAssertEqual(CameraPanelRules.chosen(order: ["a", "x", "b"], available: ["b", "a"]), ["a", "b"])
    }

    func testHeaderValue() {
        XCTAssertEqual(CameraPanelRules.headerValue(noCamera: true, switchOn: false, chosenCount: 0, singleName: "Cam"), "Off")
        XCTAssertEqual(CameraPanelRules.headerValue(noCamera: false, switchOn: true, chosenCount: 2, singleName: "Cam"), "2 cameras, switching")
        XCTAssertEqual(CameraPanelRules.headerValue(noCamera: false, switchOn: false, chosenCount: 1, singleName: "Cam"), "Cam")
        XCTAssertEqual(CameraPanelRules.headerValue(noCamera: false, switchOn: false, chosenCount: 0, singleName: nil), "No camera found")
    }

    func testNoCameraRefusedWhenNothingShared() {
        XCTAssertFalse(CameraPanelRules.noCameraEnabled(shareIsNothing: true))
        XCTAssertTrue(CameraPanelRules.noCameraEnabled(shareIsNothing: false))
    }

    func testSymbols() {
        XCTAssertEqual(CameraPanelRules.symbol(name: "X", isBuiltIn: true), "laptopcomputer")
        XCTAssertEqual(CameraPanelRules.symbol(name: "Sibhi's iPhone Camera", isBuiltIn: false), "iphone")
        XCTAssertEqual(CameraPanelRules.symbol(name: "Logitech", isBuiltIn: false), "web.camera")
    }
}
