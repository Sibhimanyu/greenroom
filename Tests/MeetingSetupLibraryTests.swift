import XCTest

/// How the Meeting setup and the layout library meet (docs/specs/meeting-setup.md P3): the values a
/// layout brings in, what is written back, and what a change to the library means for the setup.
final class MeetingSetupLibraryTests: XCTestCase {

    private func piece(_ shape: WebcamShape, width: Double = 0.24) -> LayoutCamera {
        var c = LayoutCamera()
        c.shape = shape
        c.widthFraction = width
        return c
    }

    private func share(_ kind: ShareTarget.Kind) -> ShareTarget {
        var s = ShareTarget()
        s.kind = kind
        return s
    }

    private let fallback = MeetingSetup.Values(cameraState: .onlyMe, cameraPiece: LayoutCamera(), share: ShareTarget())

    private func layout(_ name: String, state: CameraState? = .everyoneAndMe, camera: LayoutCamera? = LayoutCamera(),
                        share: ShareTarget? = ShareTarget()) -> LayoutTemplate {
        LayoutTemplate(name: name, camera: camera, share: share, cameraState: state)
    }

    private func library(_ a: LayoutTemplate, _ b: LayoutTemplate? = nil, active: LayoutTemplate? = nil) -> LayoutLibrary {
        LayoutLibrary(templates: [a] + (b.map { [$0] } ?? []), activeID: (active ?? a).id)
    }

    // Spec: meeting-setup R2.4
    func testALayoutWithNothingSavedResolvesToTheFallback() {
        let bare = layout("Bare", state: nil, camera: nil, share: nil)
        XCTAssertEqual(bare.setupValues(fallback: fallback), fallback)
    }

    // Spec: meeting-setup R2.4
    func testALayoutWithValuesBringsItsOwn() {
        let t = layout("Own", state: .off, camera: piece(.cutout), share: share(.window))
        XCTAssertEqual(t.setupValues(fallback: fallback),
                       MeetingSetup.Values(cameraState: .off, cameraPiece: piece(.cutout), share: share(.window)))
    }

    // Spec: meeting-setup R2.4 (one app is no longer offered: it reads as the whole screen)
    func testASavedAppShareReadsAsTheWholeScreen() {
        let t = layout("App", share: share(.app))
        XCTAssertEqual(t.setupValues(fallback: fallback).share.kind, .display)
    }

    // Spec: meeting-setup R2.5
    func testWritingBackTouchesOnlyTheNamedSettingsOfTheActiveLayout() {
        var lib = library(layout("A"), layout("B"))
        let other = lib.templates[1]
        let values = MeetingSetup.Values(cameraState: .off, cameraPiece: piece(.square), share: share(.nothing))
        XCTAssertTrue(lib.writeActive(values, settings: [.cameraPiece]))
        XCTAssertEqual(lib.active?.camera, piece(.square))
        XCTAssertEqual(lib.active?.cameraState, .everyoneAndMe)
        XCTAssertEqual(lib.active?.share, ShareTarget())
        XCTAssertEqual(lib.templates[1], other, "another layout is never touched")
    }

    // Spec: meeting-setup R2.5
    func testWritingBackWithNoActiveLayoutOrNothingToWriteSaysNo() {
        var none = LayoutLibrary(templates: [layout("A")], activeID: nil)
        XCTAssertFalse(none.writeActive(fallback, settings: [.share]))
        var lib = library(layout("A"))
        XCTAssertFalse(lib.writeActive(fallback, settings: []))
    }

    // Spec: meeting-setup R5.2
    func testSwitchingTheActiveLayoutBringsItsValuesIn() {
        let a = layout("A"), b = layout("B", state: .onlyEveryone, camera: piece(.cutout), share: share(.window))
        var setup = MeetingSetup(saved: a.setupValues(fallback: fallback))
        let lib = library(a, b, active: b)
        let effect = setup.followLibrary(oldActiveID: a.id, library: lib, fallback: fallback, meetingLive: true)
        XCTAssertEqual(setup.saved, b.setupValues(fallback: fallback))
        XCTAssertEqual(effect.inUse, [.cameraState, .cameraPiece, .share])
        XCTAssertTrue(effect.saved.isEmpty, "the library already holds them")
    }

    // Spec: meeting-setup R5.1
    func testSwitchingTheLayoutDropsForThisMeetingChanges() {
        let a = layout("A"), b = layout("B")
        var setup = MeetingSetup(saved: a.setupValues(fallback: fallback))
        setup.change(.share(share(.nothing)), meetingLive: true)
        setup.followLibrary(oldActiveID: a.id, library: library(a, b, active: b), fallback: fallback, meetingLive: true)
        XCTAssertFalse(setup.isForThisMeeting(.share))
        XCTAssertEqual(setup.share, ShareTarget())
    }

    // Spec: meeting-setup R5.4
    func testSwitchingTheLayoutKeepsACameraTurnedOffForThisMeeting() {
        let a = layout("A"), b = layout("B")
        var setup = MeetingSetup(saved: a.setupValues(fallback: fallback))
        setup.change(.cameraState(.off), meetingLive: true)
        setup.followLibrary(oldActiveID: a.id, library: library(a, b, active: b), fallback: fallback, meetingLive: true)
        XCTAssertEqual(setup.cameraState, .off)
    }

    // Spec: meeting-setup R4.2
    func testAnEditToTheActiveLayoutInTheLibraryIsASavedEdit() {
        let a = layout("A")
        var setup = MeetingSetup(saved: a.setupValues(fallback: fallback))
        var edited = a
        edited.share = share(.window)
        edited.camera = piece(.square)
        let effect = setup.followLibrary(oldActiveID: a.id, library: library(edited), fallback: fallback, meetingLive: false)
        XCTAssertEqual(setup.saved.share, share(.window))
        XCTAssertEqual(setup.saved.cameraPiece, piece(.square))
        XCTAssertEqual(effect.inUse, [.cameraPiece, .share])
        XCTAssertTrue(effect.saved.isEmpty)
    }

    // Spec: meeting-setup R4.2
    func testAnEditToTheActiveLayoutDuringAMeetingDoesNotOverrideAForThisMeetingChange() {
        let a = layout("A")
        var setup = MeetingSetup(saved: a.setupValues(fallback: fallback))
        setup.change(.share(share(.nothing)), meetingLive: true)
        var edited = a
        edited.share = share(.window)
        edited.camera = piece(.square)
        let effect = setup.followLibrary(oldActiveID: a.id, library: library(edited), fallback: fallback, meetingLive: true)
        XCTAssertEqual(setup.saved.share, share(.window))
        XCTAssertEqual(setup.share, share(.nothing), "the meeting keeps its own share")
        XCTAssertEqual(setup.cameraPiece, piece(.square), "no change for the piece, so the meeting gets the edit")
        XCTAssertEqual(effect.inUse, [.cameraPiece])
    }

    // Spec: meeting-setup R4.1
    func testALibraryChangeThatLeavesTheActiveValuesAloneChangesNothing() {
        let a = layout("A"), b = layout("B")
        var setup = MeetingSetup(saved: a.setupValues(fallback: fallback))
        setup.change(.share(share(.nothing)), meetingLive: true)
        var renamedOther = b
        renamedOther.name = "Renamed"
        let effect = setup.followLibrary(oldActiveID: a.id, library: library(a, renamedOther), fallback: fallback, meetingLive: true)
        XCTAssertEqual(effect, MeetingSetup.Effect())
        XCTAssertEqual(setup.share, share(.nothing))
    }

    // Spec: meeting-setup R6.1
    func testWithNoActiveLayoutTheSetupStandsOnItsOwnValues() {
        let a = layout("A")
        var setup = MeetingSetup(saved: a.setupValues(fallback: fallback))
        let effect = setup.followLibrary(oldActiveID: nil, library: LayoutLibrary(templates: [a], activeID: nil),
                                         fallback: fallback, meetingLive: false)
        XCTAssertEqual(effect, MeetingSetup.Effect())
    }

    // Spec: meeting-setup R6.2
    func testADragSavesOnlyTheDraggedPiece() {
        var saved = piece(.roundedRectangle, width: 0.2)
        saved.cutoutHeightFraction = 0.7
        saved.cutoutRightInset = 0.1
        let box = PresenceBox(widthFraction: 0.3, rightInset: 0.2, bottomInset: 0.1,
                              cutoutHeightFraction: 0.4, cutoutRightInset: 0.5, isCutout: false)
        let dragged = saved.placing(box)
        XCTAssertEqual(dragged.shape, .roundedRectangle)
        XCTAssertEqual(dragged.widthFraction, 0.3)
        XCTAssertEqual(dragged.rightInset, 0.2)
        XCTAssertEqual(dragged.bottomInset, 0.1)
        XCTAssertEqual(dragged.cutoutHeightFraction, 0.7, "the cutout numbers came from the box's working copy: not taken")
        XCTAssertEqual(dragged.cutoutRightInset, 0.1)
    }

    // Spec: meeting-setup R6.2
    func testACutoutDragSavesOnlyTheCutoutNumbers() {
        let saved = piece(.cutout, width: 0.2)
        let box = PresenceBox(widthFraction: 0.5, rightInset: 0.5, bottomInset: 0.5,
                              cutoutHeightFraction: 0.4, cutoutRightInset: 0.3, isCutout: true)
        let dragged = saved.placing(box)
        XCTAssertEqual(dragged.cutoutHeightFraction, 0.4)
        XCTAssertEqual(dragged.cutoutRightInset, 0.3)
        XCTAssertEqual(dragged.widthFraction, 0.2)
        XCTAssertEqual(dragged.rightInset, saved.rightInset)
        XCTAssertEqual(dragged.bottomInset, saved.bottomInset)
    }

    // Spec: meeting-setup R6.2
    func testADragIsClampedToTheRangesTheBubbleAllows() {
        let box = PresenceBox(widthFraction: 2, rightInset: -1, bottomInset: 5,
                              cutoutHeightFraction: 0, cutoutRightInset: 3, isCutout: false)
        let dragged = LayoutCamera().placing(box)
        XCTAssertEqual(dragged.widthFraction, 0.6)
        XCTAssertEqual(dragged.rightInset, 0)
        XCTAssertEqual(dragged.bottomInset, 0.9)
        let cut = piece(.cutout).placing(PresenceBox(widthFraction: 0, rightInset: 0, bottomInset: 0,
                                                     cutoutHeightFraction: 0, cutoutRightInset: 3, isCutout: true))
        XCTAssertEqual(cut.cutoutHeightFraction, 0.3)
        XCTAssertEqual(cut.cutoutRightInset, 0.95)
    }

    // Spec: meeting-setup R1.2 (Restore original is offered when the camera state differs)
    func testABuiltInWhoseCameraStateDiffersCountsAsEdited() throws {
        var lib = LayoutLibrary(templates: LayoutLibrary.builtIns(), activeID: nil)
        for t in lib.templates { XCTAssertTrue(t.isAsShipped, t.name) }
        let id = try XCTUnwrap(lib.templates.first { $0.starter == LayoutLibrary.rajMode }?.id)
        lib.templates[lib.templates.firstIndex { $0.id == id }!].cameraState = .off
        XCTAssertFalse(try XCTUnwrap(lib.template(id: id)).isAsShipped)
        XCTAssertTrue(lib.restoreOriginal(id))
        XCTAssertTrue(try XCTUnwrap(lib.template(id: id)).isAsShipped)
        XCTAssertEqual(lib.template(id: id)?.cameraState, .onlyEveryone, "Raj San Mode ships Only the meeting")
    }
}
