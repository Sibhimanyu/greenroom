//
//  ShapePreviewRules.swift
//  Greenroom
//
//  The rules of the live shape preview (Home's card, Settings -> Layouts):
//  who is looking, when the picture is attached to a compositor, when the
//  camera is let go, and what counts as a change worth publishing. Events in,
//  answers out, like `SessionPhase`. Spec: docs/specs/shape-preview.md.
//
//  Pure: Foundation only. `ShapePreviewController` owns the sink and the
//  tasks and carries out what this says.
//
import Foundation

/// Who is looking at the preview. Home's card and Settings -> Layouts share
/// one picture; it stops only when the last of them leaves.
/// Each Home carries its own id: SwiftUI can bring a new Home up before the
/// old one goes, and with one shared `.home` the old one's leaving turned off
/// the new one's camera.
enum ShapePreviewViewer: Hashable, CustomStringConvertible {
    case home(UUID)
    /// Settings -> Layouts, while the camera piece is selected or Preview: Everyone is on (layouts-builder R11.3).
    case layoutsCamera

    var description: String {
        switch self {
        case .home: return "home"
        case .layoutsCamera: return "layouts camera"
        }
    }
}

struct ShapePreviewState: Equatable {

    private(set) var viewers: Set<ShapePreviewViewer> = []
    /// A Record start wants the picture too. Held apart from the viewers so
    /// closing Settings does not blank the Record view, and the other way round.
    var studioWants = false
    /// The preview's sink is on the compositor.
    private(set) var attached = false
    /// The live picture's size, or nil while the schematic is showing.
    private(set) var aspect: CGSize?
    /// Where the shared content sits on the canvas, or nil.
    private(set) var content: CGRect?

    init() {}

    var hasViewers: Bool { !viewers.isEmpty }
    var isWanted: Bool { hasViewers || studioWants }
    func isShowing(_ viewer: ShapePreviewViewer) -> Bool { viewers.contains(viewer) }

    // MARK: Viewers

    enum OpenOutcome: Equatable { case firstViewer, alreadyShown }

    mutating func open(_ viewer: ShapePreviewViewer) -> OpenOutcome {
        let wasOn = hasViewers
        viewers.insert(viewer)
        return wasOn ? .alreadyShown : .firstViewer
    }

    enum CloseOutcome: Equatable {
        /// This viewer never opened.
        case notViewing
        /// Others still look.
        case stillShown
        /// The last viewer left, but the Record view still wants the picture.
        case keptForStudio
        /// The last viewer left: take the sink off, and stop the compositor
        /// when no session owns it (the camera light goes off).
        case detach(stopsStage: Bool)
    }

    mutating func close(_ viewer: ShapePreviewViewer, cameraBusy: Bool) -> CloseOutcome {
        guard viewers.remove(viewer) != nil else { return .notViewing }
        guard viewers.isEmpty else { return .stillShown }
        if studioWants { return .keptForStudio }
        attached = false
        return .detach(stopsStage: !cameraBusy)
    }

    // MARK: Attaching

    enum AttachPlan: Equatable {
        case none
        /// Camera free: make and start the compositor with the chosen look, then add the sink.
        case startStageThenAdd
        /// A session owns the compositor: only add the sink.
        case addSinkOnly
    }

    func attachPlan(cameraBusy: Bool) -> AttachPlan {
        guard isWanted, !attached else { return .none }
        return cameraBusy ? .addSinkOnly : .startStageThenAdd
    }

    mutating func markAttached() { attached = true }
    /// The sink came off, or the stage it was on went away.
    mutating func markDetached() { attached = false }

    /// A session ended and its stage went away. True when a viewer still
    /// looks and the preview should attach again (the studio alone does not).
    mutating func sessionEnded() -> Bool {
        attached = false
        return hasViewers
    }

    enum ReviveAction: Equatable { case none, restart }

    /// Someone waits on the preview but no picture is coming. `evenIfRunning`:
    /// Home waited seconds with no frame from a stage that says it is running.
    func reviveAction(cameraBusy: Bool, stageRunning: Bool, evenIfRunning: Bool) -> ReviveAction {
        guard isWanted, !cameraBusy else { return .none }
        if stageRunning, attached, aspect != nil || !evenIfRunning { return .none }
        return .restart
    }

    // MARK: Publishing

    struct Publication: Equatable { var aspectChanged: Bool; var contentChanged: Bool }

    /// Records what was published for a picture (or its clearing, `frameSize` nil)
    /// and says what changed. Content counts only while a picture exists. The
    /// frames themselves are not here: they go to the feed, never per frame to a
    /// published property.
    mutating func publish(frameSize: CGSize?, content newContent: CGRect?) -> Publication {
        let newContent = frameSize == nil ? nil : newContent
        let result = Publication(aspectChanged: frameSize != aspect, contentChanged: newContent != content)
        aspect = frameSize
        content = newContent
        return result
    }

    // MARK: Applying settings

    /// A burst of changes (a slider, several clicks) waits this long, latest wins.
    static let debounceNanoseconds: UInt64 = 120_000_000

    /// Hand the compositor the settings: it is running, a session owns the camera,
    /// or a viewer is looking (the studio alone does not count).
    func shouldApply(stageRunning: Bool, cameraBusy: Bool) -> Bool {
        stageRunning || cameraBusy || hasViewers
    }

    /// Choosing a screen-based tile is asking for the screen: if macOS has not
    /// allowed it, the pane opens once.
    static func opensScreenPermission(rebuild: Bool, capturesScreen: Bool, granted: Bool) -> Bool {
        rebuild && capturesScreen && !granted
    }
}
