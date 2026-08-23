//
//  SessionClipExporter.swift
//  Greenroom
//
//  Cuts a marked range out of a finished recording.
//
//  Passthrough, not re-encode: the bytes are copied straight across, so a
//  five-minute clip of a class costs a few seconds and loses nothing. The price
//  is that the cut lands on a keyframe rather than an exact frame, so a clip can
//  begin up to one keyframe interval early - a second or two at OBS's usual
//  settings. Early is the right direction to be wrong in: the moment the teacher
//  marked is always inside the clip, with a little run-up.
//
//  Re-encoding would be frame-exact and would also spend minutes of CPU per clip
//  and throw away quality, to fix a second of run-up nobody asked to remove.
//
import AVFoundation
import Foundation

enum SessionClipExporter {

    enum Failure: LocalizedError {
        case unreadable(URL)
        case noExportSession
        case rangeOutsideRecording
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url):
                return "Couldn't read \(url.lastPathComponent). The recording may still be finishing, or it may be damaged."
            case .noExportSession:
                return "This Mac couldn't open an export session for that recording."
            case .rangeOutsideRecording:
                return "That clip falls outside the recording. It may have been marked against a different take."
            case .exportFailed(let reason):
                return reason
            }
        }
    }

    /// What actually came out, which is not always what was asked for.
    struct Export {
        let url: URL
        let requested: SessionClip
        let actualDuration: Double
        /// How much run-up the keyframe cut added, in seconds. Reported rather
        /// than hidden: a clip labelled "5 min" that is 5:02 long should be able
        /// to say why.
        var addedLeadIn: Double { max(0, actualDuration - Double(requested.durationMs) / 1000) }
    }

    /// Clips live beside the recording they came from, in one folder per
    /// session so the session folder does not fill up with loose files.
    static func clipsFolder(for recording: URL) -> URL {
        recording.deletingLastPathComponent().appendingPathComponent("clips", isDirectory: true)
    }

    /// Named by the time of day it was marked and how long it is, because that
    /// is how a teacher remembers a moment: "the bit around twenty past".
    ///
    /// No index in the name, deliberately. An index would renumber if an earlier
    /// clip were deleted, so the file would stop matching whatever anybody had
    /// already written down or shared.
    static func exportURL(for clip: SessionClip, from recording: URL) -> URL {
        clipsFolder(for: recording)
            .appendingPathComponent("\(clip.markedAtLabel) (\(clip.durationLabel)).mp4")
    }

    static func isExported(_ clip: SessionClip, from recording: URL) -> Bool {
        FileManager.default.fileExists(atPath: exportURL(for: clip, from: recording).path)
    }

    /// Cuts one clip. Returns immediately if it already exists on disk.
    @discardableResult
    static func export(_ clip: SessionClip, from recording: URL) async throws -> Export {
        let output = exportURL(for: clip, from: recording)
        let asset = AVURLAsset(url: recording)

        guard let total = try? await asset.load(.duration), total.isValid, total.seconds > 0 else {
            throw Failure.unreadable(recording)
        }
        // A mark can outlive the file it belongs to - a recording deleted and
        // replaced, a sidecar adopted onto the wrong take. Clamp rather than
        // hand AVFoundation a range it will fail on obscurely.
        let start = max(0, min(clip.startSeconds, total.seconds))
        let end = max(start, min(clip.endSeconds, total.seconds))
        guard end - start > 0.1 else { throw Failure.rangeOutsideRecording }

        try? FileManager.default.createDirectory(at: clipsFolder(for: recording),
                                                 withIntermediateDirectories: true)
        // AVAssetExportSession refuses to write over an existing file.
        try? FileManager.default.removeItem(at: output)

        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.noExportSession
        }
        session.outputURL = output
        session.outputFileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : .mov
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: end - start, preferredTimescale: 600))
        // Nothing here is streamed; skipping the interleave pass is faster.
        session.shouldOptimizeForNetworkUse = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The completion-handler form, not the async export(to:as:) - that
            // one is macOS 15 and this app targets 14.
            session.exportAsynchronously { continuation.resume() }
        }

        guard session.status == .completed else {
            let reason = session.error?.localizedDescription
                ?? "The export stopped before it finished."
            try? FileManager.default.removeItem(at: output)
            throw Failure.exportFailed(reason)
        }

        let produced = (try? await AVURLAsset(url: output).load(.duration))?.seconds ?? (end - start)
        return Export(url: output, requested: clip, actualDuration: produced)
    }

    /// Exports every clip that is not already on disk, newest mark last so the
    /// folder fills in the order the class happened.
    ///
    /// Returns what succeeded and what did not, rather than throwing on the
    /// first failure: one unreadable clip should not stop the other four.
    static func exportAll(_ clips: [SessionClip],
                          from recording: URL,
                          onProgress: (@MainActor (Int, Int) -> Void)? = nil)
    async -> (exported: [Export], failed: [(SessionClip, Error)]) {
        var exported: [Export] = []
        var failed: [(SessionClip, Error)] = []
        let ordered = clips.sorted { $0.startMs < $1.startMs }
        for (index, clip) in ordered.enumerated() {
            if let report = onProgress { await report(index, ordered.count) }
            do { exported.append(try await export(clip, from: recording)) }
            catch { failed.append((clip, error)) }
        }
        if let report = onProgress { await report(ordered.count, ordered.count) }
        return (exported, failed)
    }
}
