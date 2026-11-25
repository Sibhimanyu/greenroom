import XCTest
import CoreGraphics

/// Moving a piece from one display of a two-display layout to the other, and the
/// "Everyone sees" display choice.
final class LayoutDisplayCrossingTests: XCTestCase {
    private let cell = LayoutGeometry.cell
    private let laptop = CGSize(width: 1440, height: 900)
    private let projector = CGSize(width: 2880, height: 1800)
    private let meeting = LayoutPiece.Kind.meeting(fillsDisplay: false, startsHidden: false)
    private let fillingMeeting = LayoutPiece.Kind.meeting(fillsDisplay: true, startsHidden: false)

    private func app(_ id: String, at rect: UnitRect, shows: Bool = true) -> LayoutPiece {
        LayoutPiece(kind: .app(AppPiece(bundleID: id)), rect: rect, showsToEveryone: shows)
    }

    private func template(main: [LayoutPiece] = [], second: [LayoutPiece] = [], shared: LayoutSlot = .main) -> LayoutTemplate {
        var two = TwoDisplay(main: main, second: second)
        two.sharedSlot = shared
        return LayoutTemplate(name: "T", oneDisplay: [], twoDisplays: two)
    }

    private func move(_ t: LayoutTemplate, _ id: UUID, from: LayoutSlot, to: LayoutSlot,
                      at p: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> Result<LayoutTemplate, LayoutPieceMoveRefusal> {
        t.movingPiece(id, from: from, to: to, at: p, fromDisplay: laptop, toDisplay: projector, snapThreshold: 0)
    }

    // MARK: Moving

    func testMoveKeepsIdAndSettingsAndChangesSide() throws {
        let p = app("com.apple.Safari", at: UnitRect(x: 0, y: 0, w: 0.5, h: 0.5), shows: false)
        let t = template(main: [p])
        let out = try move(t, p.id, from: .main, to: .second).get()
        XCTAssertTrue(out.twoDisplays!.main.isEmpty)
        let landed = try XCTUnwrap(out.twoDisplays?.second.first)
        XCTAssertEqual(landed.id, p.id)
        XCTAssertEqual(landed.kind, p.kind)
        XCTAssertFalse(landed.showsToEveryone)
    }

    func testLandsWhereDroppedOnTheGrid() throws {
        let p = app("a", at: UnitRect(x: 0, y: 0, w: 0.25, h: 0.25))
        let out = try move(template(main: [p]), p.id, from: .main, to: .second, at: CGPoint(x: 0.6, y: 0.6)).get()
        let r = try XCTUnwrap(out.twoDisplays?.second.first?.rect)
        XCTAssertEqual(r.x / cell, (r.x / cell).rounded(), accuracy: 1e-6)
        XCTAssertEqual(r.y / cell, (r.y / cell).rounded(), accuracy: 1e-6)
        // The pointer is inside the piece (it is carried by its middle).
        XCTAssertTrue(r.x <= 0.6 && r.maxX >= 0.6 - cell)
    }

    func testClampedInsideTheTargetDisplay() throws {
        let p = app("a", at: UnitRect(x: 0, y: 0, w: 0.5, h: 0.5))
        let out = try move(template(main: [p]), p.id, from: .main, to: .second, at: CGPoint(x: 1.2, y: 1.4)).get()
        let r = try XCTUnwrap(out.twoDisplays?.second.first?.rect)
        XCTAssertLessThanOrEqual(r.maxX, 1 + 1e-9)
        XCTAssertLessThanOrEqual(r.maxY, 1 + 1e-9)
        XCTAssertGreaterThanOrEqual(r.x, 0)
    }

    func testKeepsItsSizeInPointsWhereItFits() throws {
        // 0.5 of 1440 = 720 pt. The projector's cell is 240 pt: three cells.
        let p = app("a", at: UnitRect(x: 0, y: 0, w: 0.5, h: 0.5))
        let out = try move(template(main: [p]), p.id, from: .main, to: .second, at: CGPoint(x: 0.5, y: 0.5)).get()
        let r = try XCTUnwrap(out.twoDisplays?.second.first?.rect)
        XCTAssertEqual(r.w, 3 * cell, accuracy: 1e-6)
        XCTAssertEqual(r.h, 3 * cell, accuracy: 1e-6)
    }

    func testNeverBelowItsMinimumOnTheTarget() throws {
        // A Chat is 280 x 200 pt at least: on the big display that is two cells wide.
        let p = LayoutPiece(kind: .chat, rect: UnitRect(x: 0, y: 0, w: cell, h: cell))
        let out = try move(template(main: [p]), p.id, from: .main, to: .second).get()
        let r = try XCTUnwrap(out.twoDisplays?.second.first?.rect)
        let min = LayoutGeometry.minimumUnitSize(for: .chat, display: projector)
        XCTAssertGreaterThanOrEqual(r.w, min.w - 1e-6)
        XCTAssertGreaterThanOrEqual(r.h, min.h - 1e-6)
    }

    func testOverlapGoesToFreeSpace() throws {
        let p = app("a", at: UnitRect(x: 0, y: 0, w: 0.25, h: 0.25))
        let blocker = app("b", at: UnitRect(x: 0, y: 0, w: 0.5, h: 1))
        let out = try move(template(main: [p], second: [blocker]), p.id, from: .main, to: .second,
                           at: CGPoint(x: 0.55, y: 0.25)).get()
        let landed = try XCTUnwrap(out.twoDisplays?.second.first { $0.id == p.id }?.rect)
        XCTAssertFalse(LayoutGeometry.overlaps(landed, blocker.rect))
    }

    func testNoRoomRefusesAndChangesNothing() {
        let p = app("a", at: UnitRect(x: 0, y: 0, w: 0.25, h: 0.25))
        let full = LayoutPiece(kind: fillingMeeting, rect: .full)
        let t = template(main: [p], second: [full])
        guard case let .failure(why) = move(t, p.id, from: .main, to: .second) else { return XCTFail("moved") }
        XCTAssertEqual(why, .noRoom)
        XCTAssertFalse(why.message.isEmpty)
    }

    func testRoomScreenOnlyGoesToTheSecondDisplay() {
        let room = LayoutPiece(kind: .roomScreen, rect: .full)
        let t = template(main: [], second: [room])
        guard case let .failure(why) = move(t, room.id, from: .second, to: .main) else { return XCTFail("moved") }
        XCTAssertEqual(why, .roomScreenOnSecondOnly)
    }

    func testFillingMeetingStopsFillingOnMain() throws {
        let m = LayoutPiece(kind: fillingMeeting, rect: .full)
        let out = try move(template(main: [], second: [m]), m.id, from: .second, to: .main).get()
        let landed = try XCTUnwrap(out.twoDisplays?.main.first)
        XCTAssertEqual(landed.kind, meeting)
        XCTAssertLessThan(landed.rect.w, 1)
        XCTAssertLessThan(landed.rect.h, 1)
    }

    func testSameDisplayAndMissingPieceAndOneDisplay() {
        let p = app("a", at: UnitRect(x: 0, y: 0, w: 0.25, h: 0.25))
        let t = template(main: [p])
        XCTAssertEqual(move(t, p.id, from: .main, to: .main).failureValue, .sameDisplay)
        XCTAssertEqual(move(t, UUID(), from: .main, to: .second).failureValue, .notFound)
        let one = LayoutTemplate(name: "One", oneDisplay: [p])
        XCTAssertEqual(move(one, p.id, from: .one, to: .second).failureValue, .needsTwoDisplays)
    }

    func testMovingLeavesTheOtherPiecesAlone() throws {
        let a = app("a", at: UnitRect(x: 0, y: 0, w: 0.25, h: 0.25))
        let b = app("b", at: UnitRect(x: 0.5, y: 0.5, w: 0.25, h: 0.25))
        let out = try move(template(main: [a, b]), a.id, from: .main, to: .second).get()
        XCTAssertEqual(out.twoDisplays?.main, [b])
    }

    // MARK: Everyone sees

    func testSharedDisplayDefaultsToMainInOldFiles() throws {
        let json = #"{"main":[],"second":[],"secondUUID":""}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(TwoDisplay.self, from: json).sharedSlot, .main)
        let junk = #"{"main":[],"second":[],"sharedDisplay":"one"}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(TwoDisplay.self, from: junk).sharedSlot, .main)
    }

    func testSharedDisplayRoundTrips() throws {
        var two = TwoDisplay()
        two.sharedSlot = .second
        let back = try JSONDecoder().decode(TwoDisplay.self, from: JSONEncoder().encode(two))
        XCTAssertEqual(back.sharedSlot, .second)
    }

    func testRoomScreenCannotJoinTheSharedDisplay() {
        let t = template(shared: .second)
        XCTAssertFalse(t.canAdd(.roomScreen, to: .second))
        XCTAssertNotNil(t.roomScreenBlockReason)
        XCTAssertTrue(template(shared: .main).canAdd(.roomScreen, to: .second))
    }

    func testRoomScreenOnSecondBlocksSharingTheSecond() {
        let room = LayoutPiece(kind: .roomScreen, rect: .full)
        XCTAssertFalse(template(second: [room]).canShareSecondDisplay)
        XCTAssertTrue(template(second: []).canShareSecondDisplay)
    }

    func testRoomScreenForcesMainInAHandEditedFile() {
        let room = LayoutPiece(kind: .roomScreen, rect: .full)
        XCTAssertEqual(template(second: [room], shared: .second).effectiveSharedSlot, .main)
        XCTAssertEqual(template(shared: .second).effectiveSharedSlot, .second)
    }

    private let main = LayoutScreen(id: "MAIN", name: "Laptop", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), isMain: true)
    private let other = LayoutScreen(id: "OTHER", name: "Projector", visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), isMain: false)
    private let third = LayoutScreen(id: "THIRD", name: "Dell", visibleFrame: CGRect(x: 3360, y: 0, width: 1920, height: 1080), isMain: false)

    func testSharedDisplayUUIDFollowsTheChoice() {
        XCTAssertEqual(LayoutSharedDisplay.uuid(template: template(shared: .main), screens: [main, other]), "MAIN")
        XCTAssertEqual(LayoutSharedDisplay.uuid(template: template(shared: .second), screens: [main, other]), "OTHER")
    }

    func testSharedDisplayUsesTheChosenSecond() {
        var t = template(shared: .second)
        t.twoDisplays?.secondUUID = "THIRD"
        XCTAssertEqual(LayoutSharedDisplay.uuid(template: t, screens: [main, other, third]), "THIRD")
        // Saved second not plugged in: the resolver takes the first other one, so does this.
        XCTAssertEqual(LayoutSharedDisplay.uuid(template: t, screens: [main, other]), "OTHER")
    }

    func testNoSecondDisplayFallsBackToNoOverride() {
        XCTAssertNil(LayoutSharedDisplay.uuid(template: template(shared: .second), screens: [main]))
        XCTAssertNil(LayoutSharedDisplay.uuid(template: nil, screens: [main, other]))
        let one = LayoutTemplate(name: "One", oneDisplay: [])
        XCTAssertNil(LayoutSharedDisplay.uuid(template: one, screens: [main, other]))
    }

    func testRoomScreenKeepsTheShareOnMain() {
        let room = LayoutPiece(kind: .roomScreen, rect: .full)
        XCTAssertEqual(LayoutSharedDisplay.uuid(template: template(second: [room], shared: .second), screens: [main, other]), "MAIN")
    }

    func testOnlyWholeScreenSharesFollowTheLayout() {
        XCTAssertEqual(LayoutSharedDisplay.resolved(wholeScreen: true, layout: "MAIN", chosen: "X"), "MAIN")
        XCTAssertEqual(LayoutSharedDisplay.resolved(wholeScreen: false, layout: "MAIN", chosen: "X"), "X")
        XCTAssertEqual(LayoutSharedDisplay.resolved(wholeScreen: true, layout: nil, chosen: "X"), "X")
    }
}

private extension Result {
    var failureValue: Failure? { if case let .failure(e) = self { return e } else { return nil } }
}
