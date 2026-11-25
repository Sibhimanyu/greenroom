import XCTest

/// R11: the corner picker and Reset (the S / M / L presets went, owner 2026-11-26), restored from the Webcam tab, now on the
/// layout's saved camera piece.
final class CameraPlacementRulesTests: XCTestCase {
    typealias R = CameraPlacementRules
    private let wide = 16.0 / 9.0

    private func camera(_ shape: WebcamShape) -> LayoutCamera {
        var c = LayoutCamera()
        c.shape = shape
        return c
    }

    // R11: a cutout stands on the bottom edge, so it has three spots; a bubble has four corners.
    func testSpotsFollowTheShape() {
        XCTAssertEqual(R.spots(for: .cutout), [.bottomLeft, .bottom, .bottomRight])
        XCTAssertEqual(R.spots(for: .circle), [.topLeft, .topRight, .bottomLeft, .bottomRight])
    }

    // R11: Presenter is a fixed placement, so there is nothing to size or place.
    func testPresenterHasNothingToAdjust() {
        XCTAssertFalse(R.isAdjustable(shape: .presenterLarge))
        XCTAssertTrue(R.isAdjustable(shape: .circle))
        XCTAssertTrue(R.isAdjustable(shape: .cutout))
    }

    // R11: a corner lands where a fresh install would put it (the shipped margins).
    func testPlacingABubbleInEachCorner() {
        let c = camera(.circle)   // 0.24 wide, a square: 0.24 * 16/9 of the height
        let height = 0.24 * wide
        let topRight = R.placing(c, at: .topRight, canvasAspect: wide)
        XCTAssertEqual(topRight.rightInset, 0.045, accuracy: 1e-9)
        XCTAssertEqual(topRight.bottomInset, 1 - height - 0.06, accuracy: 1e-9)
        let bottomLeft = R.placing(c, at: .bottomLeft, canvasAspect: wide)
        XCTAssertEqual(bottomLeft.rightInset, 1 - 0.24 - 0.045, accuracy: 1e-9)
        XCTAssertEqual(bottomLeft.bottomInset, 0.06, accuracy: 1e-9)
        let bottomRight = R.placing(c, at: .bottomRight, canvasAspect: wide)
        XCTAssertEqual(bottomRight.rightInset, 0.045, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.bottomInset, 0.06, accuracy: 1e-9)
    }

    // R11: a cutout slides along the bottom edge; the centre spot is centred.
    func testPlacingACutoutAlongTheBottom() {
        let c = camera(.cutout)   // 0.5 tall
        let width = 0.5 * wide / wide   // as a share of a 16:9 canvas: height * cameraAspect / canvas
        XCTAssertEqual(R.placing(c, at: .bottom, canvasAspect: wide).cutoutRightInset, (1 - width) / 2, accuracy: 1e-9)
        XCTAssertEqual(R.placing(c, at: .bottomLeft, canvasAspect: wide).cutoutRightInset, 1 - width - 0.02, accuracy: 1e-9)
        XCTAssertEqual(R.placing(c, at: .bottomRight, canvasAspect: wide).cutoutRightInset, 0.02, accuracy: 1e-9)
    }

    // R11: the picker marks the spot the camera is on, and none when it is dragged in between.
    func testTheCurrentSpotIsFoundFromThePlacement() {
        let c = camera(.circle)
        XCTAssertEqual(R.currentSpot(of: c, canvasAspect: wide), .bottomRight)
        XCTAssertEqual(R.currentSpot(of: R.placing(c, at: .topLeft, canvasAspect: wide), canvasAspect: wide), .topLeft)
        var dragged = c
        dragged.rightInset = 0.3
        XCTAssertNil(R.currentSpot(of: dragged, canvasAspect: wide))
    }

    // R11: Reset puts back the size and spot of the shape on screen, and leaves the shape alone.
    func testResetIsShapeAwareAndKeepsTheShape() {
        var c = camera(.circle)
        XCTAssertTrue(R.isAtDefault(c))
        c.widthFraction = 0.4
        c.cutoutHeightFraction = 0.9   // not the shape on screen: Reset leaves it
        XCTAssertFalse(R.isAtDefault(c))
        let reset = R.reset(c)
        XCTAssertEqual(reset.shape, .circle)
        XCTAssertEqual(reset.widthFraction, LayoutCamera().widthFraction)
        XCTAssertEqual(reset.cutoutHeightFraction, 0.9)
        var cut = camera(.cutout)
        cut.cutoutHeightFraction = 0.7
        XCTAssertFalse(R.isAtDefault(cut))
        XCTAssertEqual(R.reset(cut).cutoutHeightFraction, LayoutCamera().cutoutHeightFraction)
    }
}
