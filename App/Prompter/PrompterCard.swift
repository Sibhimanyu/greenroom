//
//  PrompterCard.swift
//  Greenroom
//
//  The vocabulary of Prompter: what the detector hears (a Mention), what a
//  lookup turns it into (a PrompterCard), and what a surface needs to draw
//  and act on it (PrompterSurfaceState).
//
//  Nothing here touches speech or the network. That is deliberate: the two
//  surfaces (participants panel, menu bar) and the Sessions window all speak
//  this vocabulary and none of them need macOS 26, while the pipeline that
//  produces it does. Keeping the types unconditional is what lets the panel
//  code compile on macOS 14 with the feature simply never lit.
//
import AppKit
import Foundation

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
    /// Short and deterministic: the words that go into the search box. This
    /// is the ONLY text derived from speech that ever leaves the Mac, and it
    /// is written to the status log every time it does.
    var query: String
    /// 0...1. The heuristic detector never goes above 0.8; the model reports
    /// its own.
    var confidence: Double

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
struct PrompterCard: Identifiable, Hashable {
    enum Source: String {
        case googleBooks, openLibrary, wikipedia, wikiquote, youtube, search
        /// The Mac's own Dictionary. Nothing leaves for this one.
        case dictionary

        var label: String {
            switch self {
            case .googleBooks: return "Google Books"
            case .openLibrary: return "Open Library"
            case .wikipedia: return "Wikipedia"
            case .wikiquote: return "Wikiquote"
            case .youtube: return "YouTube"
            case .search: return "Search"
            case .dictionary: return "Dictionary"
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

    static func == (a: PrompterCard, b: PrompterCard) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Everything a surface needs, and the three things it may do. Handed to the
/// participants panel and the menu-bar item on every tick; both redraw in
/// place from it.
struct PrompterSurfaceState {
    var listening = false
    /// True while muted in Zoom or stopped for this class: the pipeline is
    /// up but nothing is being transcribed.
    var paused = false
    /// True while a lookup is in flight - the amber dot (DESIGN.md: network
    /// reads amber).
    var resolving = false
    var cards: [PrompterCard] = []
    var open: (PrompterCard) -> Void = { _ in }
    var send: (PrompterCard) -> Void = { _ in }
    var dismiss: (PrompterCard) -> Void = { _ in }
    /// Whether Send has anywhere to go: the meeting chat is joined.
    var canSend = false

    static let empty = PrompterSurfaceState()
}
