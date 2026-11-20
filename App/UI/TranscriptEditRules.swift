//
//  TranscriptEditRules.swift
//  Greenroom
//
//  The pure half of editing a transcript in place: reading a file's raw rows
//  with their positions, rewriting or removing one row without disturbing the
//  rest, and the small decisions around the ".original" copy and follow-along.
//
//  Two writers share the Transcript tab. Cues writes "h:mm:ss<TAB>text" rows
//  (transcript.txt); Analyse writes "[m:ss] text" rows (analysis-transcript.txt,
//  or an older folder's transcript.txt). Comment rows start with "#". The tab
//  hides some rows (whisper sound labels), so a displayed line is mapped back to
//  its RAW row index here; every edit touches that one row and nothing else.
//
import Foundation

enum TranscriptEditRules {

    /// One speakable row of the raw file.
    struct Row: Equatable {
        /// Index into `raw.components(separatedBy: "\n")`.
        let rawIndex: Int
        let stamp: String
        /// The row's text exactly as in the file (not noise-cleaned).
        let text: String
    }

    /// The prefix of a row that is not its text: "stamp\t" or "[stamp] ".
    private static func split(_ row: String) -> (prefix: String, stamp: String, text: String)? {
        guard !row.hasPrefix("#") else { return nil }
        if let tab = row.firstIndex(of: "\t") {
            let stamp = String(row[..<tab])
            let text = String(row[row.index(after: tab)...])
            if !stamp.isEmpty, !text.isEmpty {
                return (String(row[...tab]), stamp, text)
            }
        }
        guard row.hasPrefix("["), let close = row.firstIndex(of: "]") else { return nil }
        let stamp = String(row[row.index(after: row.startIndex)..<close])
        guard !stamp.isEmpty, stamp.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." }) else { return nil }
        var end = row.index(after: close)
        while end < row.endIndex, row[end] == " " { end = row.index(after: end) }
        return (String(row[..<end]), stamp, String(row[end...]))
    }

    /// Every timestamped row, comments and blanks skipped, with raw positions.
    static func rows(in raw: String) -> [Row] {
        raw.components(separatedBy: "\n").enumerated().compactMap { index, row in
            let row = row.hasSuffix("\r") ? String(row.dropLast()) : row
            guard let parts = split(row) else { return nil }
            return Row(rawIndex: index, stamp: parts.stamp, text: parts.text)
        }
    }

    /// Replaces one row's text, or removes the row when `newText` is nil or
    /// blank. Every other character of the file, including comments, blank
    /// rows, hidden noise rows, order and line endings, is untouched. Nil when
    /// `rawIndex` is not a timestamped row.
    static func rewrite(raw: String, rawIndex: Int, newText: String?) -> String? {
        var rows = raw.components(separatedBy: "\n")
        guard rows.indices.contains(rawIndex) else { return nil }
        var row = rows[rawIndex]
        let crlf = row.hasSuffix("\r")
        if crlf { row.removeLast() }
        guard let parts = split(row) else { return nil }
        let clean = newText.map(oneLine) ?? ""
        if clean.isEmpty {
            rows.remove(at: rawIndex)
        } else {
            rows[rawIndex] = parts.prefix + clean + (crlf ? "\r" : "")
        }
        return rows.joined(separator: "\n")
    }

    /// Tabs and newlines out, so an edit can never split a row or add one.
    static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: Stamps and time

    /// "0:12:40" (Cues) or "12:40" / "12:40.5" (Analyse) as seconds.
    static func stampSeconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
            .map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// The last line whose start is at or before `time` (a hair of slack for
    /// the player's rounding). Starts need not be sorted; the last match wins.
    static func currentLine(starts: [Double], at time: Double) -> Int? {
        starts.lastIndex { $0 <= time + 0.05 }
    }

    // MARK: Original copy and summary

    /// "transcript.txt" -> "transcript.original.txt".
    static func originalName(for name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? base + ".original" : base + ".original." + ext
    }

    /// Copy the untouched file aside on the first edit only.
    static func shouldCopyOriginal(originalExists: Bool, sourceExists: Bool) -> Bool {
        sourceExists && !originalExists
    }

    /// The summary predates the latest transcript change.
    static func summaryIsStale(transcriptModified: Date?, summaryModified: Date?) -> Bool {
        guard let transcriptModified, let summaryModified else { return false }
        return transcriptModified > summaryModified
    }

    /// Follow-along scrolls only when the reader has not scrolled lately.
    static func shouldAutoScroll(lastManualScroll: Date?, now: Date, quiet: TimeInterval = 3) -> Bool {
        guard let lastManualScroll else { return true }
        return now.timeIntervalSince(lastManualScroll) >= quiet
    }
}
