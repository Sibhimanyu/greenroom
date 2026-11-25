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
    /// to grow without bound (a 4K Stage is already 4x the 1080p rate).
    static let minimumAverage = 1_000_000
    private static let maxRatio = 4.0

    /// Crash safety depends on these two staying equal: a keyframe at the
    /// start of every fragment, so every fragment plays by itself.
    static let keyframeSeconds: Double = 2
    static let fragmentSeconds: Double = 2

    static let audioBitrate = 128_000

    private static func ratio(_ size: CGSize) -> Double {
        Double(size.width * size.height) / referencePixels
    }

    static func averageBitrate(for size: CGSize) -> Int {
        let scaled = Int((referenceAverage * min(ratio(size), maxRatio)).rounded())
        return max(scaled, minimumAverage)
    }

    static func peakBitrate(for size: CGSize) -> Int {
        let scaled = Int((referencePeak * min(ratio(size), maxRatio)).rounded())
        return max(scaled, Int((Double(minimumAverage) * referencePeak / referenceAverage).rounded()))
    }

    /// `kVTCompressionPropertyKey_DataRateLimits`: bytes allowed in a window of seconds.
    static func dataRateLimit(for size: CGSize) -> (bytes: Int, seconds: Int) {
        (peakBitrate(for: size) / 8, 1)
    }
}
