import XCTest
import CoreGraphics

final class LayoutResolverTests: XCTestCase {
    private let main = LayoutScreen(id: "MAIN", name: "Built-in", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), isMain: true)
    private let second = LayoutScreen(id: "SECOND", name: "Projector", visibleFrame: CGRect(x: 1440, y: 100, width: 1920, height: 1050), isMain: false)
    private let other = LayoutScreen(id: "OTHER", name: "Dell", visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1050), isMain: false)
    private let primaryHeight: CGFloat = 900

    private func template(secondUUID: String = "", two: Bool = true) -> LayoutTemplate {
        let app = LayoutPiece(kind: .app(AppPiece(bundleID: "com.example.app")), rect: UnitRect(x: 0, y: 0, w: 0.5, h: 1))
        let meeting = LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: false), rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.4))
        let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0.5, y: 0.4, w: 0.5, h: 0.6))
        var t = LayoutTemplate(name: "T", oneDisplay: [app, meeting, chat])
        if two {
            t.twoDisplays = TwoDisplay(
                main: [app, LayoutPiece(kind: .chat, rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 1))],
                second: [LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)],
                secondUUID: secondUUID)
        }
        return t
    }

    // MARK: Variants

    func testTwoDisplayVersionWhenASecondDisplayIsConnected() {
        let r = LayoutResolver.resolve(template(), screens: [main, second], primaryHeight: primaryHeight)
        XCTAssertEqual(r.variant, .twoDisplays)
        XCTAssertEqual(r.placed.count, 3)
        XCTAssertEqual(r.meeting?.screen.id, "SECOND")
        XCTAssertTrue(r.meeting?.fillsDisplay ?? false)
        XCTAssertTrue(r.notes.isEmpty)
    }

    func testOneDisplayVersionWhenNoSecondDisplay() {
        let r = LayoutResolver.resolve(template(), screens: [main], primaryHeight: primaryHeight)
        XCTAssertEqual(r.variant, .oneDisplay)
        XCTAssertEqual(r.placed.count, 3)
        XCTAssertFalse(r.meeting?.fillsDisplay ?? true)
        XCTAssertEqual(r.notes.count, 1, "the fallback is logged")
    }

    func testReResolvesOnEveryCall() {
        let t = template()
        XCTAssertEqual(LayoutResolver.resolve(t, screens: [main], primaryHeight: primaryHeight).variant, .oneDisplay)
        XCTAssertEqual(LayoutResolver.resolve(t, screens: [main, second], primaryHeight: primaryHeight).variant, .twoDisplays)
        XCTAssertEqual(LayoutResolver.resolve(t, screens: [main], primaryHeight: primaryHeight).variant, .oneDisplay)
    }

    func testSavedSecondDisplayIsUsedWhenConnected() {
        let r = LayoutResolver.resolve(template(secondUUID: "OTHER"), screens: [main, second, other], primaryHeight: primaryHeight)
        XCTAssertEqual(r.meeting?.screen.id, "OTHER")
        XCTAssertTrue(r.notes.isEmpty)
    }

    func testMissingSavedSecondDisplayFallsBackToTheFirstOtherOne() {
        let r = LayoutResolver.resolve(template(secondUUID: "GONE"), screens: [main, second], primaryHeight: primaryHeight)
        XCTAssertEqual(r.variant, .twoDisplays)
        XCTAssertEqual(r.meeting?.screen.id, "SECOND")
        XCTAssertEqual(r.notes.count, 1)
    }

    func testAutomaticTakesTheFirstNonMainDisplay() {
        let r = LayoutResolver.resolve(template(secondUUID: ""), screens: [main, other, second], primaryHeight: primaryHeight)
        XCTAssertEqual(r.meeting?.screen.id, "OTHER")
    }

    func testATemplateWithoutTwoDisplaysUsesTheMainDisplayEvenWithTwoConnected() {
        let r = LayoutResolver.resolve(template(two: false), screens: [main, second], primaryHeight: primaryHeight)
        XCTAssertEqual(r.variant, .oneDisplay)
        XCTAssertTrue(r.placed.allSatisfy { $0.screen.id == "MAIN" })
        XCTAssertTrue(r.notes.isEmpty)
    }

    func testNoDisplaysPlacesNothing() {
        let r = LayoutResolver.resolve(template(), screens: [], primaryHeight: primaryHeight)
        XCTAssertTrue(r.placed.isEmpty)
    }

    func testFramesAreInBothCoordinateSpaces() {
        let r = LayoutResolver.resolve(template(two: false), screens: [main], primaryHeight: primaryHeight)
        let chat = r.chat!
        XCTAssertEqual(chat.frames.ns, CGRect(x: 720, y: 0, width: 720, height: 525))
        // The AX frame is flipped against the primary display's full height.
        XCTAssertEqual(chat.frames.ax.minY, primaryHeight - 525, accuracy: 1e-6)
        XCTAssertEqual(chat.frames.ax.width, 720, accuracy: 1e-6)
    }

    // MARK: Hiding the meeting

    func testHiddenMeetingLetsTheChatGrowIntoTheGap() {
        let r = LayoutResolver.resolve(template(two: false), screens: [main], primaryHeight: primaryHeight)
        let shown = LayoutResolver.frames(of: r, meetingHidden: false)
        let hidden = LayoutResolver.frames(of: r, meetingHidden: true)
        let chat = r.chat!.piece.id, app = r.apps[0].piece.id
        XCTAssertEqual(shown[chat]?.ns.height ?? 0, 525, accuracy: 1e-6)
        XCTAssertEqual(hidden[chat]?.ns, CGRect(x: 720, y: 0, width: 720, height: 875))
        XCTAssertEqual(hidden[app], shown[app], "the app is not the joining neighbour")
        XCTAssertEqual(LayoutResolver.frames(of: r, meetingHidden: true).count, 3)
    }

    /// The Meeting window and the views go together (\u{2325}\u{2318}Z), and each gap is
    /// taken by a neighbour that is not hidden itself.
    func testHidingTheMeetingAndAViewTogetherGivesBothGapsToChat() {
        let meeting = LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: false), rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.3))
        let view = LayoutPiece(kind: .view(.handsUp, startsHidden: false), rect: UnitRect(x: 0.5, y: 0.3, w: 0.5, h: 0.2))
        let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5))
        let app = LayoutPiece(kind: .app(AppPiece(bundleID: "com.example.app")), rect: UnitRect(x: 0, y: 0, w: 0.5, h: 1))
        let r = LayoutResolver.resolve(LayoutTemplate(name: "T", oneDisplay: [app, meeting, view, chat]),
                                       screens: [main], primaryHeight: primaryHeight)
        let hidden = LayoutResolver.frames(of: r, meetingHidden: true)
        XCTAssertEqual(hidden[chat.id]?.ns, CGRect(x: 720, y: 0, width: 720, height: 875), "chat took the meeting and the view's room")
        XCTAssertEqual(hidden[app.id], LayoutResolver.frames(of: r, meetingHidden: false)[app.id])
    }

    func testAViewAloneHidesAndItsNeighbourGrows() {
        let view = LayoutPiece(kind: .view(.gallery, startsHidden: false), rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.5))
        let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5))
        let r = LayoutResolver.resolve(LayoutTemplate(name: "T", oneDisplay: [view, chat]), screens: [main], primaryHeight: primaryHeight)
        XCTAssertEqual(LayoutResolver.frames(of: r, meetingHidden: true)[chat.id]?.ns,
                       CGRect(x: 720, y: 0, width: 720, height: 875))
        XCTAssertEqual(LayoutResolver.frames(of: r, meetingHidden: false)[chat.id]?.ns.height, 437.5)
    }

    func testNoJoiningNeighbourMeansNothingMoves() {
        // The meeting is a box in a corner: nothing joins it into a rectangle.
        let t = LayoutTemplate(name: "T", oneDisplay: [
            LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: false), rect: UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.5)),
            LayoutPiece(kind: .chat, rect: UnitRect(x: 0, y: 0, w: 0.4, h: 1)),
        ])
        let r = LayoutResolver.resolve(t, screens: [main], primaryHeight: primaryHeight)
        XCTAssertEqual(LayoutResolver.frames(of: r, meetingHidden: true), LayoutResolver.frames(of: r, meetingHidden: false))
    }

    func testAbsorbingNeighbourPrefersTheLargest() {
        let m = UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.4)
        let small = (id: UUID(), rect: UnitRect(x: 0.5, y: 0.4, w: 0.5, h: 0.2))
        let big = (id: UUID(), rect: UnitRect(x: 0, y: 0, w: 0.5, h: 0.4))
        let found = LayoutResolver.absorbingNeighbour(of: m, among: [small, big])
        XCTAssertEqual(found?.id, big.id)
        XCTAssertEqual(found?.joined, UnitRect(x: 0, y: 0, w: 1, h: 0.4))
    }

    func testAMeetingThatFillsADisplayHasNothingToHide() {
        let r = LayoutResolver.resolve(template(), screens: [main, second], primaryHeight: primaryHeight)
        XCTAssertEqual(LayoutResolver.frames(of: r, meetingHidden: true), LayoutResolver.frames(of: r, meetingHidden: false))
    }

    // MARK: Zoom's own window

    func testChatFitsBelowAZoomWindowThatCameOutTaller() {
        let planned = CGRect(x: 1000, y: 500, width: 440, height: 375)
        let chat = CGRect(x: 1000, y: 0, width: 440, height: 500)
        let actual = CGRect(x: 1000, y: 380, width: 440, height: 495)   // Zoom refused 375, took 495
        let fitted = LayoutResolver.fit(chat, aroundActual: actual, planned: planned)
        XCTAssertEqual(fitted.minY, 0)
        XCTAssertEqual(fitted.maxY, 380, accuracy: 1e-6)
    }

    func testFitNeverGrowsTheNeighbourAndKeepsAFloor() {
        let planned = CGRect(x: 1000, y: 500, width: 440, height: 375)
        let chat = CGRect(x: 1000, y: 0, width: 440, height: 500)
        let same = LayoutResolver.fit(chat, aroundActual: planned, planned: planned)
        XCTAssertEqual(same, chat)
        let huge = CGRect(x: 1000, y: 10, width: 440, height: 865)
        XCTAssertEqual(LayoutResolver.fit(chat, aroundActual: huge, planned: planned).height, 200)
    }

    func testFitAboveAndBesideTheMeeting() {
        let planned = CGRect(x: 0, y: 0, width: 400, height: 300)
        let above = CGRect(x: 0, y: 300, width: 400, height: 500)
        let actual = CGRect(x: 0, y: 0, width: 400, height: 350)
        let a = LayoutResolver.fit(above, aroundActual: actual, planned: planned)
        XCTAssertEqual(a.minY, 350, accuracy: 1e-6)
        XCTAssertEqual(a.maxY, 800, accuracy: 1e-6)
        let right = CGRect(x: 400, y: 0, width: 600, height: 300)
        let wide = CGRect(x: 0, y: 0, width: 450, height: 300)
        let b = LayoutResolver.fit(right, aroundActual: wide, planned: planned)
        XCTAssertEqual(b.minX, 450, accuracy: 1e-6)
        XCTAssertEqual(b.maxX, 1000, accuracy: 1e-6)
    }

    // MARK: Small decisions

    func testCompactMeetingBelowTheFullForm() {
        XCTAssertTrue(LayoutResolver.isCompactMeeting(CGSize(width: 480, height: 400)))
        XCTAssertTrue(LayoutResolver.isCompactMeeting(CGSize(width: 900, height: 500)))
        XCTAssertTrue(LayoutResolver.isCompactMeeting(CGSize(width: 759, height: 600)))
        XCTAssertFalse(LayoutResolver.isCompactMeeting(CGSize(width: 760, height: 520)))
    }

    func testLargestAppOnMainIgnoresOtherDisplays() {
        let small = LayoutPiece(kind: .app(AppPiece(bundleID: "a")), rect: UnitRect(x: 0, y: 0, w: 0.3, h: 1))
        let big = LayoutPiece(kind: .app(AppPiece(bundleID: "b")), rect: UnitRect(x: 0.3, y: 0, w: 0.7, h: 1))
        let onSecond = LayoutPiece(kind: .app(AppPiece(bundleID: "c")), rect: .full)
        var t = LayoutTemplate(name: "T", oneDisplay: [small, big])
        t.twoDisplays = TwoDisplay(main: [small, big], second: [onSecond], secondUUID: "")
        let r = LayoutResolver.resolve(t, screens: [main, second], primaryHeight: primaryHeight)
        XCTAssertEqual(LayoutResolver.largestAppOnMain(r)?.piece.kind.app?.bundleID, "b")
        let none = LayoutResolver.resolve(LayoutTemplate(name: "Empty"), screens: [main], primaryHeight: primaryHeight)
        XCTAssertNil(LayoutResolver.largestAppOnMain(none))
    }

    func testRefusedSizeIsDetected() {
        let asked = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertFalse(LayoutResolver.differs(CGRect(x: 1, y: 0, width: 401, height: 300), from: asked))
        XCTAssertTrue(LayoutResolver.differs(CGRect(x: 0, y: 0, width: 520, height: 300), from: asked))
    }

    func testMeetingStartsHiddenReadsAndWritesEveryVersion() {
        var t = template()
        XCTAssertEqual(t.meetingStartsHidden, false)
        t.setMeetingStartsHidden(true)
        XCTAssertEqual(t.meetingStartsHidden, true)
        XCTAssertTrue(t.hasFillsDisplayMeeting)
        let noMeeting = LayoutTemplate(name: "X", oneDisplay: [LayoutPiece(kind: .chat, rect: .full)])
        XCTAssertNil(noMeeting.meetingStartsHidden)
        XCTAssertFalse(noMeeting.hasFillsDisplayMeeting)
    }
}
