//
//  ShapePreviewController.swift
//  Greenroom
//
//  The owner of the live shape preview (Home's card, Settings -> Layouts):
//  the viewers, the sink on the compositor, the debounced apply, and the feed
//  the picture reads. The rules are `ShapePreviewState`; this carries them
//  out against the compositor. The coordinator reports events and forwards.
//  Spec: docs/specs/shape-preview.md.
//
//  The shared look of the picture is the host's: it makes the stage and its
//  configuration, and publishes the two changes views watch.
//
import AppKit

/// What the preview needs from whoever runs the session.
@MainActor
protocol ShapePreviewHost: AnyObject {
    var previewStage: StageCompositor? { get }
    /// A session owns the camera (starting, or up of either kind).
    var previewCameraBusy: Bool { get }
    func previewEnsureStage() -> StageCompositor?
    func previewConfiguration() -> StageConfiguration
    /// The idle director follows the attached preview.
    func previewSyncIdleDirector()
    func previewStopStage()
    /// Published only on a real change, never per frame.
    func previewAspectChanged(_ aspect: CGSize?)
    func previewContentChanged(_ content: CGRect?)
}

@MainActor
final class ShapePreviewController {
    private(set) var state = ShapePreviewState()
    /// The frames, on an object of their own. As a @Published property of the
    /// coordinator each one invalidated every view that observes it, the whole
    /// Settings window rebuilt several times a second. Only the picture
    /// observes the feed; the rest watch the aspect, which changes only when
    /// the picture's shape does.
    let feed = ShapePreviewFeed()
    private let sink = StagePreviewSink()
    private var applyTask: Task<Void, Never>?
    private weak var host: ShapePreviewHost?

    init(host: ShapePreviewHost? = nil) { self.host = host }
    func connect(_ host: ShapePreviewHost) { self.host = host }

    var isAttached: Bool { state.attached }
    var hasViewers: Bool { state.hasViewers }
    var isWanted: Bool { state.isWanted }
    var studioWants: Bool {
        get { state.studioWants }
        set { state.studioWants = newValue }
    }
    var aspect: CGSize? { state.aspect }
    /// Set by whoever knows the session; picks the sink's rate.
    var meetingLive: Bool {
        get { sink.meetingLive }
        set { sink.meetingLive = newValue }
    }

    func isShowing(for viewer: ShapePreviewViewer) -> Bool { state.isShowing(viewer) }
    var viewers: Set<ShapePreviewViewer> { state.viewers }

    // MARK: Viewers

    /// Starts showing the picture. Outside a session the compositor is started
    /// for it, with the chosen look, so the preview shows what the NEXT
    /// session will send; during a live session it simply mirrors that one.
    /// Never asks for a permission: with Screen Recording off the picture is
    /// the camera alone.
    func start(for viewer: ShapePreviewViewer) {
        guard state.open(viewer) == .firstViewer else { return }
        StageScreenSource.log("Preview opened (\(viewer)).")
        attach()
    }

    func stop(for viewer: ShapePreviewViewer) {
        guard let host else { return }
        let busy = host.previewCameraBusy
        let wasAttached = state.attached
        switch state.close(viewer, cameraBusy: busy) {
        case .notViewing:
            return
        case .stillShown:
            StageScreenSource.log("Preview closed (\(viewer)); still shown elsewhere.")
        case .keptForStudio:
            StageScreenSource.log("Preview closed (\(viewer))\(!busy ? "; the picture stops with it" : "").")
            applyTask?.cancel()
        case .detach(let stopsStage):
            StageScreenSource.log("Preview closed (\(viewer))\(!busy ? "; the picture stops with it" : "").")
            applyTask?.cancel()
            if wasAttached, let stage = host.previewStage { stage.removeSink(sink) }
            // The preview opened the camera; a session that is not running has
            // no use for it, and the camera light should go off.
            if stopsStage { host.previewStopStage() }
            publish(nil)
        }
    }

    // MARK: Attaching

    func attach() {
        guard let host else { return }
        let plan = state.attachPlan(cameraBusy: host.previewCameraBusy)
        guard plan != .none else { return }
        if plan == .startStageThenAdd {
            guard let stage = host.previewEnsureStage() else { return }
            stage.start(host.previewConfiguration())
        }
        guard let stage = host.previewStage else { return }
        sink.onPicture = { [weak self] image, mask in self?.publish(image, mask: mask) }
        sink.coverage = { [weak stage] in stage?.lastCameraCoverage }
        stage.addSink(sink)
        state.markAttached()
        host.previewSyncIdleDirector()
    }

    /// The stage (and so the sink on it) went away under the preview.
    func stageStopped() {
        if state.attached, let stage = host?.previewStage { stage.removeSink(sink) }
        state.markDetached()
    }

    /// A session ended: a Settings window still open gets its preview back.
    func sessionEnded() {
        if state.sessionEnded() { attach() }
    }

    /// Someone is waiting on the preview but no picture is coming. Starts it
    /// again; does nothing while a session owns the picture or frames flow.
    func reviveIfStalled(evenIfRunning: Bool = false) {
        guard let host else { return }
        let running = host.previewStage?.status.isRunning ?? false
        guard state.reviveAction(cameraBusy: host.previewCameraBusy, stageRunning: running,
                                 evenIfRunning: evenIfRunning) == .restart else { return }
        StageScreenSource.log("Preview had no picture; starting it again.")
        if let stage = host.previewStage, state.attached { stage.removeSink(sink) }
        state.markDetached()
        if running { host.previewStopStage() }
        attach()
    }

    // MARK: Publishing

    func publish(_ frame: NSImage?, mask: NSImage? = nil) {
        let content = frame == nil ? nil : host?.previewStage?.lastContentRect
        let change = state.publish(frameSize: frame?.size, content: content)
        if feed.contentRect != state.content { feed.contentRect = state.content }
        if change.contentChanged { host?.previewContentChanged(state.content) }
        feed.frame = frame
        feed.openMask = mask
        if change.aspectChanged { host?.previewAspectChanged(state.aspect) }
    }

    // MARK: Applying settings

    /// Applies the current look to the picture, latest wins: a burst of changes
    /// cancels what it supersedes instead of queuing.
    func requestApply() {
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ShapePreviewState.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.applyNow()
        }
    }

    /// Hands the compositor the settings as they are now.
    func applyNow() {
        guard let host, let stage = host.previewStage,
              state.shouldApply(stageRunning: stage.status.isRunning, cameraBusy: host.previewCameraBusy)
        else { return }
        stage.update(host.previewConfiguration())
    }
}
