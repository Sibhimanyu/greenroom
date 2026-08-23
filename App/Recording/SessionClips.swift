//
//  SessionClips.swift
//  Greenroom
//
//  Marking a span of a recording without cutting it.
//
//  The teacher's mental model is a precorder - hold the last few minutes in a
//  buffer, dump it on a hotkey. Greenroom does not need one, because the whole
//  class is already being written to disk. So the hotkey is a BOOKMARK, not a
//  video operation: read where OBS currently is in the file, write down a
//  range, and get out of the way. That costs no CPU, no memory, and cannot
//  disturb the one activity that must not stutter.
//
//  Cutting happens later, from the finished master, losslessly.
//
import Foundation

/// A marked span of one recording: "the last N minutes, ending when I pressed
/// the key."
///
/// Offsets are milliseconds into the recording FILE, not wall-clock, because
/// that is what a player and an export both need and it survives the file being
/// moved or renamed. `markedAt` is kept alongside purely so the clip can be
/// labelled with the time of day it happened, which is how a teacher remembers
/// it.
struct SessionClip: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var startMs: Int
    var endMs: Int
    var markedAt: Date

    var durationMs: Int { max(0, endMs - startMs) }
    var startSeconds: Double { Double(startMs) / 1000 }
    var endSeconds: Double { Double(endMs) / 1000 }

    /// "5 min", or the real length when the mark landed before that much of the
    /// class had happened - asking for the last five minutes two minutes in
    /// gives you two minutes, and the label should not claim otherwise.
    var durationLabel: String {
        let seconds = durationMs / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes)m \(remainder)s"
    }

    /// The time of day the key was pressed.
    var markedAtLabel: String {
        SessionClip.timeFormatter.string(from: markedAt)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        return formatter
    }()
}

/// Reads and writes the sidecar that records a recording's marks.
///
/// Two files, on purpose. Marks are appended to `pending-clips.json` in the
/// session folder the instant the key is pressed, because OBS does not report
/// the recording's filename until it stops - and a mark that only existed in
/// memory would be lost by the crash it is most needed after. When the tape
/// stops and the real path is finally known, the pending file is adopted as
/// `<recording>.clips.json` and the two are married for good.
enum SessionClipStore {

    static let pendingFileName = "pending-clips.json"

    /// `Morning Reading.mp4` -> `Morning Reading.clips.json`, beside it.
    static func sidecarURL(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("clips.json")
    }

    static func pendingURL(in folder: URL) -> URL {
        folder.appendingPathComponent(pendingFileName)
    }

    static func load(for recording: URL) -> [SessionClip] {
        read(at: sidecarURL(for: recording))
    }

    @discardableResult
    static func save(_ clips: [SessionClip], for recording: URL) -> Bool {
        write(clips, to: sidecarURL(for: recording))
    }

    static func loadPending(in folder: URL) -> [SessionClip] {
        read(at: pendingURL(in: folder))
    }

    /// Appends one mark and flushes immediately. Read-modify-write rather than
    /// holding the list in memory: the whole point is that the file on disk is
    /// correct the moment the key comes back up.
    @discardableResult
    static func appendPending(_ clip: SessionClip, in folder: URL) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var clips = loadPending(in: folder)
        clips.append(clip)
        return write(clips, to: pendingURL(in: folder))
    }

    /// Marries the pending marks to the recording they belong to.
    ///
    /// Merges rather than overwrites, so stopping and restarting the tape inside
    /// one session cannot silently discard the first take's marks if both
    /// somehow resolve to the same file.
    static func adoptPending(in folder: URL, as recording: URL) {
        let pending = loadPending(in: folder)
        guard !pending.isEmpty else { return }
        var existing = load(for: recording)
        let known = Set(existing.map(\.id))
        existing.append(contentsOf: pending.filter { !known.contains($0.id) })
        if save(existing.sorted { $0.startMs < $1.startMs }, for: recording) {
            try? FileManager.default.removeItem(at: pendingURL(in: folder))
        }
    }

    private static func read(at url: URL) -> [SessionClip] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SessionClip].self, from: data)) ?? []
    }

    private static func write(_ clips: [SessionClip], to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(clips) else { return false }
        // Atomic: a half-written sidecar reads as no marks at all, which is the
        // one outcome worse than losing the newest one.
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
