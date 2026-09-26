//
//  CueCard.swift
//  Greenroom
//
//  The vocabulary of Cues: what the detector hears (a Mention), what a
//  lookup turns it into (a CueCard), and what a surface needs to draw
//  and act on it (CuesSurfaceState).
//
//  Nothing here touches speech or the network. That is deliberate: the two
//  surfaces (participants panel, menu bar) and the Sessions window all speak
//  this vocabulary and none of them need macOS 26, while the pipeline that
//  produces it does. Keeping the types unconditional is what lets the panel
//  code compile on macOS 14 with the feature simply never lit.
//
import AppKit
import Foundation

/// Which detector proposed a mention. Written into the class's cues.txt so
/// a real lesson says how the two sources actually split, rather than the split
/// being argued from one recording.
enum FoundBy: String, Hashable {
    case patterns
    case model
}

/// Something the teacher said that might be worth a link.
struct Mention: Hashable {
    /// What kind of thing was named. Learned from recorded classes rather
    /// than guessed: the teacher looks up tools and products ("it's called
    /// Haiku Deck"), word meanings ("the word pabulum"), quotations ("ask not
    /// what your country can do for you") and pictures of things, more often
    /// than book titles.
    enum Kind: String, CaseIterable {
        case book, video, topic, person, place
        /// A tool, app, product, company or other named thing.
        case thing
        /// A word whose meaning is being asked or explained.
        case word
        /// A quotation - the query is the phrase itself.
        case quote

        /// The eyebrow on a card. Mono, upper-case per DESIGN.md.
        var eyebrow: String {
            switch self {
            case .book: return "BOOK"
            case .video: return "VIDEO"
            case .topic: return "TOPIC"
            case .person: return "PERSON"
            case .place: return "PLACE"
            case .thing: return "THING"
            case .word: return "WORD"
            case .quote: return "QUOTE"
            }
        }
    }

    var kind: Kind
    /// What the thing is called, as said. Used for the card's label, for
    /// dedupe, for the roster check, and for guessing a product's domain.
    var query: String
    /// What actually goes in the search box.
    ///
    /// A bare name is often unsearchable: "monospace" alone lands nowhere,
    /// "monospace font" lands on the right page. So the model is asked for a
    /// query that carries a word or two of what kind of thing it is, drawn
    /// from what the teacher was saying. Defaults to the name when nothing
    /// richer is available (the word-pattern detector has no way to enrich).
    /// This, not `query`, is the text that leaves the Mac - and it is what
    /// the status log names.
    var searchQuery: String
    /// 0...1. The heuristic detector never goes above 0.8; the model reports
    /// its own.
    var confidence: Double
    /// Which detector proposed this. Defaults to the word patterns, which is
    /// what produces a Mention everywhere except the model's own leg.
    var foundBy: FoundBy = .patterns
    /// What the speaker said this is - "brand", "app", "font" - when a tell
    /// said it out loud. The resolver holds a page to it: "the brand called
    /// imago" must not come back as the insect life stage.
    var category: String?

    /// `searchQuery` falls back to the name, which is what the word-pattern
    /// detector always produces.
    init(kind: Kind, query: String, searchQuery: String? = nil, confidence: Double) {
        self.kind = kind
        self.query = query
        let enriched = (searchQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // A "richer" query that lost the name itself is worse than the name.
        self.searchQuery = enriched.isEmpty || !Mention.normalize(enriched).contains(Mention.normalize(query))
            ? query : enriched
        self.confidence = confidence
    }

    /// Lower-cased, whitespace-collapsed, punctuation-stripped - the key the
    /// session dedupes and suppresses on. "Charlotte's Web" and "charlottes
    /// web" are one mention.
    var normalizedKey: String { Mention.normalize(query) }

    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let stripped = String(lowered.unicodeScalars.filter { allowed.contains($0) })
        return stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// One suggestion, ready to show. A card exists only after a lookup came back
/// with a title and a URL - the one exception is a `.search` card, which
/// points at a search page and has sent nothing anywhere yet.
struct CueCard: Identifiable, Hashable {
    enum Source: String {
        case googleBooks, openLibrary, wikipedia, wikiquote, youtube, search
        /// The Mac's own Dictionary. Nothing leaves for this one.
        case dictionary
        /// The product's own homepage, found by guessing the domain from the
        /// name and checking the page really exists.
        case officialSite
        /// A picture search, as a link. Sends nothing until it is opened.
        case images

        var label: String {
            switch self {
            case .googleBooks: return "Google Books"
            case .openLibrary: return "Open Library"
            case .wikipedia: return "Wikipedia"
            case .wikiquote: return "Wikiquote"
            case .youtube: return "YouTube"
            case .search: return "Search"
            case .dictionary: return "Dictionary"
            case .officialSite: return "Official site"
            case .images: return "Images"
            }
        }

        /// The bucket analytics sees. Never the query or the URL.
        var analyticsCode: String {
            switch self {
            case .googleBooks, .openLibrary: return "books"
            case .wikipedia: return "wikipedia"
            case .wikiquote: return "quotes"
            case .youtube: return "youtube"
            case .search: return "search"
            case .dictionary: return "dictionary"
            case .officialSite: return "official_site"
            case .images: return "images"
            }
        }
    }

    let id: UUID
    var kind: Mention.Kind
    /// The phrase that was looked up, for the log line and the dedupe key.
    var query: String
    var title: String
    /// Author, channel, first line of the summary - one line under the title.
    var subtitle: String
    var source: Source
    var url: URL
    var thumbnail: NSImage?
    var createdAt: Date

    init(id: UUID = UUID(), kind: Mention.Kind, query: String, title: String, subtitle: String,
         source: Source, url: URL, thumbnail: NSImage? = nil, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.query = query
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.url = url
        self.thumbnail = thumbnail
        self.createdAt = createdAt
    }

    var normalizedKey: String { Mention.normalize(query) }

    static func == (a: CueCard, b: CueCard) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Everything a surface needs, and the three things it may do. Handed to the
/// participants panel and the menu-bar item on every tick; both redraw in
/// place from it.
struct CuesSurfaceState {
    var listening = false
    /// True while muted in Zoom or stopped for this class: the pipeline is
    /// up but nothing is being transcribed.
    var paused = false
    /// True while a lookup is in flight - the amber dot (DESIGN.md: network
    /// reads amber).
    var resolving = false
    var cards: [CueCard] = []
    var open: (CueCard) -> Void = { _ in }
    var send: (CueCard) -> Void = { _ in }
    var dismiss: (CueCard) -> Void = { _ in }
    /// Whether Send has anywhere to go: the meeting chat is joined.
    var canSend = false

    static let empty = CuesSurfaceState()
}


/// What the menu bar says while a class is running.
///
/// This exists as its own function because getting the number wrong here is
/// invisible in code review and glaring in a classroom. The status line used
/// to read `cards.count`, which is not a tally: it is a display window capped
/// at twelve that also sheds anything older than thirty minutes. On a real
/// 43-minute class on 7 Sep it filled about four minutes in and then read
/// "12 links" for the remaining thirty-nine, while the class went on to find
/// eighty-two. The teacher could talk all lesson and watch a frozen number.
///
/// The window is a budget for a rail with three visible slots. The tally is a
/// fact about the class. They are different numbers and only one of them
/// belongs in a sentence that says how many links were found.
enum CuesStatus {
    static func listening(linksFound: Int) -> String {
        guard linksFound > 0 else { return "Cues is listening" }
        return "Cues is listening \u{00B7} \(linksFound) link\(linksFound == 1 ? "" : "s")"
    }
}
