//
//  ScreenAnnotationTests.swift
//  Phase 5 of the Recorditor port: where a mark drawn on the real screen ends
//  up in the Stage picture, the model's editing rules, and the Audio only card.
//
import XCTest
import AppKit

final class ScreenAnnotationTests: XCTestCase {
    typealias Mark = ScreenAnnotationModel.Mark

    // MARK: The mapping

    func testProjectionOfADisplayPoint() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let placed = CGRect(x: 0, y: 0, width: 1920, height: 1200)   // scaled by 4/3
        let p = MarkProjection.canvasPoint(forGlobal: CGPoint(x: 720, y: 450), source: display, placed: placed)
        XCTAssertEqual(p?.x ?? -1, 960, accuracy: 0.001)
        XCTAssertEqual(p?.y ?? -1, 600, accuracy: 0.001)
    }

    func testProjectionOfAWindowPointIsRelativeToTheWindowAndLetterboxed() {
        // A window on the second display, drawn with margins into the canvas.
        let window = CGRect(x: 1540, y: 100, width: 800, height: 500)
        let placed = CGRect(x: 160, y: 48.6, width: 1600, height: 1000)
        let corner = MarkProjection.canvasPoint(forGlobal: CGPoint(x: 1540, y: 100), source: window, placed: placed)
        XCTAssertEqual(corner?.x ?? -1, 160, accuracy: 0.001)
        XCTAssertEqual(corner?.y ?? -1, 48.6, accuracy: 0.001)
        let middle = MarkProjection.canvasPoint(forGlobal: CGPoint(x: 1940, y: 350), source: window, placed: placed)
        XCTAssertEqual(middle?.x ?? -1, 960, accuracy: 0.001)
        XCTAssertEqual(middle?.y ?? -1, 548.6, accuracy: 0.001)
    }

    func testProjectionDropsPointsOutsideTheSource() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let placed = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertNil(MarkProjection.canvasPoint(forGlobal: CGPoint(x: 50, y: 150), source: window, placed: placed))
        XCTAssertNil(MarkProjection.canvasPoint(forGlobal: CGPoint(x: 200, y: 150), source: window, placed: .zero))
    }

    /// The image the Stage fits over the screen: a mark in global points lands
    /// at the pixel `MarkProjection` predicts once the image is stretched to
    /// the placed rect.
    @MainActor
    func testRenderedMarkLandsWhereTheProjectionSays() throws {
        // Second display, to the right of the main one.
        let frame = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        let highlighter = Mark(tool: .highlighter, color: .red,
                               points: [CGPoint(x: 1600, y: 300), CGPoint(x: 2000, y: 300)])
        let overlay = try XCTUnwrap(AnnotationMarksRenderer.image(of: [highlighter], over: frame))
        XCTAssertEqual(overlay.frame, frame)
        let image = overlay.image
        // The image has the screen's shape (1.6), so it fits the 16:10 content rect with no distortion.
        XCTAssertEqual(CGFloat(image.width) / CGFloat(image.height), frame.width / frame.height, accuracy: 0.01)

        let placed = CGRect(x: 0, y: 0, width: 1920, height: 1200)
        let target = try XCTUnwrap(MarkProjection.canvasPoint(forGlobal: CGPoint(x: 1800, y: 300),
                                                              source: frame, placed: placed))
        // Back from canvas px to image px (the Stage stretches image to placed).
        let ix = Int((target.x - placed.minX) / placed.width * CGFloat(image.width))
        let iy = Int((target.y - placed.minY) / placed.height * CGFloat(image.height))
        XCTAssertGreaterThan(alpha(of: image, x: ix, y: iy), 0.2, "the stroke is there")
        XCTAssertEqual(alpha(of: image, x: ix, y: min(image.height - 1, iy + Int(80 * AnnotationMarksRenderer.scale(for: frame)))),
                       0, accuracy: 0.001, "and 80 pt below it is clear")
        XCTAssertEqual(alpha(of: image, x: 2, y: 2), 0, accuracy: 0.001)
    }

    @MainActor
    func testNothingInTheFrameMeansNoOverlay() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let elsewhere = Mark(tool: .pen, color: .red, points: [CGPoint(x: 3000, y: 3000), CGPoint(x: 3100, y: 3050)])
        XCTAssertNil(AnnotationMarksRenderer.image(of: [elsewhere], over: frame))
        XCTAssertNil(AnnotationMarksRenderer.image(of: [], over: frame))
    }

    @MainActor
    func testAWindowClipCutsMarksThatRunOffIt() throws {
        let window = CGRect(x: 200, y: 100, width: 600, height: 400)
        let across = Mark(tool: .highlighter, color: .red, points: [CGPoint(x: 100, y: 300), CGPoint(x: 900, y: 300)])
        let overlay = try XCTUnwrap(AnnotationMarksRenderer.image(of: [across], over: window, clip: window))
        let image = overlay.image
        // The image covers only the window, so the whole row is inside it.
        XCTAssertGreaterThan(alpha(of: image, x: image.width / 2, y: image.height / 2), 0.2)
    }

    // MARK: The model

    @MainActor
    func testWindowFollowMovesEveryMark() {
        let model = ScreenAnnotationModel()
        model.add(Mark(tool: .arrow, color: .red, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40)]))
        var changes = 0
        model.onMarksChanged = { changes += 1 }
        model.translateAll(by: CGSize(width: 100, height: -5))
        XCTAssertEqual(model.marks[0].points, [CGPoint(x: 110, y: 5), CGPoint(x: 150, y: 35)])
        XCTAssertEqual(changes, 1)
        model.translateAll(by: .zero)
        XCTAssertEqual(changes, 1, "no move, no redraw")
    }

    @MainActor
    func testEraserSplitsALineAndTakesAnArrowWhole() {
        let model = ScreenAnnotationModel()
        let line = (0...40).map { CGPoint(x: CGFloat($0) * 5, y: 100) }
        model.add(Mark(tool: .pen, color: .red, points: line))
        model.add(Mark(tool: .arrow, color: .red, points: [CGPoint(x: 300, y: 300), CGPoint(x: 400, y: 300)]))
        model.erase(at: CGPoint(x: 100, y: 100), radius: 14)
        XCTAssertEqual(model.marks.filter { $0.tool == .pen }.count, 2, "split in two")
        model.erase(at: CGPoint(x: 350, y: 300), radius: 14)
        XCTAssertTrue(model.marks.filter { $0.tool == .arrow }.isEmpty)
    }

    @MainActor
    func testUndoClearAndReset() {
        let model = ScreenAnnotationModel()
        model.add(Mark(tool: .pen, color: .red, points: [.zero, CGPoint(x: 5, y: 5)]))
        model.add(Mark(tool: .pen, color: .red, points: [.zero, CGPoint(x: 9, y: 9)]))
        model.undo()
        XCTAssertEqual(model.marks.count, 1)
        XCTAssertTrue(model.canUndo)
        model.tool = .eraser
        model.reset()
        XCTAssertTrue(model.marks.isEmpty)
        XCTAssertEqual(model.tool, .arrow)
    }

    // MARK: The whiteboard page

    @MainActor
    func testWhiteboardPageIsWhiteWithStrokesInPageCoordinates() throws {
        let board = CameraWhiteboardModel()
        board.begin(at: CGPoint(x: 0.1, y: 0.5))
        board.extend(to: CGPoint(x: 0.9, y: 0.5))
        board.finish()
        let page = try XCTUnwrap(board.renderPage(width: 1920))
        XCTAssertEqual(page.width, 1920)
        XCTAssertEqual(page.height, 1080)
        XCTAssertEqual(alpha(of: page, x: 5, y: 5), 1, accuracy: 0.001, "opaque white page")
        // The dark pen is on the middle row at x = 0.5.
        let (r, _, _) = rgb(of: page, x: 960, y: 540)
        XCTAssertLessThan(r, 0.3, "the stroke is dark")
        let (corner, _, _) = rgb(of: page, x: 5, y: 5)
        XCTAssertGreaterThan(corner, 0.95)
    }

    // MARK: The Audio only card

    func testAudioOnlyCardIsAnOpaqueInkPictureTheSizeOfTheCanvas() throws {
        let card = try XCTUnwrap(AudioOnlyCard.image(size: CGSize(width: 1920, height: 1080)))
        XCTAssertEqual(card.extent.width, 1920)
        XCTAssertEqual(card.extent.height, 1080)
        let context = CIContext()
        let cg = try XCTUnwrap(context.createCGImage(card, from: card.extent))
        XCTAssertEqual(alpha(of: cg, x: 4, y: 4), 1, accuracy: 0.001)
        let (r, g, b) = rgb(of: cg, x: 4, y: 4)
        XCTAssertEqual(r, 16.0 / 255, accuracy: 0.02)
        XCTAssertEqual(g, 24.0 / 255, accuracy: 0.02)
        XCTAssertEqual(b, 40.0 / 255, accuracy: 0.02)
        // Something is drawn in the middle (the glyph and the words), not a bare ground.
        var lit = false
        for y in stride(from: 300, to: 780, by: 6) {
            for x in stride(from: 600, to: 1320, by: 6) where rgb(of: cg, x: x, y: y).0 > 0.6 { lit = true }
        }
        XCTAssertTrue(lit)
    }

    // MARK: pixels

    /// Alpha 0...1 at a top-down pixel.
    private func alpha(of image: CGImage, x: Int, y: Int) -> CGFloat {
        pixel(of: image, x: x, y: y).3
    }

    private func rgb(of image: CGImage, x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat) {
        let p = pixel(of: image, x: x, y: y)
        return (p.0, p.1, p.2)
    }

    /// Un-premultiplied RGBA of one pixel, top-down.
    private func pixel(of image: CGImage, x: Int, y: Int) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so that pixel (x, y) from the TOP lands in the 1x1 context.
        context.translateBy(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let a = CGFloat(data[3]) / 255
        guard a > 0 else { return (0, 0, 0, 0) }
        return (CGFloat(data[0]) / 255 / a, CGFloat(data[1]) / 255 / a, CGFloat(data[2]) / 255 / a, a)
    }
}
