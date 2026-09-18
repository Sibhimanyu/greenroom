//
//  MarksScreenEngine.swift
//  Greenroom
//
//  The screen source: a remote presenter, captured from the window they are
//  already visible in.
//
//  This is the detour around a wall. Marks cannot ask the Zoom Meeting SDK
//  for a student's video - the SDK renders into one container, that video
//  cannot leave the container's window (DESIGN.md, 2026-08-24; the
//  re-parenting experiment drew black) and the capability matrix rules out a
//  second container. What Marks can do is point at the window the student is
//  already on screen in. That works with Greenroom's own participants panel,
//  with the native Zoom app, with Meet in a browser, with a recording being
//  played back - and, unlike anything routed through the SDK, it can be
//  tested on this Mac right now with no meeting and no second person.
//
//  It captures system audio alongside, not the microphone: the thing being
//  evaluated is coming OUT of this Mac's speakers, not into its microphone.
//  That is the opposite of the camera engine's choice and it is the right one
//  for each. A camera in the room hears the room; a window on screen is heard
//  through the machine playing it.
//
//  **This is the first thing in Greenroom to want Screen Recording
//  permission.** Until now that permission belonged entirely to OBS - the
//  README says so, and the transparency page's whole argument is that the
//  list of what Greenroom touches is complete. Both were updated in the same
//  commit that added this file, because a claim that stops being true is
//  worse than one that was never made.
//
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class MarksScreenEngine: NSObject, MarksCaptureEngine {

    // MARK: What can be captured

    struct Target: Identifiable, Hashable {
        enum Kind: Hashable { case window, display }
        let kind: Kind
        let id: UInt32
        let title: String
        /// The app the window belongs to, or the resolution for a display.
        let subtitle: String

        var sourceKind: MarksSourceKind {
            kind == .window ? .window(id: id) : .display(id: id)
        }
    }

    /// Everything on screen worth pointing at, displays first.
    ///
    /// Windows without a title, and windows smaller than a thumbnail, are
    /// dropped: they are overlays, shadows and helper windows, and a list a
    /// teacher has to read past is a list they will not use. Greenroom's own
    /// windows are dropped too - capturing the window you are typing notes
    /// into is a hall of mirrors, and it is the one mistake this list can
    /// prevent outright.
    static func targets() async -> [Target] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return [] }

        let ownBundle = Bundle.main.bundleIdentifier
        let displays = content.displays.map {
            Target(kind: .display, id: $0.displayID,
                   title: "Whole screen", subtitle: "\($0.width)\u{00D7}\($0.height)")
        }
        let windows = content.windows.compactMap { window -> Target? in
            guard let title = window.title, !title.isEmpty,
                  let app = window.owningApplication,
                  app.bundleIdentifier != ownBundle,
                  window.frame.width >= 200, window.frame.height >= 150 else { return nil }
            return Target(kind: .window, id: window.windowID,
                          title: title, subtitle: app.applicationName)
        }
        .sorted { $0.subtitle.localizedCaseInsensitiveCompare($1.subtitle) == .orderedAscending }

        return displays + windows
    }

    // MARK: State

    var onChange: (() -> Void)?

    private(set) var isPreviewing = false { didSet { onChange?() } }
    private(set) var isRecording = false { didSet { onChange?() } }
    private(set) var failure: String? { didSet { onChange?() } }
    private(set) var finishedFile: URL? { didSet { onChange?() } }

    /// Where the preview frames go. An AVSampleBufferDisplayLayer rather than
    /// AVCaptureVideoPreviewLayer, because there is no capture session here -
    /// ScreenCaptureKit hands over sample buffers and something has to draw
    /// them.
    let displayLayer = AVSampleBufferDisplayLayer()

    var target: MarksSourceKind

    private var stream: SCStream?

    /// Everything the capture callback touches. It runs on `captureQueue` and
    /// nowhere else, and `state` is only read from the main actor through
    /// `positionMs`, under the lock.
    private let captureQueue = DispatchQueue(label: "com.sibhimanyu.greenroom.marks.screen")
    private let lock = NSLock()
    private nonisolated(unsafe) var writer: AVAssetWriter?
    private nonisolated(unsafe) var videoInput: AVAssetWriterInput?
    private nonisolated(unsafe) var audioInput: AVAssetWriterInput?
    private nonisolated(unsafe) var sessionStart: CMTime?
    private nonisolated(unsafe) var latestPositionMs: Int = 0
    private nonisolated(unsafe) var writing = false

    init(target: MarksSourceKind) {
        self.target = target
        super.init()
        displayLayer.videoGravity = .resizeAspect
    }

    // MARK: Preview

    func startPreview() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let filter = filter(from: content) else {
                failure = "That window has gone. Pick another one."
                return
            }
            let configuration = configuration(for: filter)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            self.stream = stream
            isPreviewing = true
            failure = nil
        } catch {
            // The first run lands here when Screen Recording has not been
            // granted: ScreenCaptureKit throws rather than prompting twice,
            // and the System Settings pane is the only way forward, so say
            // which one.
            isPreviewing = false
            failure = "Greenroom cannot record the screen yet. Allow it in System Settings \u{2192} Privacy & Security \u{2192} Screen & System Audio Recording, then reopen this window."
        }
    }

    func stopPreview() {
        let existing = stream
        stream = nil
        isPreviewing = false
        Task { try? await existing?.stopCapture() }
    }

    /// Points at something else. Refused mid-recording for the camera's
    /// reason: one file, one source.
    func use(target newTarget: MarksSourceKind) {
        guard !isRecording else { return }
        target = newTarget
        stopPreview()
        Task { await startPreview() }
    }

    private func filter(from content: SCShareableContent) -> SCContentFilter? {
        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
            return SCContentFilter(desktopIndependentWindow: window)
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
            // Greenroom's own windows are excluded from a whole-screen
            // capture rather than merely hidden: the note box is on this
            // screen, being typed into, and recording it would put the
            // evaluator's private notes inside the file the student is shown.
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        case .camera:
            return nil
        }
    }

    private func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        // Capped at 1080 tall, aspect preserved. A retina display captured at
        // its native size is a 5K video of a person talking - minutes to cut,
        // gigabytes to keep, and no more legible than this.
        let size = filter.contentRect.size
        let scale = min(1, 1080 / max(size.height, 1))
        configuration.width = Int((size.width * scale).rounded()) & ~1
        configuration.height = Int((size.height * scale).rounded()) & ~1
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = true
        // One frame in hand is enough for a talking head; a deeper queue just
        // delays the preview behind what is actually on screen.
        configuration.queueDepth = 5
        return configuration
    }

    // MARK: Recording

    func startRecording(to file: URL) {
        guard isPreviewing, !isRecording else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)

        guard let writer = try? AVAssetWriter(outputURL: file, fileType: .mov) else {
            failure = "The recording file could not be opened."
            return
        }
        let width = (stream != nil) ? currentWidth : 1280
        let height = (stream != nil) ? currentHeight : 720

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = true

        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 128_000,
        ])
        audio.expectsMediaDataInRealTime = true

        if writer.canAdd(video) { writer.add(video) }
        if writer.canAdd(audio) { writer.add(audio) }
        guard writer.startWriting() else {
            failure = "The recording could not start: \(writer.error?.localizedDescription ?? "unknown")."
            return
        }

        lock.lock()
        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
        self.sessionStart = nil
        self.latestPositionMs = 0
        self.writing = true
        lock.unlock()

        finishedFile = nil
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        lock.lock()
        writing = false
        let writer = self.writer
        let video = self.videoInput
        let audio = self.audioInput
        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        lock.unlock()

        video?.markAsFinished()
        audio?.markAsFinished()
        isRecording = false

        guard let writer else { return }
        writer.finishWriting { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if writer.status == .completed {
                    self.finishedFile = writer.outputURL
                } else {
                    self.failure = "The recording could not be saved: \(writer.error?.localizedDescription ?? "unknown")."
                }
            }
        }
    }

    /// Where the tape is, taken from the last frame actually WRITTEN.
    ///
    /// Not from a clock and not from when the button was pressed. The camera
    /// engine reads the movie output's own position for this reason; here the
    /// equivalent is the newest presentation timestamp the writer accepted,
    /// measured from the one that opened the session. A stalled capture -
    /// the window minimised, the display asleep - then stamps a note where
    /// the file actually is rather than where the wall clock thinks it is.
    var positionMs: Int {
        guard isRecording else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return latestPositionMs
    }

    private var currentWidth: Int = 1280
    private var currentHeight: Int = 720
}

// MARK: - Frames

extension MarksScreenEngine: SCStreamOutput, SCStreamDelegate {

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit emits a frame for every wake-up, including the
            // ones where nothing changed and the ones where the window is
            // occluded. Only `complete` frames carry pixels; appending the
            // others writes garbage and enqueues a blank preview.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }

            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.displayLayer.isReadyForMoreMediaData {
                    self.displayLayer.enqueue(sampleBuffer)
                }
            }
            append(sampleBuffer, video: true)

        case .audio:
            append(sampleBuffer, video: false)

        @unknown default:
            break
        }
    }

    private nonisolated func append(_ sampleBuffer: CMSampleBuffer, video: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard writing, let writer, writer.status == .writing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }

        if sessionStart == nil {
            // The session opens on the first VIDEO frame, never on audio.
            // System audio arrives continuously whether or not the window has
            // redrawn, so opening on audio would start the timeline before
            // the first picture and leave every note offset by however long
            // that gap was.
            guard video else { return }
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
        }
        guard let start = sessionStart else { return }

        let input = video ? videoInput : audioInput
        guard let input, input.isReadyForMoreMediaData else { return }
        guard input.append(sampleBuffer) else { return }

        if video {
            latestPositionMs = max(0, Int(CMTimeGetSeconds(CMTimeSubtract(pts, start)) * 1000))
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPreviewing = false
            if self.isRecording { self.stopRecording() }
            self.failure = "The capture stopped: \(error.localizedDescription)"
        }
    }
}
