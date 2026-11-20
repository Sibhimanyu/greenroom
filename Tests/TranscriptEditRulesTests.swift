import XCTest

final class TranscriptEditRulesTests: XCTestCase {
    typealias R = TranscriptEditRules

    let cues = "# header\nWhat the mic heard\n0:00:05\thello there\n0:00:09\t[BLANK_AUDIO]\n\n1:02:03\tlast words\n"
    let analyse = "[0:05] hello there\n# note\n[0:09] (birds chirping)\n[12:40]   spaced out\n"

    func testStampSeconds() {
        XCTAssertEqual(R.stampSeconds("0:00:05"), 5)
        XCTAssertEqual(R.stampSeconds("1:02:03"), 3723)
        XCTAssertEqual(R.stampSeconds("12:40"), 760)
        XCTAssertEqual(R.stampSeconds("0:05.5"), 5.5)
        XCTAssertNil(R.stampSeconds("abc"))
        XCTAssertNil(R.stampSeconds("1:2:3:4"))
        XCTAssertNil(R.stampSeconds(""))
    }

    func testCurrentLine() {
        let starts = [5.0, 9, 20]
        XCTAssertNil(R.currentLine(starts: starts, at: 1))
        XCTAssertEqual(R.currentLine(starts: starts, at: 5), 0)
        XCTAssertEqual(R.currentLine(starts: starts, at: 19.9), 1)
        XCTAssertEqual(R.currentLine(starts: starts, at: 400), 2)
        XCTAssertNil(R.currentLine(starts: [], at: 3))
    }

    func testRowsKeepRawIndexesIncludingHiddenNoise() {
        let rows = R.rows(in: cues)
        XCTAssertEqual(rows.map(\.rawIndex), [2, 3, 5])
        XCTAssertEqual(rows[0].stamp, "0:00:05")
        XCTAssertEqual(rows[1].text, "[BLANK_AUDIO]")
        let a = R.rows(in: analyse)
        XCTAssertEqual(a.map(\.rawIndex), [0, 2, 3])
        XCTAssertEqual(a[2].text, "spaced out")
    }

    func testRewriteCuesPreservesEverythingElse() {
        let out = R.rewrite(raw: cues, rawIndex: 2, newText: "hello, everyone")!
        XCTAssertEqual(out, cues.replacingOccurrences(of: "hello there", with: "hello, everyone"))
    }

    func testRewriteAnalysePreservesSpacingAndComments() {
        let out = R.rewrite(raw: analyse, rawIndex: 3, newText: "tidy")!
        XCTAssertEqual(out, analyse.replacingOccurrences(of: "spaced out", with: "tidy"))
        XCTAssertTrue(out.contains("[12:40]   tidy"))
        XCTAssertTrue(out.contains("# note"))
    }

    func testRewriteStripsTabsAndNewlines() {
        let out = R.rewrite(raw: cues, rawIndex: 2, newText: "a\tb\nc")!
        XCTAssertEqual(R.rows(in: out).map(\.text), ["a b c", "[BLANK_AUDIO]", "last words"])
    }

    func testDeleteRemovesOnlyThatRow() {
        let out = R.rewrite(raw: cues, rawIndex: 2, newText: "  ")!
        XCTAssertEqual(out, "# header\nWhat the mic heard\n0:00:09\t[BLANK_AUDIO]\n\n1:02:03\tlast words\n")
        XCTAssertEqual(R.rewrite(raw: cues, rawIndex: 5, newText: nil),
                       "# header\nWhat the mic heard\n0:00:05\thello there\n0:00:09\t[BLANK_AUDIO]\n\n")
    }

    func testRewriteRefusesNonRows() {
        XCTAssertNil(R.rewrite(raw: cues, rawIndex: 0, newText: "x"))   // comment
        XCTAssertNil(R.rewrite(raw: cues, rawIndex: 4, newText: "x"))   // blank
        XCTAssertNil(R.rewrite(raw: cues, rawIndex: 99, newText: "x"))
    }

    func testCRLFKept() {
        let raw = "0:00:01\tone\r\n0:00:02\ttwo\r\n"
        XCTAssertEqual(R.rows(in: raw).map(\.text), ["one", "two"])
        XCTAssertEqual(R.rewrite(raw: raw, rawIndex: 0, newText: "uno"), "0:00:01\tuno\r\n0:00:02\ttwo\r\n")
    }

    func testOriginalDecision() {
        XCTAssertEqual(R.originalName(for: "transcript.txt"), "transcript.original.txt")
        XCTAssertEqual(R.originalName(for: "analysis-transcript.txt"), "analysis-transcript.original.txt")
        XCTAssertTrue(R.shouldCopyOriginal(originalExists: false, sourceExists: true))
        XCTAssertFalse(R.shouldCopyOriginal(originalExists: true, sourceExists: true))
        XCTAssertFalse(R.shouldCopyOriginal(originalExists: false, sourceExists: false))
    }

    func testSummaryStaleAndAutoScroll() {
        let t = Date(), s = t.addingTimeInterval(-60)
        XCTAssertTrue(R.summaryIsStale(transcriptModified: t, summaryModified: s))
        XCTAssertFalse(R.summaryIsStale(transcriptModified: s, summaryModified: t))
        XCTAssertFalse(R.summaryIsStale(transcriptModified: t, summaryModified: nil))
        XCTAssertTrue(R.shouldAutoScroll(lastManualScroll: nil, now: t))
        XCTAssertFalse(R.shouldAutoScroll(lastManualScroll: t.addingTimeInterval(-1), now: t))
        XCTAssertTrue(R.shouldAutoScroll(lastManualScroll: t.addingTimeInterval(-4), now: t))
    }
}
