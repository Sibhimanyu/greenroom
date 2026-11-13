import XCTest
import CoreMedia

/// The pause arithmetic and the audio mix of phase 4 (docs/recorditor-integration/controls-port-log.md).
final class PauseClockTests: XCTestCase {

    func testNothingPausedLeavesTimeAlone() {
        let c = PauseClock()
        XCTAssertEqual(c.offset(at: 100), 0)
        XCTAssertEqual(c.fileTime(of: 105, firstFrame: 100), 5)
    }

    func testSamplesInsideAPauseAreDroppedAndLaterOnesMovedBack() {
        let c = PauseClock()
        c.pause(at: 110)
        XCTAssertNil(c.offset(at: 111), "paused: dropped")
        XCTAssertNil(c.offset(at: 114), "still paused: dropped")
        c.resume(at: 115)
        XCTAssertEqual(c.offset(at: 109.9), 0, "before the pause: untouched")
        XCTAssertNil(c.offset(at: 112), "inside the finished pause: dropped")
        XCTAssertEqual(c.offset(at: 115), 5, "at resume: moved back by the whole pause")
        XCTAssertEqual(c.fileTime(of: 120, firstFrame: 100), 15, "20 s of wall time, 5 s paused")
        // No gap: the last frame before the pause and the first after are adjacent.
        let before = c.fileTime(of: 109.97, firstFrame: 100)!
        let after = c.fileTime(of: 115.03, firstFrame: 100)!
        XCTAssertEqual(after - before, 0.06, accuracy: 1e-9)
    }

    func testPausesAddUp() {
        let c = PauseClock()
        c.pause(at: 10); c.resume(at: 12)
        c.pause(at: 20); c.resume(at: 23)
        XCTAssertEqual(c.offset(at: 30), 5)
        XCTAssertEqual(c.pausedSeconds(at: 30), 5)
        c.pause(at: 40)
        XCTAssertEqual(c.pausedSeconds(at: 44), 9, "a pause in progress counts up to now")
        XCTAssertEqual(c.currentPauseBegin, 40)
    }

    func testALateSampleIsJudgedByItsOwnStamp() {
        // A microphone buffer handled after the pause began, but heard before it.
        let c = PauseClock()
        c.pause(at: 50); c.resume(at: 60)
        XCTAssertEqual(c.offset(at: 49.99), 0)
        XCTAssertEqual(c.offset(at: 60.01), 10)
    }

    func testPauseAndResumeAreIdempotent() {
        let c = PauseClock()
        XCTAssertFalse(c.resume(at: 1), "nothing to resume")
        XCTAssertTrue(c.pause(at: 2))
        XCTAssertFalse(c.pause(at: 3), "already paused")
        XCTAssertTrue(c.resume(at: 4))
        XCTAssertEqual(c.pausedSeconds(at: 10), 2)
        c.reset()
        XCTAssertEqual(c.pausedSeconds(at: 10), 0)
        XCTAssertFalse(c.isPaused)
    }

    func testOldPausesAreFoldedWithoutChangingTheAnswer() {
        let c = PauseClock()
        for i in 0..<50 { c.pause(at: Double(i) * 100); c.resume(at: Double(i) * 100 + 1) }
        XCTAssertEqual(c.offset(at: 6_000), 50)
        XCTAssertEqual(c.pausedSeconds(at: 6_000), 50)
    }

    func testRetimedMovesThePresentationStamp() throws {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(seconds: 20, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: 16, height: 16,
                                       extensions: nil, formatDescriptionOut: &format)
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true,
                                          makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                          sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                          sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer)
        XCTAssertEqual(status, noErr)
        let moved = try XCTUnwrap(PauseClock.retimed(try XCTUnwrap(buffer), by: 5))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(moved).seconds, 15, accuracy: 1e-6)
        XCTAssertEqual(PauseClock.shifted(CMTime(seconds: 20, preferredTimescale: 1_000_000_000), by: 5).seconds, 15, accuracy: 1e-9)
    }
}

final class AudioMixerTests: XCTestCase {
    private let rate = AudioMixer.sampleRate

    /// `frames` of a constant value, interleaved stereo.
    private func tone(_ value: Float, frames: Int) -> [Float] { [Float](repeating: value, count: frames * 2) }

    private func collect(_ mixer: AudioMixer) -> () -> [AudioMixer.Chunk] {
        var chunks: [AudioMixer.Chunk] = []
        mixer.onChunk = { chunks.append($0) }
        return { chunks }
    }

    func testOneSourceComesOutUnchangedAndStampedOnTheGrid() {
        let m = AudioMixer(); let got = collect(m)
        // 1 s of mic in 10 ms pieces.
        for i in 0..<100 { m.add(tone(0.25, frames: 480), at: 1000 + Double(i) * 0.01, from: .microphone) }
        m.flush()
        let chunks = got()
        XCTAssertEqual(chunks.reduce(0) { $0 + $1.frames }, 48_000)
        XCTAssertEqual(chunks.first?.start ?? -1, 1000, accuracy: 1e-9)
        XCTAssertEqual(chunks[10].start, 1000.1, accuracy: 1e-9)
        XCTAssertTrue(chunks.allSatisfy { $0.samples.allSatisfy { $0 == 0.25 } })
    }

    func testTwoSourcesAreAddedWhereTheirStampsSay() {
        let m = AudioMixer(); let got = collect(m)
        // Mic 0.0 to 1.0 s at 0.25. System joins at 0.5 s with 0.5.
        // Arriving in time order, as they do live (output is held back 150 ms).
        for i in 0..<100 {
            m.add(tone(0.25, frames: 480), at: 2000 + Double(i) * 0.01, from: .microphone)
            if i >= 50 { m.add(tone(0.5, frames: 480), at: 2000 + Double(i) * 0.01, from: .system) }
        }
        m.flush()
        let all = got().flatMap(\.samples)
        XCTAssertEqual(all.count, 48_000 * 2)
        XCTAssertEqual(all[2 * 10_000], 0.25, accuracy: 1e-6, "before the system sound: mic only")
        XCTAssertEqual(all[2 * 30_000], 0.75, accuracy: 1e-6, "after: the sum")
        XCTAssertEqual(all[2 * 23_990], 0.25, accuracy: 1e-6, "the join is at 0.5 s, not 10 ms early")
        XCTAssertEqual(all[2 * 24_010], 0.75, accuracy: 1e-6)
    }

    func testASilentSourceDoesNotStallTheOther() {
        let m = AudioMixer(); let got = collect(m)
        m.add(tone(0.1, frames: 480), at: 0, from: .system)       // one buffer, then nothing
        for i in 0..<100 { m.add(tone(0.2, frames: 480), at: Double(i) * 0.01, from: .microphone) }
        XCTAssertGreaterThan(got().count, 80, "output keeps flowing while the system source is quiet")
    }

    func testAGapIsFilledWithSilenceAndSumsClip() {
        let m = AudioMixer(); let got = collect(m)
        m.add(tone(0.9, frames: 4_800), at: 10, from: .microphone)
        m.add(tone(0.9, frames: 4_800), at: 10, from: .system)
        m.add(tone(0.1, frames: 4_800), at: 10.2, from: .microphone)   // 100 ms gap after the first 100 ms
        m.flush()
        let all = got().flatMap(\.samples)
        XCTAssertEqual(all[2 * 1_000], 1, "0.9 + 0.9 clips at full scale")
        XCTAssertEqual(all[2 * 7_000], 0, "the gap is silence")
        XCTAssertEqual(all[2 * 11_000], 0.1, accuracy: 1e-6)
    }

    func testBufferConversionRoundTrips() throws {
        let samples: [Float] = (0..<960).map { Float($0 % 7) / 10 }
        let stamp = CMTime(value: 48_000 * 5, timescale: 48_000)
        let buffer = try XCTUnwrap(AudioMixer.sampleBuffer(samples: samples, at: stamp))
        let back = try XCTUnwrap(AudioMixer.floats(from: buffer))
        XCTAssertEqual(back.samples, samples)
        XCTAssertEqual(back.time, 5, accuracy: 1e-9)
    }
}
