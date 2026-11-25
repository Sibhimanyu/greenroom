import XCTest
@testable import GreenroomTests

// R15.2 (Q10): Home says "Connect the room display" when the active layout has a Room screen and
// no second display is usable. Never blocks Start.
final class RoomDisplayNoteTests: XCTestCase {
    private func roomLayout() -> LayoutTemplate {
        LayoutTemplate(name: "Room + laptop",
                       twoDisplays: TwoDisplay(second: [LayoutPiece(kind: .roomScreen, rect: .full)], secondUUID: ""))
    }
    private func plainTwoDisplay() -> LayoutTemplate {
        LayoutTemplate(name: "Two", twoDisplays: TwoDisplay(second: [], secondUUID: ""))
    }

    func testRoomScreenWithOneDisplayAsksToConnect() {
        XCTAssertEqual(RoomDisplayNote.note(for: roomLayout(), connectedDisplays: 1, isMirrored: false), .connect)
        XCTAssertEqual(RoomDisplayNote.connect.text, "Connect the room display")
    }
    func testNoteGoesWhenTheSecondDisplayConnects() {
        XCTAssertNil(RoomDisplayNote.note(for: roomLayout(), connectedDisplays: 2, isMirrored: false))
    }
    func testLayoutWithoutRoomScreenHasNoNote() {
        XCTAssertNil(RoomDisplayNote.note(for: plainTwoDisplay(), connectedDisplays: 1, isMirrored: false))
        XCTAssertNil(RoomDisplayNote.note(for: nil, connectedDisplays: 1, isMirrored: false))
    }
    func testMirroredDisplayGetsItsOwnWords() {
        XCTAssertEqual(RoomDisplayNote.note(for: roomLayout(), connectedDisplays: 1, isMirrored: true), .mirrored)
        XCTAssertEqual(RoomDisplayNote.mirrored.text,
                       "Your room display is mirrored. Set it to extended to use the Room screen.")
    }
    func testMirroredFlagIgnoredWhenAnExtendedSecondExists() {
        XCTAssertNil(RoomDisplayNote.note(for: roomLayout(), connectedDisplays: 2, isMirrored: true))
    }
    func testHintAndLink() {
        XCTAssertEqual(RoomDisplayNote.hint,
                       "Set the room's screen as an extended display (not mirrored) in System Settings → Displays.")
        XCTAssertEqual(RoomDisplayNote.openDisplaysSettingsURL,
                       "x-apple.systempreferences:com.apple.Displays-Settings.extension")
    }
}
