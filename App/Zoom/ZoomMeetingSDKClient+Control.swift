//
//  ZoomMeetingSDKClient+Control.swift
//  Greenroom
//
//  The roster, and every action a host can take on it.
//
//  None of this exists in default Zoom-UI mode: there, Zoom's own participants
//  panel reads the roster and offers the actions. Custom UI hands us bare video
//  views and nothing else, so the reference display has to ask for both.
//
//  Worth recording, because the header layout hides it: participant mute is NOT
//  a named method. There is no `muteUser:`. It is reached through the generic
//  `actionMeetingWithCmd:userID:onScreen:` with `ActionMeetingCmd_MuteAudio`,
//  which is why searching the headers for "mute" turns up only waiting-room
//  presets and callbacks. The same entry point carries mute-all, video mute,
//  unmute-by-self permission and meeting lock.
//
import AppKit
import Foundation
import ZoomSDK

@MainActor
extension ZoomMeetingSDKClient {

    // MARK: - Roster

    /// One participant, flattened into the facts the reference display draws.
    ///
    /// A value type on purpose: the display diffs these to decide what changed,
    /// and holding live `ZoomSDKUserInfo` objects across a refresh would mean
    /// reading SDK state at draw time from views that may outlive the user.
    struct RosterEntry: Identifiable, Equatable {
        var id: UInt32
        var name: String
        var isMyself: Bool
        var isHost: Bool
        var isCoHost: Bool
        var videoOn: Bool
        /// Muted, by themselves or by the host. `hasJoinedAudio == false` is a
        /// different state and is drawn differently: no microphone at all is
        /// not the same as a microphone that is off.
        var isMuted: Bool
        var hasJoinedAudio: Bool
        var isTalking: Bool
        var isRaisingHand: Bool
        var isSpotlighted: Bool
        var isPinned: Bool
    }

    private var actionController: ZoomSDKMeetingActionController? {
        ZoomSDK.shared().getMeetingService()?.getMeetingActionController()
    }

    /// The full roster, self included. Callers filter; this stays honest about
    /// who the SDK says is in the room.
    func meetingRoster() -> [RosterEntry] {
        guard let action = actionController else { return [] }
        let ids = (action.getParticipantsList() as? [NSNumber])?.map { $0.uint32Value } ?? []
        let spotlighted = Set((action.getSpotlightedUserList() as? [NSNumber])?.map { $0.uint32Value } ?? [])
        let pinned = Set((action.getPinnedUserListFromFirstView() as? [NSNumber])?.map { $0.uint32Value } ?? [])
        return ids.compactMap { id in
            guard let info = action.getUserByUserID(id) else { return nil }
            // Someone held at the door has no video to render and no state
            // worth acting on yet. They belong in the waiting-room count, not
            // as a black tile on the wall.
            guard !info.isInWaitingRoom() else { return nil }
            let audio = info.getAudioStatus()
            return RosterEntry(
                id: id,
                name: info.getUserName() ?? "Guest",
                isMyself: info.isMySelf(),
                isHost: info.isHost(),
                isCoHost: info.getUserRole() == UserRole_CoHost,
                videoOn: info.isVideoOn(),
                isMuted: audio == ZoomSDKAudioStatus_Muted
                    || audio == ZoomSDKAudioStatus_MutedByHost
                    || audio == ZoomSDKAudioStatus_MutedAllByHost,
                hasJoinedAudio: audio != ZoomSDKAudioStatus_None,
                isTalking: info.isTalking(),
                isRaisingHand: info.isRaisingHand(),
                isSpotlighted: spotlighted.contains(id),
                isPinned: pinned.contains(id)
            )
        }
    }

    // MARK: - Per-participant actions

    /// Mute and unmute, via the generic command entry point. `ScreenType_First`
    /// is the only screen this app renders to; the parameter exists for dual
    /// monitor Zoom layouts we do not use.
    func setMuted(_ muted: Bool, userID: UInt32) -> Bool {
        run { $0.actionMeeting(with: muted ? ActionMeetingCmd_MuteAudio : ActionMeetingCmd_UnMuteAudio,
                               userID: userID, on: ScreenType_First) }
    }

    /// Turning a camera OFF is a real host power. Turning one ON is only a
    /// request the participant must accept, which is why Zoom's own UI labels
    /// it "ask to start video" - the button here says the same.
    func setVideoMuted(_ muted: Bool, userID: UInt32) -> Bool {
        run { $0.actionMeeting(with: muted ? ActionMeetingCmd_MuteVideo : ActionMeetingCmd_UnMuteVideo,
                               userID: userID, on: ScreenType_First) }
    }

    func spotlight(_ on: Bool, userID: UInt32) -> Bool {
        run { on ? $0.spotlightVideo(userID) : $0.unSpotlightVideo(userID) }
    }

    func clearAllSpotlights() -> Bool { run { $0.unSpotlightAllVideos() } }

    func pin(_ on: Bool, userID: UInt32) -> Bool {
        run { on ? $0.pinVideo(toFirstView: userID) : $0.unPinVideo(fromFirstView: userID) }
    }

    func clearAllPins() -> Bool { run { $0.unPinAllVideosFromFirstView() } }

    func makeHost(userID: UInt32) -> Bool { run { $0.makeHost(userID) } }

    func setCoHost(_ on: Bool, userID: UInt32) -> Bool {
        run { on ? $0.assignCoHost(userID) : $0.revokeCoHost(userID) }
    }

    func rename(userID: UInt32, to name: String) -> Bool {
        run { $0.changeUserName(userID, newName: name) }
    }

    func lowerHand(userID: UInt32) -> Bool { run { $0.raiseHand(false, userID: userID) } }

    func expel(userID: UInt32) -> Bool { run { $0.expelUser(userID) } }

    // MARK: - Yourself

    /// The controls a teacher reaches for constantly, and the ones the first
    /// version of the panel simply did not have.
    ///
    /// There is no self-audio controller in this SDK; muting yourself is the
    /// same generic command used on anyone else, addressed to your own user ID.
    /// The panel used to hide every per-person control for `isMyself`, which is
    /// right for "make host" and wrong for the two buttons Zoom puts first.
    var myUserID: UInt32? { actionController?.getMyself()?.getUserID() }

    var iAmMuted: Bool {
        guard let me = actionController?.getMyself() else { return false }
        let status = me.getAudioStatus()
        return status == ZoomSDKAudioStatus_Muted
            || status == ZoomSDKAudioStatus_MutedByHost
            || status == ZoomSDKAudioStatus_MutedAllByHost
    }

    var myVideoIsOn: Bool { actionController?.getMyself()?.isVideoOn() ?? false }
    var myHandIsRaised: Bool { actionController?.getMyself()?.isRaisingHand() ?? false }

    func setMyMute(_ muted: Bool) -> Bool {
        guard let me = myUserID else { return false }
        return setMuted(muted, userID: me)
    }

    func setMyVideo(on: Bool) -> Bool {
        guard let me = myUserID else { return false }
        return setVideoMuted(!on, userID: me)
    }

    func setMyHand(raised: Bool) -> Bool {
        guard let me = myUserID else { return false }
        return run { $0.raiseHand(raised, userID: me) }
    }

    // MARK: - Sharing

    /// Zoom's own screen share, which is separate from the OBS composite this
    /// app sends as its camera. Both can run; they are different things, and the
    /// toolbar label has to say which.
    private var shareController: ZoomSDKASController? {
        ZoomSDK.shared().getMeetingService()?.getASController()
    }

    func shareableDisplays() -> [(id: CGDirectDisplayID, label: String)] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let size = screen.frame.size
            return (CGDirectDisplayID(number.uint32Value),
                    "Display \(index + 1) \u{2014} \(Int(size.width))\u{00D7}\(Int(size.height))")
        }
    }

    func startShare(displayID: CGDirectDisplayID) -> Bool {
        shareController?.startMonitorShare(displayID) == ZoomSDKError_Success
    }

    func stopShare() -> Bool {
        shareController?.stopShare() == ZoomSDKError_Success
    }

    // MARK: - Reactions

    /// Kept as a Swift enum so the UI never has to import ZoomSDK. The panel
    /// should know about students and actions, not about SDK constants.
    enum Reaction: String, CaseIterable {
        case thumbsUp   = "Thumbs up"
        case clap       = "Clap"
        case heart      = "Heart"
        case joy        = "Joy"
        case openMouth  = "Open mouth"
        case tada       = "Tada"

        fileprivate var sdkValue: ZoomSDKEmojiReactionType {
            switch self {
            case .thumbsUp:  return ZoomSDKEmojiReactionType_Thumbsup
            case .clap:      return ZoomSDKEmojiReactionType_Clap
            case .heart:     return ZoomSDKEmojiReactionType_Heart
            case .joy:       return ZoomSDKEmojiReactionType_Joy
            case .openMouth: return ZoomSDKEmojiReactionType_Openmouth
            case .tada:      return ZoomSDKEmojiReactionType_Tada
            }
        }
    }

    func send(_ reaction: Reaction) -> Bool {
        sendReaction(reaction.sdkValue)
    }

    private func sendReaction(_ type: ZoomSDKEmojiReactionType) -> Bool {
        ZoomSDK.shared().getMeetingService()?.getReactionController()
            .send(type) == ZoomSDKError_Success
    }

    // MARK: - Room-wide actions

    func muteEveryone() -> Bool {
        run { $0.actionMeeting(with: ActionMeetingCmd_MuteAll, userID: 0, on: ScreenType_First) }
    }

    /// Unmute-all is a request in Zoom's model, not a command: participants are
    /// asked, and each one accepts. Reported as sent, not as done.
    func askEveryoneToUnmute() -> Bool {
        run { $0.actionMeeting(with: ActionMeetingCmd_UnmuteAll, userID: 0, on: ScreenType_First) }
    }

    func setMeetingLocked(_ locked: Bool) -> Bool {
        run { $0.actionMeeting(with: locked ? ActionMeetingCmd_LockMeeting : ActionMeetingCmd_UnLockMeeting,
                               userID: 0, on: ScreenType_First) }
    }

    func lowerEveryHand() -> Bool { run { $0.lowerAllHands(false) } }

    func setAllowUnmuteSelf(_ allow: Bool) -> Bool {
        run { $0.actionMeeting(with: allow ? ActionMeetingCmd_EnableUnmuteBySelf : ActionMeetingCmd_DisableUnmuteBySelf,
                               userID: 0, on: ScreenType_First) }
    }

    func setAllowChat(_ allow: Bool) -> Bool { run { $0.allowParticipants(toChat: allow) } }
    func setAllowShare(_ allow: Bool) -> Bool { run { $0.allowParticipants(toShare: allow) } }
    func setAllowRename(_ allow: Bool) -> Bool { run { $0.allowParticipants(toRename: allow) } }
    func setAllowStartVideo(_ allow: Bool) -> Bool { run { $0.allowParticipants(toStartVideo: allow) } }
    func setFocusMode(_ on: Bool) -> Bool { run { $0.turnFocusMode(on: on) } }

    /// Local only: stops audio reaching this Mac. It does not mute anyone for
    /// each other, and the button has to say so or it reads as mute-all.
    func setIncomingAudioStopped(_ stopped: Bool) -> Bool { run { $0.stopIncomingAudio(stopped) } }

    func suspendAllActivities() -> Bool { run { $0.suspendParticipantsActivities() } }

    // MARK: - Readable room state

    struct RoomFlags: Equatable {
        var chatAllowed = true
        var shareAllowed = true
        var renameAllowed = true
        var startVideoAllowed = true
        var unmuteSelfAllowed = true
        var focusModeOn = false
        var incomingAudioStopped = false
        var iAmHostOrCoHost = false
        var canSuspend = false
    }

    func roomFlags() -> RoomFlags {
        guard let action = actionController else { return RoomFlags() }
        let me = action.getMyself()
        return RoomFlags(
            chatAllowed: action.isParticipantsChatAllowed(),
            shareAllowed: action.isParticipantsShareAllowed(),
            renameAllowed: action.isParticipantsRenameAllowed(),
            startVideoAllowed: action.isParticipantsStartVideoAllowed(),
            unmuteSelfAllowed: action.isParticipantsUnmuteSelfAllowed(),
            focusModeOn: action.isFocusModeOn(),
            incomingAudioStopped: action.isIncomingAudioStopped(),
            iAmHostOrCoHost: (me?.isHost() ?? false) || (me?.getUserRole() == UserRole_CoHost),
            canSuspend: action.canSuspendParticipantsActivities()
        )
    }

    // MARK: - Waiting room

    /// People held at the door. A class that starts on time needs this visible,
    /// not buried: a student stuck in the waiting room looks identical to a
    /// student who never showed up.
    func waitingRoomNames() -> [(id: UInt32, name: String)] {
        guard let room = ZoomSDK.shared().getMeetingService()?.getWaitingRoomController(),
              room.isSupportWaitingRoom(),
              let ids = room.getWaitRoomUserList() as? [NSNumber] else { return [] }
        return ids.map { number in
            let id = number.uint32Value
            return (id, room.getWaitingRoomUserInfo(id)?.getUserName() ?? "Guest")
        }
    }

    func admitFromWaitingRoom(userID: UInt32) -> Bool {
        ZoomSDK.shared().getMeetingService()?.getWaitingRoomController()
            .admit(toMeeting: userID) == ZoomSDKError_Success
    }

    func admitEveryoneWaiting() -> Bool {
        ZoomSDK.shared().getMeetingService()?.getWaitingRoomController()
            .admitAllToMeeting() == ZoomSDKError_Success
    }

    // MARK: -

    /// Every action funnels through here so a failure is a `false` rather than a
    /// silently discarded `ZoomSDKError`. The control surface reports what did
    /// not work; swallowing these is how the black screen-share bug survived
    /// four releases.
    private func run(_ body: (ZoomSDKMeetingActionController) -> ZoomSDKError) -> Bool {
        guard let action = actionController else { return false }
        return body(action) == ZoomSDKError_Success
    }
}
