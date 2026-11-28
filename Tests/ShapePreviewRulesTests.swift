import XCTest

/// Spec: docs/specs/shape-preview.md (R1 to R9).
final class ShapePreviewRulesTests: XCTestCase {
    typealias S = ShapePreviewState
    private let homeA = ShapePreviewViewer.home(UUID())
    private let homeB = ShapePreviewViewer.home(UUID())
    private let layouts = ShapePreviewViewer.layoutsCamera

    // Spec: shape-preview R1
    func testNothingIsWantedAtFirst() {
        let s = S()
        XCTAssertFalse(s.isWanted)
        XCTAssertFalse(s.hasViewers)
        XCTAssertFalse(s.attached)
    }
    func testPictureStaysWantedUntilTheLastViewerLeaves() {
        var s = S()
        _ = s.open(homeA); _ = s.open(homeB)
        _ = s.close(homeA, cameraBusy: false)
        XCTAssertTrue(s.isWanted)
        XCTAssertTrue(s.isShowing(homeB))
        XCTAssertFalse(s.isShowing(homeA))
    }
    func testOpeningTheSameViewerTwiceIsOneClaim() {
        var s = S()
        _ = s.open(homeA); _ = s.open(homeA)
        XCTAssertEqual(s.close(homeA, cameraBusy: false), .detach(stopsStage: true))
        XCTAssertFalse(s.isWanted)
    }
    func testClosingAViewerThatNeverOpenedChangesNothing() {
        var s = S()
        _ = s.open(homeA)
        let before = s
        XCTAssertEqual(s.close(layouts, cameraBusy: false), .notViewing)
        XCTAssertEqual(s, before)
    }
    func testEachHomeIsItsOwnViewer() {
        XCTAssertNotEqual(homeA, homeB)
        XCTAssertNotEqual(homeA, layouts)
        XCTAssertEqual("\(homeA)", "home")
        XCTAssertEqual("\(layouts)", "layouts camera")
    }
    func testAnOldHomeLeavingDoesNotTurnOffTheNewOne() {
        var s = S()
        _ = s.open(homeA); _ = s.open(homeB)
        XCTAssertEqual(s.close(homeA, cameraBusy: false), .stillShown)
        XCTAssertTrue(s.isWanted)
    }

    // Spec: shape-preview R2
    func testOnlyTheFirstViewerAsksToAttach() {
        var s = S()
        XCTAssertEqual(s.open(homeA), .firstViewer)
        XCTAssertEqual(s.open(layouts), .alreadyShown)
        XCTAssertEqual(s.open(homeA), .alreadyShown)
    }

    // Spec: shape-preview R3
    func testAttachPlanByCameraAndWant() {
        var s = S()
        XCTAssertEqual(s.attachPlan(cameraBusy: false), .none)
        _ = s.open(homeA)
        XCTAssertEqual(s.attachPlan(cameraBusy: false), .startStageThenAdd)
        XCTAssertEqual(s.attachPlan(cameraBusy: true), .addSinkOnly)
        s.markAttached()
        XCTAssertEqual(s.attachPlan(cameraBusy: false), .none)
    }
    func testStudioAloneWantsTheAttach() {
        var s = S()
        s.studioWants = true
        XCTAssertTrue(s.isWanted)
        XCTAssertFalse(s.hasViewers)
        XCTAssertEqual(s.attachPlan(cameraBusy: false), .startStageThenAdd)
    }

    // Spec: shape-preview R4
    func testLastViewerLeavingWithNoSessionStopsTheStage() {
        var s = S()
        _ = s.open(homeA); s.markAttached()
        XCTAssertEqual(s.close(homeA, cameraBusy: false), .detach(stopsStage: true))
        XCTAssertFalse(s.attached)
    }
    func testLastViewerLeavingDuringASessionKeepsTheStage() {
        var s = S()
        _ = s.open(layouts); s.markAttached()
        XCTAssertEqual(s.close(layouts, cameraBusy: true), .detach(stopsStage: false))
        XCTAssertFalse(s.attached)
    }
    func testStudioKeepsThePictureWhenTheLastViewerLeaves() {
        var s = S()
        _ = s.open(homeA); s.markAttached()
        s.studioWants = true
        XCTAssertEqual(s.close(homeA, cameraBusy: false), .keptForStudio)
        XCTAssertTrue(s.attached)
        XCTAssertTrue(s.isWanted)
    }
    func testStillShownElsewhereKeepsAttached() {
        var s = S()
        _ = s.open(homeA); _ = s.open(layouts); s.markAttached()
        XCTAssertEqual(s.close(layouts, cameraBusy: false), .stillShown)
        XCTAssertTrue(s.attached)
    }

    // Spec: shape-preview R5
    func testSessionEndingResumesForAViewer() {
        var s = S()
        _ = s.open(layouts); s.markAttached()
        XCTAssertTrue(s.sessionEnded())
        XCTAssertFalse(s.attached)
    }
    func testSessionEndingDoesNotResumeForTheStudioAlone() {
        var s = S()
        s.studioWants = true; s.markAttached()
        XCTAssertFalse(s.sessionEnded())
        XCTAssertFalse(s.attached)
    }

    // Spec: shape-preview R6
    func testReviveTable() {
        var s = S()
        // Nothing wanted.
        XCTAssertEqual(s.reviveAction(cameraBusy: false, stageRunning: false, evenIfRunning: false), .none)
        _ = s.open(homeA)
        // A session owns the picture.
        XCTAssertEqual(s.reviveAction(cameraBusy: true, stageRunning: false, evenIfRunning: true), .none)
        // Wanted, never attached.
        XCTAssertEqual(s.reviveAction(cameraBusy: false, stageRunning: false, evenIfRunning: false), .restart)
        s.markAttached()
        // Running and attached, no picture yet: only an insisting caller restarts.
        XCTAssertEqual(s.reviveAction(cameraBusy: false, stageRunning: true, evenIfRunning: false), .none)
        XCTAssertEqual(s.reviveAction(cameraBusy: false, stageRunning: true, evenIfRunning: true), .restart)
        // Stage says stopped.
        XCTAssertEqual(s.reviveAction(cameraBusy: false, stageRunning: false, evenIfRunning: false), .restart)
        // Frames flowing: even an insisting caller leaves it.
        _ = s.publish(frameSize: CGSize(width: 1920, height: 1080), content: nil)
        XCTAssertEqual(s.reviveAction(cameraBusy: false, stageRunning: true, evenIfRunning: true), .none)
    }
    func testReviveCountsTheStudioAsWanting() {
        var s = S()
        s.studioWants = true
        XCTAssertEqual(s.reviveAction(cameraBusy: false, stageRunning: false, evenIfRunning: false), .restart)
    }

    // Spec: shape-preview R7
    func testPublishReportsOnlyChanges() {
        var s = S()
        let size = CGSize(width: 1920, height: 1080)
        let rect = CGRect(x: 10, y: 20, width: 800, height: 450)
        var p = s.publish(frameSize: size, content: rect)
        XCTAssertTrue(p.aspectChanged); XCTAssertTrue(p.contentChanged)
        p = s.publish(frameSize: size, content: rect)
        XCTAssertFalse(p.aspectChanged); XCTAssertFalse(p.contentChanged)
        p = s.publish(frameSize: CGSize(width: 1280, height: 720), content: rect)
        XCTAssertTrue(p.aspectChanged); XCTAssertFalse(p.contentChanged)
        p = s.publish(frameSize: CGSize(width: 1280, height: 720), content: nil)
        XCTAssertFalse(p.aspectChanged); XCTAssertTrue(p.contentChanged)
    }
    func testClearingTheFrameClearsAspectAndContent() {
        var s = S()
        _ = s.publish(frameSize: CGSize(width: 1920, height: 1080), content: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = s.publish(frameSize: nil, content: CGRect(x: 0, y: 0, width: 5, height: 5))
        XCTAssertTrue(p.aspectChanged); XCTAssertTrue(p.contentChanged)
        XCTAssertNil(s.aspect); XCTAssertNil(s.content)
        let again = s.publish(frameSize: nil, content: nil)
        XCTAssertFalse(again.aspectChanged); XCTAssertFalse(again.contentChanged)
    }

    // Spec: shape-preview R8
    func testApplyIsDebouncedAndGatedLikeBefore() {
        XCTAssertEqual(ShapePreviewState.debounceNanoseconds, 120_000_000)
        var s = S()
        XCTAssertFalse(s.shouldApply(stageRunning: false, cameraBusy: false))
        XCTAssertTrue(s.shouldApply(stageRunning: true, cameraBusy: false))
        XCTAssertTrue(s.shouldApply(stageRunning: false, cameraBusy: true))
        _ = s.open(homeA)
        XCTAssertTrue(s.shouldApply(stageRunning: false, cameraBusy: false))
    }
    func testStudioAloneDoesNotAllowAnApply() {
        var s = S()
        s.studioWants = true
        XCTAssertFalse(s.shouldApply(stageRunning: false, cameraBusy: false))
    }

    // Spec: shape-preview R9
    func testScreenPermissionPaneOnlyForARebuildThatCapturesTheScreenWithoutAccess() {
        for rebuild in [false, true] { for captures in [false, true] { for granted in [false, true] {
            XCTAssertEqual(S.opensScreenPermission(rebuild: rebuild, capturesScreen: captures, granted: granted),
                           rebuild && captures && !granted)
        } } }
    }
}
