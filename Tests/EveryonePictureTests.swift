import XCTest
import CoreImage

/// R37: Preview: Everyone draws the meeting's real picture.
final class EveryonePictureTests: XCTestCase {
    private let display = CGSize(width: 1512, height: 884)
    private let browserID = "com.example.browser"

    private func rectsEqual(_ a: CGRect?, _ b: CGRect?, _ accuracy: CGFloat = 0.6, _ msg: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let a, let b else { return XCTAssertEqual(a == nil, b == nil, msg, file: file, line: line) }
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, msg, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, msg, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, msg, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, msg, file: file, line: line)
    }

    private lazy var browser: LayoutPiece = {
        LayoutPiece(kind: .app(AppPiece(bundleID: browserID, url: "", opensAtStart: false, closesOnStop: false, opensMinimised: false)),
                    rect: UnitRect(x: 0, y: 0, w: 0.75, h: 1))
    }()
    private lazy var chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0.75, y: 0, w: 0.25, h: 1))
    private let circle = EveryonePicture.Camera(box: PresenceBox(), shape: .circle)

    // R37.1
    func testWholeScreenAndWhiteboardHaveNoMargin() {
        let whole = StageFrame.contentRect(shareKind: .wholeScreen, sourceAspect: 1512.0 / 884, presenter: false)
        rectsEqual(whole, CGRect(x: 36.35, y: 0, width: 1847.3, height: 1080), 0.1)
        let board = StageFrame.contentRect(shareKind: .whiteboard, sourceAspect: 16.0 / 9, presenter: false)
        rectsEqual(board, CGRect(x: 0, y: 0, width: 1920, height: 1080), 0.01)
    }

    // R37.2
    func testWindowIsFittedWithMarginAloneOwnersCase() {
        let r = StageFrame.contentRect(shareKind: .window, sourceAspect: 1134.0 / 884, presenter: false)
        rectsEqual(r, CGRect(x: 329.6, y: 48.6, width: 1260.7, height: 982.8), 0.1)
    }

    // R37.3
    func testPresenterIsA78PercentPanelOnTheRight() {
        let r = StageFrame.contentRect(shareKind: .wholeScreen, sourceAspect: 16.0 / 9, presenter: true)
        rectsEqual(r, CGRect(x: 1920 - 48 - 1497.6, y: 118.8, width: 1497.6, height: 842.4), 0.1)
    }

    // R37.4
    func testJustMeHasNoContentRect() {
        XCTAssertNil(StageFrame.contentRect(shareKind: .justMe, sourceAspect: 1.5, presenter: false))
    }

    // R37.5
    func testOwnersCameraStaysInsideTheBrowser() throws {
        let pic = EveryonePicture.make(share: .window(bundleID: browserID), pieces: [browser, chat], displaySize: display, camera: circle)
        let cam = try XCTUnwrap(pic.camera)
        XCTAssertEqual(cam.minX, 1129, accuracy: 1)
        XCTAssertEqual(cam.maxX, 1590, accuracy: 1)
        XCTAssertEqual(cam.minY, 554, accuracy: 1)
        XCTAssertEqual(cam.maxY, 1015, accuracy: 1)
        XCTAssertTrue(try XCTUnwrap(pic.content).insetBy(dx: -0.01, dy: -0.01).contains(cam))
    }

    // R37.6
    func testWholeScreenDrawsTheVisiblePiecesInTheContentRect() throws {
        var hidden = chat; hidden.showsToEveryone = false
        let pic = EveryonePicture.make(share: .wholeScreen, pieces: [browser, hidden], displaySize: display, camera: nil)
        let c = try XCTUnwrap(pic.content)
        XCTAssertEqual(pic.tiles.map(\.id), [browser.id])
        rectsEqual(pic.tiles.first?.rect, CGRect(x: c.minX, y: c.minY, width: c.width * 0.75, height: c.height), 0.01)
    }

    func testWindowDrawsOnlyTheChosenPieceFillingTheRect() {
        let pic = EveryonePicture.make(share: .window(bundleID: browserID), pieces: [browser, chat], displaySize: display, camera: nil)
        XCTAssertEqual(pic.tiles.map(\.id), [browser.id])
        rectsEqual(pic.tiles.first?.rect, pic.content, 0.01)
    }

    func testWhiteboardIsAWhiteCardAndJustMeIsNothing() {
        let board = EveryonePicture.make(share: .whiteboard, pieces: [browser], displaySize: display, camera: nil)
        XCTAssertTrue(board.whiteboardCard)
        XCTAssertTrue(board.tiles.isEmpty)
        rectsEqual(board.content, CGRect(x: 0, y: 0, width: 1920, height: 1080), 0.01)
        let me = EveryonePicture.make(share: .justMe, pieces: [browser], displaySize: display, camera: circle)
        XCTAssertNil(me.content)
        XCTAssertTrue(me.tiles.isEmpty)
        XCTAssertFalse(me.whiteboardCard)
    }

    func testCameraHiddenFromEveryoneIsNotDrawn() {
        var cam = circle; cam.everyoneSees = false
        XCTAssertNil(EveryonePicture.make(share: .wholeScreen, pieces: [], displaySize: display, camera: cam).camera)
    }

    // R37.7: the renderer draws what the preview says.
    func testPreviewRectsEqualTheRenderersForEveryShareKind() throws {
        let renderer = StageRenderer(canvas: StageFrame.output)
        let cases: [(String, Visibility.Target, CGSize, Bool, WebcamShape)] = [
            ("whole screen", .wholeScreen, display, true, .circle),
            ("window", .window(bundleID: browserID), CGSize(width: 1134, height: 884), false, .circle),
            ("window, rounded", .window(bundleID: browserID), CGSize(width: 1134, height: 884), false, .roundedRectangle),
            ("whiteboard", .whiteboard, CGSize(width: 1920, height: 1080), true, .circle),
            ("presenter", .wholeScreen, display, true, .presenterLarge),
            ("just me", .justMe, display, true, .circle),
        ]
        for (name, target, source, whole, shape) in cases {
            let cameraSpec = EveryonePicture.Camera(box: PresenceBox(), shape: shape)
            let pic = EveryonePicture.make(share: target, pieces: [browser], displaySize: display, camera: cameraSpec)
            var scene = StageScene()
            scene.layout.shape = shape
            scene.contentIsWholeDisplay = whole
            let isJustMe = target == .justMe
            scene.layout.showsContent = !isJustMe
            let screen = isJustMe ? nil : CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: source))
            let cam = StageCameraInput(raw: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)))
            _ = renderer.compose(scene: scene, screen: screen, cameras: [0: cam])
            rectsEqual(pic.content, renderer.lastContentRect, 0.6, name + " content")
            if let coverage = renderer.lastCameraCoverage, shape != .presenterLarge {
                let e = coverage.extent
                rectsEqual(pic.camera, CGRect(x: e.minX, y: 1080 - e.maxY, width: e.width, height: e.height), 1.1, name + " camera")
            }
        }
    }
}
