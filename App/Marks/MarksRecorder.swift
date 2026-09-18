//
//  MarksRecorder.swift
//  Greenroom
//
//  The camera Marks points at the person presenting, and the file it writes.
//
//  This is deliberately NOT the meeting's video. Zoom's Meeting SDK renders
//  into its own container and the video cannot leave that container's window
//  - tried, drew black, recorded in DESIGN.md's decisions log on 2026-08-24 -
//  so a Marks window showing a remote student would have to be built inside
//  ParticipantGridWindow.swift, and could only ever be tested by running a
//  real meeting with a real second person in it. A local camera has neither
//  problem: Marks opens on its own, with no session, no OBS and no
//  credentials, which is what lets the note box be worked on at all.
//
//  It is also not OBS's recording. OBS records the COMPOSITE - your shared
//  screen with you keyed into the corner - which is the right picture for a
//  class and the wrong one for evaluating a speaker. Marks wants the speaker.
//
//  Offsets come from `recordedDuration`, the movie output's own position in
//  the file it is writing, never from wall-clock arithmetic. Same choice
//  SessionClips makes against OBS's outputDuration, for the same reason: it
//  is the only number that is still true after a dropped frame, a stall or a
//  device hiccup, and it is what a player will seek to later.
//
// @preconcurrency: AVCaptureDevice and friends predate Sendable and are not
// marked for it, but the capture objects here are confined to sessionQueue by
// construction (see below), which is the discipline AVFoundation itself asks
// for. Without this the file compiles to a wall of Sendable warnings that say
// nothing about whether the confinement is actually correct.
@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class MarksRecorder: NSObject, ObservableObject {

    /// Live while the camera is open, whether or not the tape is rolling.
    ///
    /// `nonisolated(unsafe)`, and the "unsafe" is doing real work: every
    /// mutation of this object and of `movieOutput` happens on `sessionQueue`
    /// and nowhere else, which is AVFoundation's own rule for them. The
    /// exceptions are handing `session` to the preview layer and reading
    /// `recordedDuration`, both of which are reads the framework documents as
    /// safe from any thread.
    nonisolated(unsafe) let session = AVCaptureSession()

    @Published private(set) var isPreviewing = false
    @Published private(set) var isRecording = false

    /// Where the tape is, in seconds. Polled rather than derived from a start
    /// date so the clock on screen and the offset written into a note come
    /// from the same source and cannot disagree.
    @Published private(set) var elapsed: TimeInterval = 0

    /// What went wrong, in a sentence the evaluator can act on. Surfaced in
    /// the window itself: DESIGN.md asks that a failure land on the surface
    /// the user was already watching.
    @Published private(set) var failure: String?

    /// The finished file, once the output has closed it.
    @Published private(set) var finishedFile: URL?

    private nonisolated(unsafe) let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    /// startRunning() blocks for as long as the device takes to wake, which on
    /// an external camera is comfortably long enough to drop frames on the main
    /// thread. Everything that touches the session's configuration goes here.
    private let sessionQueue = DispatchQueue(label: "com.sibhimanyu.greenroom.marks.session")

    private var tick: Timer?

    // MARK: Preview

    /// Opens the camera and starts the preview, asking for permission first.
    ///
    /// Camera and microphone are requested together and up front, before the
    /// evaluator has typed anything, because a permission sheet appearing at
    /// the moment they press Record is a permission sheet appearing over a
    /// student who has already started talking.
    func startPreview(cameraUID: String?) {
        Task {
            guard await Self.authorized(for: .video) else {
                failure = "Greenroom cannot see the camera. Grant camera access in System Settings \u{2192} Privacy & Security \u{2192} Camera."
                return
            }
            let hasAudio = await Self.authorized(for: .audio)
            if !hasAudio {
                failure = "Recording without sound \u{2014} grant microphone access in System Settings \u{2192} Privacy & Security \u{2192} Microphone to capture what was said."
            }
            configure(cameraUID: cameraUID, withAudio: hasAudio)
        }
    }

    /// Swaps the camera without dropping the preview. Refused mid-recording:
    /// a movie file with two different cameras in it is not a thing anyone
    /// asked for, and the alternative - stopping and restarting the tape -
    /// would silently orphan every offset already written.
    func useCamera(uid: String) {
        guard !isRecording else { return }
        configure(cameraUID: uid, withAudio: audioInput != nil)
    }

    private func configure(cameraUID: String?, withAudio: Bool) {
        let device = Self.resolveCamera(uid: cameraUID)
        guard let device else {
            failure = "No camera found. Plug one in, or check that another app has not taken it."
            return
        }
        let mic = withAudio ? AVCaptureDevice.default(for: .audio) : nil

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let session = self.session
            session.beginConfiguration()

            // Reconfiguring, not building from scratch: useCamera comes back
            // through here with a preview already running.
            for input in session.inputs { session.removeInput(input) }

            var videoInput: AVCaptureDeviceInput?
            var audioInput: AVCaptureDeviceInput?
            var problem: String?

            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            } else {
                problem = "\(device.localizedName) could not be opened. Another app may be using it."
            }
            if let mic, let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
            if session.canAddOutput(self.movieOutput) {
                session.addOutput(self.movieOutput)
            }
            session.sessionPreset = .high
            session.commitConfiguration()

            if !session.isRunning { session.startRunning() }

            Task { @MainActor in
                self.videoInput = videoInput
                self.audioInput = audioInput
                self.isPreviewing = session.isRunning && videoInput != nil
                if let problem { self.failure = problem }
            }
        }
    }

    /// Closes the camera. Called when the window goes away: a preview left
    /// running holds the camera light on for a window nobody is looking at.
    func stopPreview() {
        tick?.invalidate()
        tick = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor in self.isPreviewing = false }
        }
    }

    // MARK: Recording

    /// Starts writing `presentation.mov` into the presentation's folder.
    func startRecording(into folder: URL) {
        guard isPreviewing, !isRecording else { return }
        let file = folder.appendingPathComponent(Self.recordingFileName)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // AVCaptureMovieFileOutput refuses to start onto an existing path.
        // One presentation per folder is the contract, so anything already
        // there is a previous attempt at this same presentation.
        try? FileManager.default.removeItem(at: file)

        finishedFile = nil
        // Flipped here rather than in the queue block so the window reacts to
        // the press immediately; the delegate callback is what turns it off
        // again, so the two cannot disagree for longer than a frame.
        isRecording = true
        startTicking()
        sessionQueue.async { [movieOutput] in
            movieOutput.startRecording(to: file, recordingDelegate: self)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        tick?.invalidate()
        tick = nil
        sessionQueue.async { [movieOutput] in
            movieOutput.stopRecording()
        }
    }

    /// Where the tape is RIGHT NOW, in milliseconds - the number a note
    /// written this instant should carry.
    ///
    /// Read at the moment the note is committed rather than stored on a timer
    /// tick, so a note is stamped with the frame it belongs to and not with
    /// whenever the clock last updated.
    var positionMs: Int {
        guard isRecording else { return 0 }
        let duration = movieOutput.recordedDuration
        guard duration.isValid, !duration.isIndefinite else { return 0 }
        return max(0, Int(CMTimeGetSeconds(duration) * 1000))
    }

    /// Drives the clock on screen. Half a second, not a frame: this is a
    /// readout a human glances at, and DESIGN.md's motion rule is that nothing
    /// moves for decoration.
    private func startTicking() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                let duration = self.movieOutput.recordedDuration
                guard duration.isValid, !duration.isIndefinite else { return }
                self.elapsed = CMTimeGetSeconds(duration)
            }
        }
    }

    // MARK: Devices and permission

    static let recordingFileName = "presentation.mov"

    /// The camera to open: the one that was chosen, or the first real one.
    ///
    /// Marks has a camera picker where the OBS composite deliberately does not
    /// (see LocalDeviceResolver.physicalCameraUID). The difference is what the
    /// camera is pointed at: the composite always wants the one looking at
    /// you, so there was nothing to decide, while Marks is as likely to want an
    /// external camera pointed at a student at the front of the room. That is
    /// a real choice, made once per room, so it gets a control.
    private static func resolveCamera(uid: String?) -> AVCaptureDevice? {
        if let uid, !uid.isEmpty, let device = AVCaptureDevice(uniqueID: uid) { return device }
        guard let fallback = LocalDeviceResolver.availableCameras().first else { return nil }
        return AVCaptureDevice(uniqueID: fallback.id)
    }

    private static func authorized(for media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }
}

extension MarksRecorder: AVCaptureFileOutputRecordingDelegate {

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                               didFinishRecordingTo outputFileURL: URL,
                               from connections: [AVCaptureConnection],
                               error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            self.elapsed = 0
            // An error here is not always fatal: AVFoundation reports a
            // successfully-finished file alongside a non-nil error when it had
            // to stop early, and the bytes on disk are still playable. Trust
            // the file's existence over the error's presence, and say so
            // either way.
            let exists = FileManager.default.fileExists(atPath: outputFileURL.path)
            if exists {
                self.finishedFile = outputFileURL
                if error != nil {
                    self.failure = "The recording ended early but the file was saved."
                }
            } else if let error {
                self.failure = "The recording could not be saved: \(error.localizedDescription)"
            }
        }
    }
}
