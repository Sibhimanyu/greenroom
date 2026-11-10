//
//  ClipRing.swift
//  Greenroom
//
//  The last few minutes of the class, as encoded segments held in memory.
//
//  Memory and not disk on purpose, same as OBS's replay buffer was: a teacher
//  who chose not to record a class of children should end that class with
//  nothing written down, and a buffer only becomes a file when a clip
//  shortcut is pressed. Five minutes at 6 Mbps plus audio is about 230 MB.
//
//  The writer cuts a segment at the first keyframe after its interval, so every
//  segment starts on a keyframe and can begin a file. An initialisation segment
//  plus any run of consecutive media segments, concatenated byte for byte, is
//  a valid fragmented MP4: "joined losslessly" costs nothing but a file write.
//

import AVFoundation
import Foundation

final class ClipRing: NSObject, AVAssetWriterDelegate {
    struct Segment {
        let data: Data
        let duration: Double
    }

    private let lock = NSLock()
    private var initialization: Data?
    private var segments: [Segment] = []
    private var received = 0
    private let window: Double
    private let fallbackDuration: Double

    init(window: TimeInterval, segmentInterval: TimeInterval) {
        self.window = window
        self.fallbackDuration = segmentInterval
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        lock.lock(); defer { lock.unlock() }
        switch segmentType {
        case .initialization:
            initialization = segmentData
        case .separable:
            let reported = segmentReport?.trackReports
                .first(where: { $0.mediaType == .video })?.duration.seconds
            let duration = (reported?.isFinite == true && reported! > 0) ? reported! : fallbackDuration
            segments.append(Segment(data: segmentData, duration: duration))
            received += 1
            // Keep the window, plus enough that the oldest kept segment still
            // reaches back to it.
            var total = segments.reduce(0) { $0 + $1.duration }
            while let first = segments.first, total - first.duration >= window {
                total -= first.duration
                segments.removeFirst()
            }
        @unknown default:
            break
        }
    }

    /// How many media segments have ever arrived; lets a caller wait for a flush.
    var receivedCount: Int { lock.lock(); defer { lock.unlock() }; return received }

    var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return segments.reduce(0) { $0 + $1.duration }
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        initialization = nil; segments = []
    }

    /// The newest segments covering at least `seconds` (or all there are),
    /// with the initialisation segment, written to `url`. Returns the length
    /// of what was written.
    func write(lastSeconds seconds: Double, to url: URL) throws -> Double {
        lock.lock()
        let head = initialization
        var picked: [Segment] = []
        var covered = 0.0
        for segment in segments.reversed() {
            picked.insert(segment, at: 0)
            covered += segment.duration
            if covered >= seconds { break }
        }
        lock.unlock()

        guard let head, !picked.isEmpty else { throw RecorderError.nothingBuffered }
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: head)
        for segment in picked { try handle.write(contentsOf: segment.data) }
        return covered
    }
}
