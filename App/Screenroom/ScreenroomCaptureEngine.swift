//
//  ScreenroomCaptureEngine.swift
//  Greenroom
//
//  Where the picture comes from.
//
//  The plan asked for capture to be an abstraction from day one, "even though
//  only one source gets implemented first", and phase 1 deliberately did not
//  write one: a protocol with a single conformance is a guess about the
//  second. This is the protocol written with the second conformance in front
//  of it, and it is a different shape than the guess would have been - the
//  two engines disagree about almost everything except these six calls.
//
//  Two engines, and the honest reason there are not three:
//
//   - **Camera.** A person presenting in the room, seen by this Mac's camera
//     or one pointed at the front of the room.
//   - **Screen.** A window or a display. This is how a REMOTE presenter is
//     captured, and it is a deliberate detour around a wall: the Zoom Meeting
//     SDK renders video into one container and it cannot leave that
//     container's window (DESIGN.md, 2026-08-24 - the re-parenting experiment
//     drew black), and the capability matrix is explicit that a second
//     container is not a thing. So Screenroom cannot ask the SDK for the student's
//     video. It can point at the window the student is already visible in,
//     which works with Zoom, with Meet, with anything, and needs no meeting
//     running to test.
//
//  The third engine - the meeting feed itself - stays unbuilt because the SDK
//  will not give it up, not because nobody got to it.
//
import AVFoundation
import Foundation

/// What every source can be asked to do. Deliberately six calls: anything
/// larger starts describing the camera, and the screen engine has no answer
/// for most of what a camera knows.
@MainActor
protocol ScreenroomCaptureEngine: AnyObject {

    /// Told about every state change, because the engines reach these
    /// conclusions on their own queues and at their own times.
    var onChange: (() -> Void)? { get set }

    var isPreviewing: Bool { get }
    var isRecording: Bool { get }

    /// A sentence the evaluator can act on, or nil.
    var failure: String? { get }

    /// Where the tape is, in milliseconds, asked at the instant a note is
    /// committed. Each engine answers from its own writer's position rather
    /// than from a clock - see the two implementations for why that is not a
    /// detail.
    var positionMs: Int { get }

    /// Opens the source and starts showing it. Asks for whatever permission
    /// it needs, up front, so no sheet appears over a student mid-sentence.
    func startPreview() async

    func stopPreview()

    func startRecording(to file: URL)

    func stopRecording()

    /// The finished file, once the engine has closed it.
    var finishedFile: URL? { get }
}

/// Which kind of source, and which one of them.
enum ScreenroomSourceKind: Hashable {
    /// A camera by AVFoundation uniqueID. Empty means "the first real one".
    case camera(uid: String)
    /// A window by CGWindowID, as listed by ScreenroomScreenEngine.
    case window(id: UInt32)
    /// A whole display by its CoreGraphics id.
    case display(id: UInt32)

    var isScreen: Bool {
        switch self {
        case .camera: return false
        case .window, .display: return true
        }
    }
}
