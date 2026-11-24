import XCTest

final class CameraAimRulesTests: XCTestCase {

    private func run(_ readings: [AimMeter.Reading?], step: Double = 0.3) -> AimMeter.Outcome {
        var meter = AimMeter()
        var outcome = AimMeter.Outcome.measuring
        for reading in readings {
            if let reading { meter.note(reading) }
            outcome = meter.advance(by: step)
            if outcome != .measuring { return outcome }
        }
        return outcome
    }

    func testThreeSteadyAnglesEndTheAimWithTheirMedian() {
        XCTAssertEqual(run([.angle(40), .angle(10), .angle(12), .angle(14)]), .angle(12))
    }

    func testAnUnsteadyAngleKeepsMeasuringUntilTheClock() {
        XCTAssertEqual(run([.angle(5), .angle(40), .angle(5)]), .measuring)
        var meter = AimMeter()
        for angle in [5.0, 40, 5] { meter.note(.angle(angle)); _ = meter.advance(by: 0.3) }
        XCTAssertEqual(meter.advance(by: AimMeter.maxSeconds), .angle(5))
    }

    func testNoFrameAtAllIsNoPictureAfterThreeSeconds() {
        var meter = AimMeter()
        XCTAssertEqual(meter.advance(by: 2.9), .measuring)
        XCTAssertEqual(meter.advance(by: 0.2), .noPicture)
    }

    func testPicturesWithNobodyEndAsNoFaceAtTheClock() {
        var meter = AimMeter()
        meter.note(.noFace)
        XCTAssertEqual(meter.advance(by: 4), .measuring)
        XCTAssertEqual(meter.advance(by: 1.1), .noFace)
    }

    func testAMissingYawEndsAsNoAngle() {
        var meter = AimMeter()
        meter.note(.noAngle)
        XCTAssertEqual(meter.advance(by: AimMeter.maxSeconds), .noAngle)
    }

    func testLosingTheFaceBreaksASteadyRun() {
        var meter = AimMeter()
        meter.note(.angle(10)); meter.note(.angle(11)); meter.note(.noFace); meter.note(.angle(12))
        XCTAssertEqual(meter.advance(by: 0.3), .measuring)
    }

    func testMedianOfSpread() {
        XCTAssertEqual(AimMeter.median([30, 10, 20]), 20)
    }

    func testSidewaysFaceNeedsAnotherLook() {
        XCTAssertTrue(FaceUpright.isSideways(rollDegrees: 85))
        XCTAssertTrue(FaceUpright.isSideways(rollDegrees: -90))
        XCTAssertFalse(FaceUpright.isSideways(rollDegrees: 20))
    }

    func testMostUprightLookWinsAndTiesGoToTheOriginal() {
        XCTAssertEqual(FaceUpright.mostUpright([88, 3, 90, 177]), 1)
        XCTAssertEqual(FaceUpright.mostUpright([nil, 80, 4, nil]), 2)
        XCTAssertEqual(FaceUpright.mostUpright([5, 5, 5, 5]), 0)
        XCTAssertNil(FaceUpright.mostUpright([nil, nil]))
    }
}
