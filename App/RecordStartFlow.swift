//
//  RecordStartFlow.swift
//  Greenroom
//
//  Home's Start Recording is one flow with no screen of its own:
//
//      begin -> build the picture -> countdown -> start the tape -> finish
//
//  This is the pure decision behind it, as a small state machine: events in,
//  the next thing to do out. Foundation only, so the test target compiles this
//  file as it is; `CoordinatorController.startRecordingFlow` does the work each
//  action names.
//
//  The outcomes a person can see:
//   - finish: the tape is rolling; the main window steps aside
//     (MainWindowVisibility) and the recording bar takes over.
//   - putAway (a cancelled countdown, Esc or Cancel on the island): the picture
//     is torn down and Home is as it was. Nothing is shown as an error.
//   - showFailure: the picture is torn down, the island keeps the message with
//     Try again and Close, and the main window stays or comes back.
//
import Foundation

struct RecordStartFlow: Equatable {

    /// The two steps the island lists. The first is the picture, the second the tape.
    static let stepLabels = ["Picture", "Recording"]

    enum Stage: Equatable {
        case notStarted, buildingPicture, countingDown, startingTake, recording, cancelled, failed(String)
    }

    enum Event: Equatable {
        case begin
        case pictureReady
        /// The countdown reached go (or is Off).
        case countdownFinished
        /// Esc, Cancel, the start shortcut again, or the session ending.
        case cancelled
        case takeStarted
        /// Any step failed (permissions, the recorder, the graphics system).
        case failed(String)
    }

    enum Action: Equatable {
        case idle
        case buildPicture
        case countdown
        case beginTake
        /// The tape is rolling.
        case finish
        /// Cancelled: tear down, no error.
        case putAway
        /// Failed: tear down and tell the island.
        case showFailure(String)
    }

    private(set) var stage: Stage = .notStarted

    /// True once the flow has ended without a take: Home goes back as it was.
    var endedWithoutRecording: Bool {
        switch stage {
        case .cancelled, .failed: return true
        default: return false
        }
    }

    /// The failure to show on the island, if any.
    var failureMessage: String? {
        if case .failed(let message) = stage { return message }
        return nil
    }

    mutating func handle(_ event: Event) -> Action {
        switch (stage, event) {
        case (.notStarted, .begin):
            stage = .buildingPicture
            return .buildPicture

        case (.buildingPicture, .pictureReady):
            stage = .countingDown
            return .countdown

        case (.countingDown, .countdownFinished):
            stage = .startingTake
            return .beginTake

        case (.startingTake, .takeStarted):
            stage = .recording
            return .finish

        case (.buildingPicture, .cancelled), (.countingDown, .cancelled), (.startingTake, .cancelled):
            stage = .cancelled
            return .putAway

        case (.buildingPicture, .failed(let message)), (.countingDown, .failed(let message)),
             (.startingTake, .failed(let message)):
            stage = .failed(message)
            return .showFailure(message)

        default:
            // Anything out of order (a late event after the flow ended) changes nothing.
            return .idle
        }
    }
}
