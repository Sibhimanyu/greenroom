//
//  PreviewFpsLog.swift
//  Greenroom
//
//  DEBUG only (Debug UI never ships): once a second, one line saying how many
//  compositor ticks, preview pictures and camera frames the last second held.
//  Read it with
//      log stream --predicate 'category == "preview-fps"'
//  Ticks near 30 with pictures far below: the preview sink. Camera far below
//  ticks: the camera or Vision. See docs/specs/live-preview-smoothness.md (R6).
//
#if DEBUG
import Foundation
import os

enum PreviewFpsLog {
    enum Counter { case tick, picture, camera }

    private static let logger = Logger(subsystem: "com.sibhimanyu.greenroom", category: "preview-fps")
    private static let lock = NSLock()
    private static var counts: [Counter: Int] = [:]
    private static var windowStart = ProcessInfo.processInfo.systemUptime

    /// Counts one event; callable from any thread. The first event after a
    /// second has passed writes the line and starts the next second.
    static func count(_ counter: Counter) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        counts[counter, default: 0] += 1
        var line: String?
        if now - windowStart >= 1 {
            line = "ticks=\(counts[.tick] ?? 0) pictures=\(counts[.picture] ?? 0) camera=\(counts[.camera] ?? 0)"
            counts = [:]
            windowStart = now
        }
        lock.unlock()
        if let line { logger.notice("\(line, privacy: .public)") }
    }
}
#endif
