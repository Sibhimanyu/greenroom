import XCTest
@testable import GreenroomTests

final class HomeCalmRulesTests: XCTestCase {
    private func items(cameraOff: Bool = false, shareGone: Bool = false, cameraMissing: Bool = false) -> [SetupSummaryItem] {
        SetupSummary.items(cameraOff: cameraOff, lookSymbol: "circle", lookText: "Cutout",
                           shareSymbol: "display", shareText: "Whole screen", shareGone: shareGone,
                           cameraText: "MacBook Pro", cameraMissing: cameraMissing,
                           micText: "MacBook Pro", layoutText: "Meeting and chat")
    }

    func testSummaryOrderAndNothingAmberByDefault() {
        let result = items()
        XCTAssertEqual(result.map(\.kind), [.look, .share, .camera, .microphone, .layout])
        XCTAssertTrue(result.allSatisfy { !$0.attention })
    }

    func testCameraOffDropsLookAndNeverFlagsCamera() {
        let result = items(cameraOff: true, cameraMissing: true)
        XCTAssertEqual(result.map(\.kind), [.share, .camera, .microphone, .layout])
        XCTAssertEqual(result.first { $0.kind == .camera }?.symbol, "video.slash")
        XCTAssertFalse(result.first { $0.kind == .camera }!.attention)
    }

    func testMissingCameraAndGoneShareAreAmber() {
        let result = items(shareGone: true, cameraMissing: true)
        XCTAssertEqual(result.filter(\.attention).map(\.kind), [.share, .camera])
    }

    func testShareGone() {
        XCTAssertTrue(SetupSummary.shareIsGone(kind: .app, appBundleID: "a.b", windowTitle: "",
                                               runningApps: ["c.d"], openWindows: []))
        XCTAssertFalse(SetupSummary.shareIsGone(kind: .app, appBundleID: "a.b", windowTitle: "",
                                                runningApps: ["a.b"], openWindows: []))
        XCTAssertFalse(SetupSummary.shareIsGone(kind: .app, appBundleID: "", windowTitle: "",
                                                runningApps: [], openWindows: []))
        // A window whose title changed is still shared (ShareTarget.bestWindow).
        XCTAssertFalse(SetupSummary.shareIsGone(kind: .window, appBundleID: "a.b", windowTitle: "Doc",
                                                runningApps: [], openWindows: [("a.b", "Other")]))
        XCTAssertTrue(SetupSummary.shareIsGone(kind: .window, appBundleID: "a.b", windowTitle: "Doc",
                                               runningApps: [], openWindows: [("c.d", "Doc")]))
        XCTAssertFalse(SetupSummary.shareIsGone(kind: .window, appBundleID: "a.b", windowTitle: "Doc",
                                                runningApps: [], openWindows: [("a.b", "Doc")]))
        XCTAssertFalse(SetupSummary.shareIsGone(kind: .display, appBundleID: "x", windowTitle: "",
                                                runningApps: [], openWindows: []))
    }

    func testGoneShareSaysWhatHappens() {
        XCTAssertEqual(SetupSummary.goneShareText(kind: .window, appName: "Finder"),
                       "No Finder window open, shares whole screen")
        XCTAssertEqual(SetupSummary.goneShareText(kind: .app, appName: "Keynote"),
                       "Keynote isn\u{2019}t open, shares whole screen")
        let result = items(shareGone: true, cameraMissing: true)
        XCTAssertNotNil(result.first { $0.kind == .share }?.help)
        XCTAssertNotNil(result.first { $0.kind == .camera }?.help)
        XCTAssertTrue(items().allSatisfy { $0.help == nil })
    }

    func testAutoRecordIsSaidOnlyWhenOn() {
        XCTAssertFalse(items().contains { $0.kind == .autoRecord })
        let on = SetupSummary.items(cameraOff: false, lookSymbol: "circle", lookText: "Cutout",
                                    shareSymbol: "display", shareText: "Whole screen", shareGone: false,
                                    cameraText: "MacBook Pro", cameraMissing: false,
                                    micText: "MacBook Pro", layoutText: "None", autoRecord: true)
        XCTAssertEqual(on.last?.kind, .autoRecord)
        XCTAssertEqual(on.last?.text, "Records with the meeting")
        XCTAssertNotNil(on.last?.help)
    }

    func testReadinessReduction() {
        let ok = [ReadinessItem(id: "zoom", title: "Zoom", problem: nil),
                  ReadinessItem(id: "mic", title: "Mic", problem: nil)]
        XCTAssertEqual(ReadinessSummary.reduce(ok), .ready)
        XCTAssertEqual(ReadinessSummary.reduce([]), .ready)
        let bad = ok + [ReadinessItem(id: "screen", title: "Screen", problem: "Screen: permission needed")]
        XCTAssertEqual(ReadinessSummary.reduce(bad), .problems([bad[2]]))
    }
}
