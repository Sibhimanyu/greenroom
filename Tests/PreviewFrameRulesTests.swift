import XCTest
import CoreGraphics

final class PreviewFrameRulesTests: XCTestCase {
    // A 16:10 display drawn aspect-fitted on the 16:9 canvas: 1728 x 1080, bars either side.
    private let content = CGRect(x: 96, y: 0, width: 1728, height: 1080)

    func testCropIsContentAsUnitRect() {
        let c = PreviewFrameRules.crop(content: content, presenter: false)
        XCTAssertEqual(c.minX, 0.05, accuracy: 1e-9)
        XCTAssertEqual(c.width, 0.9, accuracy: 1e-9)
        XCTAssertEqual(c.height, 1, accuracy: 1e-9)
        XCTAssertEqual(PreviewFrameRules.aspect(canvasAspect: 16.0 / 9, crop: c), 1.6, accuracy: 1e-9)
    }

    func testNoContentOrPresenterShowsWholeCanvas() {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(PreviewFrameRules.crop(content: nil, presenter: false), whole)
        XCTAssertEqual(PreviewFrameRules.crop(content: content, presenter: true), whole)
    }

    func testCanvasRectBehindFrameFillsFrameWithCrop() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        let crop = PreviewFrameRules.crop(content: content, presenter: false)
        let canvas = PreviewFrameRules.canvasRect(frame: frame, crop: crop)
        XCTAssertEqual(canvas.width, 800 / 0.9, accuracy: 1e-6)
        // The content's left edge lands on the frame's left edge.
        XCTAssertEqual(canvas.minX + crop.minX * canvas.width, 0, accuracy: 1e-6)
        XCTAssertEqual(canvas.minY, 0, accuracy: 1e-6)
    }

    func testCanvasPointOfFrameCornersAreContentCorners() {
        let frame = CGSize(width: 800, height: 500)
        let crop = PreviewFrameRules.crop(content: content, presenter: false)
        let tl = PreviewFrameRules.canvasPoint(of: .zero, frame: frame, crop: crop)
        let br = PreviewFrameRules.canvasPoint(of: CGPoint(x: 800, y: 500), frame: frame, crop: crop)
        XCTAssertEqual(tl.x, 96, accuracy: 1e-6); XCTAssertEqual(tl.y, 0, accuracy: 1e-6)
        XCTAssertEqual(br.x, 1824, accuracy: 1e-6); XCTAssertEqual(br.y, 1080, accuracy: 1e-6)
    }

    func testCameraRectRoundTripsAndStaysInsideFrame() {
        let frame = CGSize(width: 800, height: 500)
        let box = PresenceBox(widthFraction: 0.24, rightInset: 0.045, bottomInset: 0.06)
        let r = PreviewFrameRules.cameraRect(box: box, aspect: 16.0 / 9, frame: frame, content: content)
        XCTAssertTrue(CGRect(origin: .zero, size: frame).contains(r))
        let moved = r.offsetBy(dx: -100, dy: -60)
        let next = PreviewFrameRules.box(applying: moved, to: box, aspect: 16.0 / 9, frame: frame, content: content)
        let back = PreviewFrameRules.cameraRect(box: next, aspect: 16.0 / 9, frame: frame, content: content)
        XCTAssertEqual(back.minX, moved.minX, accuracy: 1.5)
        XCTAssertEqual(back.minY, moved.minY, accuracy: 1.5)
        XCTAssertEqual(back.width, moved.width, accuracy: 1.5)
    }

    func testDraggingPastTheEdgeIsClampedInsideContent() {
        let frame = CGSize(width: 800, height: 500)
        let box = PresenceBox()
        let r = PreviewFrameRules.cameraRect(box: box, aspect: 16.0 / 9, frame: frame, content: content)
        let off = r.offsetBy(dx: 900, dy: 900)
        let next = PreviewFrameRules.box(applying: off, to: box, aspect: 16.0 / 9, frame: frame, content: content)
        let back = PreviewFrameRules.cameraRect(box: next, aspect: 16.0 / 9, frame: frame, content: content)
        XCTAssertLessThanOrEqual(back.maxX, frame.width + 1.5)
        XCTAssertLessThanOrEqual(back.maxY, frame.height + 1.5)
    }

    func testCutoutStaysFlushWithTheBottom() {
        let frame = CGSize(width: 800, height: 500)
        let box = PresenceBox(cutoutHeightFraction: 0.5, cutoutRightInset: 0.1, isCutout: true)
        let r = PreviewFrameRules.cameraRect(box: box, aspect: 16.0 / 9, frame: frame, content: content)
        XCTAssertEqual(r.maxY, frame.height, accuracy: 1e-6)
    }
}

final class LayoutCameraRulesTests: XCTestCase {
    func testContentFitsDisplayAspectOnCanvas() {
        XCTAssertEqual(LayoutCameraRules.content(displayAspect: 16.0 / 9), CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let wide = LayoutCameraRules.content(displayAspect: 2.4)
        XCTAssertEqual(wide.width, 1920, accuracy: 1e-6)
        XCTAssertEqual(wide.height, 800, accuracy: 1e-6)
        XCTAssertEqual(wide.minY, 140, accuracy: 1e-6)
        let tall = LayoutCameraRules.content(displayAspect: 1.6)
        XCTAssertEqual(tall.width, 1728, accuracy: 1e-6)
        XCTAssertEqual(tall.minX, 96, accuracy: 1e-6)
    }

    func testDefaultBoxOnSixteenNineMatchesCanvasFractions() {
        let box = PresenceBox()
        let frame = CGSize(width: 960, height: 540)   // half the canvas
        let r = LayoutCameraRules.rect(box: box, aspect: 16.0 / 9, frame: frame, displayAspect: 16.0 / 9)
        XCTAssertEqual(r.width, 1920 * 0.24 / 2, accuracy: 1.5)
        XCTAssertEqual(r.maxX, 960 - 1920 * 0.045 / 2, accuracy: 1.5)
        XCTAssertEqual(r.maxY, 540 - 1080 * 0.06 / 2, accuracy: 1.5)
    }

    func testRectThenBoxRoundTrips() {
        for aspect: CGFloat in [16.0 / 9, 1.6, 2.4] {
            for (aspect2, cutout) in [(16.0 / 9, false), (1.0, false), (16.0 / 9, true)] {
                var box = PresenceBox(); box.isCutout = cutout
                let frame = CGSize(width: 600, height: 600 / aspect)
                let r = LayoutCameraRules.rect(box: box, aspect: aspect2, frame: frame, displayAspect: aspect)
                let back = LayoutCameraRules.box(applying: r, to: box, aspect: aspect2, frame: frame, displayAspect: aspect)
                let again = LayoutCameraRules.rect(box: back, aspect: aspect2, frame: frame, displayAspect: aspect)
                XCTAssertEqual(again.minX, r.minX, accuracy: 1.5)
                XCTAssertEqual(again.minY, r.minY, accuracy: 1.5)
                XCTAssertEqual(again.width, r.width, accuracy: 1.5)
            }
        }
    }

    /// 1512x982 display, menu bar 33 pt on top, Dock 65 pt at the bottom: the
    /// builder canvas is the 1512x884 usable area, yet the camera must land
    /// where the bubble does on the whole display.
    func testBuilderCameraMatchesTheBubbleOnTheWholeDisplay() {
        let frameRect = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 65, width: 1512, height: 884)
        let space = LayoutCameraSpace(frame: frameRect, visibleFrame: visible)
        XCTAssertEqual(space.usable, CGRect(x: 0, y: 33, width: 1512, height: 884))
        let bubble = PresenceGeometry(display: frameRect, content: LayoutCameraRules.content(displayAspect: 1512.0 / 982))
        let canvas = CGSize(width: 756, height: 442)   // half scale
        let s = space.scale(frame: canvas)
        for (aspect, cutout) in [(16.0 / 9, false), (1.0, false), (16.0 / 9, true)] {
            var box = PresenceBox(); box.isCutout = cutout
            let r = LayoutCameraRules.rect(box: box, aspect: aspect, frame: canvas, space: space)
            // Canvas (top-left, usable) -> display points (Cocoa, bottom-left, whole display).
            let back = CGRect(x: r.minX / s, y: 982 - (r.maxY / s + 33), width: r.width / s, height: r.height / s)
            let expected = bubble.frame(for: box, aspect: aspect)
            XCTAssertEqual(back.minX, expected.minX, accuracy: 1.5)
            XCTAssertEqual(back.minY, expected.minY, accuracy: 1.5)
            XCTAssertEqual(back.width, expected.width, accuracy: 1.5)
            XCTAssertEqual(back.height, expected.height, accuracy: 1.5)
            // Dragging in the builder converts back to the same placement.
            let again = LayoutCameraRules.box(applying: r, to: box, aspect: aspect, frame: canvas, space: space)
            let rr = LayoutCameraRules.rect(box: again, aspect: aspect, frame: canvas, space: space)
            XCTAssertEqual(rr.minX, r.minX, accuracy: 1.5)
            XCTAssertEqual(rr.minY, r.minY, accuracy: 1.5)
        }
    }

    // The camera layer never draws past the canvas's content rect (into the bezel padding).
    func testCameraRectIsClampedToTheCanvasContentRect() {
        let canvas = CGSize(width: 320, height: 195)
        let area = LayoutCameraRules.drawable(frame: canvas, space: nil)
        XCTAssertEqual(area, CGRect(x: 0, y: 0, width: 320, height: 195))
        let poking = CGRect(x: 260, y: 150, width: 63, height: 40)      // 3 pt past the right edge
        let r = LayoutCameraRules.clamped(poking, to: area)
        XCTAssertEqual(r.maxX, 320, accuracy: 1e-9)
        XCTAssertEqual(r.size, poking.size)
        XCTAssertEqual(r.minY, 150)
        let inside = CGRect(x: 10, y: 10, width: 50, height: 30)
        XCTAssertEqual(LayoutCameraRules.clamped(inside, to: area), inside)
        XCTAssertEqual(LayoutCameraRules.clamped(CGRect(x: -5, y: -5, width: 20, height: 20), to: area).origin, .zero)
    }

    // The menu bar / Dock zone of the whole display is still drawable, the bezel padding is not.
    func testDrawableAreaKeepsTheMenuBarAndDockZone() {
        let space = LayoutCameraSpace(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                      visibleFrame: CGRect(x: 0, y: 65, width: 1512, height: 884))
        let canvas = CGSize(width: 756, height: 442)
        let area = LayoutCameraRules.drawable(frame: canvas, space: space)
        XCTAssertEqual(area.minX, 0); XCTAssertEqual(area.maxX, 756, accuracy: 1e-6)
        XCTAssertEqual(area.minY, -16.5, accuracy: 1e-6)
        XCTAssertEqual(area.maxY, 442 + 32.5, accuracy: 1e-6)
    }

    func testMovedBoxStaysInsideTheDisplay() {
        let frame = CGSize(width: 600, height: 375)
        let box = PresenceBox()
        let off = CGRect(x: 900, y: 900, width: 100, height: 56)
        let placed = LayoutCameraRules.box(applying: off, to: box, aspect: 16.0 / 9, frame: frame, displayAspect: 1.6)
        let r = LayoutCameraRules.rect(box: placed, aspect: 16.0 / 9, frame: frame, displayAspect: 1.6)
        XCTAssertLessThanOrEqual(r.maxX, frame.width + 1)
        XCTAssertLessThanOrEqual(r.maxY, frame.height + 1)
    }

    func testCardWidthFollowsAspect() {
        XCTAssertEqual(PreviewFrameRules.cardWidth(columnHeight: 320, eyebrow: 20, aspect: 1.6), 480)
        XCTAssertEqual(PreviewFrameRules.cardWidth(columnHeight: 320, eyebrow: 20, aspect: 16.0 / 9), 533)
        XCTAssertEqual(PreviewFrameRules.cardWidth(columnHeight: 320, eyebrow: 20, aspect: 9), 700)  // held to 21:9
        XCTAssertEqual(PreviewFrameRules.cardWidth(columnHeight: 320, eyebrow: 20, aspect: .nan), 480)
        XCTAssertEqual(PreviewFrameRules.defaultAspect(screen: CGSize(width: 1440, height: 900)), 1.6, accuracy: 1e-9)
        XCTAssertEqual(PreviewFrameRules.defaultAspect(screen: nil), 1.6, accuracy: 1e-9)
    }
}

final class PreviewHeldAspectTests: XCTestCase {
    func testNoPictureKeepsTheLastRealAspect() {
        XCTAssertEqual(PreviewFrameRules.heldAspect(current: 1.6, live: nil), 1.6)
    }
    func testARealPictureMovesIt() {
        XCTAssertEqual(PreviewFrameRules.heldAspect(current: 1.6, live: 16.0 / 9.0), 16.0 / 9.0, accuracy: 0.0001)
    }
    func testReturnWidthNeverBelowTheContentsNeed() {
        XCTAssertEqual(PreviewFrameRules.returnWidth(remembered: 700, current: 1180, floor: 744), 744)
        XCTAssertEqual(PreviewFrameRules.returnWidth(remembered: 900, current: 1180, floor: 744), 900)
        XCTAssertEqual(PreviewFrameRules.returnWidth(remembered: nil, current: 800, floor: 744), 800)
    }
}

final class PreviewRateTests: XCTestCase {
    func testHomeOutsideAMeetingRunsAtTheCompositorRate() {
        XCTAssertEqual(PreviewRate.framesPerSecond(meetingLive: false), 30)
    }

    func testLiveMeetingHalvesIt() {
        XCTAssertEqual(PreviewRate.framesPerSecond(meetingLive: true), 15)
    }
}
