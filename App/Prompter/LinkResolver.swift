//
//  LinkResolver.swift
//  Greenroom
//
//  Turns a mention into a card, which means this is the one file in Prompter
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
        var cards: [PrompterCard] = []
        var sentTo: [String] = []
        /// Things worth one log line each: "no result (Wikipedia)".
        var notes: [String] = []
        /// True when the only card is a search link, so nothing was sent.
        var searchLinkOnly = false
        var skipped = false
        /// Pictures to fetch for these cards, by card id - NOT fetched yet.
        ///
        /// A card used to wait for its own thumbnail before it could be shown,
        /// which put a second round trip in front of a link the teacher could
        /// already have clicked. The picture is decoration; the link is the
        /// product. The caller shows the card and fills the picture in when it
        /// arrives. See PrompterController.loadThumbnails.
        var thumbnails: [UUID: URL] = [:]
    }

    /// One host's answer: cards, or the note the status log gets instead.
    enum Lookup {
        case success([PrompterCard])
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
    static let userAgent = "Greenroom/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (macOS; Prompter; +https://sibhimanyu.github.io/greenroom/how-it-works.html)"

    private let transport: PrompterTransport
    private var configuration = Configuration()

    private var resolvedKeys: Set<String> = []
    private var cache: [String: Resolution] = [:]
    private var counts: [PrompterCard.Source: Int] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var backoffUntil: [String: Date] = [:]
    private var inFlight = 0
    private var recentLookups: [Date] = []
    private(set) var totalResolved = 0
    /// True once YouTube said the quota is gone for the day, so every further
    /// video mention becomes a search link without asking again.
    private var youtubeQuotaExhausted = false

    /// Per-session ceilings, per source.
    private let caps: [PrompterCard.Source: Int] = [.googleBooks: 60, .openLibrary: 60, .wikipedia: 60, .wikiquote: 30, .youtube: 20, .search: 200, .dictionary: 200, .officialSite: 80, .images: 200]
    private var sessionCap: Int { configuration.sessionCap }
    private let maxInFlight = 2

    /// The transport is injectable so the bench can replay recorded answers.
    /// See PrompterTransport.
    init(transport: PrompterTransport? = nil) {
        self.transport = transport ?? URLSessionTransport(userAgent: Self.userAgent)
    }

    func configure(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Forgets the session's dedupe set and caps. Called at session start.
    func reset() {
        resolvedKeys.removeAll()
        cache.removeAll()
        counts.removeAll()
        consecutiveFailures.removeAll()
        backoffUntil.removeAll()
        pendingThumbnails.removeAll()
        totalResolved = 0
        youtubeQuotaExhausted = false
    }

    var youtubeQuotaIsExhausted: Bool { youtubeQuotaExhausted }

    // MARK: Resolve

    func resolve(_ mention: Mention) async -> Resolution {
        let key = mention.normalizedKey
        guard !key.isEmpty else { return Resolution(skipped: true) }
        if let cached = cache[key] { return Resolution(cards: cached.cards, skipped: true) }
        guard !resolvedKeys.contains(key) else { return Resolution(skipped: true) }
        guard totalResolved < sessionCap else {
            return Resolution(notes: ["session limit of \(sessionCap) lookups reached \u{2014} no more cards this class"], skipped: true)
        }
        // The per-minute brake, checked before anything is sent.
        let now = Date()
        recentLookups.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentLookups.count < configuration.lookupsPerMinute else {
            return Resolution(notes: ["holding back \u{201C}\(mention.query)\u{201D} \u{2014} \(configuration.lookupsPerMinute) lookups a minute is the ceiling"], skipped: true)
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
        return resolution
    }

    // MARK: Books

    private func resolveBook(_ mention: Mention) async -> Resolution {
        var resolution = Resolution()
        var hosts: [String] = []

        if allowed(.googleBooks, host: "googleapis.com") {
            hosts.append("Google Books")
            switch await googleBooks(mention.searchQuery) {
            case .success(let cards):
                resolution.cards = cards.map { card in
                    var copy = card
                    copy.kind = .book
                    copy.query = mention.query
                    return copy
                }
            case .failure(let note):
                resolution.notes.append(note)
            }
        }
        if resolution.cards.isEmpty, allowed(.openLibrary, host: "openlibrary.org") {
            hosts.append("Open Library")
            switch await openLibrary(mention.searchQuery) {
            case .success(let cards):
                resolution.cards = cards.map { card in
                    var copy = card
                    copy.kind = .book
                    copy.query = mention.query
                    return copy
                }
                // Google Books rate-limits keyless callers freely (HTTP 429 is
                // routine). When Open Library then delivered, the earlier
                // failure is a footnote, not a skipped card.
                if !cards.isEmpty {
                    resolution.notes = resolution.notes.map { note in
                        note.hasPrefix("lookup failed (Google Books")
                            ? "Google Books did not answer (\(note.components(separatedBy: ", ").dropFirst().first?.replacingOccurrences(of: ") \u{2014} card skipped", with: "") ?? "error")); Open Library did"
                            : note
                    }
                }
            case .failure(let note):
                resolution.notes.append(note)
            }
        }
        resolution.sentTo = hosts
        if resolution.cards.isEmpty, resolution.notes.isEmpty, !hosts.isEmpty {
            resolution.notes.append("no result for \u{201C}\(mention.query)\u{201D} (\(hosts.joined(separator: " and ")))")
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
            return items.compactMap { item -> PrompterCard? in
                guard let info = item["volumeInfo"] as? [String: Any],
                      let title = info["title"] as? String,
                      let id = item["id"] as? String,
                      Self.titleMatches(title, query: query) else { return nil }
                let link = (info["canonicalVolumeLink"] as? String) ?? (info["infoLink"] as? String)
                    ?? "https://books.google.com/books?id=\(id)"
                guard let url = Self.https(link) else { return nil }
                let authors = (info["authors"] as? [String] ?? []).joined(separator: ", ")
                var card = PrompterCard(kind: .book, query: query, title: title,
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
            return docs.compactMap { doc -> PrompterCard? in
                guard let title = doc["title"] as? String, let key = doc["key"] as? String,
                      Self.titleMatches(title, query: query),
                      let url = URL(string: "https://openlibrary.org\(key)") else { return nil }
                let authors = (doc["author_name"] as? [String] ?? []).prefix(2).joined(separator: ", ")
                let card = PrompterCard(kind: .book, query: query, title: title,
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
            return pages.prefix(1).compactMap { page -> PrompterCard? in
                guard let key = page["key"] as? String, let title = page["title"] as? String,
                      let url = URL(string: "https://en.wikipedia.org/wiki/\(key)") else { return nil }
                let description = (page["description"] as? String) ?? "Wikipedia"
                let card = PrompterCard(kind: mention.kind, query: mention.query, title: title,
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

    /// A product's own homepage, guessed from its name and then checked.
    ///
    /// "Haiku Deck" -> haikudeck.com, which is right. The check matters as much
    /// as the guess: the page must answer 200 AND its title must share a word
    /// with the name, which is what rejects parked and squatted domains
    /// (scarves.com answers with a Cloudflare interstitial titled "Just a
    /// moment...").
    ///
    /// This visits the product's own site, the same page the teacher would
    /// open. It is not a search engine and nothing is scraped.
    private func officialSite(for query: String) async -> PrompterCard? {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard words.count >= 1, words.count <= 3 else { return nil }
        let host = words.joined()
        guard host.count >= 4, host.count <= 30 else { return nil }
        guard allowed(.officialSite, host: host), let url = URL(string: "https://\(host).com") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        // Ask for a web page, not JSON. The shared session defaults to
        // "Accept: application/json" for the APIs, and a real site can answer
        // that with a 500 (bookfusion.com does), which read as "no site here".
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        // Read only as far as the title.
        //
        // All this needs is one tag, and it sits in the first kilobyte or two
        // of any page - but downloading whole homepages was the single
        // slowest thing Prompter did (eink.com: ~1.7 s of a 3.3 s lookup).
        // Stopping at </title> turns that into a fraction of a page. The 16 KB
        // ceiling bounds a page that never closes the tag. The streaming itself
        // lives in the transport, so a recorded answer can just be a string.
        guard let (html, http) = try? await transport.text(for: request,
                                                           stoppingAfter: "</title>",
                                                           byteCap: 16_000),
              http.statusCode == 200, !html.isEmpty else { return nil }

        guard let range = html.range(of: "<title[^>]*>([^<]{1,120})", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let title = Self.stripHTML(String(html[range]).replacingOccurrences(of: "<title[^>]*>", with: "", options: [.regularExpression, .caseInsensitive]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The title has to look like the thing, or this is a parked domain.
        // Compare squashed as well as word by word: "book fusion" reaches
        // bookfusion.com, whose title is the single word "BookFusion".
        let normalizedTitle = Mention.normalize(title)
        let titleWords = Set(normalizedTitle.split(separator: " ").map(String.init))
        let squashedTitle = normalizedTitle.replacingOccurrences(of: " ", with: "")
        guard words.contains(where: { titleWords.contains(String($0)) }) || squashedTitle.contains(host) else { return nil }

        return PrompterCard(kind: .thing, query: query, title: title.isEmpty ? query : title,
                            subtitle: "\(host).com \u{00B7} the site itself",
                            source: .officialSite, url: url)
    }

    // MARK: Things - tools, products, companies

    /// Wikipedia first; when it has nothing, a picture search link. The
    /// teacher's own habit for a product was an image search ("e ink
    /// kindle"), and a search link sends nothing until it is opened.
    private func resolveThing(_ mention: Mention) async -> Resolution {
        var resolution = Resolution()
        // The site itself and the encyclopedia entry really are fetched
        // together now.
        //
        // The comment here has claimed that for a while and the code did not
        // do it: `async let siteCard` was awaited on the very next line, which
        // is a sequential call with extra syntax. The site check is the slow
        // leg - a real homepage, even stopping at </title> - so Wikipedia did
        // not start until it finished, and for a product with no site of its
        // own the teacher waited for both round trips end to end.
        //
        // Both are spent every time, which the plan asks for explicitly: pick
        // the best valid card rather than the first one that arrives. The site
        // still wins when it exists, because for a named product it is what
        // the teacher actually opens (haikudeck.com, in the recording).
        async let siteCard = officialSite(for: mention.query)
        async let wikipedia = thingFromWikipedia(mention)

        let site = await siteCard
        var fromWikipedia = await wikipedia
        if let site {
            resolution.cards.append(site)
            // Keep whatever Wikipedia had to say for the log, but not its card.
            resolution.notes = fromWikipedia.notes
            resolution.sentTo = fromWikipedia.sentTo
            return resolution
        }
        resolution.notes = fromWikipedia.notes
        resolution.sentTo = fromWikipedia.sentTo
        resolution.cards = fromWikipedia.cards
        resolution.thumbnails = fromWikipedia.thumbnails
        fromWikipedia.cards = []

        if resolution.cards.isEmpty {
            var components = URLComponents(string: "https://www.bing.com/images/search")!
            components.queryItems = [URLQueryItem(name: "q", value: mention.query)]
            resolution.cards = [PrompterCard(kind: .thing, query: mention.query,
                                             title: "Pictures of \u{201C}\(mention.query)\u{201D}",
                                             subtitle: "Image search \u{00B7} nothing sent until you open it",
                                             source: .search, url: components.url!)]
            resolution.searchLinkOnly = true
        }
        return resolution
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
            let said = Set(Mention.normalize(mention.query).split(separator: " ").map(String.init))
            let generic: Set<String> = ["the", "of", "and", "a", "an"]
            switch await fetchJSON(components.url!, source: .wikipedia, host: "wikipedia.org", parse: { json in
                let pages = json["pages"] as? [[String: Any]] ?? []
                return pages.compactMap { page -> PrompterCard? in
                    guard let key = page["key"] as? String, let title = page["title"] as? String,
                          let url = URL(string: "https://en.wikipedia.org/wiki/\(key)") else { return nil }
                    let description = (page["description"] as? String) ?? ""
                    // Disambiguation pages are a list, not an answer.
                    guard !description.lowercased().contains("referred to by the same term"),
                          !description.lowercased().hasPrefix("disambiguation") else { return nil }
                    let titleWords = Mention.normalize(title).split(separator: " ").map(String.init).filter { !generic.contains($0) }
                    guard !titleWords.isEmpty, titleWords.allSatisfy({ said.contains($0) }) else { return nil }
                    let card = PrompterCard(kind: .thing, query: mention.query, title: title,
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
            return results.prefix(1).compactMap { result -> PrompterCard? in
                guard let title = result["title"] as? String,
                      let url = URL(string: "https://en.wikiquote.org/wiki/" + (title.replacingOccurrences(of: " ", with: "_")
                        .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title)) else { return nil }
                let snippet = Self.stripHTML((result["snippet"] as? String) ?? "")
                return PrompterCard(kind: .quote, query: mention.query, title: title,
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
            resolution.cards = [PrompterCard(kind: .quote, query: mention.query,
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
        resolution.cards = [PrompterCard(kind: .word, query: mention.query, title: mention.query.capitalized,
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
            return items.compactMap { item -> PrompterCard? in
                guard let idBlock = item["id"] as? [String: Any], let videoID = idBlock["videoId"] as? String,
                      let snippet = item["snippet"] as? [String: Any],
                      let title = snippet["title"] as? String,
                      let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
                let channel = (snippet["channelTitle"] as? String) ?? "YouTube"
                let card = PrompterCard(kind: .video, query: mention.query, title: Self.decodeHTML(title),
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

    private static func youtubeSearchCard(for mention: Mention) -> PrompterCard {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: mention.query)]
        return PrompterCard(kind: .video, query: mention.query,
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
    private func allowed(_ source: PrompterCard.Source, host: String) -> Bool {
        if let until = backoffUntil[host], until > Date() { return false }
        return counts[source, default: 0] < caps[source, default: 0]
    }

    private func fetchJSON(_ url: URL, source: PrompterCard.Source, host: String,
                           headers: [String: String] = [:],
                           parse: ([String: Any]) -> [PrompterCard]) async -> Lookup {
        counts[source, default: 0] += 1
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, response) = try await transport.data(for: request)
            let status = response.statusCode
            guard (200..<300).contains(status) else {
                noteFailure(host)
                return .failure("lookup failed (\(source.label), HTTP \(status)) \u{2014} card skipped")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                noteFailure(host)
                return .failure("lookup failed (\(source.label), unreadable reply) \u{2014} card skipped")
            }
            consecutiveFailures[host] = 0
            return .success(parse(json))
        } catch {
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

    /// Google Books hands out http:// covers; everything Prompter opens or
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
