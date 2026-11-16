import XCTest
@testable import GreenroomTests

final class PreviewOutlineRulesTests: XCTestCase {
    typealias R = PreviewOutlineRules
    let wide: CGFloat = 16.0 / 9.0

    private func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 0.01, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: tol, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: tol, file: file, line: line)
    }

    private func inside(_ a: CGRect, _ b: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(b.insetBy(dx: -0.01, dy: -0.01).contains(a), "\(a) not in \(b)", file: file, line: line)
    }

    func testSixteenNineScreenFillsTheCanvas() {
        let f = R.frames(card: CGSize(width: 640, height: 360), canvasAspect: wide,
                         screen: CGSize(width: 1920, height: 1080), presenter: false)
        near(f.canvas, CGRect(x: 0, y: 0, width: 640, height: 360))
        near(f.screen, f.canvas)
    }

    func testSixteenTenMacGetsSideBars() {
        let f = R.frames(card: CGSize(width: 640, height: 360), canvasAspect: wide,
                         screen: CGSize(width: 1512, height: 945), presenter: false)
        XCTAssertEqual(f.screen.height, 360, accuracy: 0.01)
        XCTAssertEqual(f.screen.width, 576, accuracy: 0.01)
        XCTAssertEqual(f.screen.minX, 32, accuracy: 0.01)
    }

    func testUltrawideGetsTopAndBottomBars() {
        let f = R.frames(card: CGSize(width: 640, height: 360), canvasAspect: wide,
                         screen: CGSize(width: 3440, height: 1440), presenter: false)
        XCTAssertEqual(f.screen.width, 640, accuracy: 0.01)
        XCTAssertEqual(f.screen.height, 640 * 1440 / 3440, accuracy: 0.01)
        XCTAssertEqual(f.screen.midY, 180, accuracy: 0.01)
    }

    func testEveryScreenShapeInEveryCardStaysInTheCanvasAtItsOwnShape() {
        let screens = [CGSize(width: 1920, height: 1080), CGSize(width: 1512, height: 982),
                       CGSize(width: 1024, height: 768), CGSize(width: 3440, height: 1440),
                       CGSize(width: 1080, height: 1920), CGSize(width: 5120, height: 1440)]
        let cards = [CGSize(width: 640, height: 360), CGSize(width: 800, height: 380),
                     CGSize(width: 500, height: 400), CGSize(width: 300, height: 600)]
        for s in screens { for c in cards { for presenter in [false, true] {
            let f = R.frames(card: c, canvasAspect: wide, screen: s, presenter: presenter)
            inside(f.canvas, CGRect(origin: .zero, size: c))
            XCTAssertEqual(f.canvas.width / f.canvas.height, wide, accuracy: 0.001)
            inside(f.screen, f.canvas)
            XCTAssertEqual(f.screen.width / f.screen.height, s.width / s.height, accuracy: 0.001)
        } } }
    }

    func testNoCanvasShapeMeansThePictureIsTheScreen() {
        let f = R.frames(card: CGSize(width: 640, height: 360), canvasAspect: nil,
                         screen: CGSize(width: 1440, height: 900), presenter: false)
        near(f.screen, f.canvas)
        XCTAssertEqual(f.canvas.width / f.canvas.height, 1.6, accuracy: 0.001)
    }

    func testPresenterScreenSitsInTheRightBox() {
        let f = R.frames(card: CGSize(width: 1000, height: 562.5), canvasAspect: wide,
                         screen: CGSize(width: 1920, height: 1080), presenter: true)
        near(f.screen, CGRect(x: 1000 - 25 - 780, y: 562.5 * 0.11, width: 780, height: 562.5 * 0.78))
    }

    func testFractionUsesTopLeftOrigin() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 500)
        // Bottom-left window in AppKit coordinates is at the bottom of the picture.
        let f = R.fraction(of: CGRect(x: 0, y: 0, width: 500, height: 250), on: display)
        near(f!, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), 0.0001)
    }

    func testFractionOnASecondDisplayIsRelativeToIt() {
        let second = CGRect(x: 1000, y: 200, width: 2000, height: 1000)
        let f = R.fraction(of: CGRect(x: 2000, y: 700, width: 1000, height: 500), on: second)
        near(f!, CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), 0.0001)
    }

    func testWindowOnAnotherDisplayIsLeftOut() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 500)
        XCTAssertNil(R.fraction(of: CGRect(x: 1200, y: 0, width: 400, height: 400), on: main))
    }

    func testWindowAcrossTwoDisplaysIsClipped() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let f = R.fraction(of: CGRect(x: 800, y: 0, width: 400, height: 500), on: main)
        near(f!, CGRect(x: 0.8, y: 0, width: 0.2, height: 1), 0.0001)
    }

    func testPlaceMapsFractionsOntoTheScreen() {
        near(R.place(CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5), in: CGRect(x: 32, y: 0, width: 576, height: 360)),
             CGRect(x: 320, y: 90, width: 288, height: 180))
    }
}
