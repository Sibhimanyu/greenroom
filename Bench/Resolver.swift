//
//  Resolver.swift
//  PrompterBench
//
//  Phase 2 of docs/prompter-search-improvement-plan.md: score what the resolver
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
struct DelayedTransport: PrompterTransport {
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
    /// The card's expected title, or nil when the case expects a search link.
    let expectTitle: String?
    let expectSource: PrompterCard.Source
}

func resolverCases() -> [ResolverCase] {
    [
        ResolverCase(
            id: "thing-prefers-its-own-site",
            mention: Mention(kind: .thing, query: "haiku deck", confidence: 0.8),
            replies: [
                "https://haikudeck.com": .init(body: Recorded.homepage(title: "Haiku Deck")),
                Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                    title: "Haiku", key: "Haiku", description: "Japanese poetic form"))
            ],
            expectTitle: "Haiku Deck",
            expectSource: .officialSite),

        ResolverCase(
            id: "thing-parked-domain-rejected",
            mention: Mention(kind: .thing, query: "scarves", confidence: 0.8),
            replies: [
                // What a squatted domain actually answers with.
                "https://scarves.com": .init(body: Recorded.homepage(title: "Just a moment...")),
                Recorded.wikipediaSearch: .init(status: 404, body: "{}")
            ],
            expectTitle: nil,
            expectSource: .search),

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
        if let expected = scenario.expectTitle {
            titleOK = card?.title == expected
        } else {
            titleOK = card?.source == .search
        }
        let sourceOK = card?.source == scenario.expectSource

        if titleOK && sourceOK {
            passed += 1
            if verbose {
                print("  ok    \(pad(scenario.id, 32)) \(card?.source.label ?? "-")  \(card?.title ?? "-")")
            }
        } else {
            failures.append("  FAIL  \(pad(scenario.id, 32)) got \(card?.source.label ?? "no card")"
                + " \u{201C}\(card?.title ?? "-")\u{201D}, wanted \(scenario.expectSource.label)"
                + (scenario.expectTitle.map { " \u{201C}\($0)\u{201D}" } ?? " search link"))
        }
    }

    print("  retrieval    \(passed)/\(cases.count) cases pick the intended card")
    for line in failures { print(line) }
    print("")

    // MARK: The concurrency assertion

    let leg = 0.30
    let replies: [String: RecordedTransport.Reply] = [
        "https://haikudeck.com": .init(body: Recorded.homepage(title: "Haiku Deck")),
        Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
            title: "Haiku Deck", key: "Haiku_Deck", description: "Presentation software"))
    ]
    let transport = DelayedTransport(replies: replies, delays: [
        "https://haikudeck.com": leg,
        Recorded.wikipediaSearch: leg
    ])
    let resolver = LinkResolver(transport: transport)
    await resolver.configure(.init(sessionCap: 100, lookupsPerMinute: 100))

    let started = Date()
    _ = await resolver.resolve(Mention(kind: .thing, query: "haiku deck", confidence: 0.8))
    let elapsed = Date().timeIntervalSince(started)

    // Sequential would be 2 x leg. Concurrent is one leg plus overhead. The
    // threshold sits halfway between, so neither machine noise nor a fast run
    // can make a sequential implementation look concurrent.
    let sequential = leg * 2
    let threshold = leg * 1.5
    let concurrent = elapsed < threshold
    print("  site + wikipedia, \(Int(leg * 1000)) ms each")
    print(String(format: "    sequential would be %.0f ms, measured %.0f ms  %@",
                 sequential * 1000, elapsed * 1000, concurrent ? "CONCURRENT" : "SEQUENTIAL - REGRESSION"))
    print("")

    // MARK: The fast-path assertion
    //
    // A site that will answer eventually, and a Wikipedia card already in hand.
    // The teacher should get the Wikipedia card at the 1.5 s deadline rather
    // than waiting out the site.

    let slowSite = DelayedTransport(
        replies: [
            "https://slowproduct.com": .init(body: Recorded.homepage(title: "Slow Product")),
            Recorded.wikipediaSearch: .init(body: Recorded.wikipediaPage(
                title: "Slow Product", key: "Slow_Product", description: "A thing"))
        ],
        delays: ["https://slowproduct.com": 5.0, Recorded.wikipediaSearch: 0.05])
    let fastPathResolver = LinkResolver(transport: slowSite)
    await fastPathResolver.configure(.init(sessionCap: 100, lookupsPerMinute: 100))

    let fastStarted = Date()
    let fastResult = await fastPathResolver.resolve(
        Mention(kind: .thing, query: "slow product", confidence: 0.8))
    let fastElapsed = Date().timeIntervalSince(fastStarted)
    let card = fastResult.cards.first
    // Under 2 s means the deadline fired; the card must still be the real
    // Wikipedia answer, not the picture-search consolation prize.
    let servedInTime = fastElapsed < 2.0
    let servedTheFallback = card?.source == .wikipedia
    let fastPathOK = servedInTime && servedTheFallback

    print("  slow site (5 s) with a wikipedia card ready")
    print(String(format: "    waited %.2f s, served %@  %@",
                 fastElapsed,
                 card?.source.label ?? "nothing",
                 fastPathOK ? "FAST PATH" : "WAITED FOR THE SLOW SOURCE"))
    print("")

    // And the other half of the policy: with nothing else to show, the site is
    // worth waiting for. Cutting it short would trade a real answer for a
    // search link.
    let noFallback = DelayedTransport(
        replies: [
            "https://patientproduct.com": .init(body: Recorded.homepage(title: "Patient Product")),
            Recorded.wikipediaSearch: .init(status: 404, body: "{}")
        ],
        delays: ["https://patientproduct.com": 2.2])
    let patientResolver = LinkResolver(transport: noFallback)
    await patientResolver.configure(.init(sessionCap: 100, lookupsPerMinute: 100))
    let patient = await patientResolver.resolve(
        Mention(kind: .thing, query: "patient product", confidence: 0.8))
    let waitedItOut = patient.cards.first?.source == .officialSite

    print("  slow site (2.2 s) with nothing else to offer")
    print("    served \(patient.cards.first?.source.label ?? "nothing")  "
        + (waitedItOut ? "WAITED, CORRECTLY" : "GAVE UP TOO EARLY"))
    print("")

    let ok = failures.isEmpty && concurrent && fastPathOK && waitedItOut
    return ok
}
