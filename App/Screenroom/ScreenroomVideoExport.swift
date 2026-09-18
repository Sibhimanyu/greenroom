//
//  ScreenroomVideoExport.swift
//  Greenroom
//
//  The presentation with the notes written on it.
//
//  report.md is the document a teacher sends. This is the other half of the
//  same thought: a student watching themselves present, with the note the
//  teacher typed appearing at the moment it was typed about. Reading "at 6:40
//  you lost the thread" and WATCHING yourself lose the thread while the
//  sentence appears are not the same feedback, and the second one needs no
//  cross-referencing between a document and a scrubber.
//
//  Two exports, because they are good at different things:
//
//   - **Burned in.** One file, plays anywhere, cannot be separated from its
//     notes, looks like something. Costs a re-encode, so minutes rather than
//     seconds, and the notes can never be turned off.
//   - **A subtitle file.** Written in a second, no re-encode, no quality
//     lost, and every player can toggle it. YouTube accepts it directly. But
//     it is a second file to keep next to the first, and a student who opens
//     the video by double-clicking may never see it.
//
//  A teacher sending one file to one student wants the first. A teacher
//  uploading a term of presentations wants the second. Both are one button.
//
//  The look follows DESIGN.md: system font for the words, mono for the
//  timestamp, brand green on the timestamp only, one card bottom-left, no
//  ornament. Sizes are derived from the video's own height so a 720p capture
//  and a 1080p one produce the same picture at different scales rather than
//  the same point size at different apparent sizes.
//
import AVFoundation
import AppKit
import Foundation

enum ScreenroomVideoExport {

    enum Failure: LocalizedError {
        case noVideoTrack
        case noExportSession
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "That recording has no video in it."
            case .noExportSession:
                return "This Mac could not open an export session for that recording."
            case .exportFailed(let reason):
                return reason
            }
        }
    }

    static let annotatedFileName = "presentation-with-notes.mp4"
    static let subtitleFileName = "notes.srt"

    // MARK: Timing

    /// How long a note stays on screen: six seconds, cut short when the next
    /// note is due, never shorter than two and a half.
    ///
    /// Six because a note is one sentence and a sentence read while also
    /// watching a video takes longer than a sentence read on its own. The
    /// floor matters more than the ceiling: two notes typed nine seconds
    /// apart are a teacher reacting quickly, and the first one flashing past
    /// in half a second would be the one moment the student most needed to
    /// read.
    static let showSeconds: Double = 6
    static let minimumShowSeconds: Double = 2.5

    /// When each note appears and disappears, in seconds.
    ///
    /// Each one starts slightly BEFORE its timestamp for the reason that runs
    /// through all of Screenroom: a note is stamped at its first keystroke, so the
    /// thing it describes is already happening. Two seconds of lead means the
    /// student sees the sentence as the moment arrives rather than after it
    /// has gone.
    static let leadSeconds: Double = 2

    static func windows(for notes: [ScreenroomNote], duration: Double) -> [(note: ScreenroomNote, start: Double, end: Double)] {
        let ordered = notes.sorted { $0.atMs < $1.atMs }
        return ordered.enumerated().map { index, note in
            let start = max(0, Double(note.atMs) / 1000 - leadSeconds)
            var end = start + showSeconds
            if index + 1 < ordered.count {
                let next = max(0, Double(ordered[index + 1].atMs) / 1000 - leadSeconds)
                end = min(end, max(next, start + minimumShowSeconds))
            }
            if duration > 0 { end = min(end, duration) }
            return (note, start, max(start + 0.1, end))
        }
    }

    // MARK: Subtitles

    /// SubRip, because it is the format every player and YouTube already
    /// takes. WebVTT would be the more modern answer and QuickTime does not
    /// read it.
    static func subRip(for notes: [ScreenroomNote], duration: Double) -> String {
        windows(for: notes, duration: duration).enumerated().map { index, window in
            return """
            \(index + 1)
            \(subRipStamp(window.start)) --> \(subRipStamp(window.end))
            \(window.note.text)

            """
        }.joined(separator: "\n")
    }

    /// `00:06:40,000` - SubRip wants a comma before the milliseconds, not a
    /// full stop. A player given a full stop shows nothing and says nothing.
    static func subRipStamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - Double(Int(total))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    @discardableResult
    static func writeSubtitles(for notes: [ScreenroomNote], duration: Double,
                               in folder: URL) -> URL? {
        let text = subRip(for: notes, duration: duration)
        let target = folder.appendingPathComponent(subtitleFileName)
        guard (try? text.write(to: target, atomically: true, encoding: .utf8)) != nil else { return nil }
        return target
    }

    // MARK: Burned in

    /// Renders a new file with the notes drawn into the picture.
    ///
    /// Core Animation layers through AVVideoCompositionCoreAnimationTool,
    /// rather than drawing each frame by hand: the whole overlay is described
    /// once as layers and opacity animations, and AVFoundation renders it
    /// offline at whatever frame rate the export runs at. Drawing per frame
    /// would mean owning a render loop to produce a picture that does not
    /// Renders a new file with the notes drawn into the picture.
    ///
    /// Core Animation layers through AVVideoCompositionCoreAnimationTool,
    /// rather than drawing each frame by hand: the whole overlay is described
    /// once as layers and opacity animations, and AVFoundation renders it
    /// offline. Drawing per frame would mean owning a render loop to produce
    /// a picture that does not move.
    static func exportAnnotated(recording: URL,
                                notes: [ScreenroomNote],
                                presenter: String,
                                presentedAt: Date,
                                to output: URL,
                                onProgress: (@MainActor (Double) -> Void)? = nil) async throws -> URL {
        let asset = AVURLAsset(url: recording)
        guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack
        }
        let duration = (try? await asset.load(.duration)) ?? .zero
        let naturalSize = (try? await sourceVideo.load(.naturalSize)) ?? CGSize(width: 1280, height: 720)
        let transform = (try? await sourceVideo.load(.preferredTransform)) ?? .identity

        // The size the video actually PRESENTS at, not the size it is stored
        // at. A track recorded in portrait carries a rotation in its
        // transform, and laying the cards out against the stored size would
        // put them off the side of a rotated picture.
        let presented = naturalSize.applying(transform)
        let renderSize = CGSize(width: abs(presented.width).rounded(), height: abs(presented.height).rounded())

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noVideoTrack
        }
        let range = CMTimeRange(start: .zero, duration: duration)
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        videoTrack.preferredTransform = transform

        if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                        preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        }

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = range
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        // The layer tree the tool renders: the video underneath, everything
        // Screenroom draws on top.
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = false

        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        let overlay = overlayLayer(size: renderSize,
                                   notes: notes,
                                   presenter: presenter,
                                   presentedAt: presentedAt,
                                   duration: duration.seconds)
        parent.addSublayer(overlay)

        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)

        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // AVAssetExportSession refuses to write over an existing file.
        try? FileManager.default.removeItem(at: output)

        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.noExportSession
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.videoComposition = videoComposition

        // This one re-encodes, unlike the clip exporter, so it is the only
        // thing in Screenroom that takes minutes. Reported rather than hidden
        // behind a spinner - DESIGN.md asks that a wait say how much is left.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                onProgress?(Double(session.progress))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The completion-handler form, not the async export(to:as:) -
            // that one is macOS 15 and this app targets 14.
            session.exportAsynchronously { continuation.resume() }
        }
        ticker.cancel()

        guard session.status == .completed else {
            let reason = session.error?.localizedDescription ?? "The export stopped before it finished."
            try? FileManager.default.removeItem(at: output)
            throw Failure.exportFailed(reason)
        }
        return output
    }

    // MARK: The picture

    /// Everything drawn over the video: an opening card, then one note card
    /// at a time.
    static func overlayLayer(size: CGSize,
                             notes: [ScreenroomNote],
                             presenter: String,
                             presentedAt: Date,
                             duration: Double) -> CALayer {
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: size)

        let margin = (size.height * 0.055).rounded()
        let cardWidth = min(size.width - margin * 2, size.width * 0.66)

        if let opening = openingCard(size: size, margin: margin,
                                     presenter: presenter, presentedAt: presentedAt) {
            overlay.addSublayer(opening)
        }

        for window in windows(for: notes, duration: duration) {
            let card = noteCard(window.note, width: cardWidth, height: size.height)
            // Bottom-left, above the margin. Core Animation's origin is
            // bottom-left here, which is the one place in this app that is
            // true, so the card's y IS the margin rather than a subtraction.
            card.frame.origin = CGPoint(x: margin, y: margin)
            fade(card, from: window.start, to: window.end)
            overlay.addSublayer(card)
        }
        return overlay
    }

    /// Four seconds of who and when, so a file that gets forwarded still says
    /// what it is.
    static func openingCard(size: CGSize, margin: CGFloat,
                            presenter: String, presentedAt: Date) -> CALayer? {
        let name = presenter.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: name + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: size.height * 0.055, weight: .bold),
            .foregroundColor: NSColor.white,
        ]))
        text.append(NSAttributedString(string: presentedAt.formatted(.dateTime.day().month(.wide).year()), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: size.height * 0.024, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.75),
        ]))

        let card = card(with: text, width: size.width * 0.7, height: size.height)
        card.frame.origin = CGPoint(x: margin, y: (size.height - card.frame.height) / 2)
        fade(card, from: 0, to: 4)
        return card
    }

    static func noteCard(_ note: ScreenroomNote, width: CGFloat, height: CGFloat) -> CALayer {
        let text = NSMutableAttributedString()
        let stamp = note.offsetLabel
        text.append(NSAttributedString(string: stamp + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: height * 0.021, weight: .semibold),
            // The lime from the logo. It is barred as TEXT on white
            // (DESIGN.md: 2.25 contrast), which is not this situation - this
            // is a bright mark on a near-black card, where it is the same
            // role it plays as a fill everywhere else.
            .foregroundColor: NSColor(red: 0.47, green: 0.75, blue: 0.0, alpha: 1),
        ]))
        text.append(NSAttributedString(string: note.text, attributes: [
            .font: NSFont.systemFont(ofSize: height * 0.034, weight: .medium),
            .foregroundColor: NSColor.white,
        ]))
        return card(with: text, width: width, height: height)
    }

    /// A rounded near-black slab sized to its own text.
    ///
    /// Measured rather than fixed-height: a note is prose typed in a hurry
    /// and can be two words or three lines, and a card that clips the third
    /// line loses exactly the part the teacher went to the trouble of
    /// writing.
    static func card(with text: NSAttributedString, width: CGFloat, height: CGFloat) -> CALayer {
        let padding = (height * 0.022).rounded()
        let textWidth = width - padding * 2
        let bounds = text.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        let textHeight = ceil(bounds.height)

        let card = CALayer()
        card.frame = CGRect(x: 0, y: 0, width: width, height: textHeight + padding * 2)
        card.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        card.cornerRadius = height * 0.014
        card.opacity = 0

        let label = CATextLayer()
        label.string = text
        label.isWrapped = true
        label.alignmentMode = .left
        label.truncationMode = .none
        label.contentsScale = 1
        // Core Animation draws text top-down while the card's own geometry is
        // bottom-up, so the text layer is flipped inside the card rather than
        // the card being flipped inside the frame - flipping the card would
        // take the corner radius and the fade with it.
        label.isGeometryFlipped = true
        label.frame = CGRect(x: padding, y: padding, width: textWidth, height: textHeight)
        card.addSublayer(label)
        return card
    }

    /// Fades a card in and out at its two moments.
    ///
    /// `AVCoreAnimationBeginTimeAtZero`, not 0: Core Animation reads a
    /// beginTime of zero as "now", which during an offline render means the
    /// first card appears immediately and never leaves. The constant is the
    /// smallest time the renderer treats as a real zero.
    static func fade(_ layer: CALayer, from start: Double, to end: Double) {
        let fadeIn = CABasicAnimation(keyPath: "opacity")
        fadeIn.fromValue = 0
        fadeIn.toValue = 1
        fadeIn.beginTime = AVCoreAnimationBeginTimeAtZero + start
        fadeIn.duration = 0.3
        fadeIn.fillMode = .forwards
        fadeIn.isRemovedOnCompletion = false

        let fadeOut = CABasicAnimation(keyPath: "opacity")
        fadeOut.fromValue = 1
        fadeOut.toValue = 0
        fadeOut.beginTime = AVCoreAnimationBeginTimeAtZero + max(start + 0.4, end - 0.3)
        fadeOut.duration = 0.3
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false

        layer.add(fadeIn, forKey: "in")
        layer.add(fadeOut, forKey: "out")
    }
}
