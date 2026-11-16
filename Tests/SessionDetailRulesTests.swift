import XCTest

/// The watch page's pure rules: when the rail drops under the picture, how
/// the picture is fitted, the timeline's click maths, the speeds, the order of
/// the moments list, and when the space bar may play and pause.
final class SessionDetailRulesTests: XCTestCase {

    // MARK: Narrow rule

    func testBelowTheBreakpointTheRailDropsUnderThePicture() {
        XCTAssertTrue(SessionDetailRules.isNarrow(width: 900))
        XCTAssertTrue(SessionDetailRules.isNarrow(width: 959))
        XCTAssertFalse(SessionDetailRules.isNarrow(width: 960))
        XCTAssertFalse(SessionDetailRules.isNarrow(width: 1400))
    }

    func testAnUnmeasuredPageIsNotNarrow() {
        XCTAssertFalse(SessionDetailRules.isNarrow(width: 0))
    }

    // MARK: Picture fit

    func testWideMovieIsLimitedByWidth() {
        let size = SessionDetailRules.fit(aspect: 16.0 / 9.0, in: CGSize(width: 640, height: 600))
        XCTAssertEqual(size.width, 640, accuracy: 0.001)
        XCTAssertEqual(size.height, 360, accuracy: 0.001)
    }

    func testTallAreaLimitsAPortraitMovieByHeight() {
        let size = SessionDetailRules.fit(aspect: 9.0 / 16.0, in: CGSize(width: 800, height: 400))
        XCTAssertEqual(size.height, 400, accuracy: 0.001)
        XCTAssertEqual(size.width, 225, accuracy: 0.001)
    }

    func testPictureNeverExceedsTheRoom() {
        for aspect in [0.5, 1.0, 4.0 / 3.0, 16.0 / 9.0, 2.39] {
            let size = SessionDetailRules.fit(aspect: CGFloat(aspect), in: CGSize(width: 500, height: 300))
            XCTAssertLessThanOrEqual(size.width, 500.001)
            XCTAssertLessThanOrEqual(size.height, 300.001)
            XCTAssertEqual(size.width / size.height, CGFloat(aspect), accuracy: 0.001)
        }
    }

    func testUnknownShapeFallsBackToSixteenByNine() {
        XCTAssertEqual(SessionDetailRules.aspect(of: .zero), 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(SessionDetailRules.aspect(of: CGSize(width: 1080, height: 1920)), 9.0 / 16.0, accuracy: 0.0001)
        let size = SessionDetailRules.fit(aspect: .nan, in: CGSize(width: 160, height: 900))
        XCTAssertEqual(size.height, 90, accuracy: 0.001)
    }

    func testNoRoomGivesNoPicture() {
        XCTAssertEqual(SessionDetailRules.fit(aspect: 1.5, in: .zero), .zero)
        XCTAssertEqual(SessionDetailRules.fit(aspect: 1.5, in: CGSize(width: 300, height: -4)), .zero)
    }

    // MARK: Timeline

    func testSeekTimeMapsClickToRecordingAndClamps() {
        XCTAssertEqual(SessionDetailRules.seekTime(x: 50, width: 200, duration: 100) ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(SessionDetailRules.seekTime(x: 500, width: 200, duration: 100) ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(SessionDetailRules.seekTime(x: -30, width: 200, duration: 100) ?? -1, 0, accuracy: 0.001)
        XCTAssertNil(SessionDetailRules.seekTime(x: 5, width: 200, duration: 0))
        XCTAssertNil(SessionDetailRules.seekTime(x: 5, width: 0, duration: 10))
    }

    func testFractionClamps() {
        XCTAssertEqual(SessionDetailRules.fraction(of: 30, in: 60), 0.5, accuracy: 0.001)
        XCTAssertEqual(SessionDetailRules.fraction(of: 90, in: 60), 1)
        XCTAssertEqual(SessionDetailRules.fraction(of: 5, in: 0), 0)
    }

    func testClockReadsMinutesThenHours() {
        XCTAssertEqual(SessionDetailRules.clock(0), "0:00")
        XCTAssertEqual(SessionDetailRules.clock(65), "1:05")
        XCTAssertEqual(SessionDetailRules.clock(3729), "1:02:09")
        XCTAssertEqual(SessionDetailRules.clock(-5), "0:00")
        XCTAssertEqual(SessionDetailRules.clock(.nan), "0:00")
    }

    func testSpeedsAndTheirLabels() {
        XCTAssertEqual(SessionDetailRules.speeds, [1, 1.25, 1.5, 2])
        XCTAssertEqual(SessionDetailRules.speedLabel(1), "1\u{00D7}")
        XCTAssertEqual(SessionDetailRules.speedLabel(1.25), "1.25\u{00D7}")
        XCTAssertEqual(SessionDetailRules.speedLabel(2), "2\u{00D7}")
    }

    // MARK: Moments

    func testClipsAndNotesShareOneTimeOrder() {
        let list = SessionDetailRules.ordered([
            SessionMoment(id: "n2", kind: .note, at: 90, label: "later note"),
            SessionMoment(id: "c1", kind: .clip, at: 30, label: "Clip"),
            SessionMoment(id: "n1", kind: .note, at: 10, label: "early note"),
        ])
        XCTAssertEqual(list.map(\.id), ["n1", "c1", "n2"])
    }

    func testEqualTimesPutTheClipFirstAndKeepInputOrder() {
        let list = SessionDetailRules.ordered([
            SessionMoment(id: "n-a", kind: .note, at: 20, label: "a"),
            SessionMoment(id: "n-b", kind: .note, at: 20, label: "b"),
            SessionMoment(id: "c", kind: .clip, at: 20, label: "Clip"),
        ])
        XCTAssertEqual(list.map(\.id), ["c", "n-a", "n-b"])
    }

    func testANoteSeeksJustBeforeItAndNeverBelowZero() {
        XCTAssertEqual(SessionDetailRules.noteSeekTime(60), 56, accuracy: 0.001)
        XCTAssertEqual(SessionDetailRules.noteSeekTime(2), 0, accuracy: 0.001)
    }

    // MARK: Space bar

    func testSpacePlaysWhenNothingIsBeingTyped() {
        XCTAssertTrue(SessionDetailRules.spaceTogglesPlayback(
            textInputFocused: false, controlFocused: false, hasModifiers: false, sheetUp: false, pageActive: true))
    }

    func testSpaceIsLeftAloneInATextFieldOrOnAControl() {
        XCTAssertFalse(SessionDetailRules.spaceTogglesPlayback(
            textInputFocused: true, controlFocused: false, hasModifiers: false, sheetUp: false, pageActive: true))
        XCTAssertFalse(SessionDetailRules.spaceTogglesPlayback(
            textInputFocused: false, controlFocused: true, hasModifiers: false, sheetUp: false, pageActive: true))
    }

    func testSpaceStaysQuietUnderModifiersSheetsAndOtherPages() {
        XCTAssertFalse(SessionDetailRules.spaceTogglesPlayback(
            textInputFocused: false, controlFocused: false, hasModifiers: true, sheetUp: false, pageActive: true))
        XCTAssertFalse(SessionDetailRules.spaceTogglesPlayback(
            textInputFocused: false, controlFocused: false, hasModifiers: false, sheetUp: true, pageActive: true))
        XCTAssertFalse(SessionDetailRules.spaceTogglesPlayback(
            textInputFocused: false, controlFocused: false, hasModifiers: false, sheetUp: false, pageActive: false))
    }

    // MARK: Transcript and cuts

    func testStampsReadAsSeconds() {
        XCTAssertEqual(SessionDetailRules.stampSeconds("0:04:12"), 252)
        XCTAssertEqual(SessionDetailRules.stampSeconds("4:12"), 252)
        XCTAssertEqual(SessionDetailRules.stampSeconds("1:00:01"), 3601)
        XCTAssertNil(SessionDetailRules.stampSeconds("soon"))
        XCTAssertNil(SessionDetailRules.stampSeconds(""))
    }

    func testALineRunsToTheNextOne() {
        let span = SessionDetailRules.transcriptSpan(starts: [0, 10, 18], from: 1, duration: 60)
        XCTAssertEqual(span, 10...18)
    }

    func testALongSilenceAfterALineIsNotPartOfIt() {
        let span = SessionDetailRules.transcriptSpan(starts: [0, 100], from: 0, duration: 200)
        XCTAssertEqual(span, 0...25)
    }

    func testTheLastLineRunsToTheEnd() {
        let span = SessionDetailRules.transcriptSpan(starts: [0, 50], from: 1, duration: 58)
        XCTAssertEqual(span, 50...58)
    }

    func testSeveralLinesMakeOneCut() {
        let span = SessionDetailRules.transcriptSpan(starts: [0, 5, 9, 14], from: 2, to: 1, duration: 60)
        XCTAssertEqual(span, 5...14)
    }

    func testTooShortALineMakesNoCut() {
        XCTAssertNil(SessionDetailRules.transcriptSpan(starts: [0, 0.1], from: 0, duration: 60))
        XCTAssertNil(SessionDetailRules.transcriptSpan(starts: [0], from: 3, duration: 60))
    }

    func testTheLineBeingSpoken() {
        XCTAssertEqual(SessionDetailRules.currentLine(starts: [0, 10, 18], at: 12), 1)
        XCTAssertNil(SessionDetailRules.currentLine(starts: [5, 10], at: 1))
    }

    func testTranscriptSitsBesideThePictureOnlyWhenThereIsRoom() {
        XCTAssertTrue(SessionDetailRules.transcriptBeside(columnWidth: 700))
        XCTAssertFalse(SessionDetailRules.transcriptBeside(columnWidth: 600))
    }
}
