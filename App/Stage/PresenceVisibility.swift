//
//  PresenceVisibility.swift
//  Greenroom
//
//  Whether the presence bubble is on the presenter's screen, as a pure
//  function of facts the coordinator reads. No AppKit, so it is tested alone.
//
//  Three answers:
//   - show:                 the bubble is up and the compositor feeds it pictures.
//   - hide:                 there is nothing honest to show (no meeting or take,
//                           a look with no box to move, nothing captured yet).
//   - hideKeepingPlacement: the presenter or the situation takes the bubble off
//                           this screen; the camera stays in the picture at its
//                           placement and nothing is lost.
//  In both hidden answers the compositor is not asked for self-view pictures.
//
import Foundation

enum PresenceVisibility {
    enum ShareKind: Equatable { case display, app, window, whiteboard, nothing }

    enum Decision: Equatable { case show, hide, hideKeepingPlacement }

    struct Inputs: Equatable {
        /// A meeting, or a recording scene, is up with a compositor.
        var live = true
        /// The look has a camera box the presenter can move.
        var layoutPlaceable = true
        /// The camera is on in the meeting (Zoom video not muted). Always true
        /// outside a meeting.
        var cameraOn = true
        /// The compositor has handed over a frame of the camera.
        var hasCapturedFrame = true
        /// The renderer has drawn the shared content, so there is a rect to map to.
        var hasContentRect = true
        /// "Hide my bubble" in the control bar.
        var hiddenByPresenter = false
        var shareKind = ShareKind.display
        /// For a window or app share: the shared window is on screen on this
        /// desktop (not minimised, not hidden, not on another Space).
        var sharedWindowVisible = true
        /// Zoom's own screen share is running: Zoom shows the screen and
        /// the bubble stays out of the way.
        var nativeZoomShareActive = false
    }

    static func decide(_ i: Inputs) -> Decision {
        // Nothing honest to show.
        guard i.live, i.layoutPlaceable, i.hasCapturedFrame, i.hasContentRect else { return .hide }
        switch i.shareKind {
        case .whiteboard, .nothing: return .hide      // no real screen to sit on
        case .display, .app, .window: break
        }
        // Taken off this screen; the camera keeps its place in the picture.
        if !i.cameraOn || i.hiddenByPresenter || i.nativeZoomShareActive { return .hideKeepingPlacement }
        if (i.shareKind == .app || i.shareKind == .window) && !i.sharedWindowVisible { return .hideKeepingPlacement }
        return .show
    }

    /// Where the bubble starts at each Start or Snap Back: hidden when the layout's
    /// "Show my camera on my screen" is off. Local only (the camera stays in the
    /// meeting's picture); the control bar's bubble button flips it from there.
    static func bubbleStartsHidden(shownOnMyScreen: Bool) -> Bool { !shownOnMyScreen }
    static func bubbleStartsHidden(state: CameraState) -> Bool { !state.shownOnMyScreen }

    /// How often the coordinator re-reads the world (seconds): quicker while a
    /// window is followed, so the bubble keeps up with a window being dragged.
    static func pollInterval(shareKind: ShareKind, bubbleUp: Bool) -> TimeInterval {
        bubbleUp && (shareKind == .app || shareKind == .window) ? 0.25 : 1
    }
}
