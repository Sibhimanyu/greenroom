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
    }

    /// One host's answer: cards, or the note the status log gets instead.
    enum Lookup {
        case success([PrompterCard])
        case failure(String)
    }

    struct Configuration {
        var videoSearchEnabled = true
        /// Nil when no Google account is connected: video mentions become
        /// search links.
        var youtubeToken: (() async throws -> String)?
    }

    /// Descriptive, fixed, and the same on every request. A site owner
    /// reading their logs should be able to tell what this is.
    static let userAgent = "Greenroom/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (macOS; Prompter; +https://sibhimanyu.github.io/greenroom/how-it-works.html)"

    private let session: URLSession
    private var configuration = Configuration()

    private var resolvedKeys: Set<String> = []
    private var cache: [String: Resolution] = [:]
    private var counts: [PrompterCard.Source: Int] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var backoffUntil: [String: Date] = [:]
    private var inFlight = 0
    private(set) var totalResolved = 0
    /// True once YouTube said the quota is gone for the day, so every further
    /// video mention becomes a search link without asking again.
    private var youtubeQuotaExhausted = false

    /// Per-session ceilings, per source.
    private let caps: [PrompterCard.Source: Int] = [.googleBooks: 60, .openLibrary: 60, .wikipedia: 60, .youtube: 20, .search: 200]
    private let sessionCap = 30
    private let maxInFlight = 2

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept": "application/json"]
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
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
        case .topic, .person, .place: resolution = await resolveWikipedia(mention)
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
            switch await googleBooks(mention.query) {
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
            switch await openLibrary(mention.query) {
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
        await attachThumbnails(&resolution)
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
            let pages = json["pages"] as? [[String: Any]] ?? []
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
        await attachThumbnails(&resolution)
        return resolution
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
        await attachThumbnails(&resolution)
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

    private func attachThumbnails(_ resolution: inout Resolution) async {
        for index in resolution.cards.indices {
            let id = resolution.cards[index].id
            guard let url = pendingThumbnails.removeValue(forKey: id) else { continue }
            resolution.cards[index].thumbnail = await ThumbnailLoader.shared.image(for: url)
        }
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
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
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
