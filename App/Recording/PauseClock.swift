// Pause arithmetic ported from Recorditor (ZRecorditor @7210322,
// native/MacRecorder/Recording/ScreenRecorder.swift: timeOffset / pauseBegan /
// timingSnapshot / retimed(_:by:)), reshaped so it can be tested on its own.
//
//  PauseClock.swift
//  Greenroom
//
//  Pause without gaps. The writer is never stopped; while paused every sample
//  is dropped, and every sample after the pause is moved back in time by the
//  total length of the pauses before it, so the file is one continuous
//  stretch: no frozen picture, no silence, audio and video still in step.
//
//  Upstream snapshots "paused? offset?" at the moment a sample ARRIVES. This
//  keeps the pauses themselves (host-clock intervals) and decides by the
//  sample's own timestamp instead. A microphone buffer that is a few
//  milliseconds late is then still judged against the instant it was heard,
//  not the instant it was handled, and video and audio can never disagree
//  about which side of a pause a moment fell on.
//
//  Thread safe (one lock). No app-only dependencies: the tests compile this
//  file as it is.
//

import CoreMedia
import Foundation

final class PauseClock {
    /// A pause: from `begin`, to `end` (nil while it is still going).
    private struct Pause { var begin: Double; var end: Double? }

    private let lock = NSLock()
    /// Pauses that ended long ago, folded into one number so the list stays short.
    private var foldedOffset = 0.0
    private var pauses: [Pause] = []
    /// The newest timestamp asked about; pauses that ended well before it are folded.
    private var newest = -Double.infinity
    private static let foldAfter = 30.0

    init() {}

    /// Forget every pause (a new recording).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        foldedOffset = 0
        pauses = []
        newest = -.infinity
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return pauses.last.map { $0.end == nil } ?? false
    }

    /// When the pause in progress began, nil when not paused.
    var currentPauseBegin: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let last = pauses.last, last.end == nil else { return nil }
        return last.begin
    }

    /// Starts a pause at host time `at` (seconds). False when one is already running.
    @discardableResult
    func pause(at: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = pauses.last, last.end == nil { return false }
        pauses.append(Pause(begin: at, end: nil))
        return true
    }

    /// Ends the running pause at host time `at`. False when none was running.
    @discardableResult
    func resume(at: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = pauses.indices.last, pauses[i].end == nil else { return false }
        pauses[i].end = max(at, pauses[i].begin)
        return true
    }

    /// What to do with a sample stamped `time` (host-clock seconds): nil when
    /// it falls inside a pause (drop it), otherwise how far to move it back.
    func offset(at time: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        if time > newest { newest = time }
        var total = foldedOffset
        for pause in pauses {
            if time < pause.begin { break }
            guard let end = pause.end else { return nil }       // still paused
            if time < end { return nil }                         // inside this pause
            total += end - pause.begin
        }
        fold()
        return total
    }

    /// Total paused seconds up to host time `now` (a pause in progress counts
    /// up to `now`). The recording's length is the wall time minus this.
    func pausedSeconds(at now: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        var total = foldedOffset
        for pause in pauses {
            if now <= pause.begin { break }
            total += min(pause.end ?? now, now) - pause.begin
        }
        return total
    }

    /// Where `time` falls in the file: `time - firstFrame - paused`, nil in a pause.
    func fileTime(of time: Double, firstFrame: Double) -> Double? {
        offset(at: time).map { time - firstFrame - $0 }
    }

    private func fold() {
        // Called with the lock held. Pauses that finished long before the
        // newest timestamp can no longer matter to a sample that is still in flight.
        while let first = pauses.first, let end = first.end, end < newest - Self.foldAfter {
            foldedOffset += end - first.begin
            pauses.removeFirst()
        }
    }

    // MARK: Sample buffers

    /// A copy of `buffer` with its timestamps moved back by `offset` seconds.
    /// Upstream's `retimed(_:by:)`, with the offset in seconds. Nil if the copy fails.
    static func retimed(_ buffer: CMSampleBuffer, by offset: Double) -> CMSampleBuffer? {
        guard offset != 0 else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return buffer }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        let shift = CMTime(seconds: offset, preferredTimescale: 48_000)
        for i in 0..<count {
            infos[i].presentationTimeStamp = CMTimeSubtract(infos[i].presentationTimeStamp, shift)
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeSubtract(infos[i].decodeTimeStamp, shift)
            }
        }
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: count, sampleTimingArray: &infos, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    /// `time` moved back by `offset` seconds, on the same timescale as a frame.
    static func shifted(_ time: CMTime, by offset: Double) -> CMTime {
        guard offset != 0 else { return time }
        return CMTimeSubtract(time, CMTime(seconds: offset, preferredTimescale: max(time.timescale, 600)))
    }
}
