//
//  ScreenroomCameraEngine.swift
//  Greenroom
//
//  The camera source: a person presenting in the room.
//
//  This is phase 1's recorder, moved behind ScreenroomCaptureEngine unchanged in
//  behaviour. The notes that matter are still the two it was written with:
//
//   - Offsets come from `recordedDuration`, the movie output's own position
//     in the file it is writing, never from wall-clock arithmetic. Same
//     choice SessionClips makes against OBS's outputDuration, and for the
//     same reason: it is the only number still true after a dropped frame or
//     a device stall, and it is what a player will seek to later.
//   - The capture objects are confined to `sessionQueue`, which is
//     AVFoundation's own rule for them. `nonisolated(unsafe)` says so out
//     loud rather than hiding it behind a main-actor annotation that is not
//     true.
//
@preconcurrency import AVFoundation
import Foundation

@MainActor
final class ScreenroomCameraEngine: NSObject, ScreenroomCaptureEngine {

    var onChange: (() -> Void)?

    /// Handed to the preview layer. See the note above on confinement.
    nonisolated(unsafe) let session = AVCaptureSession()
    private nonisolated(unsafe) let movieOutput = AVCaptureMovieFileOutput()

    private(set) var isPreviewing = false { didSet { onChange?() } }
    private(set) var isRecording = false { didSet { onChange?() } }
    private(set) var failure: String? { didSet { onChange?() } }
    private(set) var finishedFile: URL? { didSet { onChange?() } }

    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "com.sibhimanyu.greenroom.screenroom.camera")

    /// Which camera. Changing it reconfigures the running preview.
    var cameraUID: String

    init(cameraUID: String) {
        self.cameraUID = cameraUID
        super.init()
    }

    // MARK: Preview

    func startPreview() async {
        guard await Self.authorized(for: .video) else {
            failure = "Greenroom cannot see the camera. Grant camera access in System Settings \u{2192} Privacy & Security \u{2192} Camera."
            return
        }
        // Camera and microphone are asked for together and up front, before
        // the evaluator has typed anything: a permission sheet appearing when
        // they press Record is a sheet appearing over a student who has
        // already started talking.
        let hasAudio = await Self.authorized(for: .audio)
        if !hasAudio {
            failure = "Recording without sound \u{2014} grant microphone access in System Settings \u{2192} Privacy & Security \u{2192} Microphone to capture what was said."
        }
        configure(withAudio: hasAudio)
    }

    /// Swaps the camera without dropping the preview. Refused mid-recording:
    /// a movie with two different cameras in it is not a thing anyone asked
    /// for, and stopping and restarting the tape would orphan every offset
    /// already written.
    func use(cameraUID uid: String) {
        guard !isRecording else { return }
        cameraUID = uid
        configure(withAudio: audioInput != nil)
    }

    private func configure(withAudio: Bool) {
        guard let device = Self.resolveCamera(uid: cameraUID) else {
            failure = "No camera found. Plug one in, or check that another app has not taken it."
            return
        }
        let mic = withAudio ? AVCaptureDevice.default(for: .audio) : nil

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let session = self.session
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }

            var video: AVCaptureDeviceInput?
            var audio: AVCaptureDeviceInput?
            var problem: String?

            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                video = input
            } else {
                problem = "\(device.localizedName) could not be opened. Another app may be using it."
            }
            if let mic, let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInput(input)
                audio = input
            }
            if session.canAddOutput(self.movieOutput) { session.addOutput(self.movieOutput) }
            session.sessionPreset = .high

            // NOT MIRRORED, said out loud rather than left to a default.
            //
            // macOS mirrors a front-facing camera automatically, because the
            // usual job is a self-view and a self-view should behave like a
            // mirror. This camera is pointed at somebody PRESENTING - a
            // student at the front of a room - and a mirrored record of them
            // is just wrong: their right hand is on the wrong side, and any
            // writing behind them is backwards.
            //
            // automaticallyAdjustsVideoMirroring has to go false first, or
            // the system overrules isVideoMirrored at the next configuration
            // change.
            for connection in self.movieOutput.connections
            where connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }

            Task { @MainActor in
                self.videoInput = video
                self.audioInput = audio
                self.isPreviewing = session.isRunning && video != nil
                if let problem { self.failure = problem }
            }
        }
    }

    func stopPreview() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor in self.isPreviewing = false }
        }
    }

    // MARK: Recording

    func startRecording(to file: URL) {
        guard isPreviewing, !isRecording else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // AVCaptureMovieFileOutput refuses to start onto an existing path.
        // One presentation per folder is the contract, so anything there is a
        // previous attempt at this same presentation.
        try? FileManager.default.removeItem(at: file)

        finishedFile = nil
        // Flipped here rather than in the queue block so the window reacts to
        // the press immediately; the delegate callback turns it off again, so
        // the two cannot disagree for longer than a frame.
        isRecording = true
        sessionQueue.async { [movieOutput] in
            movieOutput.startRecording(to: file, recordingDelegate: self)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        sessionQueue.async { [movieOutput] in movieOutput.stopRecording() }
    }

    var positionMs: Int {
        guard isRecording else { return 0 }
        let duration = movieOutput.recordedDuration
        guard duration.isValid, !duration.isIndefinite else { return 0 }
        return max(0, Int(CMTimeGetSeconds(duration) * 1000))
    }

    // MARK: Devices and permission

    /// Screenroom has a camera picker where the OBS composite deliberately does
    /// not (LocalDeviceResolver.physicalCameraUID). The difference is what the
    /// camera is pointed at: the composite always wants the one looking at
    /// you, so there was nothing to decide, while Screenroom is as likely to want
    /// an external camera pointed at a student at the front of the room. That
    /// is a real choice, made once per room, so it gets a control.
    private static func resolveCamera(uid: String) -> AVCaptureDevice? {
        if !uid.isEmpty, let device = AVCaptureDevice(uniqueID: uid) { return device }
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

extension ScreenroomCameraEngine: AVCaptureFileOutputRecordingDelegate {

    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        Task { @MainActor in
            self.isRecording = false
            // An error here is not always fatal: AVFoundation reports a
            // finished file alongside a non-nil error when it had to stop
            // early, and the bytes on disk are still playable. Trust the
            // file's existence over the error's presence, and say so either
            // way.
            if FileManager.default.fileExists(atPath: outputFileURL.path) {
                self.finishedFile = outputFileURL
                if error != nil { self.failure = "The recording ended early but the file was saved." }
            } else if let error {
                self.failure = "The recording could not be saved: \(error.localizedDescription)"
            }
        }
    }
}
