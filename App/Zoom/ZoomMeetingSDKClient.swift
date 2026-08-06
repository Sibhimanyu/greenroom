//
//  ZoomMeetingSDKClient.swift
//  Greenroom
//
//  Wraps the native Zoom Meeting SDK (Vendor/ZoomSDK - see that folder's
//  README) to join a meeting as a SEPARATE, second connection purely for
//  chat - not a replacement for the native Zoom app, which is still what
//  carries your real video/audio. That means this shows up as a second
//  participant to everyone else in the meeting.
//
//  Every type/method/property name below is confirmed directly against
//  the real framework headers in
//  Vendor/ZoomSDK/ZoomSDK/ZoomSDK.framework/Versions/A/Headers/ - not
//  guessed from docs (an earlier draft of this file was; it had several
//  names wrong, e.g. the singleton is `sharedSDK()` not `shared()`, join
//  params are `ZoomSDKJoinMeetingElements` not `JoinMeetingParam4WithoutLogin`,
//  and the off-video/off-audio fields are `isNoVideo`/`isNoAudio` not
//  `isVideoOff`/`isAudioOff`). Still unbuilt/unrun though - this hasn't
//  gone through an actual Xcode compile yet.
//
//  NOTE: ZoomSDKError/ZoomSDKAuthError/ZoomSDKMeetingStatus are plain
//  `typedef enum` (not NS_ENUM), so Swift imports each case as a
//  top-level constant (e.g. `ZoomSDKError_Success`), not as `.success`
//  dot-syntax on the type.
//
import Foundation
import ZoomSDK

@MainActor
final class ZoomMeetingSDKClient: NSObject, ObservableObject {

    @Published private(set) var isJoined = false
    /// True when this SDK connection STARTED the meeting (New Meeting
    /// mode) rather than joining one - decides whether leaving should end
    /// the meeting for everyone.
    private(set) var isHosting = false

    private var didInit = false
    private var authCompletion: ((Result<Void, Error>) -> Void)?
    private var joinCompletion: ((Result<Void, Error>) -> Void)?

    /// Brings the SDK up and authorizes it. Idempotent - safe to call every
    /// time before joining.
    func ensureReady(clientID: String, clientSecret: String) async throws {
        if !didInit {
            let params = ZoomSDKInitParams()
            params.enableLog = true
            params.zoomDomain = "zoom.us"
            let result = ZoomSDK.shared().initSDK(with: params)
            guard result == ZoomSDKError_Success else {
                throw ZoomMeetingSDKError.initFailed(result)
            }
            didInit = true
        }

        guard let jwt = ZoomMeetingSDKJWT.makeToken(clientID: clientID, clientSecret: clientSecret) else {
            throw ZoomMeetingSDKError.jwtGenerationFailed
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            // getAuthService() is declared nonnull in the header (no
            // _Nullable under NS_ASSUME_NONNULL_BEGIN), so Swift imports it
            // as non-optional - confirmed by the compiler rejecting a
            // guard-let here.
            let authService = ZoomSDK.shared().getAuthService()
            authCompletion = { result in continuation.resume(with: result) }
            authService.delegate = self
            let context = ZoomSDKAuthContext()
            context.jwtToken = jwt
            let result = authService.sdkAuth(context)
            if result != ZoomSDKError_Success {
                continuation.resume(throwing: ZoomMeetingSDKError.authCallFailed(result))
                authCompletion = nil
            }
            // On success, onZoomSDKAuthReturn below resolves this, not here.
        }
    }

    /// The SDK's join/start flow pops a video-preview dialog by default -
    /// a modal that needs a click. Deadly in combination with the ghost
    /// window hiding (confirmed live: the dialog appeared, got hidden
    /// half a second later, and the start sat waiting forever on an
    /// invisible button). Suppress it before every connect.
    ///
    /// Also strips the meeting window down ahead of time: the parked
    /// side-column tile should be a simple current-speaker view, so the
    /// self-thumbnail strip and the info button overlay are hidden here
    /// (configuration is read at join; see simplifyMeetingView() for the
    /// part that can only happen once the window exists).
    private func suppressInteractiveJoinUI() {
        guard let meetingService = ZoomSDK.shared().getMeetingService() else { return }
        meetingService.getMeetingUIController().isShowVideoPreview(whenJoinMeeting: false)
        let configuration = meetingService.getMeetingConfiguration()
        configuration.hideThumbnailVideoWindow = true
        configuration.hideMeetingInfoButtonOnVideo = true
        // Without this, the active-speaker layout still shows YOU next to
        // the speaker whenever your camera is on. Same switch as the Zoom
        // client's "Hide Self View" (ZoomSDKSettingVideoController.h) -
        // your video keeps sending, it's just not rendered locally.
        ZoomSDK.shared().getSettingService()?.getVideoSetting()?.enableHideSelfView(true)
    }

    /// Switches the built-in client's meeting window to the plain
    /// current-speaker layout (confirmed against
    /// ZoomSDKMeetingUIController.h: switchToActiveSpeakerView, the
    /// counterpart of switchToVideoWallView). Only meaningful once the
    /// meeting window actually exists, i.e. after InMeeting - callers
    /// invoke it when parking the window, not at connect time.
    func simplifyMeetingView() {
        ZoomSDK.shared().getMeetingService()?.getMeetingUIController().switchToActiveSpeakerView()
    }

    /// Dual-screen mode: the SDK opens a SECOND meeting window (the
    /// gallery/"people view", same as the Zoom client's dual-monitor
    /// option) alongside the primary one. The SDK persists this setting
    /// across sessions, so it's asserted - or explicitly cleared - before
    /// every connect rather than trusted. Confirmed against
    /// ZoomSDKSettingGeneralController.h (enableMeetingSetting:SettingCmd:)
    /// and MeetingSettingCmd_DualScreenMode in ZoomSDKErrors.h.
    func setDualScreenMode(_ enabled: Bool) {
        ZoomSDK.shared().getSettingService()?.getGeneralSetting()?
            .enableMeetingSetting(enabled, settingCmd: MeetingSettingCmd_DualScreenMode)
    }

    /// Joins as a second, muted/camera-off participant purely for chat -
    /// the actual meeting audio/video is still whatever's running in the
    /// native Zoom app.
    ///
    /// `onBehalfToken` is the OAuth-fetched OBF token Zoom's March 2026
    /// rule wants for meetings hosted outside the account that owns this
    /// SDK app (see ZoomOAuthClient.obfToken). Optional: same-account
    /// joins work without one.
    /// `enableMedia: true` is the all-in-one client mode - joins as the
    /// user with camera and mic live, rather than as a hidden chat-only
    /// participant.
    func join(meetingNumber: String, password: String, displayName: String = "Greenroom Chat", onBehalfToken: String? = nil, enableMedia: Bool = false) async throws {
        guard let number = Int64(meetingNumber) else {
            throw ZoomMeetingSDKError.invalidMeetingNumber
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let meetingService = ZoomSDK.shared().getMeetingService() else {
                continuation.resume(throwing: ZoomMeetingSDKError.meetingServiceUnavailable)
                return
            }
            joinCompletion = { result in continuation.resume(with: result) }
            meetingService.delegate = self
            suppressInteractiveJoinUI()

            let joinParam = ZoomSDKJoinMeetingElements()
            joinParam.meetingNumber = number
            joinParam.password = password
            joinParam.displayName = displayName
            joinParam.isNoVideo = !enableMedia
            joinParam.isNoAudio = !enableMedia
            joinParam.onBehalfToken = onBehalfToken

            let result = meetingService.joinMeeting(joinParam)
            if result != ZoomSDKError_Success {
                continuation.resume(throwing: ZoomMeetingSDKError.joinFailed(result))
                joinCompletion = nil
            }
            // On success, onMeetingStatusChange below resolves this, not here.
        }
    }

    /// All-in-one mode: force a specific camera (the OBS Virtual Camera)
    /// as the SDK client's video source, matched by name fragment.
    /// Requires the SDK to be initialized+authed (call after ensureReady).
    func selectCamera(named nameFragment: String) -> Bool {
        guard let videoSetting = ZoomSDK.shared().getSettingService()?.getVideoSetting(),
              let list = videoSetting.getCameraList() else { return false }
        for case let device as SDKDeviceInfo in list {
            guard device.getDeviceName().localizedCaseInsensitiveContains(nameFragment) else { continue }
            return videoSetting.selectCamera(device.getDeviceID()) == ZoomSDKError_Success
        }
        return false
    }

    /// STARTS a meeting as its host, using the ZAK host key the
    /// create-meeting API returns - the meeting is live the moment this
    /// resolves, so the native Zoom client (and anyone else) can just
    /// join. This replaced launching the native client as host via
    /// zoommtg://start, which opened Zoom but silently failed to start
    /// the meeting (never diagnosed - client/account mismatch suspected).
    /// Confirmed against ZoomSDKMeetingService.h: startMeetingWithZAK: +
    /// ZoomSDKStartMeetingUseZakElements + SDKUserType_APIUser.
    ///
    /// `enableMedia: true` is the all-in-one client mode: the SDK IS the
    /// meeting client, camera and mic on, the user's own name - no ghost,
    /// no separate Zoom app.
    func startAsHost(meetingNumber: String, zak: String, displayName: String = "Greenroom Chat", enableMedia: Bool = false) async throws {
        guard let number = Int64(meetingNumber) else {
            throw ZoomMeetingSDKError.invalidMeetingNumber
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let meetingService = ZoomSDK.shared().getMeetingService() else {
                continuation.resume(throwing: ZoomMeetingSDKError.meetingServiceUnavailable)
                return
            }
            joinCompletion = { result in continuation.resume(with: result) }
            meetingService.delegate = self
            suppressInteractiveJoinUI()

            let startParam = ZoomSDKStartMeetingUseZakElements()
            startParam.zak = zak
            startParam.meetingNumber = number
            startParam.displayName = displayName
            startParam.userType = SDKUserType_APIUser
            startParam.isNoVideo = !enableMedia
            startParam.isNoAudio = !enableMedia

            let result = meetingService.startMeeting(withZAK: startParam)
            if result != ZoomSDKError_Success {
                continuation.resume(throwing: ZoomMeetingSDKError.joinFailed(result))
                joinCompletion = nil
            }
            // On success, onMeetingStatusChange resolves this at InMeeting.
        }
        isHosting = true
    }

    func chatController() -> ZoomSDKMeetingChatController? {
        ZoomSDK.shared().getMeetingService()?.getMeetingChatController()
    }

    /// Hands the host role to the first human who joins - in the session
    /// flow that's the user's own native Zoom client, which Greenroom
    /// launches into the meeting seconds after starting it. Gives the
    /// user the REAL host experience (participants panel, security menu,
    /// mute controls) in their own client instead of the role sitting
    /// with this invisible connection. Polls because the native client
    /// takes a few seconds to arrive.
    ///
    /// On success, `isHosting` flips false: leave()/Stop then merely
    /// leaves (a non-host can't end the meeting) - ending it becomes the
    /// user's call from their own Zoom.
    func promoteFirstOtherParticipantToHost(timeout: TimeInterval) async -> Bool {
        guard isHosting else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let action = ZoomSDK.shared().getMeetingService()?.getMeetingActionController(),
               let list = action.getParticipantsList() {
                for case let id as NSNumber in list {
                    guard let info = action.getUserByUserID(id.uint32Value), !info.isMySelf() else { continue }
                    if action.makeHost(id.uint32Value) == ZoomSDKError_Success {
                        isHosting = false
                        return true
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Leaves the meeting. When this connection is the HOST (New Meeting
    /// mode), leaving ends the meeting for everyone - Stop means the
    /// session is over, not "the host vanished and the meeting lingers".
    /// Safe to call when not in one. The isJoined flip also feeds the
    /// coordinator's meeting-ended observer, which closes the chat window.
    func leave() {
        let cmd = isHosting ? LeaveMeetingCmd_End : LeaveMeetingCmd_Leave
        ZoomSDK.shared().getMeetingService()?.leaveMeeting(with: cmd)
        isJoined = false
        isHosting = false
    }
}

enum ZoomMeetingSDKError: LocalizedError {
    case initFailed(ZoomSDKError)
    case jwtGenerationFailed
    case authServiceUnavailable
    case authCallFailed(ZoomSDKError)
    case authRejected(ZoomSDKAuthError)
    case meetingServiceUnavailable
    case invalidMeetingNumber
    case joinFailed(ZoomSDKError)
    /// The real, specific reason from ZoomSDKMeetingServiceDelegate's
    /// `meetingError` - this is the one that actually matters (e.g.
    /// `ZoomSDKMeetingError_UnableToJoinExternalMeeting = 63` or
    /// `ZoomSDKMeetingError_AppCanNotAnonymousJoinMeeting = 504`, both of
    /// which point at Zoom's cross-account-join restriction). An earlier
    /// version of this file discarded this value and reported a hardcoded
    /// generic ZoomSDKError_Failed instead - fixed after a real join
    /// attempt surfaced only "(rawValue: 1)" with no way to tell which of
    /// several possible causes it actually was.
    case joinRejected(ZoomSDKMeetingError)

    /// Zoom refused because the meeting is hosted on a different Zoom
    /// account than the one owning this Marketplace app (error 63).
    /// Exposed as a plain Bool so callers outside App/Zoom/ can branch on
    /// it without importing ZoomSDK - the Zoom types stay behind this
    /// wrapper layer.
    var isCrossAccountRejection: Bool {
        if case .joinRejected(let reason) = self {
            return reason == ZoomSDKMeetingError_UnableToJoinExternalMeeting
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .initFailed(let error): return "Meeting SDK init failed (\(error))."
        case .jwtGenerationFailed: return "Couldn't build the Meeting SDK auth token."
        case .authServiceUnavailable: return "Zoom Meeting SDK's auth service isn't available."
        case .authCallFailed(let error): return "Meeting SDK auth call failed immediately (\(error))."
        case .authRejected(let error): return "Meeting SDK auth was rejected (\(error))."
        case .meetingServiceUnavailable: return "Zoom Meeting SDK's meeting service isn't available."
        case .invalidMeetingNumber: return "Meeting number must be numeric."
        case .joinFailed(let error): return "Zoom Meeting SDK join call failed immediately (\(error))."
        case .joinRejected(let error): return "Zoom Meeting SDK join was rejected (\(error))."
        }
    }
}

// MARK: - ZoomSDKAuthDelegate
// Confirmed against ZoomSDKAuthService.h - both methods here are @required.

extension ZoomMeetingSDKClient: ZoomSDKAuthDelegate {
    func onZoomSDKAuthReturn(_ returnValue: ZoomSDKAuthError) {
        authCompletion?(returnValue == ZoomSDKAuthError_Success ? .success(()) : .failure(ZoomMeetingSDKError.authRejected(returnValue)))
        authCompletion = nil
    }

    func onZoomAuthIdentityExpired() {
        // Would need re-auth via ensureReady(...) again - not wired up yet
        // since this is a short-lived personal tool, not a long-running service.
    }
}

// MARK: - ZoomSDKMeetingServiceDelegate
// Confirmed against ZoomSDKMeetingService.h - this method is @optional;
// implementing it is enough, no other methods on this protocol are required.

extension ZoomMeetingSDKClient: ZoomSDKMeetingServiceDelegate {
    // Confirmed by the compiler itself (a "nearly matches" note surfaced
    // the real bridged signature) - the third label is `end`, not
    // `endReason` as guessed in an earlier draft.
    func onMeetingStatusChange(_ state: ZoomSDKMeetingStatus, meetingError error: ZoomSDKMeetingError, end reason: EndMeetingReason) {
        switch state {
        case ZoomSDKMeetingStatus_InMeeting:
            isJoined = true
            joinCompletion?(.success(()))
            joinCompletion = nil
        case ZoomSDKMeetingStatus_Failed, ZoomSDKMeetingStatus_Ended, ZoomSDKMeetingStatus_Disconnecting:
            if !isJoined {
                joinCompletion?(.failure(ZoomMeetingSDKError.joinRejected(error)))
                joinCompletion = nil
            }
            isJoined = (state == ZoomSDKMeetingStatus_InMeeting)
        default:
            break
        }
    }
}
