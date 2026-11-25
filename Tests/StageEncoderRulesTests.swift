import XCTest

/// The recording's bitrate numbers (smaller files, 2026-11-25).
final class StageEncoderRulesTests: XCTestCase {

    func test1080pAverageIsThreePointFiveMbpsAndPeakSix() {
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(StageEncoderRules.averageBitrate(for: size), 3_500_000)
        XCTAssertEqual(StageEncoderRules.peakBitrate(for: size), 6_000_000)
    }

    func test720pScalesWithPixelCount() {
        let size = CGSize(width: 1280, height: 720)
        // 720p is 4/9 of 1080p's pixels.
        XCTAssertEqual(StageEncoderRules.averageBitrate(for: size), 1_555_555, accuracy: 2)
        XCTAssertEqual(StageEncoderRules.peakBitrate(for: size), 2_666_666, accuracy: 2)
    }

    // R12.2 (owner bug list): a 4K picture averages at most 12 Mbps, and the peak stays
    // 1.7 times the average at every size, so the cap does not grow past it (it was 24 Mbps at 4K).
    func test4KAveragesTwelveAndItsPeakStaysAboutOnePointSevenTimesThat() {
        let size = CGSize(width: 3840, height: 2160)
        XCTAssertEqual(StageEncoderRules.averageBitrate(for: size), 12_000_000)
        XCTAssertEqual(Double(StageEncoderRules.peakBitrate(for: size)), 12_000_000 * 1.7, accuracy: 0.02 * 12_000_000)
        XCTAssertLessThan(StageEncoderRules.peakBitrate(for: size), 21_000_000)
    }

    func testThePeakIsAlwaysAboutOnePointSevenTimesTheAverage() {
        for size in [CGSize(width: 160, height: 90), CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080),
                     CGSize(width: 2560, height: 1440), CGSize(width: 3840, height: 2160), CGSize(width: 7680, height: 4320)] {
            let ratio = Double(StageEncoderRules.peakBitrate(for: size)) / Double(StageEncoderRules.averageBitrate(for: size))
            XCTAssertEqual(ratio, 1.7, accuracy: 0.02, "\(size)")
        }
    }

    func testTinyAndHugeStagesAreClamped() {
        XCTAssertEqual(StageEncoderRules.averageBitrate(for: CGSize(width: 160, height: 90)),
                       StageEncoderRules.minimumAverage)
        XCTAssertEqual(StageEncoderRules.averageBitrate(for: CGSize(width: 7680, height: 4320)),
                       StageEncoderRules.averageBitrate(for: CGSize(width: 3840, height: 2160)))
    }

    func testPeakIsAlwaysAboveAverage() {
        for size in [CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080),
                     CGSize(width: 2560, height: 1440), CGSize(width: 3840, height: 2160)] {
            XCTAssertGreaterThan(StageEncoderRules.peakBitrate(for: size),
                                 StageEncoderRules.averageBitrate(for: size))
        }
    }

    func testDataRateLimitIsBytesPerSecond() {
        let limit = StageEncoderRules.dataRateLimit(for: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(limit.bytes, 750_000)   // 6 Mbps / 8
        XCTAssertEqual(limit.seconds, 1)
    }

    func testAudioIs128kbps() {
        XCTAssertEqual(StageEncoderRules.audioBitrate, 128_000)
    }

    func testKeyframesAndFragmentsStayAtTwoSeconds() {
        XCTAssertEqual(StageEncoderRules.keyframeSeconds, 2)
        XCTAssertEqual(StageEncoderRules.fragmentSeconds, 2)
    }
}
