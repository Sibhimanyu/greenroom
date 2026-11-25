//
//  StopVideoRules.swift
//  Greenroom
//
//  Stop video (GLOSSARY.md; spec R49; owner, 2026-11-26, option A): Zoom's own full video off for
//  the owner. Nothing goes to the meeting, not even the shared screen, and everyone sees the owner's
//  name or avatar. It is NOT camera state Off: Off only takes the camera out of the picture and the
//  meeting still gets the screen. The four camera states stay as they are and keep working while
//  video is stopped; the local stage, the recording and the Room screen keep running.
//
//  Zoom's own state is the truth for "video stopped": the coordinator reads it back from the SDK's
//  video-status callback (`OwnVideoStatus`), so a stop made by Zoom or a co-host shows too.
//
//  This file decides, from camera state x video stopped, the camera button's icon, colour, words and
//  caption, what its click does, the menu row, and which moments clear it. Foundation only: the test
//  target compiles it as it is (Tests/StopVideoRulesTests.swift, Tests/CameraMatrixTests.swift).
//
import Foundation

/// Zoom's word for the owner's own video, as a plain value (App/Zoom maps the SDK's status onto it).
enum OwnVideoStatus: Equatable {
    case on
    case off
    /// A host or co-host stopped it (Zoom's MutedByHost).
    case stoppedByHost
    /// Zoom would not say (its None).
    case unknown
}

/// What a press on the one camera button does.
enum CameraButtonPress: Equatable {
    /// Video is stopped: start it again, back as the camera state that is active.
    case startVideo
    /// Today's click (R6.6): a camera-state change.
    case cameraState(CameraState)
}

enum StopVideoRules {
    static let stopTitle = "Stop video"
    static let startTitle = "Start video"
    static var stoppedWords: String { VisibilitySymbol.videoStopped.words }
    /// The menu row's one line, while video goes out.
    static let stopNote = "Everyone sees your name. Nothing is sent, not even your screen."
    /// The menu row's one line, while video is stopped.
    static let startNote = "Everyone sees your picture again."

    /// What Greenroom asks Zoom for.
    enum Request: Equatable { case stop, start }

    static func request(videoStopped: Bool) -> Request { videoStopped ? .start : .stop }

    /// The session-log line when Zoom refuses; nil when it accepted. Either way the UI waits for Zoom's
    /// callback, so a refusal leaves it as it was.
    static func refusalLine(_ request: Request, accepted: Bool) -> String? {
        guard !accepted else { return nil }
        return "\(request == .stop ? stopTitle : startTitle): Zoom refused. Nothing changed."
    }

    /// What the shortcut ran into (`CoordinatorController.toggleStopVideo`'s answer).
    enum ShortcutOutcome: Equatable {
        case notInMeeting
        case asked(Request, accepted: Bool)
    }

    /// The shortcut's toast.
    struct ShortcutToast: Equatable {
        enum Style: Equatable { case done, refused, quiet }
        var title: String
        var style: Style
    }

    /// "Video stopped" / "Video on"; a refusal says so; outside a meeting a quiet word and nothing else.
    static func shortcutToast(_ outcome: ShortcutOutcome) -> ShortcutToast {
        switch outcome {
        case .notInMeeting:
            return ShortcutToast(title: "Stop video works during a meeting", style: .quiet)
        case let .asked(request, accepted):
            if let line = refusalLine(request, accepted: accepted) { return ShortcutToast(title: line, style: .refused) }
            return ShortcutToast(title: request == .stop ? stoppedWords : "Video on", style: .done)
        }
    }

    /// The menu-bar menu's item, in its title case.
    static func menuBarTitle(videoStopped: Bool) -> String { videoStopped ? "Start Video" : "Stop Video" }

    // MARK: Zoom's state, and the moments

    /// Zoom's callback is the truth. An unknown status changes nothing.
    static func videoStopped(after status: OwnVideoStatus, was: Bool) -> Bool {
        switch status {
        case .on: return false
        case .off, .stoppedByHost: return true
        case .unknown: return was
        }
    }

    /// A layout switch or Snap Back never starts the video. Start begins with video on (as today) and
    /// the end of the meeting clears it. Nothing here ever stops it.
    static func videoStopped(after moment: CameraStateSession.Moment, was: Bool) -> Bool {
        switch moment {
        case .start, .end: return false
        case .snapBack, .layoutSwitch: return was
        }
    }

    // MARK: The camera button

    /// Stopped, a click starts the video again (never a camera-state change). Otherwise the camera
    /// state's own click (R6.6). The camera shortcut does not come through here: it is unchanged.
    static func press(state: CameraState, lastOn: CameraState, noCameraAllowed: Bool, videoStopped: Bool) -> CameraButtonPress {
        if videoStopped { return .startVideo }
        return .cameraState(CameraStateSession.clickTarget(current: state, lastOn: lastOn, noCameraAllowed: noCameraAllowed))
    }

    /// The bar's, the toolbar's and the "You" tile's camera button. Stopped: Zoom's red, filled
    /// video.slash (`VisibilitySymbol.videoStopped`), which camera state Off (the quiet outline) never
    /// wears. Otherwise the camera state's own cell.
    static func cell(state: CameraState, videoStopped: Bool) -> MeetingBarModel.IconCell {
        guard videoStopped else { return MeetingBarModel.cameraStateCell(state) }
        let symbol = VisibilitySymbol.videoStopped
        return MeetingBarModel.IconCell(
            symbol: symbol.name,
            help: "\(stoppedWords). Everyone sees your name; nothing is sent, not even your screen. "
                + "Click to start video again as \(state.name); the arrow chooses who sees your camera.",
            spoken: "\(stoppedWords). Click to start video as \(state.name)",
            on: false, symbolBadge: symbol.badge, tint: symbol.tint)
    }

    /// The Meeting toolbar's caption under the camera glyph: what a press does while stopped, as Zoom
    /// words it; otherwise the camera state's name.
    static func caption(state: CameraState, videoStopped: Bool) -> String {
        videoStopped ? startTitle : state.name
    }

    /// The camera menu's last row, after a divider: "Stop video", or "Start video" while stopped.
    static func menuRow(videoStopped: Bool, toggle: @escaping () -> Void) -> [MenuEntry] {
        [.separator,
         .item(videoStopped ? startTitle : stopTitle, note: videoStopped ? startNote : stopNote, toggle)]
    }
}
