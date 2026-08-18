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
    private var isAuthed = false
    private var authedClientID: String?
    private var authCompletion: ((Result<Void, Error>) -> Void)?
    private var joinCompletion: ((Result<Void, Error>) -> Void)?
    /// Bumped every time a completion slot is armed, so a watchdog from
    /// an earlier attempt can never fire into a later attempt's slot.
    private var callbackGeneration = 0

    /// Watchdogs for the single-slot SDK callbacks: when the delegate
    /// never fires (a wedged SDK - it happens), the waiting continuation
    /// must FAIL, not leave Start stuck on "Starting..." until force
    /// quit. Safe against double-resume: whoever takes the slot first
    /// (delegate or watchdog) nils it, and both run on the main thread.
    private func armAuthWatchdog(seconds: TimeInterval = 30) {
        callbackGeneration += 1
        let generation = callbackGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.callbackGeneration == generation,
                  let completion = self.authCompletion else { return }
            self.authCompletion = nil
            completion(.failure(ZoomMeetingSDKError.timedOut("Zoom SDK authorization")))
        }
    }

    private func armJoinWatchdog(seconds: TimeInterval = 120) {
        callbackGeneration += 1
        let generation = callbackGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.callbackGeneration == generation,
                  let completion = self.joinCompletion else { return }
            self.joinCompletion = nil
            completion(.failure(ZoomMeetingSDKError.timedOut("Connecting to the meeting")))
        }
    }

    /// Brings the SDK up and authorizes it. Genuinely idempotent: a repeat
    /// call with the same credentials returns immediately instead of
    /// re-running the ~1-2s SDK auth round trip - which lets the start
    /// flow prefetch this in parallel with the OBS pipeline and lets the
    /// meeting flows call it again for free.
    func ensureReady(clientID: String, clientSecret: String) async throws {
        if isAuthed && authedClientID == clientID { return }
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
            armAuthWatchdog()
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
        isAuthed = true
        authedClientID = clientID
    }

    /// Orderly SDK teardown for process exit. The SDK's in-process video
    /// and audio engines (zVideoUIBridge, viper) SEGV in their own
    /// destructors when the process simply exits around them - every
    /// "Greenroom quit unexpectedly" dialog was one of those, confirmed
    /// against the crash reports. unInitSDK (ZoomSDK.h) lets them shut
    /// down while the runtime is still intact.
    func shutdown() {
        guard didInit else { return }
        ZoomSDK.shared().unInitSDK()
        didInit = false
        isAuthed = false
        authedClientID = nil
    }

    /// Waits (bounded) for the meeting to actually reach a closed state
    /// after leave() - so a hosted meeting's END lands at Zoom before
    /// unInitSDK/_exit tears the SDK down mid-send. Returns the moment
    /// the status is terminal; no-op when the SDK never initialized.
    func awaitMeetingClosed(timeout: TimeInterval = 5) async {
        guard didInit, let service = ZoomSDK.shared().getMeetingService() else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch service.getMeetingStatus() {
            case ZoomSDKMeetingStatus_Idle, ZoomSDKMeetingStatus_Ended, ZoomSDKMeetingStatus_Failed:
                return
            default:
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
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
        // Zoom's "Hide Self View" - a USER PREFERENCE, not hardcoded:
        // hidden (the default) keeps the speaker tile and gallery to just
        // the others; shown puts your tile among them like anyone else's.
        // Either way your video keeps sending - this only affects local
        // rendering (ZoomSDKSettingVideoController.h).
        ZoomSDK.shared().getSettingService()?.getVideoSetting()?.enableHideSelfView(hideSelfViewPreference)
        // "Mirror my video" OFF (persisted setting, asserted every
        // connect): mirroring only affects the LOCAL self-view - others
        // always see the feed un-mirrored - and this feed is the OBS
        // composite with the shared screen's TEXT in it, which mirroring
        // renders backwards to the presenter mid-lesson. Off, the
        // self-view shows exactly what the class sees.
        ZoomSDK.shared().getSettingService()?.getVideoSetting()?.enableMirrorEffect(false)
        // "Spotlight my video when I speak" OFF (persisted, asserted
        // every connect): with it stuck on, the active-speaker view LOCKS
        // ONTO YOUR OWN video whenever you talk - and a teacher talks
        // most of the class, so the speaker tile showed the presenter
        // instead of the students (reported live). Off, the speaker view
        // follows whoever else is talking, Zoom's normal behavior.
        ZoomSDK.shared().getSettingService()?.getVideoSetting()?.onSpotlightMyVideo(whenISpeaker: false)
        // PERSISTED setting, asserted off before every connect (same
        // never-trust doctrine as DualScreenMode below): when it sticks
        // on, the SDK fullscreens its meeting windows at join - and a
        // fullscreen meeting window on the main display gets filmed by
        // OBS's screen capture, feeding the meeting back into itself
        // (the "cascading" camera feed seen live). Fullscreen windows
        // also ignore setFrame, so window parking silently failed too.
        ZoomSDK.shared().getSettingService()?.getGeneralSetting()?
            .enableMeetingSetting(false, settingCmd: MeetingSettingCmd_AutoFullScreenWhenJoinMeeting)
    }

    /// Whether the local self-view tile is hidden (Zoom's "Hide Self
    /// View"). Synced from the coordinator's preference; read at connect
    /// by suppressInteractiveJoinUI.
    var hideSelfViewPreference = true

    /// Applies the Hide Self View preference - works live mid-meeting
    /// (it's a settings-service switch, not a join-time-only config).
    func setHideSelfView(_ hide: Bool) {
        hideSelfViewPreference = hide
        ZoomSDK.shared().getSettingService()?.getVideoSetting()?.enableHideSelfView(hide)
    }

    /// Kicks BOTH meeting views (primary + dual-screen gallery) out of
    /// fullscreen via the SDK's own control (ZoomSDKMeetingUIController.h
    /// enterFullScreen:firstMonitor:DualMonitor:). The window parker calls
    /// this before tiling: a window in a fullscreen Space ignores
    /// setFrame, so nothing can be positioned until this has run.
    func exitFullScreen() {
        ZoomSDK.shared().getMeetingService()?.getMeetingUIController()
            .enterFullScreen(false, firstMonitor: true, dualMonitor: true)
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

    /// Switches the PRIMARY meeting view to the gallery/video-wall grid -
    /// used in dual-screen sessions, where the primary window (the one
    /// carrying Zoom's meeting controls) lives full-screen on the
    /// extended display: grid + controls there, while the SECONDARY
    /// video-only window shows Zoom's complementary clean active-speaker
    /// view and makes the parked tile.
    func showGalleryOnPrimaryView() {
        ZoomSDK.shared().getMeetingService()?.getMeetingUIController().switchToVideoWallView()
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
        guard let number = Int64(ZoomMeetingLinkParser.digits(meetingNumber)) else {
            throw ZoomMeetingSDKError.invalidMeetingNumber
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let meetingService = ZoomSDK.shared().getMeetingService() else {
                continuation.resume(throwing: ZoomMeetingSDKError.meetingServiceUnavailable)
                return
            }
            joinCompletion = { result in continuation.resume(with: result) }
            armJoinWatchdog()
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
        guard let number = Int64(ZoomMeetingLinkParser.digits(meetingNumber)) else {
            throw ZoomMeetingSDKError.invalidMeetingNumber
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let meetingService = ZoomSDK.shared().getMeetingService() else {
                continuation.resume(throwing: ZoomMeetingSDKError.meetingServiceUnavailable)
                return
            }
            joinCompletion = { result in continuation.resume(with: result) }
            armJoinWatchdog()
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
        // The isHosting flag only knows about explicit host STARTS - but
        // host can also arrive mid-meeting: joining your OWN meeting (the
        // Scheduled list flow) has Zoom promote you on arrival, with the
        // flag still false, so Stop used to merely leave and the meeting
        // kept running host-less. Ask the SDK who we are RIGHT NOW; the
        // live answer also covers the hybrid flow's host handoff (host
        // given away mid-meeting -> just leave, as before).
        let isHostNow = ZoomSDK.shared().getMeetingService()?
            .getMeetingActionController().getMyself()?.isHost() ?? false
        let cmd = (isHosting || isHostNow) ? LeaveMeetingCmd_End : LeaveMeetingCmd_Leave
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
    case timedOut(String)
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
        case .timedOut(let what): return "\(what) timed out \u{2014} the Zoom SDK never called back. Press End Session and try again."
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
