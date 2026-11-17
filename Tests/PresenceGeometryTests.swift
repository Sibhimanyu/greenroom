import XCTest
import CoreGraphics

final class PresenceGeometryTests: XCTestCase {
    // A 16:10 laptop display at a non-zero origin, drawn aspect-fitted on the canvas.
    private let display = CGRect(x: 1440, y: -200, width: 1440, height: 900)
    private var fitted: CGRect {
        let h = 1080.0, w = h * 1440 / 900          // pillarboxed: 1728 x 1080
        return CGRect(x: (1920 - w) / 2, y: 0, width: w, height: h)
    }

    private func close(_ a: PresenceBox, _ b: PresenceBox, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.widthFraction, b.widthFraction, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.rightInset, b.rightInset, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.bottomInset, b.bottomInset, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.cutoutHeightFraction, b.cutoutHeightFraction, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(a.cutoutRightInset, b.cutoutRightInset, accuracy: 1e-9, file: file, line: line)
    }

    func testFullCanvasDisplayMapsOneToOneInFractions() {
        let g = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: nil)
        let box = PresenceBox(widthFraction: 0.25, rightInset: 0.05, bottomInset: 0.10)
        let f = g.frame(for: box, aspect: 1)
        XCTAssertEqual(f.width, 480, accuracy: 1e-9)
        XCTAssertEqual(f.height, 480, accuracy: 1e-9)
        XCTAssertEqual(f.maxX, 1920 - 96, accuracy: 1e-9)          // 5% of 1920 from the right
        XCTAssertEqual(f.minY, 108, accuracy: 1e-9)                // 10% of 1080 above the bottom (Cocoa y up)
    }

    func testRoundTripOnAnOffsetLetterboxedDisplay() {
        let g = PresenceGeometry(display: display, content: fitted)
        let box = PresenceBox(widthFraction: 0.3, rightInset: 0.2, bottomInset: 0.15)
        let f = g.frame(for: box, aspect: 16.0 / 9.0)
        close(g.layout(applying: f, to: box, aspect: 16.0 / 9.0), box)
        XCTAssertEqual(f.width / f.height, 16.0 / 9.0, accuracy: 1e-9)
    }

    func testMovingTheBubbleLeftRaisesTheRightInset() {
        let g = PresenceGeometry(display: display, content: fitted)
        let box = PresenceBox()
        // The renderer rounds the box to whole canvas pixels, so these are exact to a pixel.
        let f = g.frame(for: box, aspect: 1)
        let moved = g.layout(applying: f.offsetBy(dx: -100, dy: 0), to: box, aspect: 1)
        // The default inset (4.5%) puts the box in the right bar, so it first slides onto the content (inset 96px).
        let slidInset = (1920 - fitted.maxX) / 1920
        XCTAssertEqual(moved.rightInset - slidInset, 100 * g.scale / 1920, accuracy: 0.002)
        XCTAssertEqual(moved.bottomInset, box.bottomInset, accuracy: 0.002)
        XCTAssertEqual(moved.widthFraction, box.widthFraction, accuracy: 0.002)
    }

    func testMovingUpRaisesTheBottomInset() {
        let g = PresenceGeometry(display: display, content: fitted)
        let box = PresenceBox()
        let f = g.frame(for: box, aspect: 1)
        let moved = g.layout(applying: f.offsetBy(dx: 0, dy: 50), to: box, aspect: 1)   // Cocoa y up
        XCTAssertEqual(moved.bottomInset - box.bottomInset, 50 * g.scale / 1080, accuracy: 0.002)
    }

    func testResultsAreClampedToWhatTheCoordinatorAccepts() {
        let g = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: nil)
        let huge = g.layout(applying: CGRect(x: 500, y: -300, width: 1800, height: 1800), to: PresenceBox())
        XCTAssertEqual(huge.widthFraction, 0.6, accuracy: 1e-9)
        XCTAssertEqual(huge.rightInset, 0, accuracy: 1e-9)             // right edge is past the screen
        XCTAssertEqual(huge.bottomInset, 0, accuracy: 1e-9)            // bottom edge is below it
        let high = g.layout(applying: CGRect(x: 0, y: 1000, width: 200, height: 80), to: PresenceBox())
        XCTAssertEqual(high.bottomInset, 1 - 200.0 / 1920 * 1920 / (16.0 / 9.0) / 1080, accuracy: 1e-9)   // the box must still fit under the top edge
    }

    func testCutoutUsesHeightAndItsOwnInsetAndStaysFlushWithTheBottom() {
        let g = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: nil)
        let box = PresenceBox(cutoutHeightFraction: 0.5, cutoutRightInset: 0.02, isCutout: true)
        let f = g.frame(for: box, aspect: 16.0 / 9.0)
        XCTAssertEqual(f.height, 540, accuracy: 1e-9)
        XCTAssertEqual(f.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(f.maxX, 1920 - 0.02 * 1920, accuracy: 1e-9)
        let moved = g.layout(applying: f.offsetBy(dx: -192, dy: 300), to: box)
        XCTAssertEqual(moved.cutoutRightInset, 0.12, accuracy: 1e-9)
        XCTAssertEqual(moved.bottomInset, box.bottomInset, accuracy: 1e-9)      // untouched
        XCTAssertEqual(moved.rightInset, box.rightInset, accuracy: 1e-9)
        XCTAssertEqual(moved.cutoutHeightFraction, 0.5, accuracy: 1e-9)
    }

    func testWidthRangeMatchesTheCoordinatorsFractions() {
        let g = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 960, height: 540), content: nil)   // scale 2
        let r = g.widthRange(for: PresenceBox(), aspect: 1)
        XCTAssertEqual(r.lowerBound, 0.08 * 1920 / 2, accuracy: 1e-9)
        XCTAssertEqual(r.upperBound, 0.5625 * 1920 / 2, accuracy: 1e-9)   // a square cannot be taller than the canvas: 1080 / 1920
    }

    /// The size bug: a 16:10 laptop display shared whole sits pillarboxed on
    /// the canvas. The bubble, mapped back through the content rect, must be the
    /// rect the renderer draws, for every shape, and its size relative to the
    /// screen must equal the camera's size relative to the shared picture.
    func testBubbleMatchesTheRenderersCameraRectOnA16by10Display() {
        let canvas = CGSize(width: 1920, height: 1080)
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let h = 1080.0, w = h * 1512 / 982
        let content = CGRect(x: (1920 - w) / 2, y: 0, width: w, height: h)
        let g = PresenceGeometry(display: laptop, content: content)
        let cases: [(PresenceBox, Double)] = [
            (PresenceBox(), 1),                                            // circle / square
            (PresenceBox(widthFraction: 0.3, rightInset: 0.1, bottomInset: 0.12), 4.0 / 3.0),  // rounded rectangle
            (PresenceBox(widthFraction: 0.3, rightInset: 0.1, bottomInset: 0.12), 16.0 / 9.0),
            (PresenceBox(cutoutHeightFraction: 0.6, cutoutRightInset: 0.05, isCutout: true), 0.8),   // cutout
        ]
        for (box, aspect) in cases {
            let r = PresenceGeometry.cameraRect(for: box, aspect: aspect, canvas: canvas, bounds: content)
            let f = g.frame(for: box, aspect: aspect)
            // Back to the canvas through the content rect.
            let s = content.width / laptop.width
            let x = content.minX + (f.minX - laptop.minX) * s
            let top = content.minY + (laptop.maxY - f.maxY) * s
            XCTAssertEqual(x, r.minX, accuracy: 1e-6)
            XCTAssertEqual(top, r.minY, accuracy: 1e-6)
            XCTAssertEqual(f.width * s, r.width, accuracy: 1e-6)
            XCTAssertEqual(f.height * s, r.height, accuracy: 1e-6)
            // Relative to the screen: the camera's share of the shared picture.
            XCTAssertEqual(f.width / laptop.width, r.width / content.width, accuracy: 1e-9)
            XCTAssertEqual(f.height / laptop.height, r.height / content.height, accuracy: 1e-9)
        }
        // The old assumption (display fills the canvas) was wrong by this much.
        let wrong = PresenceGeometry(display: laptop, content: nil).frame(for: PresenceBox(), aspect: 1)
        XCTAssertGreaterThan(abs(wrong.width / laptop.width - 0.24 * 1920 / content.width), 0.02)
    }

    // MARK: inside the canvas

    private let full = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: nil)

    private func assertInsideCanvas(_ r: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(r.minX, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.minY, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxX, 1920 + 1e-9, file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxY, 1080 + 1e-9, file: file, line: line)
    }

    func testTopLeftCornerDragKeepsTheWholeBoxOnTheCanvas() {
        let box = PresenceBox(widthFraction: 0.3, rightInset: 0.045, bottomInset: 0.06)
        let size = full.frame(for: box, aspect: 16.0 / 9.0)
        // Dragged far past the top-left corner of the screen.
        let moved = full.layout(applying: CGRect(x: -400, y: 1500, width: size.width, height: size.height),
                                to: box, aspect: 16.0 / 9.0)
        let r = PresenceGeometry.cameraRect(for: moved, aspect: 16.0 / 9.0, canvas: full.canvas)
        assertInsideCanvas(r)
        XCTAssertEqual(r.minX, 0, accuracy: 1.5)
        XCTAssertEqual(r.minY, 0, accuracy: 1.5)
        // The bubble that follows is the same rect, so nothing sticks out of the screen.
        let f = full.frame(for: moved, aspect: 16.0 / 9.0)
        XCTAssertEqual(f.minX, 0, accuracy: 1.5)
        XCTAssertEqual(f.maxY, 1080, accuracy: 1.5)
    }

    func testStaleInsetsThatWouldPutTheCameraOffCanvasAreClampedByTheRenderer() {
        let box = PresenceBox(widthFraction: 0.6, rightInset: 0.9, bottomInset: 0.9)
        assertInsideCanvas(PresenceGeometry.cameraRect(for: box, aspect: 16.0 / 9.0, canvas: full.canvas))
        assertInsideCanvas(PresenceGeometry.cameraRect(for: box, aspect: 0.5, canvas: full.canvas))
    }

    func testLargeSizesAreCappedSoTheBoxFitsTheCanvasHeight() {
        // A portrait camera at 60% of the width would be taller than the canvas.
        let box = PresenceBox(widthFraction: 0.6)
        let r = PresenceGeometry.cameraRect(for: box, aspect: 0.5, canvas: full.canvas)
        assertInsideCanvas(r)
        XCTAssertEqual(r.height, 1080, accuracy: 1)
        XCTAssertEqual(full.maxWidthFraction(for: box, aspect: 0.5), 0.28125, accuracy: 1e-9)   // 1080 * 0.5 / 1920
        XCTAssertEqual(Double(full.widthRange(for: box, aspect: 0.5).upperBound), 540, accuracy: 1e-9)
        let asked = full.layout(applying: CGRect(x: 0, y: 0, width: 1500, height: 3000), to: box, aspect: 0.5)
        XCTAssertEqual(asked.widthFraction, 0.28125, accuracy: 1e-9)
        XCTAssertEqual(asked.bottomInset, 0, accuracy: 1e-9)
    }

    func testBiggestBoxLeavesNoRoomToMove() {
        let box = PresenceBox(widthFraction: 0.6)
        let f = full.frame(for: box, aspect: 16.0 / 9.0)
        let moved = full.layout(applying: f.offsetBy(dx: -900, dy: 0), to: box, aspect: 16.0 / 9.0)
        XCTAssertEqual(moved.rightInset, 0.4, accuracy: 1e-9)          // 1 - 0.6: flush with the left edge
        XCTAssertEqual(full.slid(f.offsetBy(dx: -5000, dy: 5000)).minX, 0, accuracy: 1e-9)
        XCTAssertEqual(full.slid(f.offsetBy(dx: -5000, dy: 5000)).maxY, 1080, accuracy: 1e-9)
    }

    func testCutoutStaysInsideTheCanvasAtEveryEdge() {
        let box = PresenceBox(cutoutHeightFraction: 1.0, cutoutRightInset: 0.9, isCutout: true)
        for a in [0.5, 0.8, 16.0 / 9.0, 2.5] {
            assertInsideCanvas(PresenceGeometry.cameraRect(for: box, aspect: a, canvas: full.canvas))
        }
        let small = PresenceBox(cutoutHeightFraction: 0.5, cutoutRightInset: 0.02, isCutout: true)
        let f = full.frame(for: small, aspect: 0.8)
        let moved = full.layout(applying: f.offsetBy(dx: -4000, dy: 0), to: small, aspect: 0.8)
        let w = 0.5 * 1080 * 0.8 / 1920                                // box width as a canvas fraction
        XCTAssertEqual(moved.cutoutRightInset, 1 - w, accuracy: 1e-9)  // flush with the left edge
        let r = PresenceGeometry.cameraRect(for: moved, aspect: 0.8, canvas: full.canvas)
        XCTAssertEqual(r.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(r.maxY, 1080, accuracy: 1e-9)                   // still flush with the bottom
    }

    func testBoundsOnScreenIsTheDisplayNotTheBars() {
        let g = PresenceGeometry(display: display, content: fitted)
        XCTAssertEqual(g.boundsOnScreen, display)
    }

    // MARK: camera stays over the content, never in the bars

    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private var laptopContent: CGRect {
        let h = 1080.0, w = h * 1512 / 982
        return CGRect(x: (1920 - w) / 2, y: 0, width: w, height: h)
    }

    func testPlacementInTheRightBarSlidesToTheContentsRightEdge() {
        let c = laptopContent
        let g = PresenceGeometry(display: laptop, content: c)
        let box = PresenceBox(widthFraction: 0.24, rightInset: 0.01, bottomInset: 0.06)   // 19px from the canvas edge: in the bar
        let r = PresenceGeometry.cameraRect(for: box, aspect: 1, canvas: g.canvas, bounds: c)
        XCTAssertEqual(r.maxX, c.maxX, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(r.minX, c.minX)
        // Without bounds the same box stays in the bar.
        XCTAssertGreaterThan(PresenceGeometry.cameraRect(for: box, aspect: 1, canvas: g.canvas).maxX, c.maxX)
        // The bubble is the mapped renderer rect: flush with the display's right edge, not past it.
        let f = g.frame(for: box, aspect: 1)
        XCTAssertEqual(f.maxX, laptop.maxX, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(f.maxY, laptop.maxY + 1e-6)
        let s = c.width / laptop.width
        XCTAssertEqual(c.minX + (f.minX - laptop.minX) * s, r.minX, accuracy: 1e-6)
        XCTAssertEqual(f.width * s, r.width, accuracy: 1e-6)
        // Applying the bubble's frame stores an inset that lands on the content.
        let applied = g.layout(applying: f, to: box, aspect: 1)
        XCTAssertEqual(applied.rightInset, (1920 - c.maxX) / 1920, accuracy: 1e-9)
        // A drag past the display edge is clamped to the content, not the canvas.
        let dragged = g.layout(applying: f.offsetBy(dx: 400, dy: 0), to: box, aspect: 1)
        XCTAssertEqual(dragged.rightInset, (1920 - c.maxX) / 1920, accuracy: 1e-9)
        XCTAssertEqual(g.slid(f.offsetBy(dx: 400, dy: 0)).maxX, laptop.maxX, accuracy: 1e-9)
    }

    func testSizeIsCappedToTheContentHeightAndWidth() {
        let c = laptopContent
        let g = PresenceGeometry(display: laptop, content: c)
        let box = PresenceBox(widthFraction: 0.6)
        let r = PresenceGeometry.cameraRect(for: box, aspect: 0.5, canvas: g.canvas, bounds: c)
        XCTAssertLessThanOrEqual(r.height, c.height + 1)
        XCTAssertGreaterThanOrEqual(r.minX, c.minX)
        XCTAssertLessThanOrEqual(r.maxX, c.maxX + 1e-9)
        XCTAssertEqual(g.maxWidthFraction(for: box, aspect: 1), 1080.0 / 1920, accuracy: 1e-9)   // square: content height 1080
        // A pillar-sized content cannot hold a box wider than itself.
        let narrow = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 500, height: 1080),
                                      content: CGRect(x: 710, y: 0, width: 500, height: 1080))
        XCTAssertEqual(narrow.maxWidthFraction(for: box, aspect: 16.0 / 9.0), 500.0 / 1920, accuracy: 1e-9)
        let asked = g.layout(applying: CGRect(x: 0, y: 0, width: 1500, height: 3000), to: box, aspect: 0.5)
        XCTAssertLessThanOrEqual(asked.widthFraction * 1920, c.width + 1e-9)
    }

    func testCutoutOnAnUltraWideDisplaySitsOnTheContentsBottomEdge() {
        // 21:9 display, letterboxed: 1920 x 823 content, bars above and below.
        let c = CGRect(x: 0, y: (1080 - 1920 * 9.0 / 21) / 2, width: 1920, height: 1920 * 9.0 / 21)
        let ultra = CGRect(x: 0, y: 0, width: 3360, height: 1440)
        let g = PresenceGeometry(display: ultra, content: c)
        let box = PresenceBox(cutoutHeightFraction: 1.0, cutoutRightInset: 0.02, isCutout: true)
        let r = PresenceGeometry.cameraRect(for: box, aspect: 0.8, canvas: g.canvas, bounds: c)
        XCTAssertEqual(r.maxY, c.maxY, accuracy: 1e-9)                 // flush with the content, not the canvas
        XCTAssertLessThan(r.maxY, 1080)
        XCTAssertEqual(r.height, c.height, accuracy: 1e-9)             // capped to the content's height
        XCTAssertGreaterThanOrEqual(r.minY, c.minY - 1e-9)
        let f = g.frame(for: box, aspect: 0.8)
        XCTAssertEqual(f.minY, ultra.minY, accuracy: 1e-6)             // on the display's bottom edge
        XCTAssertEqual(f.height, ultra.height, accuracy: 1e-6)
        // Full-canvas cutout is unchanged: flush with the canvas bottom.
        XCTAssertEqual(PresenceGeometry.cameraRect(for: box, aspect: 0.8, canvas: g.canvas).maxY, 1080, accuracy: 1e-9)
    }

    func testFullCanvasDisplayIsUnchangedByBounds() {
        let canvas = full.canvas
        let whole = CGRect(origin: .zero, size: canvas)
        for box in [PresenceBox(), PresenceBox(widthFraction: 0.4, rightInset: 0.9, bottomInset: 0.9),
                    PresenceBox(cutoutHeightFraction: 0.7, cutoutRightInset: 0.3, isCutout: true)] {
            XCTAssertEqual(PresenceGeometry.cameraRect(for: box, aspect: 1.2, canvas: canvas),
                           PresenceGeometry.cameraRect(for: box, aspect: 1.2, canvas: canvas, bounds: whole))
        }
        XCTAssertEqual(PresenceGeometry(display: full.display, content: whole).frame(for: PresenceBox(), aspect: 1),
                       full.frame(for: PresenceBox(), aspect: 1))
    }

    // MARK: size steps

    func testStepUpAndDownChangesWidthByOneStep() {
        let g = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: nil)
        let box = PresenceBox(widthFraction: 0.25, rightInset: 0.1, bottomInset: 0.1)
        XCTAssertEqual(g.stepped(box, aspect: 1, steps: 1).widthFraction, 0.30, accuracy: 1e-6)
        XCTAssertEqual(g.stepped(box, aspect: 1, steps: -1).widthFraction, 0.20, accuracy: 1e-6)
    }

    func testStepClampsAtTheLimitsAndStaysInsideContent() {
        let g = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: nil)
        var small = PresenceBox(widthFraction: 0.1, rightInset: 0.0, bottomInset: 0.0)
        small = g.stepped(small, aspect: 16.0 / 9, steps: -1)
        XCTAssertEqual(small.widthFraction, PresenceGeometry.widthFractions.lowerBound, accuracy: 1e-6)
        XCTAssertEqual(g.stepped(small, aspect: 16.0 / 9, steps: -1).widthFraction,
                       PresenceGeometry.widthFractions.lowerBound, accuracy: 1e-6)
        var big = PresenceBox(widthFraction: 0.58, rightInset: 0.0, bottomInset: 0.0)
        for _ in 0..<5 { big = g.stepped(big, aspect: 16.0 / 9, steps: 1) }
        XCTAssertLessThanOrEqual(big.widthFraction, g.maxWidthFraction(for: big, aspect: 16.0 / 9) + 1e-9)
        let r = PresenceGeometry.cameraRect(for: big, aspect: 16.0 / 9, canvas: g.canvas)
        XCTAssertGreaterThanOrEqual(r.minX, 0); XCTAssertLessThanOrEqual(r.maxX, 1920)
        XCTAssertGreaterThanOrEqual(r.minY, 0); XCTAssertLessThanOrEqual(r.maxY, 1080)
    }

    func testStepKeepsAGrowingBoxInsideAPillarboxedContent() {
        let g = PresenceGeometry(display: display, content: fitted)
        var box = PresenceBox(widthFraction: 0.3, rightInset: 0.0, bottomInset: 0.0)
        box = g.stepped(box, aspect: 1, steps: 1)
        let r = PresenceGeometry.cameraRect(for: box, aspect: 1, canvas: g.canvas, bounds: fitted)
        XCTAssertGreaterThanOrEqual(r.minX, fitted.minX - 1e-6)
        XCTAssertLessThanOrEqual(r.maxX, fitted.maxX + 1e-6)
        XCTAssertLessThanOrEqual(r.maxY, fitted.maxY + 1e-6)
    }

    func testAnchoredStepsKeepTheNamedEdgeAndCentreFixed() {
        let g = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: nil)
        let box = PresenceBox(widthFraction: 0.25, rightInset: 0.3, bottomInset: 0.3)
        let before = g.frame(for: box, aspect: 1)
        let top = g.frame(for: g.stepped(box, aspect: 1, steps: 1, anchor: .top), aspect: 1)
        XCTAssertEqual(top.maxY, before.maxY, accuracy: 1.5)
        XCTAssertEqual(top.midX, before.midX, accuracy: 1.5)
        XCTAssertGreaterThan(top.width, before.width)
        let bottom = g.frame(for: g.stepped(box, aspect: 1, steps: -1, anchor: .bottom), aspect: 1)
        XCTAssertEqual(bottom.minY, before.minY, accuracy: 1.5)
        XCTAssertEqual(bottom.midX, before.midX, accuracy: 1.5)
        XCTAssertLessThan(bottom.width, before.width)
    }

    func testSmallAmountsAccumulateAndAnchoredGrowthIsClampedInside() {
        let g = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: nil)
        var box = PresenceBox(widthFraction: 0.25, rightInset: 0.0, bottomInset: 0.0)
        for _ in 0..<5 { box = g.stepped(box, aspect: 1, by: 0.01, anchor: .top) }
        XCTAssertEqual(box.widthFraction, 0.30, accuracy: 1e-3)
        let r = PresenceGeometry.cameraRect(for: box, aspect: 1, canvas: g.canvas)
        XCTAssertGreaterThanOrEqual(r.minY, 0); XCTAssertLessThanOrEqual(r.maxX, 1920)
    }

    func testCutoutStaysFlushWithTheBottomWhateverTheAnchor() {
        let g = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: nil)
        let box = PresenceBox(cutoutHeightFraction: 0.5, cutoutRightInset: 0.1, isCutout: true)
        let f = g.frame(for: g.stepped(box, aspect: 0.8, steps: 1, anchor: .top), aspect: 0.8)
        XCTAssertEqual(f.minY, 0, accuracy: 1e-6)
    }

    func testCutoutStepsItsHeightAndClamps() {
        let g = PresenceGeometry(display: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: nil)
        let box = PresenceBox(cutoutHeightFraction: 0.5, cutoutRightInset: 0.02, isCutout: true)
        XCTAssertEqual(g.stepped(box, aspect: 16.0 / 9, steps: 1).cutoutHeightFraction, 0.55, accuracy: 1e-6)
        XCTAssertEqual(g.stepped(box, aspect: 16.0 / 9, steps: -1).cutoutHeightFraction, 0.45, accuracy: 1e-6)
        var top = box
        for _ in 0..<20 { top = g.stepped(top, aspect: 16.0 / 9, steps: 1) }
        XCTAssertLessThanOrEqual(top.cutoutHeightFraction, 1.0 + 1e-9)
        var low = box
        for _ in 0..<20 { low = g.stepped(low, aspect: 16.0 / 9, steps: -1) }
        XCTAssertEqual(low.cutoutHeightFraction, 0.3, accuracy: 1e-6)
    }
}
