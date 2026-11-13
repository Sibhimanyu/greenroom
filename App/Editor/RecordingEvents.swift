// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Recording/InputEventTracker.swift) — the RecordingEvents model only, not the tracker class.
import AppKit

/// Clicks and keystrokes captured alongside a recording — the raw material
/// for the editor's click ripples, keystroke overlay and auto-zoom. Stored
/// as a small JSON sidecar next to the video (same name, .events.json).
struct RecordingEvents: Codable {
    /// t = seconds into the finished video; x/y normalized 0…1, top-left
    /// origin, in the recorded display's space.
    struct Click: Codable {
        let t: Double
        let x: Double
        let y: Double
    }

    struct Key: Codable {
        let t: Double
        let text: String
    }

    var clicks: [Click] = []
    var keys: [Key] = []

    var isEmpty: Bool { clicks.isEmpty && keys.isEmpty }

    static func sidecarURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("events.json")
    }

    static func load(for videoURL: URL) -> RecordingEvents? {
        guard let data = try? Data(contentsOf: sidecarURL(for: videoURL)) else { return nil }
        return try? JSONDecoder().decode(RecordingEvents.self, from: data)
    }

    func save(for videoURL: URL) {
        guard !isEmpty, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.sidecarURL(for: videoURL))
    }
}
