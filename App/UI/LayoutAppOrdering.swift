//
//  LayoutAppOrdering.swift
//  Greenroom
//
//  The order and the search of the Apps section in the layout "+ Add" popover.
//  Pure values in, ids out, so it is unit tested (Tests/LayoutAppOrderingTests).
//
import Foundation

struct LayoutAppCandidate: Equatable {
    let id: String
    let name: String
    var isBrowser = false
    var isRunning = false
}

enum LayoutAppOrdering {
    struct Result: Equatable {
        /// Browsers, slide and notes apps and running apps, in that order. Empty while searching.
        var suggested: [String]
        /// Everything else, alphabetical; while searching, every match, alphabetical.
        var rest: [String]
        var searching: Bool
    }

    /// How many apps the Suggested row holds (two rows of four).
    static let suggestedLimit = 8

    private static let browserOrder = ["greenroom browser", "safari", "chrome", "arc", "firefox", "edge", "ulaa"]
    private static let slideAndNotes = ["keynote", "powerpoint", "google", "notes", "preview", "textedit"]

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// "Microsoft Edge" starts a word with "edge"; "Marcus" does not with "arc".
    private static func startsAWord(_ name: String, _ key: String) -> Bool {
        name.split(separator: " ").contains { $0.hasPrefix(key) } || name.hasPrefix(key)
    }

    /// nil when the app is not a suggestion; else a sort key (group, position).
    static func suggestionRank(_ app: LayoutAppCandidate) -> (group: Int, index: Int)? {
        let name = fold(app.name)
        if let i = browserOrder.firstIndex(where: { startsAWord(name, $0) }) { return (0, i) }
        if app.isBrowser { return (0, browserOrder.count) }
        if let i = slideAndNotes.firstIndex(where: { startsAWord(name, $0) }) { return (1, i) }
        if app.isRunning { return (2, 0) }
        return nil
    }

    static func arrange(_ apps: [LayoutAppCandidate], query: String) -> Result {
        let byName: (LayoutAppCandidate, LayoutAppCandidate) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        if !q.isEmpty {
            let hits = apps.filter { fold($0.name).contains(q) }.sorted(by: byName)
            return Result(suggested: [], rest: hits.map(\.id), searching: true)
        }
        let ranked = apps.compactMap { app in suggestionRank(app).map { (app, $0) } }
            .sorted { a, b in
                if a.1.group != b.1.group { return a.1.group < b.1.group }
                if a.1.index != b.1.index { return a.1.index < b.1.index }
                return byName(a.0, b.0)
            }
            .prefix(suggestedLimit)
            .map(\.0)
        let picked = Set(ranked.map(\.id))
        let rest = apps.filter { !picked.contains($0.id) }.sorted(by: byName)
        return Result(suggested: ranked.map(\.id), rest: rest.map(\.id), searching: false)
    }
}
