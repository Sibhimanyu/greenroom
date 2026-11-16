//
//  SessionsIndex.swift
//
//  What the Sessions list knows about each folder that RecordingsView's scan
//  does not hand it: is there a video to share, how many moments are marked,
//  how it was shared, and what was said (transcript.txt). Read in the
//  background from the same files the session's page reads, cached by the
//  folder's modification date, and merged into the cards (`enrich`) so the
//  rows, the sidebar badges and the search can never disagree.
//
//  A session id is its folder's path (RecordingsView.Session.id); the loose
//  legacy bucket has no folder and so no extras.
//
import Foundation
import SwiftUI

@MainActor
final class SessionsIndex: ObservableObject {
    static let shared = SessionsIndex()

    struct Extras: Equatable {
        var hasVideo = false
        var momentCount = 0
        var uploadPrivacy: String?
        var lines: [(stamp: String, text: String)] = []
        /// "Course \u{00B7} Topic", when one can be made (SessionTitleSuggester).
        var suggestedTitle: String?
        /// The title the user typed, if any; it always wins.
        var customTitle: String?

        static func == (a: Extras, b: Extras) -> Bool {
            a.hasVideo == b.hasVideo && a.momentCount == b.momentCount
                && a.uploadPrivacy == b.uploadPrivacy && a.lines.count == b.lines.count
                && a.suggestedTitle == b.suggestedTitle && a.customTitle == b.customTitle
        }
    }

    @Published private(set) var extras: [String: Extras] = [:]
    private var stamps: [String: String] = [:]
    private var running = false

    /// The cards with this index's findings merged in.
    func enrich(_ cards: [SessionCardModel]) -> [SessionCardModel] {
        cards.map { card in
            guard let e = extras[card.id] else { return card }
            var out = card
            out.hasVideo = e.hasVideo
            out.momentCount = e.momentCount
            out.uploadPrivacy = e.uploadPrivacy
            out.hasTranscript = !e.lines.isEmpty
            out.title = Self.shown(card.title, extras: e)
            return out
        }
    }

    /// The title a card shows: the typed one, else the suggestion, else `fallback`.
    private static func shown(_ fallback: String, extras e: Extras) -> String {
        SessionTitleSuggester.displayTitle(custom: e.customTitle, course: nil, topic: nil, fallback: e.suggestedTitle ?? fallback)
    }

    /// The title for a session's page, same rule as the list.
    func title(for id: String, fallback: String) -> String {
        extras[id].map { Self.shown(fallback, extras: $0) } ?? fallback
    }

    /// Sentences matching the query, per session, newest session order left to the caller.
    func hits(for query: String) -> [String: [TranscriptHit]] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [:] }
        var out: [String: [TranscriptHit]] = [:]
        for (id, e) in extras where !e.lines.isEmpty {
            let found = TranscriptSearch.hits(sessionID: id, lines: e.lines, query: q)
            if !found.isEmpty { out[id] = found }
        }
        return out
    }

    /// Re-reads folders that changed since they were last read.
    func refresh(_ cards: [SessionCardModel]) async {
        guard !running else { return }
        running = true
        defer { running = false }
        let known = stamps
        let work = cards.filter { $0.id != "__loose__" }.map { ($0.id, $0.isUploaded, $0.isAnalysed, $0.title) }
        let result = await Task.detached(priority: .utility) { () -> [(String, String, Extras)] in
            var out: [(String, String, Extras)] = []
            for (id, uploaded, analysed, title) in work {
                let folder = URL(fileURLWithPath: id, isDirectory: true)
                let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                let stamp = "\(modified)|\(uploaded)|\(analysed)|\(title)"
                if known[id] == stamp { continue }
                out.append((id, stamp, Self.read(folder)))
            }
            return out
        }.value
        guard !result.isEmpty else { return }
        var next = extras
        for (id, stamp, e) in result {
            next[id] = e
            stamps[id] = stamp
        }
        extras = next
    }

    nonisolated private static func read(_ folder: URL) -> Extras {
        var e = Extras()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let video: Set<String> = ["mov", "mp4", "m4v"]
        var clips = 0
        for file in files where video.contains(file.pathExtension.lowercased()) {
            if SessionClipExporter.isClip(file) { clips += 1 } else { e.hasVideo = true }
        }
        // A session with only clips still has something to share.
        if clips > 0 { e.hasVideo = true }
        var notes = 0
        if let raw = try? String(contentsOf: ScreenroomNotesFile.url(in: folder), encoding: .utf8) {
            notes = raw.split(separator: "\n").count
        }
        e.momentCount = clips + notes
        let meta = SessionMetadata.load(in: folder)
        e.uploadPrivacy = meta.uploads.last?.privacy
        e.lines = SessionSummary.lines(in: folder).map { ($0.stamp, $0.text) }
        e.customTitle = meta.title
        e.suggestedTitle = SessionTitleSuggester.suggestion(
            course: meta.course, topic: SessionTitleSuggester.topic(fromLines: e.lines.map(\.text)))
        return e
    }
}
