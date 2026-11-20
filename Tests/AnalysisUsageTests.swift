import XCTest

final class AnalysisUsageTests: XCTestCase {

    private let claudeTurn1 = #"{"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}"#
    private let claudeTurn2 = #"{"type":"assistant","message":{"id":"m2","content":[],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":200,"cache_creation_input_tokens":0}}}"#
    private let claudeResult = #"{"type":"result","subtype":"success","result":"{}","total_cost_usd":0.0412,"usage":{"input_tokens":120,"output_tokens":30,"cache_read_input_tokens":1500,"cache_creation_input_tokens":60}}"#

    func testClaudeSumsTurnsThenResultWins() {
        var reader = AnalysisUsageReader(tool: "Claude Code")
        XCTAssertNil(reader.usage)
        XCTAssertTrue(reader.consume(claudeTurn1))
        XCTAssertTrue(reader.consume(claudeTurn2))
        let live = reader.usage
        XCTAssertEqual(live?.input, 110)
        XCTAssertEqual(live?.output, 25)
        XCTAssertEqual(live?.cacheRead, 1200)
        XCTAssertEqual(live?.cacheWrite, 50)
        XCTAssertNil(live?.costUSD)

        XCTAssertTrue(reader.consume(claudeResult))
        let final = reader.usage
        XCTAssertEqual(final?.input, 120)
        XCTAssertEqual(final?.output, 30)
        XCTAssertEqual(final?.cacheRead, 1500)
        XCTAssertEqual(final?.cacheWrite, 60)
        XCTAssertEqual(final?.costUSD ?? 0, 0.0412, accuracy: 1e-9)
        XCTAssertEqual(final?.tool, "Claude Code")
    }

    func testClaudeRepeatedMessageIdIsNotCountedTwice() {
        var reader = AnalysisUsageReader(tool: "Claude Code")
        reader.consume(claudeTurn1)
        reader.consume(claudeTurn1)
        XCTAssertEqual(reader.usage?.output, 20)
    }

    func testCodexTurnCompletedSumsAndTakesCachedOutOfInput() {
        var reader = AnalysisUsageReader(tool: "Codex")
        reader.consume(#"{"type":"turn.started"}"#)
        reader.consume(#"{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":50}}"#)
        reader.consume(#"{"type":"turn.completed","usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":25}}"#)
        let usage = reader.usage
        XCTAssertEqual(usage?.input, 1000)
        XCTAssertEqual(usage?.cacheRead, 500)
        XCTAssertEqual(usage?.output, 75)
        XCTAssertNil(usage?.costUSD)
    }

    func testCodexTokenCountShapesReplaceRatherThanAdd() {
        var reader = AnalysisUsageReader(tool: "Codex")
        reader.consume(#"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":100,"output_tokens":10}}}}"#)
        reader.consume(#"{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":300,"output_tokens":40}}}"#)
        XCTAssertEqual(reader.usage?.input, 600)
        XCTAssertEqual(reader.usage?.cacheRead, 300)
        XCTAssertEqual(reader.usage?.output, 40)
    }

    func testGarbageIsIgnored() {
        var reader = AnalysisUsageReader(tool: "Claude Code")
        for line in ["", "not json", "{broken", "[1,2]", #"{"no":"type"}"#,
                     #"{"type":"assistant","message":{"content":[]}}"#,
                     #"{"type":"result","result":"x"}"#,
                     #"{"type":"turn.completed","usage":"lots"}"#,
                     #"{"type":"system","usage":{"input_tokens":5}}"#] {
            XCTAssertFalse(reader.consume(line), line)
        }
        XCTAssertNil(reader.usage)
    }

    func testCompactNumbers() {
        XCTAssertEqual(AnalysisUsage.compact(0), "0")
        XCTAssertEqual(AnalysisUsage.compact(812), "812")
        XCTAssertEqual(AnalysisUsage.compact(1_000), "1k")
        XCTAssertEqual(AnalysisUsage.compact(12_400), "12.4k")
        XCTAssertEqual(AnalysisUsage.compact(999_990), "1M")
        XCTAssertEqual(AnalysisUsage.compact(1_260_000), "1.3M")
    }

    func testLines() {
        let usage = AnalysisUsage(tool: "Claude Code", input: 12_400, output: 1_800,
                                  cacheRead: 9_100, cacheWrite: 0, costUSD: 0.04)
        XCTAssertEqual(usage.liveLine, "12.4k in \u{00B7} 1.8k out \u{00B7} 9.1k cached \u{00B7} $0.04")
        XCTAssertEqual(usage.reportLine, "Written by Claude Code \u{00B7} 23.3k tokens \u{00B7} $0.04")
        let plain = AnalysisUsage(tool: "Codex", input: 500, output: 20)
        XCTAssertEqual(plain.liveLine, "500 in \u{00B7} 20 out")
        XCTAssertEqual(AnalysisUsage.money(0.001), "<$0.01")
        XCTAssertEqual(AnalysisUsage.money(0), "$0.00")
    }

    func testCodableRoundTrip() throws {
        let usage = AnalysisUsage(tool: "Codex", input: 1, output: 2, cacheRead: 3, cacheWrite: 4, costUSD: nil)
        let back = try JSONDecoder().decode(AnalysisUsage.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(back, usage)
    }
}
