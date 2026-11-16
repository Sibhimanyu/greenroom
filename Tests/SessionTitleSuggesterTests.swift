import XCTest

final class SessionTitleSuggesterTests: XCTestCase {
    private let filler = Array(repeating: "so we will do it again and then we go on with the rest of it now", count: 5)

    func testTypedTitleAlwaysWins() {
        XCTAssertEqual(SessionTitleSuggester.displayTitle(custom: " My class ", course: "Class 9", topic: "Optics", fallback: "Recording"), "My class")
    }

    func testCourseAndTopic() {
        XCTAssertEqual(SessionTitleSuggester.suggestion(course: "Class 9 Science", topic: "Optics"), "Class 9 Science \u{00B7} Optics")
        XCTAssertEqual(SessionTitleSuggester.suggestion(course: nil, topic: "Optics"), "Optics")
        XCTAssertNil(SessionTitleSuggester.suggestion(course: "Class 9", topic: nil))
        XCTAssertEqual(SessionTitleSuggester.displayTitle(custom: nil, course: nil, topic: nil, fallback: "Recording - 2026"), "Recording - 2026")
    }

    func testTopicFromRepeatedPhrase() {
        let lines = filler + ["Today the quadratic equations are our topic.",
                              "A quadratic equations has a squared term.",
                              "Solve quadratic equations with the formula."]
        XCTAssertEqual(SessionTitleSuggester.topic(fromLines: lines), "Quadratic Equations")
    }

    func testTopicFromSingleWords() {
        let lines = filler + ["Photosynthesis happens in leaves.", "Photosynthesis needs light.", "Light drives photosynthesis."]
        let topic = SessionTitleSuggester.topic(fromLines: lines)
        XCTAssertEqual(topic, "Photosynthesis")
    }

    func testNumberLineIsAPhrase() {
        let lines = filler + ["Fractions on a number line.", "Put fractions on the number line.", "The number line helps compare fractions."]
        XCTAssertEqual(SessionTitleSuggester.topic(fromLines: lines), "Number Line")
    }

    func testWeakerRunnerUpDoesNotJoin() {
        let lines = filler + ["Photosynthesis happens.", "Photosynthesis matters.", "Photosynthesis again.", "Photosynthesis everywhere.",
                              "Sunlight helps.", "Sunlight warms.", "Sunlight shines."]
        XCTAssertEqual(SessionTitleSuggester.topic(fromLines: lines), "Photosynthesis")
    }

    func testTooLittleSaidGivesNoTopic() {
        XCTAssertNil(SessionTitleSuggester.topic(fromLines: ["Hello everyone, quadratic equations today."]))
        XCTAssertNil(SessionTitleSuggester.topic(fromLines: []))
    }

    func testDeterministic() {
        let lines = filler + ["Optics lenses optics lenses optics lenses."]
        XCTAssertEqual(SessionTitleSuggester.topic(fromLines: lines), SessionTitleSuggester.topic(fromLines: lines))
    }
}
