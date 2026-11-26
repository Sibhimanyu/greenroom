//
//  StartStepProofTests.swift
//  GreenroomTests
//
//  The Recording and Tiling steps of a meeting start go green only on proof:
//  the first frame in the file, and the placement pass run to its end. Asking
//  for them is not enough.
//
import XCTest

final class StartStepProofTests: XCTestCase {

    func testRecordingIsDoneOnlyOnceAFrameIsInTheFile() {
        XCTAssertEqual(StartChoreography.recordingStep(rolling: true, firstFrameWritten: true, waited: 0.2), .done)
        XCTAssertEqual(StartChoreography.recordingStep(rolling: true, firstFrameWritten: false, waited: 0.2), .waiting,
                       "a take that began but has written nothing is not done")
        XCTAssertEqual(StartChoreography.recordingStep(rolling: false, firstFrameWritten: false, waited: 0.2), .waiting)
    }

    func testRecordingWithNoFrameInTimeFailsInWords() {
        let limit = StartChoreography.recordingProofSeconds
        guard case .failed(let words) = StartChoreography.recordingStep(rolling: true, firstFrameWritten: false, waited: limit) else {
            return XCTFail("no frame in \(limit) s must fail the step")
        }
        XCTAssertTrue(words.contains("recording"), words)
        guard case .failed = StartChoreography.recordingStep(rolling: false, firstFrameWritten: false, waited: limit) else {
            return XCTFail("a take that never began must fail the step")
        }
    }

    func testTilingIsDoneOnlyWhenThePlacementPassFinished() {
        XCTAssertEqual(StartChoreography.tilingStep(placementFinished: true), .done)
        guard case .failed(let words) = StartChoreography.tilingStep(placementFinished: false) else {
            return XCTFail("a placement pass that did not run is not done")
        }
        XCTAssertTrue(words.contains("windows"), words)
    }
}
