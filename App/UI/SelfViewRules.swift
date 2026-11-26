//
//  SelfViewRules.swift
//  Greenroom
//
//  The owner's own "You" tile in the Meeting window (SelfPreviewView), and the
//  owner's own row in the people lists, read from the one camera state
//  (CoordinatorController.cameraState / cameraIsOff), never from Zoom's own
//  video flag.
//
//  What the tile draws: Zoom's render of the owner's own outgoing video, which
//  is the Stage, so it is always what everyone sees. In Off and Only me the
//  Stage leaves the camera out, so the tile shows the shared screen alone; a
//  small mark says why (owner, 2026-11-26: option (a)). The other answer,
//  a "Camera off" placeholder, is `SelfViewContent.placeholder` and is one
//  switch away (`content`).
//
//  Foundation only: the test target compiles this file as it is.
//
import Foundation

enum SelfViewContent: Equatable {
    /// What everyone sees (the Stage), with `SelfViewRules.mark` over it.
    case everyoneSees
    /// The name on the tile colour with video.slash, Zoom's camera-off look.
    case placeholder
}

enum SelfViewRules {
    /// The owner's choice (2026-11-26): the tile keeps showing what everyone sees.
    static let showsPlaceholderWhenCameraIsOut = false

    /// The corner mark on the tile: the camera state's icon and name.
    struct Mark: Equatable {
        var symbol: VisibilitySymbol
        /// Tooltip and VoiceOver: "Camera: Off".
        var label: String
    }

    /// `cameraInPicture` is `!CoordinatorController.cameraIsOff`: whether the meeting's picture
    /// draws the camera (`Visibility.cameraEveryoneSees`; Just my camera keeps it in whatever the state).
    /// While video is stopped (R49) the mark is Stop video's own ("Video stopped"), whatever the state.
    static func mark(state: CameraState, cameraInPicture: Bool, videoStopped: Bool = false) -> Mark? {
        if videoStopped { return Mark(symbol: .videoStopped, label: VisibilitySymbol.videoStopped.words) }
        guard !cameraInPicture else { return nil }
        return Mark(symbol: .camera(state), label: "Camera: \(state.name)")
    }

    /// What the tile draws in this state. While video is stopped everyone sees the owner's name, so
    /// the tile does too: Zoom's video-off look (R49), whatever the placeholder switch says.
    static func content(cameraInPicture: Bool, videoStopped: Bool = false,
                        placeholderWhenOut: Bool = showsPlaceholderWhenCameraIsOut) -> SelfViewContent {
        if videoStopped { return .placeholder }
        return placeholderWhenOut && !cameraInPicture ? .placeholder : .everyoneSees
    }

    /// The "You" tile's whole look, the one source every surface that shows the owner reads:
    /// the Meeting window's "You" tile and a view window's tile of the owner (the Self view window).
    struct Look: Equatable {
        var mark: Mark?
        var content: SelfViewContent
    }

    static func look(state: CameraState, cameraInPicture: Bool, videoStopped: Bool = false) -> Look {
        Look(mark: mark(state: state, cameraInPicture: cameraInPicture, videoStopped: videoStopped),
             content: content(cameraInPicture: cameraInPicture, videoStopped: videoStopped))
    }

    /// What a view window's tile (MeetingVideoTile) draws for one person: the corner mark, and whether
    /// the picture shows (false draws Zoom's video-off look, the name on the tile colour).
    struct TileLook: Equatable {
        var mark: Mark?
        var videoOn: Bool
    }

    /// The owner's tile follows `you`, so the placeholder shows even while Zoom's roster still says
    /// video on; anyone else's tile, or the owner's before `you` is known, follows Zoom's flag alone.
    static func tile(isMe: Bool, zoomVideoOn: Bool, you: Look?) -> TileLook {
        guard isMe, let you else { return TileLook(mark: nil, videoOn: zoomVideoOn) }
        return TileLook(mark: you.mark, videoOn: zoomVideoOn && you.content != .placeholder)
    }

    /// The owner's own row in People and in view windows: the camera icon is struck when the camera
    /// is not in the meeting's picture, or Zoom is sending no video at all.
    static func ownRowCameraOff(cameraInPicture: Bool, zoomVideoOn: Bool) -> Bool {
        !cameraInPicture || !zoomVideoOn
    }
}
