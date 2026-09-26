//
//  LinkResolver.swift
//  Greenroom
//
//  Turns a mention into a card, which means this is the one file in Cues
//  that talks to the internet - and the only place any word derived from the
//  teacher's speech leaves the Mac. What leaves is the query string, over
//  HTTPS, to a fixed list of hosts, with a User-Agent that says who is asking.
//  Every request is reported back to the caller so the status log can name
//  it; nothing is sent quietly.
//
//  The hosts, and why each:
//    - Google Books (no key) then Open Library: covers and a canonical page
//      for a book. Books get two hosts because a picture-book title often
//      misses on one.
//    - Wikipedia's title search: topics, people, places. One request gives
//      title, one-line description, thumbnail and page.
//    - YouTube Data API search.list, only when a Google account is connected
//      and the teacher left video search on; otherwise a plain YouTube search
//      link, which sends nothing until it is clicked.
//
//  Per-session caps, dedupe by normalised query, a per-host back-off after
//  three consecutive failures, and at most two requests in flight. A session
//  of fifty minutes should cost a few dozen small GETs, not a stream.
//
import AppKit
import CoreServices
import Foundation

actor LinkResolver {

    /// What one mention became. `sentTo` names the hosts that received the
    /// query, in the words the status log uses.
    struct Resolution {
        var cards: [CueCard] = []
        var sentTo: [String] = []
        /// Things worth one log line each: "no result (Wikipedia)".
        var notes: [String] = []
        /// True when the only card is a search link, so nothing was sent.
        var searchLinkOnly = false
        var skipped = false
        /// Held back by the per-minute brake, not refused: worth asking again.
        var heldBack = false
        /// Pictures to fetch for these cards, by card id - NOT fetched yet.
        ///
        /// A card used to wait for its own thumbnail before it could be shown,
        /// which put a second round trip in front of a link the teacher could
        /// already have clicked. The picture is decoration; the link is the
        /// product. The caller shows the card and fills the picture in when it
        /// arrives. See CuesController.loadThumbnails.
        var thumbnails: [UUID: URL] = [:]
    }

    /// One host's answer: cards, or the note the status log gets instead.
    enum Lookup {
        case success([CueCard])
        case failure(String)
    }

    struct Configuration {
        /// Lookups allowed in one session. A class is capped tight (30); the
        /// bench raises it, because seeing everything is the point there.
        var sessionCap = 30
        /// A ceiling on how fast lookups may leave, whatever the detector
        /// offers. Quality filters judge; this one simply refuses to send
        /// more than this many in any sixty seconds, so a talkative stretch
        /// cannot flood the network.
        var lookupsPerMinute = 6
        var videoSearchEnabled = true
        /// Nil when no Google account is connected: video mentions become
        /// search links.
        var youtubeToken: (() async throws -> String)?
    }

    /// Descriptive, fixed, and the same on every request. A site owner
    /// reading their logs should be able to tell what this is.
    static let userAgent = "Greenroom/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (macOS; Cues; +https://sibhimanyu.github.io/greenroom/how-it-works.html)"

    private let transport: CuesTransport
    private var configuration = Configuration()

    private var resolvedKeys: Set<String> = []
    private var cache: [String: Resolution] = [:]
    private var counts: [CueCard.Source: Int] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var backoffUntil: [String: Date] = [:]
    private var inFlight = 0
    private var recentLookups: [Date] = []
    /// Per-source timing, so where a class's waiting actually went is a fact
    /// rather than a guess.
    ///
    /// Deliberately NOT wired into source selection yet. The plan's next step
    /// is to prefer fast reliable sources per kind, and there is no evidence
    /// yet for what that ordering should be - inventing one from a hunch is
    /// how the eight-letter word filter happened. This collects the evidence
    /// first; the policy comes after a few real classes.
    private var timings: [CueCard.Source: [Double]] = [:]
    private var failures: [CueCard.Source: Int] = [:]
    private(set) var totalResolved = 0
    private var reportedSessionCap = false
    /// True once YouTube said the quota is gone for the day, so every further
    /// video mention becomes a search link without asking again.
    private var youtubeQuotaExhausted = false

    /// Per-session ceilings, per source.
    /// Per-source request ceilings. Runaway guards, not budgets: a class should
    /// never reach one.
    ///
    /// Wikipedia was 60, and the 7 Sep class spent all 60 before halfway - so
    /// its genuinely good later terms ("prefrontal cortex", "Generative AI")
    /// could not reach the encyclopedia at all and fell through to a picture
    /// search. Worse, `allowed` said nothing when it stood a source down, so
    /// the feature quietly got worse mid-lesson with no line in the log.
    ///
    /// YouTube stays at 20: that one is a real external quota shared with
    /// uploads, and raising it would spend the teacher's own allowance.
    /// Google Books refusals this session. See resolveBook.
    private var googleBooksRefusals = 0
    private let caps: [CueCard.Source: Int] = [.googleBooks: 200, .openLibrary: 200, .wikipedia: 400, .wikiquote: 100, .youtube: 20, .search: 400, .dictionary: 400, .images: 400]
    private var sessionCap: Int { configuration.sessionCap }
    private let maxInFlight = 2

    /// The transport is injectable so the bench can replay recorded answers.
    /// See CuesTransport.
    init(transport: CuesTransport? = nil) {
        self.transport = transport ?? URLSessionTransport(userAgent: Self.userAgent)
    }

    func configure(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Forgets the session's dedupe set and caps. Called at session start.
    func reset() {
        googleBooksRefusals = 0
        resolvedKeys.removeAll()
        cache.removeAll()
        counts.removeAll()
        consecutiveFailures.removeAll()
        backoffUntil.removeAll()
        pendingThumbnails.removeAll()
        timings.removeAll()
        failures.removeAll()
        totalResolved = 0
        reportedSessionCap = false
        reportedCeilings = []
        ceilingNotes = []
        youtubeQuotaExhausted = false
    }

    var youtubeQuotaIsExhausted: Bool { youtubeQuotaExhausted }

    /// One line naming each source used, how many times, its median, and how
    /// many of those came back as nothing. Empty when nothing was looked up.
    func timingSummary() -> String {
        let used = timings.filter { !$0.value.isEmpty }
        guard !used.isEmpty else { return "" }
        let parts = used.keys.sorted { $0.label < $1.label }.map { source -> String in
            let samples = used[source]!.sorted()
            let median = samples[samples.count / 2]
            let failed = failures[source, default: 0]
            return "\(source.label) \(samples.count)"
                + String(format: " (median %.0f ms", median * 1000)
                + (failed > 0 ? ", \(failed) failed)" : ")")
        }
        return parts.joined(separator: ", ")
    }

    private func note(_ source: CueCard.Source, seconds: Double, failed: Bool) {
        timings[source, default: []].append(seconds)
        if failed { failures[source, default: 0] += 1 }
    }

    // MARK: Resolve

    func resolve(_ mention: Mention) async -> Resolution {
        guard !mention.normalizedKey.isEmpty else { return Resolution(skipped: true) }
        // Kind and name, not name alone. "The book, Adobe Illustrator" after a
        // card for the software is a new request; keyed on the name it was
        // answered from the cache with the software.
        let key = mention.kind.rawValue + ":" + mention.normalizedKey
        if let cached = cache[key] { return Resolution(cards: cached.cards, skipped: true) }
        guard !resolvedKeys.contains(key) else { return Resolution(skipped: true) }
        guard totalResolved < sessionCap else {
            // Said once. The 7 Sep class wrote this same line forty-three times.
            let notes = reportedSessionCap ? []
                : ["session limit of \(sessionCap) links reached \u{2014} no more cards this class"]
            reportedSessionCap = true
            return Resolution(notes: notes, skipped: true)
        }
        // The per-minute brake, checked before anything is sent.
        let now = Date()
        recentLookups.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentLookups.count < configuration.lookupsPerMinute else {
            var held = Resolution(notes: ["holding back \u{201C}\(mention.query)\u{201D} \u{2014} \(configuration.lookupsPerMinute) lookups a minute is the ceiling; it goes when there is room"], skipped: true)
            held.heldBack = true
            return held
        }
        recentLookups.append(now)
        resolvedKeys.insert(key)

        // Two at a time. A burst of mentions waits its turn rather than
        // opening six sockets.
        while inFlight >= maxInFlight {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        inFlight += 1
        defer { inFlight -= 1 }

        var resolution: Resolution
        switch mention.kind {
        case .book: resolution = await resolveBook(mention)
        case .video: resolution = await resolveVideo(mention)
        case .topic, .person, .place:
            resolution = await encyclopediaEntry(searching: mention.searchQuery, fallingBackTo: mention.query,
                                                 confidence: mention.confidence)
        case .thing: resolution = await resolveThing(mention)
        case .quote: resolution = await resolveQuote(mention)
        case .word: resolution = resolveWord(mention)
        }
        if !resolution.cards.isEmpty {
            totalResolved += 1
            cache[key] = resolution
        }
        // Carry any ceiling notice out to the status log. Cached before this
        // point on purpose: the notice is about this class, not this query, and
        // must not be replayed from the cache on a later repeat.
        if !ceilingNotes.isEmpty {
            resolution.notes.append(contentsOf: ceilingNotes)
            ceilingNotes = []
        }
        return resolution
    }

    // MARK: Books

    private func resolveBook(_ mention: Mention) async -> Resolution {
        var resolution = Resolution()
        var hosts: [String] = []

        // Both at once, not one after the other. Google Books refuses keyless
        // callers routinely (HTTP 429), and waiting for that refusal before
        // asking Open Library put ~2.5 s in front of every book card; the mega
        // test measured 4.2 s for "the book called Wonder". Google's answer is
        // still preferred when it has one - it has the better covers - and
        // after it has refused twice this session it is not asked again.
        let askGoogle = googleBooksRefusals < 2 && allowed(.googleBooks, host: "googleapis.com")
        let askOpenLibrary = allowed(.openLibrary, host: "openlibrary.org")
        if askGoogle { hosts.append("Google Books") }
        if askOpenLibrary { hosts.append("Open Library") }
        async let fromGoogle: Lookup? = askGoogle ? googleBooks(mention.searchQuery) : nil
        async let fromOpenLibrary: Lookup? = askOpenLibrary ? openLibrary(mention.searchQuery) : nil
        let google = await fromGoogle
        let library = await fromOpenLibrary

        func books(_ cards: [CueCard]) -> [CueCard] {
            cards.map { card in
                var copy = card
                copy.kind = .book
                copy.query = mention.query
                return copy
            }
        }
        if case .success(let cards)? = google, !cards.isEmpty {
            resolution.cards = books(cards)
        } else if case .success(let cards)? = library, !cards.isEmpty {
            resolution.cards = books(cards)
            if case .failure(let note)? = google {
                resolution.notes.append("Google Books did not answer (\(note.contains("429") ? "HTTP 429" : "error")); Open Library did")
            }
        } else {
            if case .failure(let note)? = google { resolution.notes.append(note) }
            if case .failure(let note)? = library { resolution.notes.append(note) }
        }
        if case .failure(let note)? = google, note.contains("429") || note.contains("403") {
            googleBooksRefusals += 1
            if googleBooksRefusals == 2 {
                resolution.notes.append("Google Books refused twice \u{2014} books come from Open Library for the rest of this class")
            }
        }
        resolution.sentTo = hosts
        if resolution.cards.isEmpty, resolution.notes.isEmpty, !hosts.isEmpty {
            resolution.notes.append("no result for \u{201C}\(mention.query)\u{201D} (\(hosts.joined(separator: " and ")))")
        }
        // "Have you heard of the book, X?" is a direct request. When neither
        // catalogue knows the title - often because the transcriber misheard
        // it - the card is a book search the teacher can open, not silence.
        if resolution.cards.isEmpty, mention.category != nil {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "tbm", value: "bks"),
                                     URLQueryItem(name: "q", value: mention.query)]
            resolution.cards = [CueCard(kind: .book, query: mention.query, title: mention.query,
                                        subtitle: "Search for this book \u{00B7} nothing sent until you open it",
                                        source: .search, url: components.url!)]
            resolution.searchLinkOnly = true
        }
        takeThumbnails(&resolution)
        return resolution
    }

    private func googleBooks(_ query: String) async -> Lookup {
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "intitle:\(query)"),
            URLQueryItem(name: "maxResults", value: "3"),
            URLQueryItem(name: "printType", value: "books"),
            URLQueryItem(name: "fields", value: "items(id,volumeInfo(title,authors,imageLinks/thumbnail,canonicalVolumeLink,infoLink))")
        ]
        return await fetchJSON(components.url!, source: .googleBooks, host: "googleapis.com") { json in
            let items = json["items"] as? [[String: Any]] ?? []
            return items.compactMap { item -> CueCard? in
                guard let info = item["volumeInfo"] as? [String: Any],
                      let title = info["title"] as? String,
                      let id = item["id"] as? String,
                      Self.titleMatches(title, query: query) else { return nil }
                let link = (info["canonicalVolumeLink"] as? String) ?? (info["infoLink"] as? String)
                    ?? "https://books.google.com/books?id=\(id)"
                guard let url = Self.https(link) else { return nil }
                let authors = (info["authors"] as? [String] ?? []).joined(separator: ", ")
                var card = CueCard(kind: .book, query: query, title: title,
                                        subtitle: authors.isEmpty ? "Google Books" : authors,
                                        source: .googleBooks, url: url)
                if let thumb = (info["imageLinks"] as? [String: Any])?["thumbnail"] as? String,
                   let thumbURL = Self.https(thumb) {
                    card.thumbnail = nil
                    pendingThumbnails[card.id] = thumbURL
                }
                return card
            }
        }
    }

    private func openLibrary(_ query: String) async -> Lookup {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "title", value: query),
            URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i")
        ]
        return await fetchJSON(components.url!, source: .openLibrary, host: "openlibrary.org") { json in
            let docs = json["docs"] as? [[String: Any]] ?? []
            return docs.compactMap { doc -> CueCard? in
                guard let title = doc["title"] as? String, let key = doc["key"] as? String,
                      Self.titleMatches(title, query: query),
                      let url = URL(string: "https://openlibrary.org\(key)") else { return nil }
                let authors = (doc["author_name"] as? [String] ?? []).prefix(2).joined(separator: ", ")
                let card = CueCard(kind: .book, query: query, title: title,
                                        subtitle: authors.isEmpty ? "Open Library" : authors,
                                        source: .openLibrary, url: url)
                if let cover = doc["cover_i"] as? Int,
                   let coverURL = URL(string: "https://covers.openlibrary.org/b/id/\(cover)-M.jpg") {
                    pendingThumbnails[card.id] = coverURL
                }
                return card
            }
        }
    }

    /// The top result has to look like what was said. "Matilda" must not come
    /// back as "Matilda's Big Book of Tax Law" - a loose match here is where
    /// false cards come from.
    private static func titleMatches(_ title: String, query: String) -> Bool {
        let a = Set(Mention.normalize(title).split(separator: " ").map(String.init))
        let b = Set(Mention.normalize(query).split(separator: " ").map(String.init))
        guard !a.isEmpty, !b.isEmpty else { return false }
        let overlap = a.intersection(b).count
        return Double(overlap) / Double(b.count) >= 0.6
    }

    // MARK: Wikipedia

    private func resolveWikipedia(_ mention: Mention) async -> Resolution {
        var resolution = Resolution()
        guard allowed(.wikipedia, host: "wikipedia.org") else { return resolution }
        resolution.sentTo = ["Wikipedia"]
        var components = URLComponents(string: "https://en.wikipedia.org/w/rest.php/v1/search/title")!
        components.queryItems = [URLQueryItem(name: "q", value: mention.query), URLQueryItem(name: "limit", value: "3")]
        switch await fetchJSON(components.url!, source: .wikipedia, host: "wikipedia.org", parse: { json in
            let pages = (json["pages"] as? [[String: Any]] ?? []).filter { page in
                // Disambiguation pages are a list, not an answer.
                !((page["description"] as? String) ?? "").lowercased().contains("referred to by the same term")
            }
            return pages.prefix(1).compactMap { page -> CueCard? in
                guard let key = page["key"] as? String, let title = page["title"] as? String,
                      let url = URL(string: "https://en.wikipedia.org/wiki/\(key)") else { return nil }
                // The same rule resolveThing uses, which this path never had.
                //
                // TitleMatch guarded `.thing` only, so topics, people and
                // places took whatever the title search returned. A real class
                // on 6 Sep turned "Jao Maa" into the Wikipedia page for Jan
                // Mayen, an Arctic island, and served it as a topic. Three of
                // the four kinds that reach Wikipedia had no title check at all.
                guard TitleMatch.answers(title: title, said: mention.query),
                              !TitleMatch.guessedTheSense(title: title, said: mention.query) else { return nil }
                let description = (page["description"] as? String) ?? "Wikipedia"
                // Topics answer to the creative-work rule as well; books and
                // videos deliberately do not.
                if mention.kind == .topic,
                   TitleMatch.namesACreativeWork(description: description) { return nil }
                let card = CueCard(kind: mention.kind, query: mention.query, title: title,
                                        subtitle: description.prefix(1).uppercased() + description.dropFirst(),
                                        source: .wikipedia, url: url)
                if let thumb = (page["thumbnail"] as? [String: Any])?["url"] as? String {
                    let absolute = thumb.hasPrefix("//") ? "https:" + thumb : thumb
                    if let thumbURL = Self.https(absolute) { pendingThumbnails[card.id] = thumbURL }
                }
                return card
            }
        }) {
        case .success(let cards):
            resolution.cards = cards
            if cards.isEmpty { resolution.notes.append("no result for \u{201C}\(mention.query)\u{201D} (Wikipedia)") }
        case .failure(let note):
            resolution.notes.append(note)
        }
        takeThumbnails(&resolution)
        return resolution
    }

    /// The encyclopedia entry, richer query first and the bare name second.
    ///
    /// Wikipedia matches on TITLES, so the extra word cuts both ways, measured
    /// on real cases: "Tahoma" alone lands on a high school in Washington and
    /// "Tahoma font" lands on the typeface, but "E Ink technology" matches no
    /// title at all where "E Ink" is exactly right. Both run at once - the
    /// second is a cheap request and running it concurrently means a missing
    /// rich match costs no extra wait.
    private func encyclopediaEntry(searching query: String, fallingBackTo name: String,
                                   confidence: Double) async -> Resolution {
        guard Mention.normalize(query) != Mention.normalize(name) else {
            return await resolveWikipedia(Mention(kind: .topic, query: query, confidence: confidence))
        }
        async let richResult = resolveWikipedia(Mention(kind: .topic, query: query, confidence: confidence))
        async let bareResult = resolveWikipedia(Mention(kind: .topic, query: name, confidence: confidence))
        let rich = await richResult
        var bare = await bareResult
        guard rich.cards.isEmpty else { return rich }
        bare.notes = rich.notes + bare.notes
        return bare
    }

    // MARK: Things - tools, products, companies

    /// Wikipedia, or nothing.
    ///
    /// This used to do two more things, and one recorded 43-minute class
    /// retired both.
    ///
    /// It guessed an official site by deleting the spaces from the query and
    /// fetching `<that>.com`. That ran 54 times of the class's 80-lookup
    /// budget and failed 41 of them, and the nine that answered were a
    /// packaging firm for "Vijay Shri", a Utah gym for "upper limit" and
    /// Whitepages for "phone number". It was a domain-squatter detector
    /// wearing two thirds of the lookup budget.
    ///
    /// When everything failed it offered a Bing image search instead. That
    /// card cannot be wrong, so it became the place every bad mention landed:
    /// 54 of the 82 links that class were "Pictures of ..." over scraps like
    /// "this part" and "Other number". Worse, the junk exhausted Wikipedia's
    /// own 60-lookup cap, so the genuinely good late-class terms -
    /// "prefrontal cortex", "Generative AI", "virtual memory" - could no
    /// longer reach Wikipedia and got picture searches too, when all three
    /// have exact articles. Suppressing the noise is what gets them their
    /// real entry back; a card that is never wrong and rarely useful is not
    /// worth a slot the right answer needed.
    private func resolveThing(_ mention: Mention) async -> Resolution {
        var resolution = await thingFromWikipedia(mention)
        // The speaker said outright what this is ("the brand called imago")
        // and no page fits it. Silence would be the detector ignoring a
        // direct request, so the card is a search the teacher can open -
        // nothing is sent until they do.
        if resolution.cards.isEmpty, let category = mention.category {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: "\(mention.query) \(category)")]
            resolution.cards = [CueCard(kind: .thing, query: mention.query,
                                        title: mention.query,
                                        subtitle: "Search for this \(category) \u{00B7} nothing sent until you open it",
                                        source: .search, url: components.url!)]
            resolution.searchLinkOnly = true
        }
        return resolution
    }

    /// Whether a page's one-line description is the kind of thing the speaker
    /// said it was. Words, not a model: a brand's page says "company",
    /// "brand" or "manufacturer"; the insect stage says none of them.
    static func description(_ description: String, fits category: String) -> Bool {
        let fits: [String: [String]] = [
            "brand": ["brand", "company", "manufacturer", "corporation", "business", "retailer", "label", "maker", "firm"],
            "company": ["company", "corporation", "business", "manufacturer", "brand", "firm", "retailer", "conglomerate", "startup"],
            "startup": ["company", "startup", "business", "firm"],
            "app": ["app", "application", "software", "service", "platform", "website", "program", "company"],
            "application": ["app", "application", "software", "service", "platform", "program"],
            "tool": ["tool", "software", "app", "application", "service", "platform", "program", "website", "device", "instrument"],
            "software": ["software", "application", "program", "suite", "editor", "tool", "system", "platform"],
            "program": ["software", "program", "application", "tool"],
            "programme": ["software", "programme", "program", "application", "series", "show"],
            "website": ["website", "site", "service", "platform", "online", "company", "portal"],
            "site": ["website", "site", "service", "platform", "online"],
            "platform": ["platform", "service", "software", "website", "company", "online"],
            "service": ["service", "platform", "company", "website", "software", "app"],
            "product": ["product", "brand", "line", "device", "software", "company"],
            "device": ["device", "product", "line", "computer", "phone", "reader", "tablet", "model", "brand"],
            "gadget": ["device", "product", "gadget", "line"],
            "phone": ["phone", "smartphone", "device", "line", "model"],
            "laptop": ["laptop", "computer", "notebook", "line", "model"],
            "camera": ["camera", "device", "line", "model", "brand"],
            "robot": ["robot", "device", "machine"],
            "car": ["car", "automobile", "vehicle", "model", "manufacturer"],
            "game": ["game"],
            "font": ["typeface", "font"],
            "typeface": ["typeface", "font"],
            "language": ["language"],
            "framework": ["framework", "library", "software"],
            "library": ["library", "software", "framework"],
            "magazine": ["magazine", "publication", "periodical", "journal"],
            "newspaper": ["newspaper", "publication", "daily"],
            "blog": ["blog", "website", "publication"],
            "band": ["band", "group", "duo", "trio", "musician"],
            "extension": ["extension", "software", "add-on", "plugin"],
            "plugin": ["plugin", "plug-in", "extension", "software", "add-on"],
            "plug-in": ["plugin", "plug-in", "extension", "software", "add-on"],
            "chatbot": ["chatbot", "assistant", "language model", "software", "ai"],
            "model": ["model", "language model", "ai", "software", "line", "product"]
        ]
        guard let words = fits[category] else { return true }
        let lowered = description.lowercased()
        return words.contains { lowered.range(of: "\\b\($0)", options: .regularExpression) != nil }
    }

    /// How long a preferred source may keep the teacher waiting once a valid
    /// fallback is already in hand.
    private static let fastPathSeconds: Double = 1.5

    private enum Race {
        case finished(CueCard?)
        /// This leg was cancelled because the other one won.
        case lost
    }

    /// The task's value, or nil if it has not produced one within `seconds`.
    ///
    /// "No site" and "the site took too long" are the same thing to a caller
    /// that has an alternative ready, so both come back as nil rather than
    /// being distinguished for no one.
    ///
    /// The deadline leg cancels `task` itself rather than relying on
    /// `group.cancelAll()`. That distinction is the whole function: cancelling
    /// the group cancels the child that is AWAITING the task, not the task,
    /// and `Task.value` on a non-throwing task keeps waiting through its own
    /// cancellation. withTaskGroup then cannot return until every child has
    /// drained, so the first version of this waited out the full five seconds
    /// it was written to avoid - the bench measured 5.11 s and said so.
    private func result(of task: Task<CueCard?, Never>, within seconds: Double) async -> CueCard? {
        let timer = Task { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        return await withTaskGroup(of: Race.self) { group in
            group.addTask { .finished(await task.value) }
            group.addTask {
                do { try await timer.value } catch { return .lost }
                task.cancel()
                return .finished(nil)
            }
            var winner: CueCard?
            while let outcome = await group.next() {
                if case .finished(let card) = outcome {
                    winner = card
                    break
                }
            }
            // Both cancels have to happen HERE, before the closure returns:
            // withTaskGroup drains its children on the way out, so a timer
            // cancelled in a `defer` outside is cancelled too late and the
            // fast site pays the full deadline anyway. The bench caught that
            // too - the concurrent case jumped from 315 ms to 1862 ms.
            timer.cancel()
            group.cancelAll()
            return winner
        }
    }

    /// The encyclopedia leg of a named thing, on its own so it can be started
    /// alongside the site check rather than after it.
    private func thingFromWikipedia(_ mention: Mention) async -> Resolution {
        var resolution = Resolution()
        if allowed(.wikipedia, host: "wikipedia.org") {
            resolution.sentTo = ["Wikipedia"]
            // Title search, then a strict check: every word of the page's title
            // must have been said. A look-alike title ("Haiku d'Etat" for
            // "haiku deck", "AdventHealth University" for "Advent University")
            // fails it; a broader page ("Amazon Kindle" for "Kindle Paperwhite")
            // fails it too and falls through to the picture search, which is
            // what the teacher did for that one himself. Tested against the
            // full-text endpoint as well: worse, it matched excerpts.
            var components = URLComponents(string: "https://en.wikipedia.org/w/rest.php/v1/search/title")!
            components.queryItems = [URLQueryItem(name: "q", value: mention.query), URLQueryItem(name: "limit", value: "3")]
            switch await fetchJSON(components.url!, source: .wikipedia, host: "wikipedia.org", parse: { json in
                let pages = json["pages"] as? [[String: Any]] ?? []
                return pages.compactMap { page -> CueCard? in
                    guard let key = page["key"] as? String, let title = page["title"] as? String,
                          let url = URL(string: "https://en.wikipedia.org/wiki/\(key)") else { return nil }
                    let description = (page["description"] as? String) ?? ""
                    // Disambiguation pages are a list, not an answer.
                    guard !description.lowercased().contains("referred to by the same term"),
                          !description.lowercased().hasPrefix("disambiguation") else { return nil }
                    // A named thing is not a 1904 film that happens to share
                    // the phrase. See TitleMatch.namesACreativeWork.
                    guard !TitleMatch.namesACreativeWork(description: description) else { return nil }
                    // One shared rule, in TitleMatch. The check that used to
                    // live here asked only that every word of the TITLE had
                    // been said, which let a title that is a subset of the
                    // phrase win: "haiku deck" matched the page "Haiku", the
                    // poetic form. Everything said has to be answered now.
                    guard TitleMatch.answers(title: title, said: mention.query),
                              !TitleMatch.guessedTheSense(title: title, said: mention.query) else { return nil }
                    // Said to be a brand, an app, a font: the page has to be one.
                    if let category = mention.category,
                       !Self.description(description, fits: category) { return nil }
                    let card = CueCard(kind: .thing, query: mention.query, title: title,
                                            subtitle: description.isEmpty ? "Wikipedia" : description.prefix(1).uppercased() + description.dropFirst(),
                                            source: .wikipedia, url: url)
                    if let thumb = (page["thumbnail"] as? [String: Any])?["url"] as? String {
                        let absolute = thumb.hasPrefix("//") ? "https:" + thumb : thumb
                        if let thumbURL = Self.https(absolute) { pendingThumbnails[card.id] = thumbURL }
                    }
                    return card
                }
            }) {
            case .success(let cards):
                resolution.cards = Array(cards.prefix(1))
            case .failure(let note):
                resolution.notes.append(note)
            }
            takeThumbnails(&resolution)
        }
        return resolution
    }

    // MARK: Quotations

    /// Wikiquote's search, with the spoken line as the query. The page it
    /// finds is the speaker (or the work), which is what the teacher wants
    /// to name; the snippet carries the line as written.
    private func resolveQuote(_ mention: Mention) async -> Resolution {
        var resolution = Resolution()
        guard allowed(.wikiquote, host: "wikiquote.org") else { return resolution }
        resolution.sentTo = ["Wikiquote"]
        var components = URLComponents(string: "https://en.wikiquote.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: mention.query), URLQueryItem(name: "srlimit", value: "3"),
            URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "utf8", value: "1")
        ]
        switch await fetchJSON(components.url!, source: .wikiquote, host: "wikiquote.org", parse: { json in
            let results = ((json["query"] as? [String: Any])?["search"] as? [[String: Any]]) ?? []
            return results.prefix(1).compactMap { result -> CueCard? in
                guard let title = result["title"] as? String,
                      let url = URL(string: "https://en.wikiquote.org/wiki/" + (title.replacingOccurrences(of: " ", with: "_")
                        .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)) else { return nil }
                let snippet = Self.stripHTML((result["snippet"] as? String) ?? "")
                return CueCard(kind: .quote, query: mention.query, title: title,
                                    subtitle: snippet.isEmpty ? "Wikiquote" : "\u{201C}\(snippet)\u{201D}",
                                    source: .wikiquote, url: url)
            }
        }) {
        case .success(let cards):
            resolution.cards = cards
            if cards.isEmpty { resolution.notes.append("no result for the quotation (Wikiquote)") }
        case .failure(let note):
            resolution.notes.append(note)
        }
        if resolution.cards.isEmpty {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: "\"\(mention.query)\"")]
            resolution.cards = [CueCard(kind: .quote, query: mention.query,
                                             title: "Search for the quotation",
                                             subtitle: "\u{201C}\(mention.query)\u{201D} \u{00B7} nothing sent until you open it",
                                             source: .search, url: components.url!)]
        }
        return resolution
    }

    // MARK: Words - the Mac's own dictionary, nothing leaves

    private func resolveWord(_ mention: Mention) -> Resolution {
        var resolution = Resolution()
        let word = mention.query.lowercased()
        let range = CFRange(location: 0, length: word.utf16.count)
        guard let definition = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?,
              !definition.isEmpty else {
            resolution.notes.append("\u{201C}\(mention.query)\u{201D} is not in the Mac's dictionary (nothing sent)")
            return resolution
        }
        // The first sense only: "pabulum | ˈpabyələm | noun bland or insipid
        // intellectual matter..." - drop the headword and pronunciation.
        var text = definition
        if let bar = text.range(of: "| ", options: .backwards, range: text.startIndex..<(text.index(text.startIndex, offsetBy: min(60, text.count)))) {
            text = String(text[bar.upperBound...])
        }
        let firstSense = text.components(separatedBy: CharacterSet(charactersIn: ".;\n")).first ?? text
        resolution.cards = [CueCard(kind: .word, query: mention.query, title: mention.query.capitalized,
                                         subtitle: firstSense.trimmingCharacters(in: .whitespaces),
                                         source: .dictionary,
                                         url: URL(string: "dict://\(word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word)")!)]
        resolution.notes.append("looked up \u{201C}\(mention.query)\u{201D} in the Mac\u{2019}s dictionary (nothing sent)")
        return resolution
    }

    private static func stripHTML(_ text: String) -> String {
        decodeHTML(text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Video

    private func resolveVideo(_ mention: Mention) async -> Resolution {
        var resolution = Resolution()
        let searchCard = Self.youtubeSearchCard(for: mention)

        guard configuration.videoSearchEnabled, let token = configuration.youtubeToken,
              !youtubeQuotaExhausted, allowed(.youtube, host: "youtube.googleapis.com") else {
            resolution.cards = [searchCard]
            resolution.searchLinkOnly = true
            return resolution
        }
        resolution.sentTo = ["YouTube"]
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")!
        components.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "maxResults", value: "3"),
            URLQueryItem(name: "safeSearch", value: "strict"),
            URLQueryItem(name: "q", value: mention.query)
        ]
        let bearer: String
        do { bearer = try await token() } catch {
            resolution.cards = [searchCard]
            resolution.searchLinkOnly = true
            resolution.sentTo = []
            resolution.notes.append("YouTube sign-in unavailable (\(error.localizedDescription)) \u{2014} video cards link to YouTube search instead")
            return resolution
        }
        switch await fetchJSON(components.url!, source: .youtube, host: "youtube.googleapis.com",
                               headers: ["Authorization": "Bearer \(bearer)"], parse: { json in
            let items = json["items"] as? [[String: Any]] ?? []
            return items.compactMap { item -> CueCard? in
                guard let idBlock = item["id"] as? [String: Any], let videoID = idBlock["videoId"] as? String,
                      let snippet = item["snippet"] as? [String: Any],
                      let title = snippet["title"] as? String,
                      let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
                let channel = (snippet["channelTitle"] as? String) ?? "YouTube"
                let card = CueCard(kind: .video, query: mention.query, title: Self.decodeHTML(title),
                                        subtitle: channel, source: .youtube, url: url)
                if let thumbs = snippet["thumbnails"] as? [String: Any],
                   let medium = (thumbs["medium"] ?? thumbs["default"]) as? [String: Any],
                   let thumb = medium["url"] as? String, let thumbURL = Self.https(thumb) {
                    pendingThumbnails[card.id] = thumbURL
                }
                return card
            }
        }) {
        case .success(let cards):
            resolution.cards = cards.isEmpty ? [searchCard] : cards
            resolution.searchLinkOnly = cards.isEmpty
        case .failure(let note):
            // 403 quotaExceeded / 429: switch to search links for the rest of
            // the day and say so once.
            if note.contains("HTTP 403") || note.contains("HTTP 429") {
                youtubeQuotaExhausted = true
                resolution.notes.append("YouTube search quota is used up for today \u{2014} video cards link to YouTube search instead")
            } else {
                resolution.notes.append(note)
            }
            resolution.cards = [searchCard]
            resolution.searchLinkOnly = true
        }
        takeThumbnails(&resolution)
        return resolution
    }

    private static func youtubeSearchCard(for mention: Mention) -> CueCard {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: mention.query)]
        return CueCard(kind: .video, query: mention.query,
                            title: "Search YouTube for \u{201C}\(mention.query)\u{201D}",
                            subtitle: "Nothing sent until you open it", source: .search, url: components.url!)
    }

    // MARK: Fetch

    private var pendingThumbnails: [UUID: URL] = [:]

    /// Hands the pending picture URLs to the caller instead of fetching them.
    /// Synchronous on purpose: nothing here touches the network.
    private func takeThumbnails(_ resolution: inout Resolution) {
        for card in resolution.cards {
            guard let url = pendingThumbnails.removeValue(forKey: card.id) else { continue }
            resolution.thumbnails[card.id] = url
        }
        // Only this resolution's entries are taken. Clearing the whole table
        // here would be wrong: two lookups run at once (maxInFlight is 2), so
        // the leftovers may belong to the other one, still in flight. What is
        // genuinely stranded - cards that lost a ranking round - is a handful
        // of URLs per session and goes in reset().
    }

    /// Cap and back-off check for one source. A host that failed three times
    /// running is left alone for five minutes.
    /// Sources whose ceiling has already been reported this class.
    private var reportedCeilings: Set<CueCard.Source> = []
    /// Ceiling notices waiting to be attached to the next resolution.
    private var ceilingNotes: [String] = []

    private func allowed(_ source: CueCard.Source, host: String) -> Bool {
        if let until = backoffUntil[host], until > Date() { return false }
        guard counts[source, default: 0] < caps[source, default: 0] else {
            // Once, not once per mention. A silent stand-down is how the 7 Sep
            // class lost Wikipedia for its whole second half without a word.
            if reportedCeilings.insert(source).inserted {
                ceilingNotes.append("\(source.label) has answered \(caps[source, default: 0]) times this class \u{2014} no more from that source")
            }
            return false
        }
        return true
    }

    private func fetchJSON(_ url: URL, source: CueCard.Source, host: String,
                           headers: [String: String] = [:],
                           parse: ([String: Any]) -> [CueCard]) async -> Lookup {
        counts[source, default: 0] += 1
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let started = Date()
        do {
            let (data, response) = try await transport.data(for: request)
            let status = response.statusCode
            guard (200..<300).contains(status) else {
                note(source, seconds: Date().timeIntervalSince(started), failed: true)
                noteFailure(host)
                return .failure("lookup failed (\(source.label), HTTP \(status)) \u{2014} card skipped")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                note(source, seconds: Date().timeIntervalSince(started), failed: true)
                noteFailure(host)
                return .failure("lookup failed (\(source.label), unreadable reply) \u{2014} card skipped")
            }
            note(source, seconds: Date().timeIntervalSince(started), failed: false)
            consecutiveFailures[host] = 0
            return .success(parse(json))
        } catch {
            note(source, seconds: Date().timeIntervalSince(started), failed: true)
            noteFailure(host)
            let reason = (error as? URLError)?.code == .notConnectedToInternet ? "offline" : "network error"
            return .failure("lookup failed (\(source.label), \(reason)) \u{2014} card skipped")
        }
    }

    private func noteFailure(_ host: String) {
        consecutiveFailures[host, default: 0] += 1
        if consecutiveFailures[host, default: 0] >= 3 {
            backoffUntil[host] = Date().addingTimeInterval(300)
            consecutiveFailures[host] = 0
        }
    }

    /// Google Books hands out http:// covers; everything Cues opens or
    /// fetches is https or nothing.
    private static func https(_ string: String) -> URL? {
        var text = string
        if text.hasPrefix("http://") { text = "https://" + text.dropFirst("http://".count) }
        guard let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }

    private static func decodeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
