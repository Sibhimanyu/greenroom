//
//  ScreenroomPresence.swift
//  Greenroom
//
//  What the recording shows, counted rather than described.
//
//  Speech tools of this shape report an "eye contact" figure from the
//  webcam. This is the same measurement done honestly, and the difference is
//  worth stating because the report prints it:
//
//   - **This measures head direction, not gaze.** Vision gives the yaw of a
//     detected face. It does not tell you where the eyes are pointed. A
//     presenter can face the camera squarely while reading the ceiling, and
//     nothing here would notice. So the number is called FACING THE ROOM
//     everywhere it appears, never eye contact, and the report says what it
//     is measured from.
//   - **A gap is not a failure.** No face in a frame usually means they
//     turned to the screen behind them, which is a normal thing to do and
//     sometimes the right one. The figure is reported; the judgement is not.
//
//  Gesture is the other half, and it is the part the commercial tools do not
//  do at all - they ask a model to comment on it from stills, which is a
//  guess wearing a number. Vision's body-pose request gives wrist, elbow and
//  shoulder positions per frame, so "how much did the hands move" and "were
//  they visible above the waist" are measurable rather than inferred. Both
//  are reported as they are: movement, not quality. Whether a gesture helped
//  is a judgement that belongs to the teacher's notes.
//
//  Everything runs on this Mac through the Vision framework. Nothing leaves.
//
import AVFoundation
import CoreGraphics
import Foundation
import Vision

struct ScreenroomPresence: Codable, Hashable {

    var v: Int = 1
    var generatedAt: Date = Date()

    /// How often the video was looked at, in milliseconds.
    var everyMs: Int = ScreenroomPresence.everyMs

    var samples: [Sample] = []

    /// One look at one frame. Small on purpose: a twenty-minute talk is six
    /// hundred of these and they sit in the session folder forever.
    struct Sample: Codable, Hashable, Identifiable {
        var atMs: Int
        /// A face was found at all.
        var face: Bool
        /// That face was turned within `facingDegrees` of the camera.
        var facing: Bool
        /// A body was found at all. The gesture figures mean nothing
        /// without this: a head-and-shoulders webcam shot never shows a
        /// wrist, and "0% hands up" would read as a verdict on a presenter
        /// whose hands were simply out of frame.
        var body: Bool = false
        /// Both a body and at least one wrist above the hips.
        var hands: Bool
        /// How far the wrists moved since the previous sample, in frame
        /// widths. Zero when there was nothing to compare against.
        var motion: Double
        var id: Int { atMs }
    }

    // MARK: The figures the report prints

    var sampleCount: Int { samples.count }

    /// Of the frames where a face was found, how many were turned towards
    /// the camera. The denominator is deliberately "frames with a face"
    /// rather than all frames: turning to the screen is not the same failure
    /// as facing the wall, and averaging them together hides both.
    var facingRatio: Double {
        let seen = samples.filter(\.face)
        guard !seen.isEmpty else { return 0 }
        return Double(seen.filter(\.facing).count) / Double(seen.count)
    }

    /// How much of the recording had the presenter in shot at all.
    var onCameraRatio: Double {
        guard !samples.isEmpty else { return 0 }
        return Double(samples.filter(\.face).count) / Double(samples.count)
    }

    /// Whether the framing showed enough of the presenter to say anything
    /// about their hands. Below a tenth of the frames, it did not.
    var sawBody: Bool {
        guard !samples.isEmpty else { return false }
        return Double(samples.filter(\.body).count) / Double(samples.count) >= 0.1
    }

    /// How much of the time the hands were up and in the picture, measured
    /// against the frames a body was found in rather than against all of
    /// them. Nil when the framing never showed one.
    var gestureRatio: Double? {
        let bodies = samples.filter(\.body)
        guard sawBody, !bodies.isEmpty else { return nil }
        return Double(bodies.filter(\.hands).count) / Double(bodies.count)
    }

    /// Distinct hand movements a minute. A gesture is a run of samples over
    /// the movement threshold, so a single sweep of the arm counts once
    /// however many frames it spans.
    var gesturesPerMinute: Double? {
        guard sawBody,
              let span = samples.last.map({ Double($0.atMs) / 60_000 }), span > 0.01 else { return nil }
        var bursts = 0
        var inside = false
        for sample in samples {
            if sample.motion >= Self.movementThreshold {
                if !inside { bursts += 1; inside = true }
            } else {
                inside = false
            }
        }
        return Double(bursts) / span
    }

    /// The longest continuous stretch with the face turned away or absent,
    /// as (start, length) in milliseconds. Nil when there is nothing over
    /// `awayWorthNamingMs`.
    var longestAway: (startMs: Int, lengthMs: Int)? {
        var best: (Int, Int)?
        var runStart: Int?
        var last = 0
        for sample in samples {
            if sample.facing {
                if let start = runStart {
                    let length = last - start
                    if length > (best?.1 ?? 0) { best = (start, length) }
                    runStart = nil
                }
            } else if runStart == nil {
                runStart = sample.atMs
            }
            last = sample.atMs + everyMs
        }
        if let start = runStart {
            let length = last - start
            if length > (best?.1 ?? 0) { best = (start, length) }
        }
        guard let best, best.1 >= Self.awayWorthNamingMs else { return nil }
        return (best.0, best.1)
    }

    /// Plain sentences for the brief and the export, same contract as
    /// ScreenroomSpeechMetrics.sentences: figures, never verdicts.
    var sentences: [String] {
        guard !samples.isEmpty else { return [] }
        var out: [String] = []
        out.append("Facing the room \(Int((facingRatio * 100).rounded()))% of the frames a face was found in, measured from head direction every \(everyMs / 1000) seconds. This is head direction, not gaze: it cannot tell you where the eyes were pointed.")
        out.append("In shot for \(Int((onCameraRatio * 100).rounded()))% of the recording.")
        if let away = longestAway {
            out.append("Longest stretch turned away or out of shot: \(String(format: "%.0f", Double(away.lengthMs) / 1000))s from \(Self.clock(away.startMs)).")
        }
        if let ratio = gestureRatio, let rate = gesturesPerMinute {
            out.append("Hands visible and raised in \(Int((ratio * 100).rounded()))% of the frames a body was found in, with about \(String(format: "%.1f", rate)) distinct hand movements a minute. Movement only \u{2014} whether a gesture helped is not measured.")
        } else {
            out.append("Nothing can be said about hands or gesture: the framing is too tight for Vision to find a body, so the wrists are never in shot. Do not comment on gesture.")
        }
        return out
    }

    private static func clock(_ ms: Int) -> String {
        let s = max(0, ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: The thresholds, stated so they can be argued with

    /// Two seconds between looks. Dense enough that a timeline strip reads
    /// as a strip rather than as dots, and coarse enough that a twenty-minute
    /// talk is six hundred Vision passes rather than three thousand.
    static let everyMs = 2_000

    /// How far off-centre a head may be turned and still count as facing the
    /// room. Twenty degrees is roughly the span of an audience from a
    /// lectern, so a presenter working the room reads as facing it.
    static let facingDegrees: Double = 20

    /// Wrist movement between samples, as a fraction of frame width, that
    /// counts as a hand movement rather than as standing still.
    static let movementThreshold: Double = 0.04

    /// Below this, looking away is reading a note. Above it, it is a stretch.
    static let awayWorthNamingMs = 8_000

    /// Frames are scaled to this long edge before Vision sees them. Face and
    /// body detection do not need more, and the whole pass is bounded by how
    /// many pixels go through it.
    static let longEdge: CGFloat = 640

    // MARK: The pass

    /// Walks the recording, two seconds at a time, and counts what is there.
    ///
    /// Sequential rather than concurrent on purpose: the image generator
    /// decodes forwards, and asking it for frames out of order costs more
    /// than the Vision work it would parallelise.
    static func measure(recording: URL,
                        onProgress: (@MainActor (Int, Int) -> Void)? = nil) async throws -> ScreenroomPresence {
        let asset = AVURLAsset(url: recording)
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        guard duration > 0 else { return ScreenroomPresence() }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: longEdge, height: longEdge)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var times: [Double] = []
        var at: Double = 0
        while at < duration {
            times.append(at)
            at += Double(everyMs) / 1000
        }

        let faces = VNDetectFaceRectanglesRequest()
        // Yaw only exists from revision 3 onwards, and the default revision
        // is whatever the OS picked. Asking for it explicitly is the
        // difference between a facing figure and a silent zero.
        if VNDetectFaceRectanglesRequest.supportedRevisions.contains(VNDetectFaceRectanglesRequestRevision3) {
            faces.revision = VNDetectFaceRectanglesRequestRevision3
        }
        let bodies = VNDetectHumanBodyPoseRequest()

        var samples: [Sample] = []
        var previousWrists: [CGPoint] = []

        for (index, seconds) in times.enumerated() {
            if Task.isCancelled { break }
            if let report = onProgress { await report(index, times.count) }
            guard let cg = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                                      actualTime: nil) else { continue }
            let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
            try? handler.perform([faces, bodies])

            // The biggest face, on the assumption that the presenter is the
            // one nearest the camera. A room with two faces in it is a
            // different feature.
            let face = (faces.results ?? []).max { left, right in
                left.boundingBox.width * left.boundingBox.height
                    < right.boundingBox.width * right.boundingBox.height
            }
            var facing = false
            if let face {
                // Vision reports yaw in radians and only from revision 3
                // onwards. A face with no yaw is counted as present but not
                // facing, rather than silently as facing, which would turn a
                // missing capability into a flattering number.
                let yaw = abs((face.yaw?.doubleValue ?? .pi) * 180 / .pi)
                facing = yaw <= facingDegrees
            }

            let body = (bodies.results ?? []).first
            var wrists: [CGPoint] = []
            var handsUp = false
            if let body, let points = try? body.recognizedPoints(.all) {
                // The hip line, when Vision is confident about it. When it is
                // not - which is most seated or tightly framed shots - fall
                // back to the middle of the frame rather than dropping the
                // measurement entirely.
                var hipLine: CGFloat = 0.45
                if let root = points[.root], root.confidence > 0.3 { hipLine = root.location.y }
                for joint in [VNHumanBodyPoseObservation.JointName.leftWrist, .rightWrist] {
                    guard let point = points[joint], point.confidence > 0.3 else { continue }
                    wrists.append(point.location)
                    // Vision's y runs up from the bottom, so "above the
                    // hips" is a greater y, not a smaller one.
                    if point.location.y > hipLine { handsUp = true }
                }
            }

            var motion: Double = 0
            if !wrists.isEmpty, wrists.count == previousWrists.count {
                let moved = zip(wrists, previousWrists).map { now, before in
                    hypot(now.x - before.x, now.y - before.y)
                }
                motion = moved.max() ?? 0
            }
            previousWrists = wrists

            samples.append(Sample(atMs: Int(seconds * 1000),
                                  face: face != nil,
                                  facing: facing,
                                  body: body != nil,
                                  hands: handsUp,
                                  motion: motion))
        }
        if let report = onProgress { await report(times.count, times.count) }

        var presence = ScreenroomPresence()
        presence.samples = samples
        return presence
    }

    // MARK: Disk

    static let fileName = "presence.json"

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load(in folder: URL) -> ScreenroomPresence? {
        guard let data = try? Data(contentsOf: url(in: folder)),
              let decoded = try? decoder.decode(ScreenroomPresence.self, from: data),
              !decoded.samples.isEmpty else { return nil }
        return decoded
    }

    @discardableResult
    func save(in folder: URL) -> Bool {
        guard !samples.isEmpty, let data = try? Self.encoder.encode(self) else { return false }
        return (try? data.write(to: Self.url(in: folder), options: .atomic)) != nil
    }
}
