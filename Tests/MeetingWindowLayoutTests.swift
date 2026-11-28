import XCTest
import CoreGraphics

final class MeetingWindowLayoutTests: XCTestCase {
    private typealias L = MeetingWindowLayout

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // Spec: meeting-window-layout R1
    func testNarrowIsBelow900() {
        XCTAssertTrue(L.isNarrow(width: 899.9))
        XCTAssertFalse(L.isNarrow(width: 900))
    }

    // Spec: meeting-window-layout R2
    func testGalleryPageSizeSteps() {
        XCTAssertEqual(L.galleryPageSize(width: 0, height: 100), 9)
        XCTAssertEqual(L.galleryPageSize(width: 100, height: 0), 9)
        XCTAssertEqual(L.galleryPageSize(width: 259, height: 149), 1)
        XCTAssertEqual(L.galleryPageSize(width: 260, height: 150), 1)
        XCTAssertEqual(L.galleryPageSize(width: 780, height: 150), 2)
        XCTAssertEqual(L.galleryPageSize(width: 520, height: 300), 4)
        XCTAssertEqual(L.galleryPageSize(width: 260, height: 600), 4)
        XCTAssertEqual(L.galleryPageSize(width: 780, height: 300), 6)
        XCTAssertEqual(L.galleryPageSize(width: 520, height: 450), 6)
        XCTAssertEqual(L.galleryPageSize(width: 780, height: 450), 9)
        XCTAssertEqual(L.galleryPageSize(width: 1040, height: 450), 12)
        XCTAssertEqual(L.galleryPageSize(width: 1300, height: 600), 12)
    }

    // Spec: meeting-window-layout R3
    func testSpeakerAndMultiSpeakerPageSize() {
        XCTAssertEqual(L.pageSize(mode: .speaker, galleryWidth: 1000, galleryHeight: 500, stripCapacity: 5, largeCount: 3), 5)
        XCTAssertEqual(L.pageSize(mode: .multiSpeaker, galleryWidth: 1000, galleryHeight: 500, stripCapacity: 5, largeCount: 0), 6)
        XCTAssertEqual(L.pageSize(mode: .multiSpeaker, galleryWidth: 1000, galleryHeight: 500, stripCapacity: 5, largeCount: 3), 8)
        XCTAssertEqual(L.pageSize(mode: .gallery, galleryWidth: 780, galleryHeight: 450, stripCapacity: 5, largeCount: 3), 9)
    }

    // Spec: meeting-window-layout R4
    func testStripCapacityAndReservedEnd() {
        XCTAssertEqual(L.stripCapacity(gridWidth: 1000, stripHeight: 104, reservedRight: 0), 5)
        XCTAssertEqual(L.stripCapacity(gridWidth: 1000, stripHeight: 104, reservedRight: 179), 4)
        XCTAssertEqual(L.stripCapacity(gridWidth: 100, stripHeight: 104, reservedRight: 500), 1)
        XCTAssertEqual(L.stripCapacity(gridWidth: 9000, stripHeight: 104, reservedRight: 0), 8)
        XCTAssertEqual(L.reservedRight(mode: .multiSpeaker, stripHeight: 104, hidesSelf: false), 179)
        XCTAssertEqual(L.reservedRight(mode: .multiSpeaker, stripHeight: 104, hidesSelf: true), 0)
        XCTAssertEqual(L.reservedRight(mode: .speaker, stripHeight: 104, hidesSelf: false), 0)
        XCTAssertEqual(L.reservedRight(mode: .gallery, stripHeight: 104, hidesSelf: false), 0)
    }

    // Spec: meeting-window-layout R5
    func testYourPreviewInAStrip() {
        XCTAssertEqual(L.stripSelfSize(stripHeight: 104), CGSize(width: 171, height: 96))
    }

    // Spec: meeting-window-layout R6
    func testPages() {
        XCTAssertEqual(L.pageCount(listed: 0, perPage: 4), 1)
        XCTAssertEqual(L.pageCount(listed: 4, perPage: 4), 1)
        XCTAssertEqual(L.pageCount(listed: 8, perPage: 4), 2)
        XCTAssertEqual(L.pageCount(listed: 9, perPage: 4), 3)
        XCTAssertEqual(L.pageRange(page: 0, perPage: 4, listed: 6), 0..<4)
        XCTAssertEqual(L.pageRange(page: 1, perPage: 4, listed: 6), 4..<6)
        XCTAssertTrue(L.pageRange(page: 2, perPage: 4, listed: 6).isEmpty)
        XCTAssertFalse(L.isLastPage(page: 0, perPage: 4, listed: 8))
        XCTAssertTrue(L.isLastPage(page: 1, perPage: 4, listed: 8))
        XCTAssertTrue(L.isLastPage(page: 5, perPage: 4, listed: 0), "with nobody listed every page is the last")
    }

    // Spec: meeting-window-layout R7
    func testRegionsReserveTheBarsInTheFullFormOnly() {
        let full = L.regions(size: CGSize(width: 1000, height: 700), topBar: 36, toolbar: 64, slotForm: false, panelOpen: false)
        XCTAssertEqual(full.stage, rect(0, 64, 1000, 600))
        XCTAssertNil(full.panel)
        XCTAssertEqual(full.clearRight, 1000)
        let slot = L.regions(size: CGSize(width: 1000, height: 700), topBar: 36, toolbar: 64, slotForm: true, panelOpen: false)
        XCTAssertEqual(slot.stage, rect(0, 0, 1000, 700))
        let squat = L.regions(size: CGSize(width: 1000, height: 80), topBar: 36, toolbar: 64, slotForm: false, panelOpen: false)
        XCTAssertEqual(squat.stage.height, 0)
    }

    // Spec: meeting-window-layout R8
    func testSidePanelTakesAColumnWhenWideAndOverlaysWhenNarrow() {
        let wide = L.regions(size: CGSize(width: 1000, height: 700), topBar: 36, toolbar: 64, slotForm: false, panelOpen: true)
        XCTAssertEqual(wide.stage, rect(0, 64, 680, 600))
        XCTAssertEqual(wide.panel, rect(680, 64, 320, 600))
        XCTAssertEqual(wide.clearRight, 680)
        let narrow = L.regions(size: CGSize(width: 800, height: 700), topBar: 36, toolbar: 64, slotForm: false, panelOpen: true)
        XCTAssertEqual(narrow.stage, rect(0, 64, 800, 600))
        XCTAssertEqual(narrow.panel, rect(480, 64, 320, 600))
        XCTAssertEqual(narrow.clearRight, 480)
        let tiny = L.regions(size: CGSize(width: 300, height: 700), topBar: 36, toolbar: 64, slotForm: false, panelOpen: true)
        XCTAssertEqual(tiny.panel, rect(0, 64, 300, 600))
        XCTAssertEqual(tiny.stage.width, 300)
        XCTAssertEqual(tiny.clearRight, 0)
    }

    // Spec: meeting-window-layout R9
    func testYourPreviewIsInTheStripOnlyWhenShownAndThereAreOthers() {
        XCTAssertTrue(L.selfInStrip(mode: .speaker, hidesSelf: false, hasOthers: true, hasRest: false))
        XCTAssertFalse(L.selfInStrip(mode: .speaker, hidesSelf: false, hasOthers: false, hasRest: true))
        XCTAssertTrue(L.selfInStrip(mode: .multiSpeaker, hidesSelf: false, hasOthers: false, hasRest: true))
        XCTAssertFalse(L.selfInStrip(mode: .multiSpeaker, hidesSelf: false, hasOthers: true, hasRest: false))
        XCTAssertFalse(L.selfInStrip(mode: .gallery, hidesSelf: false, hasOthers: true, hasRest: true))
        XCTAssertFalse(L.selfInStrip(mode: .speaker, hidesSelf: true, hasOthers: true, hasRest: true))
    }

    // Spec: meeting-window-layout R9
    func testYourPreviewRightLimitIsClearRightOrAreaEdge() {
        XCTAssertEqual(L.areaRight(area: rect(0, 64, 1000, 600), clearRight: 680), 680)
        XCTAssertEqual(L.areaRight(area: rect(0, 64, 500, 600), clearRight: 680), 500)
    }

    // Spec: meeting-window-layout R9
    func testYourPreviewPlacement() {
        let area = rect(0, 64, 680, 600)
        XCTAssertEqual(L.selfPreviewFrame(area: area, areaRight: 680, mode: .gallery, inStrip: false, stripHeight: 104, tileGap: 4),
                       rect(476, 76, 192, 108))
        XCTAssertEqual(L.selfPreviewFrame(area: area, areaRight: 680, mode: .speaker, inStrip: false, stripHeight: 104, tileGap: 4),
                       rect(476, 76, 192, 108))
        XCTAssertEqual(L.selfPreviewFrame(area: area, areaRight: 680, mode: .speaker, inStrip: true, stripHeight: 104, tileGap: 4),
                       rect(505, 564, 171, 96))
        XCTAssertEqual(L.selfPreviewFrame(area: area, areaRight: 680, mode: .multiSpeaker, inStrip: true, stripHeight: 104, tileGap: 4),
                       rect(505, 68, 171, 96))
    }

    // Spec: meeting-window-layout R10
    func testGridHostPerMode() {
        let area = rect(0, 64, 680, 600)
        XCTAssertEqual(L.gridHostFrame(area: area, areaRight: 680, mode: .gallery, hasOthers: true, inStrip: false, stripHeight: 104, tileGap: 4),
                       rect(4, 68, 672, 592))
        XCTAssertEqual(L.gridHostFrame(area: area, areaRight: 680, mode: .speaker, hasOthers: true, inStrip: true, stripHeight: 104, tileGap: 4),
                       rect(0, 560, 501, 104))
        XCTAssertEqual(L.gridHostFrame(area: area, areaRight: 680, mode: .speaker, hasOthers: true, inStrip: false, stripHeight: 104, tileGap: 4),
                       rect(0, 560, 680, 104))
        XCTAssertEqual(L.gridHostFrame(area: area, areaRight: 680, mode: .speaker, hasOthers: false, inStrip: false, stripHeight: 104, tileGap: 4),
                       rect(0, 664, 680, 0))
        XCTAssertEqual(L.gridHostFrame(area: area, areaRight: 680, mode: .multiSpeaker, hasOthers: true, inStrip: true, stripHeight: 104, tileGap: 4),
                       rect(4, 68, 672, 592))
    }

    // Spec: meeting-window-layout R11
    func testStageHostIgnoresTheRightLimit() {
        let area = rect(0, 64, 680, 600)
        XCTAssertEqual(L.stageHostFrame(area: area, hasOthers: true, stripHeight: 104), rect(4, 68, 672, 488))
        XCTAssertEqual(L.stageHostFrame(area: area, hasOthers: false, stripHeight: 104), rect(4, 68, 672, 592))
    }

    // Spec: meeting-window-layout R12
    func testEmptyNote() {
        let area = rect(0, 64, 680, 600)
        XCTAssertEqual(L.emptyNoteFrame(area: area, areaRight: 680), rect(40, 324, 600, 80))
        XCTAssertEqual(L.emptyNoteFrame(area: area, areaRight: 100).width, 80)
    }

    // Spec: meeting-window-layout R13
    func testShareCardChipAndArea() {
        XCTAssertEqual(L.shareCardFrame(in: CGSize(width: 672, height: 488), card: CGSize(width: 360, height: 132)),
                       rect(156, 178, 360, 132))
        let stage = rect(0, 64, 680, 600)
        XCTAssertEqual(L.shareChipFrame(in: stage, textWidth: 200), rect(228, 626, 224, 26))
        XCTAssertEqual(L.shareChipFrame(in: stage, textWidth: 900).width, 656)
        XCTAssertEqual(L.shareChipFrame(in: rect(0, 0, 20, 100), textWidth: 50).size.width, -4, "quirk: not clamped")
        XCTAssertEqual(L.shareArea(stage: rect(0, 64, 1000, 600), clearRight: 680), rect(0, 64, 680, 600))
        XCTAssertEqual(L.shareArea(stage: rect(0, 64, 1000, 600), clearRight: 1200), rect(0, 64, 1000, 600))
    }

    // Spec: meeting-window-layout R14
    func testInspectorDrawer() {
        let stage = rect(0, 64, 680, 600)
        XCTAssertEqual(L.inspectorFrame(stage: stage, clearRight: 680, width: 300, wantedHeight: 400), rect(364, 248, 300, 400))
        XCTAssertEqual(L.inspectorFrame(stage: stage, clearRight: 680, width: 300, wantedHeight: 900), rect(364, 80, 300, 568))
        XCTAssertEqual(L.inspectorFrame(stage: rect(0, 0, 680, 20), clearRight: 680, width: 300, wantedHeight: 400).size.height, -12,
                       "quirk: not clamped")
    }

    // Spec: meeting-window-layout R15
    func testPagerArrows() {
        let arrows = L.pagerArrows(in: rect(4, 68, 672, 592))
        XCTAssertEqual(arrows.previous, rect(10, 336, 30, 56))
        XCTAssertEqual(arrows.next, rect(640, 336, 30, 56))
    }

    // Spec: meeting-window-layout R16
    func testSidePanelParts() {
        let parts = L.sidePanelParts(size: CGSize(width: 320, height: 600), titleSize: CGSize(width: 100, height: 17))
        XCTAssertEqual(parts.body, rect(0, 0, 320, 556))
        XCTAssertEqual(parts.divider, rect(0, 0, 1, 600))
        XCTAssertEqual(parts.close, rect(284, 566, 24, 24))
        XCTAssertEqual(parts.title, rect(16, 569.5, 100, 17))
        let wide = L.sidePanelParts(size: CGSize(width: 320, height: 600), titleSize: CGSize(width: 400, height: 17))
        XCTAssertEqual(wide.title.width, 256)
        let thin = L.sidePanelParts(size: CGSize(width: 40, height: 600), titleSize: CGSize(width: 100, height: 17))
        XCTAssertEqual(thin.title.width, 0)
    }

    // Spec: meeting-window-layout R17
    func testQueueAndRosterShareTheBody() {
        XCTAssertEqual(L.queueHeight(wanted: 0, bodyHeight: 556), 0)
        XCTAssertEqual(L.queueHeight(wanted: 100, bodyHeight: 556), 100)
        XCTAssertEqual(L.queueHeight(wanted: 400, bodyHeight: 556), 250)
        let split = L.peopleSplit(bodyHeight: 556, width: 320, queueHeight: 250)
        XCTAssertEqual(split.queue, rect(0, 306, 320, 250))
        XCTAssertEqual(split.roster, rect(0, 0, 320, 306))
        XCTAssertEqual(L.peopleSplit(bodyHeight: 100, width: 320, queueHeight: 250).roster.height, 0)
    }
}
