import XCTest
import CoreGraphics

final class MeetingBarPlacementTests: XCTestCase {
    private typealias P = MeetingBarPlacement
    private let main = CGRect(x: 0, y: 25, width: 1440, height: 850)      // menu bar above, Dock below
    private let right = CGRect(x: 1440, y: 0, width: 1920, height: 1055)   // a second display, to the right
    private let pill = CGSize(width: 496, height: 44)
    private let puck = CGSize(width: 44, height: 44)

    private func frame(_ x: CGFloat, _ y: CGFloat, _ s: CGSize) -> CGRect { CGRect(origin: CGPoint(x: x, y: y), size: s) }

    // MARK: Clamp and snap

    func testClampPullsAFrameFullyInside() {
        XCTAssertEqual(P.clamp(frame(-50, 0, pill), to: main), frame(0, 25, pill))
        XCTAssertEqual(P.clamp(frame(1300, 900, pill), to: main), frame(944, 831, pill))
        let inside = frame(300, 300, pill)
        XCTAssertEqual(P.clamp(inside, to: main), inside)
    }

    func testClampPinsAFrameLargerThanTheArea() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 30)
        XCTAssertEqual(P.clamp(frame(500, 500, pill), to: tiny).origin, CGPoint(x: 0, y: 0))
    }

    func testSnapDocksWithinTheDistanceAndLeavesTheRest() {
        // 10pt off the left edge, 200 up: docks left at the margin, stays at its height.
        XCTAssertEqual(P.snap(frame(10, 225, pill), to: main), frame(P.edgeMargin, 225, pill))
        // 24pt is in range, 25 is not.
        XCTAssertEqual(P.snap(frame(24, 300, pill), to: main).minX, P.edgeMargin)
        XCTAssertEqual(P.snap(frame(25, 300, pill), to: main).minX, 25)
        // Near the right edge it docks to the right margin.
        XCTAssertEqual(P.snap(frame(main.maxX - pill.width - 5, 300, pill), to: main).maxX, main.maxX - P.edgeMargin)
        // Near the top.
        XCTAssertEqual(P.snap(frame(400, main.maxY - 44 - 8, pill), to: main).maxY, main.maxY - P.edgeMargin)
    }

    func testBottomCentreIsAlreadyDocked() {
        let d = P.defaultFrame(size: pill, in: main)
        XCTAssertEqual(d.minY, main.minY + P.edgeMargin)
        XCTAssertEqual(d.midX, main.midX, accuracy: 0.5)
        XCTAssertEqual(P.snap(d, to: main), d)
    }

    func testSnapPicksTheNearerOfTwoEdges() {
        let narrow = CGRect(x: 0, y: 0, width: 100, height: 400)
        let f = frame(35, 100, puck)   // 35 from the left, 21 from the right: the right is in range and nearer
        XCTAssertEqual(P.snap(f, to: narrow).maxX, narrow.maxX - P.edgeMargin)
    }

    // MARK: Dropping across displays

    func testDropStaysOnTheDisplayItLandedOn() {
        // Mostly on the right display, hanging over the seam.
        let landed = P.drop(frame(1400, 400, pill), areas: [main, right])
        XCTAssertTrue(right.contains(landed))
        XCTAssertFalse(main.intersects(landed.insetBy(dx: 1, dy: 1)))
    }

    func testDropFullyInsideAfterSnapAndClamp() {
        for f in [frame(-200, -200, pill), frame(5000, 5000, puck), frame(1430, 20, puck), frame(1500, 1040, pill)] {
            let d = P.drop(f, areas: [main, right])
            XCTAssertTrue([main, right].contains { $0.contains(d) }, "\(f) -> \(d)")
        }
    }

    func testDropOffEveryScreenGoesToTheNearest() {
        let d = P.drop(frame(-900, 400, pill), areas: [main, right])
        XCTAssertTrue(main.contains(d))
    }

    func testAreaForPicksTheLargestOverlap() {
        XCTAssertEqual(P.area(for: frame(1000, 300, pill), in: [main, right]), main)   // 440 on main, 56 over
        XCTAssertEqual(P.area(for: frame(1300, 300, pill), in: [main, right]), right)  // 140 on main, 356 over
        XCTAssertNil(P.area(for: frame(0, 0, pill), in: []))
    }

    // MARK: Saved spots

    func testRestoreKeepsASavedSpotThatIsStillOnScreen() {
        let saved = frame(300, 400, pill)
        XCTAssertEqual(P.restore(saved: saved, size: pill, areas: [main], defaultArea: main), saved)
    }

    func testRestoreKeepsTheCentreWhenTheWidthChanges() {
        let saved = frame(300, 400, pill)
        let r = P.restore(saved: saved, size: puck, areas: [main], defaultArea: main)
        XCTAssertEqual(r.midX, saved.midX, accuracy: 1)
        XCTAssertEqual(r.size, puck)
    }

    func testRestoreFallsBackToBottomCentreWhenTheScreenIsGone() {
        let onSecond = frame(2000, 400, pill)
        XCTAssertEqual(P.restore(saved: onSecond, size: pill, areas: [main], defaultArea: main),
                       P.defaultFrame(size: pill, in: main))
        XCTAssertEqual(P.restore(saved: nil, size: pill, areas: [main], defaultArea: main),
                       P.defaultFrame(size: pill, in: main))
    }

    func testRestorePullsInASpotThatSticksOut() {
        let r = P.restore(saved: frame(1300, 400, pill), size: pill, areas: [main], defaultArea: main)
        XCTAssertTrue(main.contains(r))
    }

    // MARK: Collapse and expand anchor at the nearest edge

    func testCollapseKeepsTheLeadingEdgeOnTheLeft() {
        let pillAtLeft = frame(16, 100, pill)
        let r = P.resized(from: pillAtLeft, to: puck, in: main)
        XCTAssertEqual(r.minX, pillAtLeft.minX)
        XCTAssertEqual(r.size, puck)
    }

    func testCollapseKeepsTheTrailingEdgeOnTheRight() {
        let pillAtRight = frame(main.maxX - 16 - pill.width, 100, pill)
        let r = P.resized(from: pillAtRight, to: puck, in: main)
        XCTAssertEqual(r.maxX, pillAtRight.maxX)
    }

    func testCollapseAtBottomCentreStaysCentred() {
        let d = P.defaultFrame(size: pill, in: main)
        let r = P.resized(from: d, to: puck, in: main)
        XCTAssertEqual(r.midX, d.midX, accuracy: 0.5)
        XCTAssertEqual(r.minY, d.minY)
    }

    func testExpandFromACornerGrowsAwayFromIt() {
        let puckAtRight = frame(main.maxX - 16 - 44, 400, puck)
        let big = P.resized(from: puckAtRight, to: pill, in: main)
        XCTAssertEqual(big.maxX, puckAtRight.maxX)
        XCTAssertTrue(main.contains(big))
        let puckAtLeft = frame(16, main.maxY - 16 - 44, puck)
        let big2 = P.resized(from: puckAtLeft, to: pill, in: main)
        XCTAssertEqual(big2.minX, puckAtLeft.minX)
        XCTAssertTrue(main.contains(big2))
    }

    func testResizeNeverEndsOffScreen() {
        for x in stride(from: CGFloat(0), through: 1400, by: 70) {
            for y in stride(from: CGFloat(25), through: 830, by: 100) {
                let r = P.resized(from: frame(x, y, puck), to: pill, in: main)
                XCTAssertTrue(main.contains(r), "\(x),\(y) -> \(r)")
            }
        }
    }

    // MARK: Notes bar and toasts stay clear

    private let notes = CGSize(width: 520, height: 64)

    func testNotesRestAboveABarAtTheBottom() {
        let bar = P.defaultFrame(size: pill, in: main)
        XCTAssertEqual(P.notesRestingY(bar: bar, area: main, notesSize: notes), 16 + 44 + 12)
        // A puck at the bottom centre is the same height, so the same place.
        let puckBar = P.defaultFrame(size: puck, in: main)
        XCTAssertEqual(P.notesRestingY(bar: puckBar, area: main, notesSize: notes), 16 + 44 + 12)
    }

    func testNotesGoBackToDefaultWhenTheBarMovedAway() {
        XCTAssertEqual(P.notesRestingY(bar: frame(600, 500, pill), area: main, notesSize: notes), P.edgeMargin)
        XCTAssertEqual(P.notesRestingY(bar: frame(16, 41, puck), area: main, notesSize: notes), P.edgeMargin) // bottom-left corner, off to the side
        XCTAssertEqual(P.notesRestingY(bar: frame(2000, 41, pill), area: main, notesSize: notes), P.edgeMargin) // other display
    }

    func testNotesClearABarThatSitsSlightlyHigher() {
        let bar = frame(472, 85, pill)   // 60 up, centred: overlaps the default notes row
        XCTAssertEqual(P.notesRestingY(bar: bar, area: main, notesSize: notes), bar.maxY + P.stackGap - main.minY)
    }

    func testToastFloorFollowsTheBarOnlyAtTheBottom() {
        let bottom = P.defaultFrame(size: pill, in: main)
        XCTAssertEqual(P.toastFloorY(bar: bottom, area: main, notesHeight: 64), 16 + 44 + 12 + 64 + 12)
        XCTAssertEqual(P.toastFloorY(bar: frame(600, 500, pill), area: main, notesHeight: 64), P.toastDefaultFloor)
        XCTAssertEqual(P.toastFloorY(bar: frame(2000, 41, pill), area: main, notesHeight: 64), P.toastDefaultFloor)
    }

    // MARK: Motion

    func testSpringStartsAtZeroSettlesAtOneAndNeverOvershoots() {
        XCTAssertEqual(P.spring(0), 0)
        XCTAssertEqual(P.spring(P.settleSeconds), 1)
        var last = 0.0
        for i in 1...40 {
            let v = P.spring(Double(i) * 0.01)
            XCTAssertGreaterThanOrEqual(v, last)
            XCTAssertLessThanOrEqual(v, 1)
            last = v
        }
        XCTAssertGreaterThan(P.spring(0.25), 0.95)   // snappy: essentially there at 250ms
    }

    func testLerp() {
        let m = P.lerp(frame(0, 0, pill), frame(100, 50, puck), 0.5)
        XCTAssertEqual(m.minX, 50)
        XCTAssertEqual(m.width, (pill.width + puck.width) / 2)
    }
}
