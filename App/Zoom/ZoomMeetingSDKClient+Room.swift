//
//  ZoomMeetingSDKClient+Room.swift
//  Greenroom
//
//  Phase 3: what a host sees happen in the room and the rules a host can set.
//
//  Events (protocols with no @optional, so every method is implemented):
//    - waiting room   ZoomSDKWaitingRoomDelegate, ZoomSDKWaitingRoomController.h:126-170 (7 methods)
//    - reactions      ZoomSDKReactionControllerDelegate, ZoomSDKReactionController.h:15-46 (4 methods)
//  Both controllers' `delegate` properties: ZoomSDKWaitingRoomController.h:187 and
//  ZoomSDKReactionController.h:65.
//
//  Rules and actions, each read and written through these headers:
//    lock meeting             ActionMeetingCmd_LockMeeting / _UnLockMeeting (ZoomSDKErrors.h:73-75); the
//                             state is the onMeetingLockStatus: event (ActionController.h:791), no getter
//    waiting room on/off      isEnableWaitingRoomOnEntry / enableWaitingRoomOnEntry: /
//                             isWaitingRoomOnEntryLocked (WaitingRoomController.h:204-222)
//    share rule               getShareSettingType: / setShareSettingType: (ActionController.h:1029-1036)
//    chat who                 setParticipantsChatPrivilege: (ActionController.h:1357); the read is
//                             isParticipantsChatAllowed (:1128) plus what was last set here
//    rename / unmute / video  isParticipants{Rename,UnmuteSelf,StartVideo}Allowed (:1141, :1258, :1433)
//    suspend                  canSuspendParticipantsActivities / suspendParticipantsActivities (:1478-1484)
//    admit, deny, send back   admitToMeeting: / admitAllToMeeting / expelUser: / putIntoWaitingRoom:
//                             (WaitingRoomController.h:223-311), expel gated by canExpelUser (:304)
//
import AppKit
import Foundation
import ZoomSDK

// MARK: - Events

@MainActor
final class RoomEvents: NSObject, ZoomSDKWaitingRoomDelegate, ZoomSDKReactionControllerDelegate {

    private(set) var waiting = WaitingRoomLedger()
    private(set) var reactions = ReactionLedger()
    /// What Zoom last said about the waiting room's entrance; nil until it does.
    private(set) var entranceEnabled: Bool?
    /// The chat rule as last set from here (the SDK has no direct getter).
    var chatWho: ChatWho = .everyone
    /// Kept so that sharing by everyone returns to the host's last choice.
    var lastConcurrent: ConcurrentShare = .one

    /// Something a host should see changed: redraw the toolbar and window now.
    var onChange: (() -> Void)?
    /// Someone reached the waiting room (name, how many are waiting).
    var onWaitingJoin: ((WaitingPerson, Int) -> Void)?
    var nameForWaiting: (UInt32) -> String? = { _ in nil }

    static func log(_ message: String) { ZoomMeetingSDKClient.videoLog("Room: \(message)") }

    func install(on service: ZoomSDKMeetingService) {
        service.getWaitingRoomController().delegate = self
        service.getReactionController().delegate = self
        Self.log("waiting-room and reaction delegates wired")
    }

    func reset() {
        waiting = WaitingRoomLedger()
        reactions = ReactionLedger()
        entranceEnabled = nil
        chatWho = .everyone
        lastConcurrent = .one
    }

    func changed() { onChange?() }

    func syncWaiting(present: Set<UInt32>) { waiting.keep(only: present) }
    func pruneReactions(present: Set<UInt32>) { reactions.prune(now: Date(), present: present) }

    // MARK: ZoomSDKWaitingRoomDelegate

    func onUserJoinWaitingRoom(_ userid: UInt32) {
        waiting.arrived(userid, at: Date())
        let name = nameForWaiting(userid) ?? ""
        Self.log("joined waiting room user=\(userid)")
        let count = ZoomSDK.shared().getMeetingService()?.getWaitingRoomController()
            .getWaitRoomUserList()?.count ?? 1
        onWaitingJoin?(WaitingPerson(id: userid, name: name), count)
        onChange?()
    }

    func onUserLeftWaitingRoom(_ userid: UInt32) {
        waiting.left(userid)
        onChange?()
    }

    func onWaitingRoomPresetAudioStatusChanged(_ audioCanTurnOn: Bool) {}
    func onWaitingRoomPresetVideoStatusChanged(_ videoCanTurnOn: Bool) {}
    func onCustomWaitingRoomDataUpdated(_ bData: ZoomSDKCustomWaitingRoomData?,
                                        handle: ZoomSDKWaitingRoomDataDownloadHandler?) {}
    func onWaitingRoomUserNameChanged(_ userID: UInt32, userName: String) { onChange?() }

    func onWaitingRoomEntranceEnabled(_ enabled: Bool) {
        entranceEnabled = enabled
        onChange?()
    }

    // MARK: ZoomSDKReactionControllerDelegate

    func onEmojiReactionReceived(_ userid: UInt32, reactionType type: ZoomSDKEmojiReactionType,
                                 reactionSkinTone skinTone: ZoomSDKEmojiReactionSkinTone) {
        guard let glyph = ReactionWords.glyph(reactionRaw: Int(type.rawValue)) else { return }
        reactions.reacted(userid, glyph: glyph, at: Date())
        onChange?()
        // The tile clears three seconds on; redraw then, not at the next poll.
        DispatchQueue.main.asyncAfter(deadline: .now() + ReactionLedger.lifetime + 0.1) { [weak self] in
            self?.onChange?()
        }
    }

    func onEmojiReactionReceived(inWebinar type: ZoomSDKEmojiReactionType) {}

    func onEmojiFeedbackReceived(_ userid: UInt32, emojiFeedbackType type: ZoomSDKEmojiFeedbackType) {
        if let label = ReactionWords.label(feedbackRaw: Int(type.rawValue)) {
            reactions.gaveFeedback(userid, label: label)
        } else {
            reactions.canceledFeedback(userid)
        }
        onChange?()
    }

    func onEmojiFeedbackCanceled(_ userid: UInt32) {
        reactions.canceledFeedback(userid)
        onChange?()
    }
}

// MARK: - Rules, read and written

@MainActor
extension ZoomMeetingSDKClient {

    private var actions: ZoomSDKMeetingActionController? {
        ZoomSDK.shared().getMeetingService()?.getMeetingActionController()
    }
    private var waitingRoom: ZoomSDKWaitingRoomController? {
        ZoomSDK.shared().getMeetingService()?.getWaitingRoomController()
    }

    /// The Security menu's live state. Read at the moment the menu opens and on
    /// every one-second refresh.
    func securityState() -> SecurityMenuState {
        var state = SecurityMenuState()
        state.locked = meetingIsLocked
        if let room = waitingRoom, room.isSupportWaitingRoom() {
            state.waitingRoomSupported = true
            state.waitingRoomOn = roomEvents.entranceEnabled ?? room.isEnableWaitingRoomOnEntry()
            state.waitingRoomLocked = room.isWaitingRoomOnEntryLocked()
        } else {
            state.waitingRoomSupported = false
        }
        let flags = roomFlags()
        state.rename = flags.renameAllowed
        state.unmuteSelf = flags.unmuteSelfAllowed
        state.startVideo = flags.startVideoAllowed
        state.canSuspend = flags.canSuspend
        state.shareRule = shareRule()
        // Not allowed at all is "No one"; otherwise whatever was last chosen
        // here, which starts as everyone.
        state.chat = flags.chatAllowed ? (roomEvents.chatWho == .nobody ? .everyone : roomEvents.chatWho) : .nobody
        return state
    }

    // MARK: Share rule

    func shareRule() -> ShareRule? {
        var type = ShareSettingType_None
        if let actions, actions.getShareSettingType(&type) == ZoomSDKError_Success,
           let rule = ShareRule(sdkRaw: Int(type.rawValue), remembering: roomEvents.lastConcurrent) {
            if rule.who == .everyone { roomEvents.lastConcurrent = rule.concurrent }
            return rule
        }
        // The SDK would not say; fall back to the plain allow-sharing flag.
        guard let actions else { return nil }
        return ShareRule(who: actions.isParticipantsShareAllowed() ? .everyone : .hostOnly,
                         concurrent: roomEvents.lastConcurrent)
    }

    func setShareRule(_ rule: ShareRule) -> Bool {
        guard let actions else { return false }
        let type = ZoomSDKShareSettingType(rawValue: UInt32(rule.sdkRaw))
        if rule.who == .everyone { roomEvents.lastConcurrent = rule.concurrent }
        return actions.setShareSettingType(type) == ZoomSDKError_Success
    }

    /// Why this Mac cannot start a share right now, or nil when it can.
    func cannotShareReason() -> String? {
        guard let controller = ZoomSDK.shared().getMeetingService()?.getASController() else { return nil }
        var reason = ZoomSDKCannotShareReasonType_None
        if controller.canStartShare(&reason) { return nil }
        switch reason {
        case ZoomSDKCannotShareReasonType_Locked: return "The host has locked sharing"
        case ZoomSDKCannotShareReasonType_Disabled: return "Sharing is turned off for this meeting"
        case ZoomSDKCannotShareReasonType_Other_Screen_Sharing: return "Someone else is sharing"
        case ZoomSDKCannotShareReasonType_Other_WB_Sharing: return "Someone is sharing a whiteboard"
        default: return "Zoom will not let this Mac share right now"
        }
    }

    // MARK: Chat, waiting room

    func setChatWho(_ who: ChatWho) -> Bool {
        guard let actions else { return false }
        let type = ZoomSDKChatPrivilegeType(rawValue: UInt32(who.sdkRaw))
        let ok = actions.setParticipantsChatPrivilege(type) == ZoomSDKError_Success
        if ok { roomEvents.chatWho = who }
        return ok
    }

    func setWaitingRoomOn(_ on: Bool) -> Bool {
        guard let room = waitingRoom else { return false }
        let ok = room.enableWaitingRoom(onEntry: on) == ZoomSDKError_Success
        if ok { roomEvents.syncWaiting(present: Set(waitingRoomNames().map(\.id))) }
        return ok
    }

    func canExpelFromWaitingRoom() -> Bool { waitingRoom?.canExpelUser() ?? false }

    /// Deny: removes them from the waiting room, so they are not admitted.
    func denyWaiting(userID: UInt32) -> Bool {
        waitingRoom?.expelUser(userID) == ZoomSDKError_Success
    }

    /// Send someone already in the meeting back to the waiting room.
    func putInWaitingRoom(userID: UInt32) -> Bool {
        waitingRoom?.put(intoWaitingRoom: userID) == ZoomSDKError_Success
    }

    var waitingRoomAvailable: Bool { waitingRoom?.isSupportWaitingRoom() ?? false }

    // MARK: Camera

    func cameraDevices() -> (devices: [MeetingMenus.Device], selectedID: String?) {
        guard let video = ZoomSDK.shared().getSettingService()?.getVideoSetting() else { return ([], nil) }
        let list = (video.getCameraList() ?? []).compactMap { $0 as? SDKDeviceInfo }
        let devices = list.map { MeetingMenus.Device(id: $0.getDeviceID() ?? "", name: $0.getDeviceName() ?? "Camera") }
        return (devices, list.first { $0.isSelectedDevice() }?.getDeviceID())
    }

    func selectCamera(id: String) -> Bool {
        ZoomSDK.shared().getSettingService()?.getVideoSetting()?.selectCamera(id) == ZoomSDKError_Success
    }

    // MARK: Zoom app

    /// A `zoommtg://` link for this meeting, for the Zoom app.
    func zoomAppLink() -> URL? {
        guard let invite = meetingInvite() else { return nil }
        return ZoomAppLink.make(joinURL: invite.joinURL, number: invite.number, passcode: invite.passcode)
    }
}
