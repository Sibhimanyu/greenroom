import XCTest

final class WhisperLoopsTests: XCTestCase {

    func testRealExampleCollapses() {
        let line = "How much is this? I don't know how much this is I don't know how much this is I don't know how much this is I don't know how much this is"
        XCTAssertEqual(WhisperLoops.collapse(line), "How much is this? I don't know how much this is")
    }

    func testCaseAndPunctuationInsensitive() {
        XCTAssertEqual(WhisperLoops.collapse("I don't know. i DON'T know, I don't know!"), "I don't know.")
    }

    func testCrossSegmentRepeatsCollapseKeepingFirst() {
        let out = WhisperLoops.collapse(segments: [
            "Right so I don't know how much this is",
            "I don't know how much this is",
            "I don't know how much this is",
            "Next slide please"])
        XCTAssertEqual(out, ["Right so I don't know how much this is", "", "", "Next slide please"])
    }

    func testWordPerSegmentStream() {
        let words = "so I don't know how much this is I don't know how much this is then".split(separator: " ").map(String.init)
        let keep = WhisperLoops.keepMask(words)
        XCTAssertEqual(zip(words, keep).filter { $0.1 }.map { $0.0 }.joined(separator: " "),
                       "so I don't know how much this is then")
    }

    func testShortGenuineRepeatsSurvive() {
        XCTAssertEqual(WhisperLoops.collapse("yes yes"), "yes yes")
        XCTAssertEqual(WhisperLoops.collapse("no, no, no"), "no, no, no")
        XCTAssertEqual(WhisperLoops.collapse("very very good"), "very very good")
        XCTAssertEqual(WhisperLoops.collapse("I see. I see. Okay."), "I see. I see. Okay.")
    }

    func testShortPhraseThreeTimesCollapses() {
        XCTAssertEqual(WhisperLoops.collapse("Thank you. Thank you. Thank you. Bye"), "Thank you. Bye")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(WhisperLoops.collapse(""), "")
        XCTAssertEqual(WhisperLoops.collapse(segments: []), [])
        XCTAssertEqual(WhisperLoops.keepMask([]), [])
    }
}
