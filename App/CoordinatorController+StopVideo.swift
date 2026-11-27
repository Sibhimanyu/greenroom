//
//  CoordinatorController+StopVideo.swift
//  Greenroom
//
//  Stop video (GLOSSARY.md; spec R49; owner, 2026-11-26, option A). Zoom's own video mute for the
//  owner: nothing is sent to the meeting, not even the screen, and everyone sees the owner's name.
//  The four camera states are untouched and keep working while it is on; the local stage, the
//  recording and the Room screen keep running, since none of them goes through Zoom.
//
//  This is the one file that calls `setMyVideo` (SourceScanTests allows exactly this call site).
//  Greenroom never sets `videoStopped` from its own request: it waits for Zoom's video-status
//  callback, so a refusal leaves the UI as it was and a stop made by a co-host or Zoom shows too.
//  The decisions are StopVideoRules.swift's.
//
import Foundation

extension CoordinatorController {

    /// Once, at init: Zoom's word on the owner's video feeds `videoStopped`.
    func installStopVideoHooks() {
        zoomChatClient.onMyVideoStatus = { [weak self] status in
            self?.noteOwnVideoStatus(status)
        }
    }

    /// Zoom's video-status callback for the owner: the truth for "video stopped".
    func noteOwnVideoStatus(_ status: OwnVideoStatus) {
        let next = StopVideoRules.videoStopped(after: status, was: videoStopped)
        guard next != videoStopped else { return }
        videoStopped = next
        log(next ? (status == .stoppedByHost ? "Video stopped by the host. Nothing goes to the meeting."
                                             : "Video stopped. Nothing goes to the meeting, not even your screen.")
                 : "Video started. Everyone sees your picture again (\(cameraState.name)).")
    }

    /// The camera menu's last row, the menu-bar item and the shortcut: Stop video, or Start video while
    /// stopped. In a meeting only. The answer is what the request met, for the shortcut's toast.
    @discardableResult
    func toggleStopVideo() -> StopVideoRules.ShortcutOutcome {
        guard zoomChatClient.myUserID != nil else { return .notInMeeting }
        let request = StopVideoRules.request(videoStopped: videoStopped)
        let accepted = zoomChatClient.setMyVideo(on: request == .start)
        Analytics.track(.controlAction, [.action: request == .stop ? "stop_video" : "start_video",
                                         .refused: accepted ? "no" : "yes"])
        if let line = StopVideoRules.refusalLine(request, accepted: accepted) { log(line) }
        return .asked(request, accepted: accepted)
    }

    /// The one camera button's click (bar, Meeting toolbar, the "You" tile's hover button). Stopped, it
    /// starts the video again, back as the camera state that is active; otherwise today's click (R6.6).
    /// The camera shortcut keeps `toggleLiveCameraState`: it is unchanged.
    func pressCameraButton() {
        let press = StopVideoRules.press(
            state: cameraState, lastOn: meetingSetup.cameraLastOn,
            noCameraAllowed: CameraPanelRules.noCameraEnabled(shareIsNothing: shareTarget.sharesNothing),
            videoStopped: videoStopped)
        switch press {
        case .startVideo: toggleStopVideo()
        case let .cameraState(state): setLiveCameraState(state)
        }
    }
}
