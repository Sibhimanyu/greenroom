//
//  BrowserHistory.swift
//  Greenroom
//
//  Where the built-in browser has been: one entry per page visit, newest
//  first, kept in Application Support as JSON. Read by the history popover
//  (⌘Y); written as tabs navigate. Local only - nothing here leaves the
//  Mac, which matters for a product whose whole pitch is verifiability.
//
import Foundation

@MainActor
final class BrowserHistory: ObservableObject {
    static let shared = BrowserHistory()

    struct Entry: Codable, Identifiable, Hashable {
        var id: UUID
        var url: String
        var title: String
        var visitedAt: Date

        var host: String { URL(string: url)?.host ?? url }
        var displayTitle: String { title.isEmpty ? host : title }
    }

    /// Newest first.
    @Published private(set) var entries: [Entry] = []

    /// Plenty for years of mornings; keeps the file and the popover quick.
    private static let cap = 5000

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Greenroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("browser-history.json")
        load()
    }

    /// A navigation landed on `url`. The same page twice in a row is one
    /// visit (a reload, or the title arriving after the URL), not two.
    func record(url: URL, title: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return }
        let address = url.absoluteString
        if let first = entries.first, first.url == address {
            entries[0].visitedAt = Date()
            if !title.isEmpty { entries[0].title = title }
        } else {
            entries.insert(Entry(id: UUID(), url: address, title: title, visitedAt: Date()), at: 0)
            if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
        }
        scheduleSave()
    }

    /// Titles arrive after URLs; fill in the most recent entry for the page.
    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty,
              let index = entries.firstIndex(where: { $0.url == url.absoluteString }) else { return }
        guard entries[index].title != title else { return }
        entries[index].title = title
        scheduleSave()
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    /// Case-insensitive match on title or address; everything when empty.
    func matching(_ query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.url.localizedCaseInsensitiveContains(needle)
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    /// Debounced: a page that redirects three times writes the file once.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
