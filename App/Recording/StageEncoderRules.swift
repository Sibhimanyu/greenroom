//
//  StageEncoderRules.swift
//  Greenroom
//
//  The numbers behind the recording's encoder settings, pure so they can be
//  tested. `StageEncoder` reads them; nothing here touches AVFoundation.
//
//  Chosen 2026-11-25 to make recordings smaller: a busy 1080p recording was
//  about 45 MB a minute at 6 Mbps. Now 3.5 Mbps average with a 6 Mbps cap over
//  any one second, so a burst of motion cannot balloon a stretch of the file.
//
import CoreGraphics
import Foundation

enum StageEncoderRules {
    static let referencePixels: Double = 1920 * 1080
    static let referenceAverage: Double = 3_500_000
    static let referencePeak: Double = 6_000_000

    /// A tiny Stage still gets a watchable picture; a huge one is not allowed
    /// to grow without bound: the average stops at 12 Mbps (reached at 4K).
    static let minimumAverage = 1_000_000
    static let maximumAverage = 12_000_000
    /// The peak is a fixed multiple of the average (about 1.7), so its cap never grows
    /// faster than the picture's own rate does.
    static let peakToAverage = referencePeak / referenceAverage

    /// Crash safety depends on these two staying equal: a keyframe at the
    /// start of every fragment, so every fragment plays by itself.
    static let keyframeSeconds: Double = 2
    static let fragmentSeconds: Double = 2

    static let audioBitrate = 128_000

    private static func ratio(_ size: CGSize) -> Double {
        Double(size.width * size.height) / referencePixels
    }

    static func averageBitrate(for size: CGSize) -> Int {
        let scaled = Int((referenceAverage * ratio(size)).rounded())
        return min(max(scaled, minimumAverage), maximumAverage)
    }

    static func peakBitrate(for size: CGSize) -> Int {
        Int((Double(averageBitrate(for: size)) * peakToAverage).rounded())
    }

    /// `kVTCompressionPropertyKey_DataRateLimits`: bytes allowed in a window of seconds.
    static func dataRateLimit(for size: CGSize) -> (bytes: Int, seconds: Int) {
        (peakBitrate(for: size) / 8, 1)
    }
}
