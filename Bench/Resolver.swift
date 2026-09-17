//
//  Resolver.swift
//  CuesBench
//
//  Phase 2 of docs/cues-search-improvement-plan.md: score what the resolver
//  does with an answer, and how long it takes to get there, without asking the
//  live internet. Every reply here is recorded, so the same input gives the
//  same card and the same shape of timing every run.
//
//  The timing cases are the point of this file. "These two requests run
//  concurrently" is exactly the kind of claim that rots: resolveThing carried a
//  comment saying so while awaiting one before starting the other, and nothing
//  caught it because a comment cannot be run. Giving the recorded transport a
//  deliberate delay turns that claim into an assertion - sequential and
//  concurrent differ by a factor of two, which no amount of machine noise can
//  blur.
//
import Foundation

/// A recorded transport that also takes its time, so concurrency is measurable.
struct DelayedTransport: CuesTransport {
    let replies: [String: RecordedTransport.Reply]
    /// URL prefix -> seconds this reply should take to arrive.
    let delays: [String: Double]

    private func lookUp(_ request: URLRequest) async -> RecordedTransport.Reply {
        let asked = request.url?.absoluteString ?? ""
        for (prefix, seconds) in delays where asked.hasPrefix(prefix) {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            break
        }
        if let exact = replies[asked] { return exact }
        for (key, reply) in replies where asked.hasPrefix(key) { return reply }
        return RecordedTransport.Reply(status: 404, body: "")
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = await lookUp(request)
        return (Data(reply.body.utf8),
                HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                httpVersion: nil, headerFields: nil)!)
    }

    func text(for request: URLRequest, stoppingAfter marker: String,
              byteCap: Int) async throws -> (String, HTTPURLResponse) {
        let reply = await lookUp(request)
        return (reply.status == 200 ? String(reply.body.prefix(byteCap)) : "",
                HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                httpVersion: nil, headerFields: nil)!)
    }
}

// MARK: - Recorded bodies

enum Recorded {
    static let wikipediaSearch = "https://en.wikipedia.org/w/rest.php/v1/search/title"

    /// A Wikipedia title-search reply whose only page is `title`.
    static func wikipediaPage(title: String, key: String, description: String) -> String {
        """
        {"pages":[{"id":1,"key":"\(key)","title":"\(title)",
        "excerpt":"","description":"\(description)",
        "thumbnail":{"url":"//upload.wikimedia.org/thumb.jpg","width":60,"height":80}}]}
        """
    }

    static func homepage(title: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(title)</title></head><body>"
    }
}

// MARK: - Cases

struct ResolverCase {
    let id: String
    /// Why this case is here. Read by people, not by the runner.
    var _why: String = ""
    let mention: Mention
    let replies: [String: RecordedTransport.Reply]
    /// The card's expected title, or nil when the case expects NO card.
    ///
    /// It used to mean "expects a picture-search link". That consolation card
    /// is gone: when no source answers, the correct behaviour is to offer the
    /// teacher nothing.
    let expectTitle: String?
    let expectSource: CueCard.Source
}

func resolverCases() -> [ResolverCase] {
    [
        ResolverCase(
            id: "thing-no-site-guess",
            mention: Mention(kind: .thing, query: "haiku deck", confidence: 0.8),
            replies: [
                // haikudeck.com is real and this used to prefer it. The same
                // guess reached Whitepages for "phone number" and a Utah gym
                // for "upper limit", 54 lookups for nine wrong answers, so the
                // guess is gone: Wikipedia answers or nothing does.
                "https://haikudeck.com": .init(body: Recorded.homepage(title: "Haiku Deck")),
                Recorded.wikipediaSearch: .init(status: 404, body: "{}")
            ],
            expectTitle: nil,
            expectSource: .wikipedia),

        ResolverCase(
            id: "thing-nothing-found-offers-nothing",
            mention: Mention(kind: .thing, query: "scarves", confidence: 0.8),
            replies: [
                Recorded.wikipediaSearch: .init(status: 404, body: "{}")
            ],
            // Was a Bing image search, which cannot be wrong and is therefore
            // where every bad mention landed - 54 of one class's 82 links.
            expectTitle: nil,
            expectSource: .wikipedia),

        ResolverCase(
            id: "thing-wikipedia-disambiguation-rejected",
            mention: Mention(kind: .thing, query: "shut down", confidence: 0.8),
            replies: [
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "Shut Down (Blackpink song)", key: "Shut_Down",
                    description: "2022 single"))
            ],
            // Every spoken word is in the title, so answers() passed it and a
            // real class got a K-pop single. A parenthetical means the phrase
            // was ambiguous and Wikipedia chose for us.
            expectTitle: nil,
            expectSource: .wikipedia),

        ResolverCase(
            id: "thing-creative-work-rejected",
            mention: Mention(kind: .thing, query: "interesting story", confidence: 0.8),
            replies: [
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "An Interesting Story", key: "An_Interesting_Story",
                    description: "1904 film"))
            ],
            // An exact title, and the wrong answer in a reading lesson.
            expectTitle: nil,
            expectSource: .wikipedia),

        ResolverCase(
            id: "thing-person-description-still-allowed",
            mention: Mention(kind: .thing, query: "orson welles", confidence: 0.8),
            replies: [
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "Orson Welles", key: "Orson_Welles",
                    description: "American film director"))
            ],
            // The guard against over-reach: "film" in a job title is not a
            // release date, so this must survive.
            expectTitle: "Orson Welles",
            expectSource: .wikipedia),

        ResolverCase(
            id: "thing-wikipedia-when-no-site",
            mention: Mention(kind: .thing, query: "e ink", confidence: 0.8),
            replies: [
                "https://eink.com": .init(status: 404, body: ""),
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "E Ink", key: "E_Ink", description: "Electronic paper technology"))
            ],
            expectTitle: "E Ink",
            expectSource: .wikipedia),

        ResolverCase(
            id: "thing-broader-page-rejected",
            mention: Mention(kind: .thing, query: "kindle paperwhite", confidence: 0.8),
            replies: [
                "https://kindlepaperwhite.com": .init(status: 404, body: ""),
                // Every word of the title must have been said. "Amazon" was not,
                // so this falls through to the picture search - which is what the
                // teacher did for this one himself.
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "Amazon Kindle", key: "Amazon_Kindle", description: "E-reader series"))
            ],
            expectTitle: nil,
            expectSource: .search),

        ResolverCase(
            id: "thing-subset-title-rejected",
            _why: "The hole in the old rule. Every word of 'Haiku' had been said, so the poetic form was served confidently to a teacher talking about slide software.",
            mention: Mention(kind: .thing, query: "haiku deck", confidence: 0.8),
            replies: [
                "https://haikudeck.com": .init(status: 404, body: ""),
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "Haiku", key: "Haiku", description: "Japanese poetic form"))
            ],
            expectTitle: nil,
            expectSource: .search),

        ResolverCase(
            id: "thing-asr-mangled-brand",
            _why: "What the transcriber actually wrote for Haiku Deck. Four edits away by spelling, the same word by sound.",
            mention: Mention(kind: .thing, query: "hyco deck", confidence: 0.8),
            replies: [
                "https://hycodeck.com": .init(status: 404, body: ""),
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "Haiku Deck", key: "Haiku_Deck", description: "Presentation software"))
            ],
            expectTitle: "Haiku Deck",
            expectSource: .wikipedia),

        ResolverCase(
            id: "thing-extra-title-word-allowed",
            _why: "A title may say more than was said. Only missing what WAS said is disqualifying.",
            mention: Mention(kind: .thing, query: "monospace", confidence: 0.8),
            replies: [
                "https://monospace.com": .init(status: 404, body: ""),
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "Monospaced font", key: "Monospaced_font", description: "Typeface class"))
            ],
            expectTitle: "Monospaced font",
            expectSource: .wikipedia),

        ResolverCase(
            id: "thing-phonetic-not-a-blank-cheque",
            _why: "Soundex is loose. It may rescue one mangled token, never carry a whole wrong title.",
            mention: Mention(kind: .thing, query: "brand new gadget", confidence: 0.8),
            replies: [
                "https://brandnewgadget.com": .init(status: 404, body: ""),
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "Burnt Nut Gasket", key: "Burnt_Nut_Gasket", description: "Unrelated"))
            ],
            expectTitle: nil,
            expectSource: .search),

        ResolverCase(
            id: "thing-phonetic-alone-is-not-evidence",
            _why: "From the 22-29 class. Tamil speech gave the model 'Orukuntu'; it keys to O625 and so does 'Orkun', so the phonetic path served a Turkish footballer. The bound was one phonetic token per title, which is no bound at all when the phrase IS one token.",
            mention: Mention(kind: .thing, query: "orukuntu", confidence: 0.8),
            replies: [
                "https://orukuntu.com": .init(status: 404, body: ""),
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "Orkun Usak", key: "Orkun_Usak", description: "Turkish footballer"))
            ],
            expectTitle: nil,
            expectSource: .search),

        ResolverCase(
            id: "thing-disambiguation-rejected",
            mention: Mention(kind: .thing, query: "mercury", confidence: 0.8),
            replies: [
                "https://mercury.com": .init(status: 404, body: ""),
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "Mercury", key: "Mercury",
                    description: "Topics referred to by the same term"))
            ],
            expectTitle: nil,
            expectSource: .search)
    ]
}

// MARK: - Run

func runResolverBench(verbose: Bool) async -> Bool {
    print("")
    print("PROMPTER RESOLVER BENCH  ·  recorded replies, no network")
    print(String(repeating: "-", count: 78))
    print("")

    var passed = 0
    var failures: [String] = []
    let cases = resolverCases()

    for scenario in cases {
        let resolver = LinkResolver(transport: RecordedTransport(replies: scenario.replies))
        await resolver.configure(.init(sessionCap: 100, lookupsPerMinute: 100))
        let resolution = await resolver.resolve(scenario.mention)
        let card = resolution.cards.first

        let titleOK: Bool
        let sourceOK: Bool
        if let expected = scenario.expectTitle {
            titleOK = card?.title == expected
            sourceOK = card?.source == scenario.expectSource
        } else {
            titleOK = card == nil
            sourceOK = true
        }

        if titleOK && sourceOK {
            passed += 1
            if verbose {
                print("  ok    \(pad(scenario.id, 32)) \(card?.source.label ?? "-")  \(card?.title ?? "-")")
            }
        } else {
            failures.append("  FAIL  \(pad(scenario.id, 32)) got \(card?.source.label ?? "no card")"
                + " \u{201C}\(card?.title ?? "-")\u{201D}, wanted \(scenario.expectSource.label)"
                + (scenario.expectTitle.map { " \u{201C}\($0)\u{201D}" } ?? " no card at all"))
        }
    }

    print("  retrieval    \(passed)/\(cases.count) cases pick the intended card")
    for line in failures { print(line) }
    print("")

    // MARK: The concurrency assertion
    //
    // Retargeted. This used to time resolveThing fetching a product's homepage
    // and its Wikipedia entry together; the homepage guess is gone, so the
    // remaining pair is encyclopediaEntry's two legs - the enriched search
    // query and the bare name, which run as `async let` and must overlap.

    let leg = 0.30
    let replies: [String: RecordedTransport.Reply] = [
        Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
            title: "Working memory", key: "Working_memory", description: "Cognitive system"))
    ]
    let transport = DelayedTransport(replies: replies,
                                     delays: [Recorded.wikipediaSearch: leg])
    let resolver = LinkResolver(transport: transport)
    await resolver.configure(.init(sessionCap: 100, lookupsPerMinute: 100))

    let started = Date()
    _ = await resolver.resolve(Mention(kind: .topic, query: "working memory",
                                       searchQuery: "working memory psychology",
                                       confidence: 0.8))
    let elapsed = Date().timeIntervalSince(started)

    // Sequential would be 2 x leg. Concurrent is one leg plus overhead. The
    // threshold sits halfway between, so neither machine noise nor a fast run
    // can make a sequential implementation look concurrent.
    let sequential = leg * 2
    let threshold = leg * 1.5
    let concurrent = elapsed < threshold
    print("  two wikipedia legs, \(Int(leg * 1000)) ms each")
    print(String(format: "    sequential would be %.0f ms, measured %.0f ms  %@",
                 sequential * 1000, elapsed * 1000, concurrent ? "CONCURRENT" : "SEQUENTIAL - REGRESSION"))
    print("")

    let compositeOK = await runCompositeBench()
    let rulesOK = runRulesBench()
    let ok = failures.isEmpty && concurrent && compositeOK && rulesOK
    return ok
}

// MARK: - Composite detector

/// A detector that returns whatever it was handed, and records whether it ran.
/// Standing in for the real model, which cannot be part of a deterministic
/// bench: it is a language model, so the same input is not a promise of the
/// same output. What IS testable is the composition - who gets asked, when,
/// and whose answer wins - and that is what this checks.
final class StubDetector: MentionDetector, @unchecked Sendable {
    let name = "stub"
    let analyticsCode = "stub"
    let isCheap = true
    private let output: [Mention]
    private(set) var ran = false

    init(returning output: [Mention]) { self.output = output }

    func detect(newText: String, context: String, excludedNames: [String]) async throws -> [Mention] {
        ran = true
        return output
    }
}

func runCompositeBench() async -> Bool {
    print("  composite detector")
    var ok = true

    // 1. An explicit tell: the patterns answer and the model is never asked.
    let quietModel = StubDetector(returning: [
        Mention(kind: .topic, query: "slides", confidence: 1.0)
    ])
    let withTell = CompositeDetector(model: quietModel)
    let told = (try? await withTell.detect(
        newText: "There is a tool called Figma that we will use today.",
        context: "", excludedNames: [])) ?? []
    let patternsAnswered = told.contains { $0.query.lowercased().contains("figma") }
    let modelSpared = !quietModel.ran
    print("    explicit tell        patterns answered \(patternsAnswered ? "yes" : "NO")"
        + ", model asked \(quietModel.ran ? "YES - it should not have been" : "no")")
    ok = ok && patternsAnswered && modelSpared

    // 2. No tell at all: the patterns are silent, so the model gets its turn,
    //    and what it returns is tagged as its own.
    let busyModel = StubDetector(returning: [
        Mention(kind: .thing, query: "book fusion", searchQuery: "book fusion library",
                confidence: 1.0)
    ])
    let noTell = CompositeDetector(model: busyModel)
    let untold = (try? await noTell.detect(
        newText: "Many of you still have not joined book fusion, please do it tonight.",
        context: "", excludedNames: [])) ?? []
    let modelFilledIn = untold.contains { $0.query == "book fusion" }
    let tagged = untold.allSatisfy { $0.foundBy == .model }
    print("    no tell              model asked \(busyModel.ran ? "yes" : "NO")"
        + ", answer tagged \(tagged && modelFilledIn ? "model" : "WRONG")")
    ok = ok && busyModel.ran && modelFilledIn && tagged

    // 3. The roster rule still binds on the model's leg. It ignores its
    //    instructions, so this cannot be left to the prompt.
    let looseModel = StubDetector(returning: [
        Mention(kind: .person, query: "Arun Kumar", confidence: 1.0)
    ])
    let guarded = CompositeDetector(model: looseModel)
    let roster = (try? await guarded.detect(
        newText: "Right, so that is the plan for the rest of this week everyone.",
        context: "", excludedNames: ["Arun Kumar"])) ?? []
    let studentDropped = !roster.contains { $0.query == "Arun Kumar" }
    print("    roster name from model  \(studentDropped ? "dropped" : "LEAKED")")
    ok = ok && studentDropped

    // 4. A batch that is not English is not a batch to mine for named things.
    //    From the 22-29 class: this sentence is Tamil as the English model
    //    heard it, zero of five words in the dictionary, and it produced two
    //    of that class's three wrong links.
    let tamilModel = StubDetector(returning: [
        Mention(kind: .thing, query: "Orukuntu", confidence: 1.0),
        Mention(kind: .thing, query: "Kayam", confidence: 1.0)
    ])
    let tamilGuard = CompositeDetector(model: tamilModel)
    let tamil = (try? await tamilGuard.detect(
        newText: "Eppudu, Orukuntu, Indha, veyyil, Kayam.",
        context: "", excludedNames: [])) ?? []
    let skippedTheModel = !tamilModel.ran && tamil.isEmpty
    print("    non-English batch    model asked \(tamilModel.ran ? "YES - it should not have been" : "no")")
    ok = ok && skippedTheModel

    // And the other side: an English sentence with no tell must still reach it.
    let englishModel = StubDetector(returning: [
        Mention(kind: .thing, query: "book fusion", confidence: 1.0)
    ])
    let englishGuard = CompositeDetector(model: englishModel)
    _ = try? await englishGuard.detect(
        newText: "Many of you still have not joined book fusion, please do it tonight.",
        context: "", excludedNames: [])
    print("    English, no tell     model asked \(englishModel.ran ? "yes" : "NO - the guard is too tight")")
    ok = ok && englishModel.ran

    print("")
    return ok
}

/// Rules that decide whether a phrase is worth anything, checked directly.
/// Cheaper and more precise than reaching them through a whole resolution.
func runRulesBench() -> Bool {
    print("  quotation rule")
    var ok = true
    let cases: [(text: String, isQuote: Bool, why: String)] = [
        ("there is a very famous quote from that speech. Kennedy. Ask not what your country can do for you.",
         true, "recitation cue in the lead-in"),
        ("Hello, how is everyone today?",
         false, "a greeting, which went to Wikiquote in the 22-29 class"),
        ("As a woman like that was really into me.",
         false, "conversation, which went to Wikiquote in the 03-sep class"),
        ("and as he said, the only thing we have to fear is fear itself",
         true, "as he said"),
        ("Oh my God.",
         false, "an exclamation")
    ]
    for test in cases {
        let got = HeuristicDetector.hasRecitationCue(test.text)
        let pass = got == test.isQuote
        ok = ok && pass
        print("    \(pass ? "ok   " : "FAIL ") quotation=\(got ? "yes" : "no ")  \(test.why)")
    }
    print("")
    return ok
}
