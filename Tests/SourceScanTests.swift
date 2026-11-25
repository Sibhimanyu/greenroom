//
//  SourceScanTests.swift
//  GreenroomTests
//
//  Rules that live in DESIGN.md and AGENTS.md, checked against the App/ sources
//  on disk. Each failure names file:line. The scanner is deliberately small:
//  one lexer that splits a file into code (comments and string contents
//  blanked) and string-literal segments, then one regex per rule.
//
//  Allow-lists name a file and a snippet of the line, each with a reason. An
//  entry that no longer matches anything fails too, so the lists stay honest.
//  `knownDrift` entries are real violations found when the scan was added
//  (2026-11-26): they are listed so the scan can go green, and should be fixed
//  and removed, never added to.
//
import XCTest

final class SourceScanTests: XCTestCase {

    // MARK: Rule 1: raw RGB colours in App/UI

    /// DESIGN.md: colour comes from tokens. The tokens (`Brand`, `StageFrame.ink`)
    /// live outside App/UI, in App/GreenroomApp.swift and App/Stage/StageFrame.swift.
    func testNoRawRGBColoursInUI() throws {
        let rule = try NSRegularExpression(pattern: #"(?<![A-Za-z])(NS)?Color\((red|calibratedRed):"#)
        let allowed: [Allowance] = [
            Allowance("App/UI/WebcamShapePreview.swift", "chromaGreen = Color(red:",
                      "a chroma-key green screen in the sketch; DESIGN.md names it apart from the brand"),
            Allowance("App/UI/LayoutEveryonePicture.swift", "Color(red: StageFrame.ink.red",
                      "bridges the --ink token (StageFrame.ink) into SwiftUI; no raw value"),
        ]
        let knownDrift: [Allowance] = [
            Allowance("App/UI/WhiteboardViews.swift", "Color(red: 1, green: 0.29, blue: 0.31)",
                      "DRIFT: whiteboard close badge, a hand-picked red; should be a system red"),
            Allowance("App/UI/DockHint.swift", "static let stage = Color(red: 0.11",
                      "DRIFT: the hint pictures' dark stage, near but not --ink; should use StageFrame.ink"),
            Allowance("App/UI/DockHint.swift", "Color(red: 0.2, green: 0.25, blue: 0.3)",
                      "DRIFT: the hint whiteboard's ink stroke, a hand-picked grey"),
        ]
        try check(under: "App/UI", rule: rule, allowed: allowed + knownDrift, what: "raw RGB colour; use a token (DESIGN.md)") { $0.codeLines }
    }

    // MARK: Rule 2: "class" in UI strings

    /// UI words say meeting or everyone, never class (AGENTS.md, Rules that bite).
    func testNoClassInUIStrings() throws {
        let rule = try NSRegularExpression(pattern: #"\bclass(es)?\b"#, options: [.caseInsensitive])
        let allowed: [Allowance] = [
            Allowance("App/UI/SessionTitleSuggester.swift", #""class", "lesson""#,
                      "stopwords dropped from transcripts when suggesting a title; never shown"),
            Allowance("App/UI/Tiles.swift", #"ForEach(["Class", "Talk"]"#,
                      "sample labels in the #Preview canvas; not in the app"),
        ]
        try check(under: "App/UI", rule: rule, allowed: allowed, what: "\"class\" in a UI string; say meeting or everyone") { $0.literals }
    }

    // MARK: Rule 3: one place sets sharingType

    /// What other apps' recorders see is decided by PresenceRecorderRules and
    /// applied in one file. Nothing else assigns `sharingType`.
    func testSharingTypeIsAssignedInOneFile() throws {
        let rule = try NSRegularExpression(pattern: #"\.sharingType\s*=(?!=)"#)
        let allowed: [Allowance] = [
            Allowance("App/UI/RecorderVisibility.swift", "window.sharingType = wanted",
                      "the one file that applies PresenceRecorderRules to a window"),
        ]
        try check(under: "App", rule: rule, allowed: allowed, what: "sharingType assigned outside RecorderVisibility.swift") { $0.codeLines }
    }

    // MARK: Rule 4: exact rect equality in App/Layout

    /// Rects come out of floating-point arithmetic, so `==` on them is a trap.
    /// Use `isClose(to:)` (UnitRect), `LayoutGeometry.same` or
    /// `LayoutGeometry.differs(_:from:)` (CGRect). Only `==` is scanned, where
    /// an operand's name ends in rect or frame; `!=` guards that skip a no-op
    /// write are exact on purpose and are not flagged.
    func testNoExactRectEqualityInLayout() throws {
        // A dotted path whose last part is `rect`/`frame` or ends in `Rect`/`Frame`
        // (so `isCorrect` and `frameCount` stay out).
        let operand = #"(?:[\w$]+[?!]?(?:\[[^\]]*\])?\.)*(?:\w*(?:Rect|Frame)|rect|frame)"#
        let rule = try NSRegularExpression(pattern:
            #"(?:(?<![\w.$])"# + operand + #"\s*==(?!=))|(?:(?<![=!<>])==\s*"# + operand + #"(?![\w.\[(]|[?!]\.))"#)
        let knownDrift: [Allowance] = [
            Allowance("App/Layout/DisplayPlan.swift", "return moved == frame ? nil : moved",
                      "DRIFT: a fractional frame always reads as moved; use LayoutGeometry.differs"),
            Allowance("App/Layout/DisplayMonitor.swift", "$0.frame == window.frame",
                      "DRIFT: a window a hair off a screen's frame is treated as stranded; compare with a tolerance"),
        ]
        try check(under: "App/Layout", rule: rule, allowed: knownDrift, what: "exact == on rects; use a tolerance helper") { $0.codeLines }
    }

    // MARK: The lexer, tested on its own

    func testLexerSeparatesCodeCommentsAndStrings() {
        let src = """
        let a = "one class" // a class comment
        /* class Color(red: 1) */ class Foo {}
        let b = "x \\(f("inner class")) y"
        let c = #"raw "class" here"#
        let d = \"""
            many
            class lines
            \"""
        """
        let s = Lexed(src)
        XCTAssertEqual(s.literals.map(\.text), ["one class", "x ", "inner class", " y", #"raw "class" here"#, "    many", "    class lines"])
        XCTAssertEqual(s.literals.map(\.line), [1, 3, 3, 3, 4, 6, 7])
        XCTAssertFalse(s.code[0].contains("class"), s.code[0])
        XCTAssertFalse(s.code[1].contains("Color"), s.code[1])
        XCTAssertTrue(s.code[1].contains("class Foo"), s.code[1])
        XCTAssertTrue(s.code[2].contains("f("), s.code[2])
        XCTAssertEqual(s.code.count, 8)
    }

    // MARK: Plumbing

    struct Allowance {
        let file: String, snippet: String, reason: String
        init(_ file: String, _ snippet: String, _ reason: String) {
            self.file = file; self.snippet = snippet; self.reason = reason
        }
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Each swift file under `dir` (relative to the repo root), lexed.
    private func sources(under dir: String) throws -> [(path: String, lexed: Lexed)] {
        let base = Self.root.appendingPathComponent(dir)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            XCTFail("cannot read \(base.path)"); return []
        }
        var out: [(String, Lexed)] = []
        for case let url as URL in walk where url.pathExtension == "swift" {
            let rel = String(url.standardizedFileURL.path.dropFirst(Self.root.standardizedFileURL.path.count + 1))
            out.append((rel, Lexed(try String(contentsOf: url, encoding: .utf8))))
        }
        XCTAssertFalse(out.isEmpty, "no sources under \(dir)")
        return out.sorted { $0.0 < $1.0 }
    }

    /// Runs `rule` over the chosen text of every file and records one failure
    /// per unallowed hit, located at the offending file:line.
    private func check(under dir: String, rule: NSRegularExpression, allowed: [Allowance], what: String,
                       text: (Lexed) -> [(line: Int, text: String)]) throws {
        var used = Set<Int>()
        for (path, lexed) in try sources(under: dir) {
            let lines = lexed.source.components(separatedBy: "\n")
            for (line, chunk) in text(lexed) {
                guard rule.firstMatch(in: chunk, range: NSRange(chunk.startIndex..., in: chunk)) != nil else { continue }
                let raw = lines[line - 1]
                if let i = allowed.firstIndex(where: { $0.file == path && raw.contains($0.snippet) }) {
                    used.insert(i); continue
                }
                fail("\(path):\(line): \(what): \(raw.trimmingCharacters(in: .whitespaces))", path: path, line: line)
            }
        }
        for (i, a) in allowed.enumerated() where !used.contains(i) {
            fail("stale allow-list entry, nothing matches: \(a.file) \"\(a.snippet)\"", path: a.file, line: 1)
        }
    }

    private func fail(_ message: String, path: String, line: Int) {
        let location = XCTSourceCodeLocation(filePath: Self.root.appendingPathComponent(path).path, lineNumber: line)
        record(XCTIssue(type: .assertionFailure, compactDescription: message,
                        sourceCodeContext: XCTSourceCodeContext(location: location)))
    }
}

/// A Swift file split into code and string literals. `code` has one entry per
/// source line, with comments and string contents replaced by spaces (quotes
/// kept). `literals` holds each string's text, one segment per line and per
/// side of an interpolation, with its 1-based line. Handles escapes,
/// `\(...)` interpolation (nested strings included), raw `#"..."#` and
/// multi-line strings, and nested block comments. Not handled: regex literals.
struct Lexed {
    let source: String
    private(set) var code: [String] = []
    private(set) var literals: [(line: Int, text: String)] = []
    var codeLines: [(line: Int, text: String)] { code.enumerated().map { ($0.offset + 1, $0.element) } }

    init(_ source: String) {
        self.source = source
        let s = Array(source.unicodeScalars)
        enum Mode { case code, lineComment, blockComment(Int), string(multi: Bool, hashes: Int) }
        var mode = Mode.code
        var interps: [(multi: Bool, hashes: Int, depth: Int)] = []
        var codeLine = String.UnicodeScalarView(), literal = String.UnicodeScalarView()
        var line = 1, inLiteral = false
        var i = 0

        func at(_ k: Int) -> Unicode.Scalar? { k < s.count ? s[k] : nil }
        func run(of c: Unicode.Scalar, from k: Int) -> Int { var n = 0; while at(k + n) == c { n += 1 }; return n }
        func flushLiteral() {
            if inLiteral && !literal.isEmpty { literals.append((line, String(literal))) }
            literal = .init()
        }

        while i < s.count {
            let c = s[i]
            if c == "\n" {
                if case .string = mode { flushLiteral() }
                if case .lineComment = mode { mode = .code }
                code.append(String(codeLine)); codeLine = .init(); line += 1; i += 1
                continue
            }
            switch mode {
            case .code:
                if c == "/" && at(i + 1) == "/" { mode = .lineComment; codeLine.append(" "); i += 1; continue }
                if c == "/" && at(i + 1) == "*" { mode = .blockComment(1); codeLine.append(" "); i += 1; continue }
                let hashes = run(of: "#", from: i)
                if at(i + hashes) == "\"" {
                    let multi = run(of: "\"", from: i + hashes) >= 3
                    let open = hashes + (multi ? 3 : 1)
                    for _ in 0..<open { codeLine.append("\"") }
                    i += open
                    mode = .string(multi: multi, hashes: hashes); inLiteral = true
                    // A multi-line string's text starts on the next line.
                    if multi { while at(i) != nil && at(i) != "\n" { i += 1 } }
                    continue
                }
                if !interps.isEmpty {
                    if c == "(" { interps[interps.count - 1].depth += 1 }
                    if c == ")" {
                        if interps[interps.count - 1].depth == 0 {
                            let back = interps.removeLast()
                            mode = .string(multi: back.multi, hashes: back.hashes); inLiteral = true
                            codeLine.append(")"); i += 1; continue
                        }
                        interps[interps.count - 1].depth -= 1
                    }
                }
                codeLine.append(c); i += 1
            case .lineComment:
                codeLine.append(" "); i += 1
            case .blockComment(let depth):
                if c == "*" && at(i + 1) == "/" {
                    mode = depth == 1 ? .code : .blockComment(depth - 1); codeLine.append(" "); i += 2; continue
                }
                if c == "/" && at(i + 1) == "*" { mode = .blockComment(depth + 1); i += 2; continue }
                codeLine.append(" "); i += 1
            case .string(let multi, let hashes):
                if c == "\\" && run(of: "#", from: i + 1) >= hashes {
                    let after = i + 1 + hashes
                    if at(after) == "(" {
                        flushLiteral(); inLiteral = false
                        interps.append((multi, hashes, 0)); mode = .code
                        codeLine.append("("); i = after + 1; continue
                    }
                    if at(after) == "\n" { literal.append(c); i += 1; continue }
                    if hashes == 0 || run(of: "#", from: i + 1) == hashes {
                        literal.append(c); if let n = at(after) { literal.append(n) }
                        codeLine.append(" "); i = after + 1; continue
                    }
                }
                let quotes = multi ? 3 : 1
                if c == "\"" && run(of: "\"", from: i) >= quotes && run(of: "#", from: i + quotes) >= hashes {
                    // A multi-line string closes on a line of its own; its indent is not text.
                    if multi, String(literal).trimmingCharacters(in: .whitespaces).isEmpty { literal = .init() }
                    flushLiteral(); inLiteral = false
                    mode = .code
                    for _ in 0..<(quotes + hashes) { codeLine.append("\"") }
                    i += quotes + hashes; continue
                }
                literal.append(c); codeLine.append(" "); i += 1
            }
        }
        if case .string = mode { flushLiteral() }
        code.append(String(codeLine))
    }
}
