//
//  main.swift
//  PrompterBench
//
//  Phase 1 of docs/prompter-search-improvement-plan.md: a repeatable score for
//  the word-pattern detector, so a change to it is a measurement rather than an
//  opinion.
//
//  It exists because of a specific failure. A rule was added letting any
//  ordinary dictionary word of eight letters or more through the filter, on the
//  reasoning that a long word is a subject word. It shipped unmeasured, and the
//  next real class produced exactly one suggestion: a dictionary entry for
//  "happening", out of "Okay. What is happening right now?". Every case in
//  `fixtures/detector.json` that must produce nothing is there to make that
//  class of mistake fail here first, in under a second, with no meeting.
//
//  Deliberately NOT an XCTest bundle. The app target links ZoomSDK, Sparkle and
//  Apptics, so a hosted test bundle would drag all three in to exercise two
//  files that import Foundation. Keeping the bench to a plain tool also keeps
//  the detector honest: the moment it reaches for anything in the app, this
//  stops compiling.
//
//  Run it:  scripts/prompter-bench.sh
//
import Foundation

// MARK: - Fixtures

struct Fixture: Decodable {
    struct Expected: Decodable {
        let kind: String
        let query: String
    }
    let id: String
    /// The newly finalised sentence(s) the detector sees.
    let text: String
    /// Preceding speech, as the pipeline would pass it. Quote cues read it.
    let context: String?
    /// Names in the meeting, which must never become mentions.
    let roster: [String]?
    /// What a card SHOULD be offered for. Empty means: offer nothing.
    let expect: [Expected]
    let tags: [String]?
}

struct FixtureFile: Decodable {
    let cases: [Fixture]
}

// MARK: - Matching

/// A detection answers an expectation when either normalised phrase contains
/// the other.
///
/// Not equality. The truth file written from the real class keys on the short
/// form a person would write - "haiku" for "it's called Haiku Deck" - while the
/// detector captures the span it actually heard. Demanding they match character
/// for character would score span boundaries, which is not what is being
/// measured here.
func answers(_ detected: String, _ expected: String) -> Bool {
    let d = Mention.normalize(detected)
    let e = Mention.normalize(expected)
    guard !d.isEmpty, !e.isEmpty else { return false }
    return d.contains(e) || e.contains(d)
}

// MARK: - Results

struct Outcome {
    var truePositives = 0
    var falsePositives = 0
    var falseNegatives = 0
    /// Of the matched detections, how many also had the right kind.
    var kindCorrect = 0

    var precision: Double {
        let denominator = truePositives + falsePositives
        return denominator == 0 ? 1 : Double(truePositives) / Double(denominator)
    }
    var recall: Double {
        let denominator = truePositives + falseNegatives
        return denominator == 0 ? 1 : Double(truePositives) / Double(denominator)
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[index]
}

func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s.padding(toLength: n, withPad: " ", startingAt: 0)
}

// MARK: - Run

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: PrompterBench <fixtures.json> [--verbose]\n".utf8))
    exit(2)
}
let verbose = arguments.contains("--verbose")
let fixtureURL = URL(fileURLWithPath: arguments[1])

let file: FixtureFile
do {
    file = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: fixtureURL))
} catch {
    FileHandle.standardError.write(Data("cannot read fixtures at \(fixtureURL.path): \(error)\n".utf8))
    exit(2)
}

let detector = HeuristicDetector()
var overall = Outcome()
var byKind: [String: Outcome] = [:]
var durations: [Double] = []
var falsePositiveLines: [String] = []
var missLines: [String] = []
var wrongKindLines: [String] = []

let semaphore = DispatchSemaphore(value: 0)
Task {
    for fixture in file.cases {
        let started = Date()
        let detected = (try? await detector.detect(newText: fixture.text,
                                                   context: fixture.context ?? "",
                                                   excludedNames: fixture.roster ?? [])) ?? []
        durations.append(Date().timeIntervalSince(started) * 1000)

        var unmatchedExpectations = fixture.expect
        var matchedDetections = Set<Int>()

        for (index, mention) in detected.enumerated() {
            guard let position = unmatchedExpectations.firstIndex(where: {
                answers(mention.query, $0.query)
            }) else { continue }
            let expectation = unmatchedExpectations.remove(at: position)
            matchedDetections.insert(index)
            overall.truePositives += 1
            byKind[expectation.kind, default: Outcome()].truePositives += 1
            if mention.kind.rawValue == expectation.kind {
                overall.kindCorrect += 1
                byKind[expectation.kind, default: Outcome()].kindCorrect += 1
            } else {
                wrongKindLines.append("  \(pad(fixture.id, 28)) \(pad(mention.query, 26)) said \(mention.kind.rawValue), expected \(expectation.kind)")
            }
        }

        for (index, mention) in detected.enumerated() where !matchedDetections.contains(index) {
            overall.falsePositives += 1
            byKind[mention.kind.rawValue, default: Outcome()].falsePositives += 1
            let why = fixture.expect.isEmpty ? "must offer nothing" : "not expected"
            falsePositiveLines.append("  \(pad(fixture.id, 28)) \(pad(mention.query, 26)) \(pad(mention.kind.rawValue, 7)) \(why)")
        }

        for expectation in unmatchedExpectations {
            overall.falseNegatives += 1
            byKind[expectation.kind, default: Outcome()].falseNegatives += 1
            missLines.append("  \(pad(fixture.id, 28)) \(pad(expectation.query, 26)) \(expectation.kind)")
        }
    }
    semaphore.signal()
}
semaphore.wait()

// MARK: - Report

let expectedTotal = file.cases.reduce(0) { $0 + $1.expect.count }
let mustBeSilent = file.cases.filter { $0.expect.isEmpty }.count

print("")
print("PROMPTER DETECTOR BENCH  ·  word patterns  ·  \(file.cases.count) cases, \(expectedTotal) expected mentions, \(mustBeSilent) must-stay-silent")
print(String(repeating: "-", count: 78))
print("")
print("  precision      \(String(format: "%5.1f%%", overall.precision * 100))   target >= 70%   \(overall.precision >= 0.70 ? "PASS" : "FAIL")")
print("  recall         \(String(format: "%5.1f%%", overall.recall * 100))")
print("  kind correct   \(overall.truePositives == 0 ? "  n/a" : String(format: "%5.1f%%", Double(overall.kindCorrect) / Double(overall.truePositives) * 100))   of matched detections")
print("  detect p50     \(String(format: "%5.2f ms", percentile(durations, 0.50)))")
print("  detect p95     \(String(format: "%5.2f ms", percentile(durations, 0.95)))")
print("")
print("  hits \(overall.truePositives)   false alarms \(overall.falsePositives)   misses \(overall.falseNegatives)")
print("")

print("  per kind         hits  false  miss   precision  recall")
for kind in byKind.keys.sorted() {
    let outcome = byKind[kind]!
    print("  \(pad(kind, 16))  \(pad(String(outcome.truePositives), 4)) \(pad(String(outcome.falsePositives), 6)) \(pad(String(outcome.falseNegatives), 5))  "
        + String(format: "%7.1f%%  %6.1f%%", outcome.precision * 100, outcome.recall * 100))
}
print("")

if !falsePositiveLines.isEmpty {
    print("FALSE ALARMS  (\(falsePositiveLines.count)) - a card the class did not need")
    for line in falsePositiveLines.prefix(verbose ? .max : 20) { print(line) }
    if !verbose, falsePositiveLines.count > 20 { print("  ... \(falsePositiveLines.count - 20) more, run with --verbose") }
    print("")
}
if !missLines.isEmpty {
    print("MISSES  (\(missLines.count)) - a card the class wanted and did not get")
    for line in missLines.prefix(verbose ? .max : 20) { print(line) }
    if !verbose, missLines.count > 20 { print("  ... \(missLines.count - 20) more, run with --verbose") }
    print("")
}
if !wrongKindLines.isEmpty {
    print("RIGHT PHRASE, WRONG KIND  (\(wrongKindLines.count)) - resolves against the wrong source")
    for line in wrongKindLines.prefix(verbose ? .max : 20) { print(line) }
    print("")
}

exit(overall.precision >= 0.70 ? 0 : 1)
