import XCTest

final class AudioLevelMeterTests: XCTestCase {
    func testSilenceIsSilent() {
        var m = AudioLevelMeter()
        let zeros = [Int16](repeating: 0, count: 100)
        zeros.withUnsafeBufferPointer { m.add(int16: $0) }
        XCTAssertEqual(m.summary, "silent")
        XCTAssertEqual(m.sampleCount, 100)
    }

    func testFullScaleSquareIsAboutZeroDB() {
        var m = AudioLevelMeter()
        let loud = [Int16](repeating: Int16.min, count: 50)
        loud.withUnsafeBufferPointer { m.add(int16: $0) }
        XCTAssertEqual(m.peakDB, 0, accuracy: 0.001)
        XCTAssertEqual(m.rmsDB, 0, accuracy: 0.001)
    }

    func testHalfScaleFloatIsMinusSix() {
        var m = AudioLevelMeter()
        let half = [Float](repeating: -0.5, count: 10)
        half.withUnsafeBufferPointer { m.add(float32: $0) }
        XCTAssertEqual(m.peakDB, -6.02, accuracy: 0.01)
    }

    func testPeakVersusRms() {
        var m = AudioLevelMeter()
        let s: [Float] = [1, 0, 0, 0]
        s.withUnsafeBufferPointer { m.add(float32: $0) }
        XCTAssertEqual(m.peakDB, 0, accuracy: 0.001)
        XCTAssertEqual(m.rmsDB, -6.02, accuracy: 0.01)
    }

    func testResetClears() {
        var m = AudioLevelMeter()
        [Float(1)].withUnsafeBufferPointer { m.add(float32: $0) }
        m.reset()
        XCTAssertEqual(m.sampleCount, 0)
        XCTAssertEqual(m.summary, "silent")
    }

    func testMergeCombinesPeakAndEnergy() {
        var a = AudioLevelMeter(), b = AudioLevelMeter()
        [Float(0.5), 0.5].withUnsafeBufferPointer { a.add(float32: $0) }
        [Float(1), 0].withUnsafeBufferPointer { b.add(float32: $0) }
        a.merge(b)
        XCTAssertEqual(a.sampleCount, 4)
        XCTAssertEqual(a.peakDB, 0, accuracy: 0.001)
        XCTAssertEqual(a.rms, (1.5 / 4).squareRoot(), accuracy: 1e-9)
    }
}
