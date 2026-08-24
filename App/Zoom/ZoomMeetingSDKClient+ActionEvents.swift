//
//  ZoomMeetingSDKClient+ActionEvents.swift
//  Greenroom
//
//  The meeting action controller's delegate - the SDK's EVENT channel for
//  in-meeting state. Custom UI mode needs it for exactly one thing Greenroom
//  cannot get any other way: who is speaking, live.
//
//  isTalking() exists and is a poll, but the signals Zoom actually documents
//  for active-speaker tracking are onUserActiveAudioChange (the users
//  currently producing audio) and onActiveSpeakerVideoUserChanged - both
//  delegate-only. Polling left the featured tile stuck on whoever joined
//  first; the events are what Zoom's own UI runs on.
//
//  The protocol is 51 methods with no @optional, so most of this file is
//  deliberate no-ops. Only the handful at the top do anything.
//
import Foundation
import ZoomSDK

extension ZoomMeetingSDKClient: ZoomSDKMeetingActionControllerDelegate {

    // MARK: The events this file exists for

    /// The users currently producing audio. THE active-speaker signal.
    ///
    /// An empty array means silence - the last speaker is deliberately kept,
    /// so the featured tile stays on whoever spoke last instead of blanking
    /// between sentences.
    public func onUserActiveAudioChange(_ useridArray: [Any]!) {
        let ids = (useridArray as? [NSNumber])?.map { $0.uint32Value } ?? []
        noteActiveAudio(ids)
    }

    /// Zoom's own pick of the featured video user - fires when IT would switch
    /// its speaker view. Kept alongside the audio event: audio says "is making
    /// sound now", this says "deserves the big tile", and following Zoom's own
    /// judgement makes the panel agree with what students see in their Zoom.
    public func onActiveSpeakerVideoUserChanged(_ userID: UInt32) {
        noteActiveSpeaker(userID)
    }

    public func onActiveVideoUserChanged(_ userID: UInt32) {
        noteActiveSpeaker(userID)
    }

    // MARK: Deliberate no-ops (protocol has no @optional)

    public func onUserAudioStatusChange(_ userAudioStatusArray: [Any]!) {}
    public func onUserJoin(_ array: [Any]!) {
        onParticipantCountChanged?()
    }

    /// Someone left: release their video element NOW. The 1s poll would get
    /// there, but the subscription slot it frees is budget the remaining
    /// tiles may be waiting on.
    public func onUserLeft(_ array: [Any]!) {
        let ids = (array as? [NSNumber])?.map { $0.uint32Value } ?? []
        guard !ids.isEmpty else { return }
        noteUsersLeft(ids)
        onParticipantCountChanged?()
    }
    public func onUserInfoUpdate(_ userID: UInt32) {}
    public func onHostChange(_ userID: UInt32) {}
    public func onVirtualNameTagStatusChanged(_ bOn: Bool, userID: UInt32) {}
    public func onVirtualNameTagRosterInfoUpdated(_ userID: UInt32) {}
    public func onMeetingCoHostChanged(_ userID: UInt32, isCoHost: Bool) {}
    public func onSpotlightVideoUserChange(_ spotlightedUserList: [Any]?) {}
    public func onVideoStatusChange(_ videoStatus: ZoomSDKVideoStatus, userID: UInt32) {}
    public func onLowOrRaiseHandStatusChange(_ raise: Bool, userID: UInt32) {}
    public func onJoinMeetingResponse(_ joinMeetingHelper: ZoomSDKJoinMeetingHelper?) {}
    public func onMulti(toSingleShareNeedConfirm confirmHandle: ZoomSDKMultiToSingleShareConfirmHandler?) {}
    public func onHostAskUnmute() {}
    public func onHostAskStartVideo() {}
    public func onUserNamesChanged(_ userList: [NSNumber]) {}
    public func onInvalidReclaimHostKey() {}
    public func onHostVideoOrderUpdated(_ orderList: [Any]) {}
    public func onLocalVideoOrderUpdated(_ localOrderList: [Any]) {}
    public func onFollowHostVideoOrderChanged(_ follow: Bool) {}
    public func onAllHandsLowered() {}
    public func onUserVideoQualityChanged(_ quality: ZoomSDKVideoQuality, userID: UInt32) {}
    public func onChatMsgDeleteNotification(_ msgID: String, messageDeleteType: ZoomSDKChatMessageDeleteType) {}
    public func onChatStatusChangedNotification(_ status: ZoomSDKChatStatus) {}
    public func onShareMeetingChatStatusChanged(_ start: Bool) {}
    public func onSuspendParticipantsActivities() {}
    public func onAllowParticipantsStartVideoNotification(_ allow: Bool) {}
    public func onAllowParticipantsRenameNotification(_ allow: Bool) {}
    public func onAllowParticipantsUnmuteSelfNotification(_ allow: Bool) {}
    public func onAllowParticipantsShareWhiteBoardNotification(_ allow: Bool) {}
    public func onMeetingLockStatus(_ isLock: Bool) {}
    public func onRequestLocalRecordingPrivilegeChanged(_ status: ZoomSDKLocalRecordingRequestPrivilegeStatus) {}
    public func onAllowParticipantsRequestCloudRecording(_ allow: Bool) {}
    public func on(inMeetingUserAvatarPathUpdated userID: UInt32) {}
    public func onAICompanionActiveChangeNotice(_ active: Bool) {}
    public func onParticipantProfilePictureStatusChange(_ hidden: Bool) {}
    public func onVideoAlphaChannelStatusChanged(_ isAlphaModeOn: Bool) {}
    public func onFocusModeStateChanged(_ on: Bool) {}
    public func onFocusModeShareTypeChanged(_ type: ZoomSDKFocusModeShareType) {}
    public func onMeetingQAStatusChanged(_ available: Bool) {}
    public func notify(toJoin3rdPartyTelephonyAudio audioInfo: String) {}
    public func onCameraControlRequestReceived(_ userID: UInt32,
                                               requestType: ZoomSDKCameraControlRequestType,
                                               actionApprove: (() -> ZoomSDKError)?,
                                               actionDecline: (() -> ZoomSDKError)?) {}
    public func onCameraControlRequestResult(_ userID: UInt32, resultType: ZoomSDKCameraControlRequestResult) {}
    public func onMute(onEntryStatusChange bEnabled: Bool) {}
    public func onMeetingTopicChanged(_ topic: String) {}
    public func onBotAuthorizerRelationChanged(_ authorizerUserID: UInt32) {}
    public func onCreateCompanionRelation(_ parentUserID: UInt32, childUserID: UInt32) {}
    public func onRemoveCompanionRelation(_ userID: UInt32) {}
    public func onGrantCoOwnerPrivilegeChanged(_ isGrant: Bool) {}
}
