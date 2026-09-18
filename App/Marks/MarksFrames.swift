//
//  MarksFrames.swift
//  Greenroom
//
//  Stills from the recording, so something that cannot watch a video can
//  still see one.
//
//  This exists because of a limit worth stating plainly: the agents people
//  actually have on their machines - Claude Code, Codex - read text and
//  images. None of them watch an .mov. Handing one a video file and asking
//  about body language gets you a confident answer about a file it never
//  opened.
//
//  Frames are the honest version. A still every twenty seconds is enough to
//  see posture, whether they are reading from a screen, whether they face the
//  room, what is on the slide behind them. It is not enough to judge gesture
//  or pace, and the brief written for the agent says so rather than letting
//  it guess.
//
import AVFoundation
import AppKit
import Foundation

enum MarksFrames {

    static let folderName = "frames"

    /// One still every twenty seconds.
    ///
    /// Chosen against what the frames are for rather than against a quality
    /// target: a ten-minute presentation gives thirty images, which is a
    /// number a model can attend to properly. Every five seconds would give a
    /// hundred and twenty, which is a number it skims.
    static let everySeconds: Double = 20

    /// Long edge. 960 is legible for posture and slide text and keeps thirty
    /// frames under a few megabytes, which matters when they are about to be
    /// read by something with a context window.
    static let longEdge: CGFloat = 960

    static func folder(in presentation: URL) -> URL {
        presentation.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Extracts the stills, replacing any from a previous run.
    @discardableResult
    static func extract(from recording: URL,
                        into presentation: URL,
                        onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> [URL] {
        let asset = AVURLAsset(url: recording)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard duration > 0 else { return [] }

        let target = folder(in: presentation)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longEdge, height: longEdge)
        // A second either side is fine and is much faster than an exact seek.
        // Nothing here depends on landing on a particular frame.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        var times: [Double] = []
        var at: Double = min(2, duration / 2)
        while at < duration {
            times.append(at)
            at += everySeconds
        }

        var written: [URL] = []
        for (index, seconds) in times.enumerated() {
            if let report = onProgress { await report(index, times.count) }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            let bitmap = NSBitmapImageRep(cgImage: cg)
            guard let data = bitmap.representation(using: .jpeg,
                                                   properties: [.compressionFactor: 0.7]) else { continue }
            // Named by where they are in the recording, so a model that
            // mentions one by file name has told you where to look.
            let name = String(format: "%03d-%@.jpg", index + 1, stamp(seconds))
            let file = target.appendingPathComponent(name)
            try? data.write(to: file, options: .atomic)
            written.append(file)
        }
        if let report = onProgress { await report(times.count, times.count) }
        return written
    }

    static func existing(in presentation: URL) -> [URL] {
        let target = folder(in: presentation)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: target, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `06-40`, not `6:40` - a colon is a path separator to Finder.
    static func stamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d-%02d", total / 60, total % 60)
    }
}
