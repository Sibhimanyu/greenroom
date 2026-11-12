import XCTest
import CoreGraphics

final class LayoutGeometryTests: XCTestCase {
    private let c = LayoutGeometry.cell
    private func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> UnitRect {
        UnitRect(x: Double(x) * c, y: Double(y) * c, w: Double(w) * c, h: Double(h) * c)
    }

    // MARK: Grid and snapping

    func testMoveSnapsToTheGrid() {
        let r = rect(0, 0, 4, 4)
        let out = LayoutGeometry.snapMove(r, toOrigin: CGPoint(x: 2.3 * c, y: 1.8 * c), neighbours: [], threshold: 0.005)
        XCTAssertEqual(out.rect.x, 2 * c, accuracy: 1e-9)
        XCTAssertEqual(out.rect.y, 2 * c, accuracy: 1e-9)
        XCTAssertTrue(out.guidesX.isEmpty && out.guidesY.isEmpty)
    }

    func testMoveSticksToNeighbourEdgeWithAGuide() {
        let neighbour = UnitRect(x: 0.5 + 0.01, y: 0, w: 0.3, h: 1)   // an off-grid edge
        let r = rect(0, 0, 4, 4)
        // Right edge lands 0.004 short of the neighbour's left edge.
        let origin = CGPoint(x: neighbour.x - r.w - 0.004, y: 0.2)
        let out = LayoutGeometry.snapMove(r, toOrigin: origin, neighbours: [neighbour], threshold: 0.01)
        XCTAssertEqual(out.rect.maxX, neighbour.x, accuracy: 1e-9)
        XCTAssertEqual(out.guidesX, [neighbour.x])
    }

    func testMoveStaysInsideTheDisplay() {
        let out = LayoutGeometry.snapMove(rect(0, 0, 4, 4), toOrigin: CGPoint(x: 5, y: -3), neighbours: [], threshold: 0.01)
        XCTAssertEqual(out.rect.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(out.rect.y, 0, accuracy: 1e-9)
    }

    func testDisplayEdgeGuide() {
        let out = LayoutGeometry.snapMove(rect(0, 0, 4, 4), toOrigin: CGPoint(x: 8 * c + 0.003, y: 0.3), neighbours: [], threshold: 0.01)
        XCTAssertEqual(out.rect.maxX, 1, accuracy: 1e-9)
        XCTAssertEqual(out.guidesX, [1])
    }

    // MARK: Overlap

    func testTouchingIsNotOverlapping() {
        XCTAssertFalse(LayoutGeometry.overlaps(rect(0, 0, 6, 12), rect(6, 0, 6, 12)))
        XCTAssertTrue(LayoutGeometry.overlaps(rect(0, 0, 7, 12), rect(6, 0, 6, 12)))
    }

    func testResizeStopsAtANeighbour() {
        let a = rect(0, 0, 4, 12), b = rect(8, 0, 4, 12)
        let out = LayoutGeometry.snapResize(a, handle: .right, delta: CGPoint(x: 0.9, y: 0), neighbours: [b],
                                            minimum: (w: 2 * c, h: 2 * c), threshold: 0.005)
        XCTAssertEqual(out.rect.maxX, b.x, accuracy: 1e-9)
    }

    func testResizeHonoursTheMinimum() {
        let a = rect(0, 0, 6, 6)
        let out = LayoutGeometry.snapResize(a, handle: .bottomRight, delta: CGPoint(x: -0.9, y: -0.9), neighbours: [],
                                            minimum: (w: 3 * c, h: 2 * c), threshold: 0.005)
        XCTAssertEqual(out.rect.w, 3 * c, accuracy: 1e-9)
        XCTAssertEqual(out.rect.h, 2 * c, accuracy: 1e-9)
    }

    func testResizeFromTheLeftKeepsTheRightEdge() {
        let a = rect(4, 0, 4, 12)
        let out = LayoutGeometry.snapResize(a, handle: .left, delta: CGPoint(x: -2 * c, y: 0), neighbours: [],
                                            minimum: (w: c, h: c), threshold: 0.005)
        XCTAssertEqual(out.rect.x, 2 * c, accuracy: 1e-9)
        XCTAssertEqual(out.rect.maxX, 8 * c, accuracy: 1e-9)
    }

    // MARK: Free space

    func testLargestFreeRectBesideAColumn() {
        let free = LayoutGeometry.largestFreeRect(avoiding: [rect(0, 0, 8, 12)])
        XCTAssertEqual(free, rect(8, 0, 4, 12))
    }

    func testLargestFreeRectUnderThePointer() {
        let others = [rect(0, 0, 12, 3), rect(0, 3, 3, 9)]
        // Largest overall is the 9x9 block bottom-right; a point in the free
        // strip... there is none above, so a point on a piece finds nothing.
        XCTAssertEqual(LayoutGeometry.largestFreeRect(avoiding: others, containing: CGPoint(x: 0.7, y: 0.7)),
                       rect(3, 3, 9, 9))
        XCTAssertNil(LayoutGeometry.largestFreeRect(avoiding: others, containing: CGPoint(x: 0.05, y: 0.05)))
    }

    func testNoFreeRectWhenFull() {
        XCTAssertNil(LayoutGeometry.largestFreeRect(avoiding: [.full]))
    }

    func testMinimumSizeFiltersFreeRects() {
        let others = [rect(0, 0, 11, 12)]   // one column left
        XCTAssertNotNil(LayoutGeometry.largestFreeRect(avoiding: others, minCols: 1, minRows: 1))
        XCTAssertNil(LayoutGeometry.largestFreeRect(avoiding: others, minCols: 2, minRows: 1))
    }

    func testDropOnANeighbourLandsInFreeSpace() {
        let others = [rect(0, 0, 8, 12)]
        let dropped = rect(6, 2, 4, 4)   // overlaps the neighbour
        let out = LayoutGeometry.resolveDrop(dropped, pointer: CGPoint(x: 0.9, y: 0.3), others: others,
                                             minimum: (w: 2 * c, h: 2 * c))
        XCTAssertNotNil(out)
        XCTAssertFalse(LayoutGeometry.hasOverlap(out!, with: others))
        XCTAssertGreaterThanOrEqual(out!.x, 8 * c - 1e-9)
    }

    func testDropSpringsBackWithNoRoom() {
        let others = [rect(0, 0, 12, 12)]
        XCTAssertNil(LayoutGeometry.resolveDrop(rect(2, 2, 3, 3), pointer: CGPoint(x: 0.3, y: 0.3), others: others,
                                                minimum: (w: c, h: c)))
    }

    func testPlaceNewUsesTheLargestFreeRect() {
        let display = CGSize(width: 1440, height: 900)
        let out = LayoutGeometry.placeNew(.chat, avoiding: [rect(0, 0, 8, 12)], display: display)
        XCTAssertEqual(out?.x ?? -1, 8 * c, accuracy: 1e-9)
        XCTAssertNil(LayoutGeometry.placeNew(.chat, avoiding: [.full], display: display))
    }

    // MARK: Minimums and keyboard

    func testMinimumsBecomeWholeCellsPerDisplay() {
        // 1440 wide: a cell is 120pt, so 320 -> 3 cells; 900 high: 75pt, 200 -> 3 cells.
        let m = LayoutGeometry.minimumCells(for: .meeting(fillsDisplay: false, startsHidden: false),
                                            display: CGSize(width: 1440, height: 900))
        XCTAssertEqual(m.cols, 3); XCTAssertEqual(m.rows, 3)
        // An app on a small 1024x640 display: 400/85.33 -> 5, 300/53.33 -> 6.
        let a = LayoutGeometry.minimumCells(for: .app(AppPiece(bundleID: "x")), display: CGSize(width: 1024, height: 640))
        XCTAssertEqual(a.cols, 5); XCTAssertEqual(a.rows, 6)
    }

    func testMinimumNeverExceedsTheGrid() {
        let m = LayoutGeometry.minimumCells(for: .app(AppPiece(bundleID: "x")), display: CGSize(width: 200, height: 100))
        XCTAssertEqual(m.cols, 12); XCTAssertEqual(m.rows, 12)
    }

    func testArrowMovesOneCellAndStopsAtEdgesAndNeighbours() throws {
        let r = rect(2, 2, 4, 4)
        XCTAssertTrue(LayoutGeometry.same(try XCTUnwrap(LayoutGeometry.moved(r, cols: 1, rows: 0, neighbours: [])), rect(3, 2, 4, 4)))
        XCTAssertNil(LayoutGeometry.moved(rect(8, 0, 4, 4), cols: 1, rows: 0, neighbours: []))
        XCTAssertNil(LayoutGeometry.moved(rect(2, 2, 4, 4), cols: 1, rows: 0, neighbours: [rect(6, 0, 6, 12)]))
    }

    func testShiftArrowResizesFromTheRightOrBottom() throws {
        let r = rect(2, 2, 4, 4)
        let out = LayoutGeometry.resized(r, cols: 1, rows: 0, neighbours: [], minimum: (w: c, h: c))
        XCTAssertTrue(LayoutGeometry.same(try XCTUnwrap(out), rect(2, 2, 5, 4)))
        XCTAssertNil(LayoutGeometry.resized(r, cols: -4, rows: 0, neighbours: [], minimum: (w: c, h: c)))
    }

    // MARK: Labels and frames

    func testCellSpanReadsLikeSpeech() {
        let s = LayoutGeometry.cellSpan(of: rect(8, 5, 4, 7))
        XCTAssertEqual(s.cols, 9...12)
        XCTAssertEqual(s.rows, 6...12)
    }

    func testNSAndAXFrames() {
        // A 1000x600 usable area whose bottom-left is (100, 50) on a 700-high primary.
        let visible = CGRect(x: 100, y: 50, width: 1000, height: 600)
        let r = UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.25)    // top-right quarter-height block
        let ns = LayoutGeometry.nsFrame(for: r, visibleFrame: visible)
        XCTAssertEqual(ns, CGRect(x: 600, y: 500, width: 500, height: 150))
        let ax = LayoutGeometry.axFrame(for: r, visibleFrame: visible, primaryHeight: 700)
        XCTAssertEqual(ax, CGRect(x: 600, y: 50, width: 500, height: 150))
    }

    func testPointSizeReadout() {
        let s = LayoutGeometry.pointSize(of: UnitRect(x: 0, y: 0, w: 8.0 / 12, h: 1), display: CGSize(width: 1440, height: 875))
        XCTAssertEqual(s.w, 960); XCTAssertEqual(s.h, 875)
    }
}
