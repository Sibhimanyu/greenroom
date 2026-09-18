//
//  MarksRecorder.swift
//  Greenroom
//
//  One recorder, two engines: whichever source Marks is pointed at.
//
//  The window binds to this and nothing else, so adding the screen engine
//  changed no view code beyond the picture itself and the picker that chooses
//  it. Which is the test of whether the abstraction in MarksCaptureEngine was
//  worth writing.
//
//  What stays here rather than in an engine: the clock, the file name, and
//  the rule that a source cannot change while the tape is rolling. All three
//  are true of Marks, not of a way of capturing.
//
import AVFoundation
import Combine
import Foundation

@MainActor
final class MarksRecorder: ObservableObject {

    /// One presentation is one folder, and this is the file in it. The
    /// library finds presentations by their notes, but everything that plays,
    /// seeks or cuts looks for this name.
    static let recordingFileName = "presentation.mov"

    @Published private(set) var source: MarksSourceKind

    @Published private(set) var isPreviewing = false
    @Published private(set) var isRecording = false
    @Published private(set) var failure: String?
    @Published private(set) var finishedFile: URL?

    /// Where the tape is, in seconds, polled from the engine rather than
    /// derived from a start date - so the clock on screen and the offset
    /// written into a note come from one source and cannot disagree.
    @Published private(set) var elapsed: TimeInterval = 0

    /// Every window on screen worth pointing at. Empty until asked for, and
    /// re-read each time the picker opens: windows come and go.
    @Published private(set) var screenTargets: [MarksScreenEngine.Target] = []

    private var camera: MarksCameraEngine?
    private var screen: MarksScreenEngine?
    private var tick: Timer?

    /// The camera preview needs the session; the screen preview needs the
    /// layer being drawn into. Exposed rather than abstracted into one
    /// "preview view", because the two are genuinely different objects and
    /// wrapping them in a common box would mean owning a third drawing path
    /// for no gain.
    var cameraSession: AVCaptureSession? { camera?.session }
    var screenLayer: AVSampleBufferDisplayLayer? { screen?.displayLayer }

    init(source: MarksSourceKind) {
        self.source = source
    }

    private var engine: MarksCaptureEngine? {
        source.isScreen ? screen : camera
    }

    // MARK: Source

    /// Points Marks at something else, building the engine for it on first
    /// use. Refused mid-recording: one file, one source. Both engines refuse
    /// too, so this is belt and braces on the one rule that cannot be allowed
    /// to slip - a source swapped mid-tape orphans every offset already
    /// written.
    func use(source newSource: MarksSourceKind) async {
        guard !isRecording, newSource != source else { return }

        if source.isScreen != newSource.isScreen {
            engine?.stopPreview()
        }
        source = newSource

        switch newSource {
        case .camera(let uid):
            if let camera {
                camera.use(cameraUID: uid)
            } else {
                let engine = MarksCameraEngine(cameraUID: uid)
                adopt(engine)
                camera = engine
                await engine.startPreview()
            }
        case .window, .display:
            if let screen {
                screen.use(target: newSource)
            } else {
                let engine = MarksScreenEngine(target: newSource)
                adopt(engine)
                screen = engine
                await engine.startPreview()
            }
        }
        syncFromEngine()
    }

    private func adopt(_ engine: MarksCaptureEngine) {
        engine.onChange = { [weak self] in self?.syncFromEngine() }
    }

    /// The engines are not ObservableObjects - they run on their own queues
    /// and report when something changed. This is the one place their state
    /// becomes the window's.
    private func syncFromEngine() {
        guard let engine else { return }
        isPreviewing = engine.isPreviewing
        isRecording = engine.isRecording
        failure = engine.failure
        finishedFile = engine.finishedFile
        if !engine.isRecording { stopTicking() }
    }

    // MARK: Preview

    /// Opens whatever the stored source asks for. Building the engine lazily
    /// rather than in init is what keeps a closed Marks window off the camera
    /// and off the screen-recording permission entirely.
    func startPreview() async {
        if engine == nil {
            switch source {
            case .camera(let uid):
                let engine = MarksCameraEngine(cameraUID: uid)
                adopt(engine)
                camera = engine
                await engine.startPreview()
            case .window, .display:
                let engine = MarksScreenEngine(target: source)
                adopt(engine)
                screen = engine
                await engine.startPreview()
            }
        }
        syncFromEngine()
    }

    func stopPreview() {
        stopTicking()
        camera?.stopPreview()
        screen?.stopPreview()
        isPreviewing = false
    }

    func refreshScreenTargets() async {
        screenTargets = await MarksScreenEngine.targets()
    }

    // MARK: Recording

    func startRecording(into folder: URL) {
        guard let engine, engine.isPreviewing, !isRecording else { return }
        engine.startRecording(to: folder.appendingPathComponent(Self.recordingFileName))
        syncFromEngine()
        startTicking()
    }

    func stopRecording() {
        engine?.stopRecording()
        stopTicking()
        syncFromEngine()
    }

    /// Where the tape is RIGHT NOW, in milliseconds - the number a note
    /// written this instant should carry.
    ///
    /// Read at the moment the note is committed rather than off a timer tick,
    /// so a note is stamped with the frame it belongs to and not with
    /// whenever the clock last updated.
    var positionMs: Int { engine?.positionMs ?? 0 }

    /// Half a second, not a frame: this is a readout a human glances at, and
    /// DESIGN.md's motion rule is that nothing moves for decoration.
    private func startTicking() {
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed = Double(self.positionMs) / 1000
            }
        }
    }

    private func stopTicking() {
        tick?.invalidate()
        tick = nil
        if !isRecording { elapsed = 0 }
    }
}
