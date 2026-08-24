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

    /// True once initSDK has run in this process. `needCustomizedUI` is an init
    /// parameter, so after this point the UI mode cannot change until relaunch -
    /// which Settings needs to know so it can say so rather than letting the
    /// toggle look broken.
    private(set) var didInit = false

    /// Whether this process initialised the SDK in custom-UI mode. Recorded at
    /// init because the flag could be flipped in defaults afterwards, and what
    /// matters downstream is the mode the SDK is actually RUNNING in.
    private(set) var didUseCustomUI = false

    /// Opt-in, and app-restart-scoped: `needCustomizedUI` is an initSDK
    /// parameter, so it cannot change while the process lives.
    static var customUIModeEnabled: Bool {
        UserDefaults.standard.bool(forKey: "customUIMode")
    }

    /// Held for the meeting's lifetime. The SDK renders into views owned by
    /// these objects, so dropping them would drop the video.
    private var videoContainer: ZoomSDKVideoContainer?

    /// Appends one line to ~/Library/Logs/Greenroom-video.log.
    ///
    /// A file, not the status log, for the same reason the quit path uses one:
    /// the status log is not reachable from outside the app, and a black tile
    /// gives no clue which of createNormalVideoElement, setResolution,
    /// subscribeVideo or showVideo actually refused.
    static func videoLog(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Greenroom-video.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Called when the SDK refuses a video subscription, so the reason reaches
    /// the status log instead of showing up as an unexplained black tile.
    var onVideoSubscribeFailure: ((String) -> Void)?

    /// The resolution to ask for, chosen from how large the view actually is.
    ///
    /// This is the fix for participant tiles rendering black. Without an explicit
    /// resolution the SDK subscribes at high quality, and it enforces hard quotas:
    /// ZoomSDKVideoSubscribe_Fail_HasSubscribe1080POr720P,
    /// _HasSubscribeTwo720P and _HasSubscribeExceededLimit. Two or three greedy
    /// streams exhaust the allowance and every later subscription is refused -
    /// silently, because nothing was listening to the container delegate. Asking
    /// for what a 300pt tile can actually display leaves room for a whole class.
    private static func resolution(for frame: NSRect,
                                   openStreams: Int,
                                   hero: Bool) -> ZoomSDKVideoRenderResolution {
        // Two limits, and the lower one wins.
        //
        // Size alone was not enough. The SDK's quotas are documented in
        // ZoomSDKErrors.h and they are hard: _HasSubscribe1080POr720P,
        // _HasSubscribeTwo720P ("Maximum limit reached") and
        // _HasSubscribeExceededLimit. A rail tile 800pt tall asked for 720p,
        // which on its own consumed the allowance - so the FIRST student
        // rendered and every later subscription was refused, along with the
        // active-speaker view. Two students on screen, one of them black.
        //
        // This is what Zoom's own gallery does: thumbnails get thumbnail
        // streams and only the hero view gets a big one. A slightly soft tile
        // beats a black one, and the ceiling lifts again as the room empties.
        // Only ONE stream is ever allowed to be the expensive one, and it is
        // the speaker view - the thing actually being looked at. A grid tile is
        // never worth a 720p slot: giving the first one 720p purely because it
        // was drawn large is what spent the allowance before the rest of the
        // class had asked for anything.
        let ceiling: ZoomSDKVideoRenderResolution
        switch (hero, openStreams) {
        case (true, 0...1):  ceiling = ZoomSDKVideoRenderResolution_720p
        case (true, _):      ceiling = ZoomSDKVideoRenderResolution_360p
        case (false, 0...3): ceiling = ZoomSDKVideoRenderResolution_360p
        default:             ceiling = ZoomSDKVideoRenderResolution_180p
        }
        let wanted: ZoomSDKVideoRenderResolution
        switch frame.height {
        case ..<200: wanted = ZoomSDKVideoRenderResolution_90p
        case ..<420: wanted = ZoomSDKVideoRenderResolution_180p
        case ..<700: wanted = ZoomSDKVideoRenderResolution_360p
        default: wanted = ZoomSDKVideoRenderResolution_720p
        }
        // The enum is ordered by quality, so the smaller raw value is the
        // cheaper stream.
        return wanted.rawValue <= ceiling.rawValue ? wanted : ceiling
    }

    /// Wires the container delegate once, so failures are never silent again.
    private func adopt(container: ZoomSDKVideoContainer) {
        videoContainer = container
        if container.delegate !== self { container.delegate = self }
    }

    /// One render element per participant, keyed by user ID. Cached because a
    /// layout pass runs every couple of seconds: recreating elements each time
    /// would unsubscribe and resubscribe every student's video continuously.
    private var participantElements: [UInt32: ZoomSDKNormalVideoElement] = [:]
    /// The frame each element was last asked for.
    ///
    /// The panel re-lays out at 1Hz and nearly always arrives at the same
    /// geometry, so resizing unconditionally spent an SDK round trip per tile
    /// per second re-laying out a render that had not moved. Only genuine
    /// changes go through now.
    private var lastRequestedFrame: [UInt32: NSRect] = [:]
    private var lastSelfFrame: NSRect = .zero

    /// Who is in the meeting. `excludingSelf` follows the same Hide Self View
    /// preference the default UI honours, so the gallery matches what the
    /// teacher already chose rather than inventing a second rule.
    func participantUserIDs(excludingSelf: Bool) -> [UInt32] {
        guard let action = ZoomSDK.shared().getMeetingService()?.getMeetingActionController() else { return [] }
        let ids = (action.getParticipantsList() as? [NSNumber])?.map { $0.uint32Value } ?? []
        guard excludingSelf, let me = action.getMyself()?.getUserID() else { return ids }
        return ids.filter { $0 != me }
    }

    func participantName(userID: UInt32) -> String? {
        ZoomSDK.shared().getMeetingService()?.getMeetingActionController()
            .getUserByUserID(userID)?.getUserName()
    }

    /// When a refused user may be re-subscribed, and how many times in a row
    /// they have been refused.
    ///
    /// Rebuilding on the very next poll was the original design, and for
    /// _HasSubscribeExceededLimit it is sound: the quota frees up as soon as
    /// another stream closes, so trying again shortly after costs nothing.
    ///
    /// For _TooFrequentCall it is exactly backwards, and it was the whole bug.
    /// That refusal is CAUSED by how often the subscription is asked for, so
    /// tearing the element down and rebuilding it one second later guarantees
    /// the next refusal, which schedules the next rebuild. The measured result
    /// was a loop that climbed from 3 refusals a second to 69 over one session
    /// (2,565 of them in Greenroom-video.log, every single one code 7) while
    /// every tile stayed black.
    ///
    /// So a refusal now buys silence rather than another attempt: exponential
    /// backoff, and the existing element is left alone while it runs.
    private var subscriptionCooldown: [UInt32: Date] = [:]
    private var subscriptionAttempts: [UInt32: Int] = [:]
    private var lastSubscriptionFailure: [UInt32: Date] = [:]
    /// Why a user was last refused. Decides whether a fresh element could
    /// possibly help - see the cooldown handling in participantView.
    private var lastFailureReason: [UInt32: ZoomSDKVideoSubscribeFailReason] = [:]

    /// A view rendering one participant, reused across layout passes.
    func participantView(userID: UInt32, frame: NSRect, hero: Bool = false) -> NSView? {
        guard didUseCustomUI else { return nil }
        if let readyAt = subscriptionCooldown[userID] {
            guard Date() >= readyAt else {
                // Still backing off. Hand back whatever is already there rather
                // than rebuilding - the rebuild is what causes the refusal.
                return participantElements[userID]?.getVideoView()
            }
            subscriptionCooldown[userID] = nil
            // Rebuild only for reasons a FRESH element could fix.
            //
            // TooFrequentCall is not one of them. The probe shows the existing
            // element's layer growing from 1 sublayer to 4 after it is
            // attached, which is the SDK wiring up rendering - so the thing
            // being destroyed may already be working. And the teardown itself
            // is a subscribeVideo(false) immediately followed by a
            // subscribeVideo(true) on the replacement, which is exactly the
            // burst the SDK is complaining about. Retrying was feeding the
            // refusal it was reacting to.
            if lastFailureReason[userID] == ZoomSDKVideoSubscribe_Fail_TooFrequentCall,
               let existing = participantElements[userID] {
                // Re-ask on the SAME element, rather than rebuilding it OR
                // leaving it alone.
                //
                // Rebuilding caused the refusal loop. Leaving it alone is just
                // as broken in the other direction, and was the bug that kept
                // every tile black: the log showed exactly ONE subscribeVideo
                // call in a five-minute session, refused asynchronously, and
                // never repeated. The element then draws the avatar - which
                // needs no subscription - and goes black the instant the
                // camera comes on, which is exactly what was reported.
                //
                // Re-asking on the retained element carries no teardown burst
                // and is the only thing that actually reinstates the stream.
                let again = existing.subscribeVideo(true)
                Self.videoLog("user=\(userID) cooldown over, re-subscribed existing element"
                    + " result=\(again.rawValue)")
                if again == ZoomSDKError_Success { lastFailureReason[userID] = nil }
            } else if let dead = participantElements.removeValue(forKey: userID) {
                _ = dead.subscribeVideo(false)
                _ = videoContainer?.clean(dead)
                Self.videoLog("retrying user=\(userID) after backoff")
            }
        }
        if let existing = participantElements[userID] {
            if lastRequestedFrame[userID] != frame {
                lastRequestedFrame[userID] = frame
                _ = existing.resize(frame)
            }
            return existing.getVideoView()
        }
        guard let container = ZoomSDK.shared().getMeetingService()?.getVideoContainer() else { return nil }
        adopt(container: container)
        var element = ZoomSDKNormalVideoElement(frame: frame)
        guard container.createNormalVideoElement(&element) == ZoomSDKError_Success else { return nil }
        element.userid = userID
        // Ask for a tile-sized stream BEFORE subscribing. After subscribing is
        // too late: the quota is spent at subscribe time.
        // Every element already in the container is a stream competing for the
        // same allowance - including this user's own about to be added.
        let asked = Self.resolution(for: frame,
                                    openStreams: participantElements.count,
                                    hero: hero)
        var resolutionResult = element.setResolution(asked)
        let subscribed = element.subscribeVideo(true)
        // setResolution fails intermittently (ZoomSDKError_Failed) with no
        // pattern in size, count or order - and every tile it failed on has
        // rendered black, while same-session tiles where it succeeded drew
        // fine. Strongest correlation in the whole log history. Whether the
        // element recovers when asked again after subscribing is exactly what
        // this measures.
        if resolutionResult != ZoomSDKError_Success {
            resolutionResult = element.setResolution(asked)
            Self.videoLog("setResolution retry user=\(userID)"
                + " result=\(resolutionResult.rawValue)")
        }
        let shown = element.showVideo(true)
        let info = ZoomSDK.shared().getMeetingService()?
            .getMeetingActionController().getUserByUserID(userID)
        let action = ZoomSDK.shared().getMeetingService()?.getMeetingActionController()
        Self.videoLog("""
            tile user=\(userID)             frame=\(Int(frame.width))x\(Int(frame.height))             setResolution=\(resolutionResult.rawValue) asked=\(asked.rawValue)             subscribe=\(subscribed.rawValue)             showVideo=\(shown.rawValue)             view=\(element.getVideoView() == nil ? "nil" : "ok")             theirVideoOn=\(info?.isVideoOn() ?? false)             dataType=\(element.getDataType().rawValue)             incomingVideoStopped=\(action?.isIncomingVideoStopped() ?? false)
            """.replacingOccurrences(of: "\n", with: ""))
        guard subscribed == ZoomSDKError_Success else {
            // Do not cache a failed subscription: keeping it would make every
            // later pass believe this user is already wired up.
            _ = videoContainer?.clean(element)
            return nil
        }
        participantElements[userID] = element
        lastRequestedFrame[userID] = frame
        return element.getVideoView()
    }

    /// A SECOND self-video element, for the control panel's own self view.
    ///
    /// An NSView has exactly one superview, so the panel and the speaker window
    /// cannot both host one view - whichever parented it
    /// last would steal it, and the other would go blank. They get separate
    /// render elements instead. The SDK is happy to draw the same user twice.
    private var railSelfElement: ZoomSDKNormalVideoElement?

    func makeRailSelfView(frame: NSRect) -> NSView? {
        guard didUseCustomUI else { return nil }
        if let existing = railSelfElement {
            if lastSelfFrame != frame {
                lastSelfFrame = frame
                _ = existing.resize(frame)
            }
            return existing.getVideoView()
        }
        guard let service = ZoomSDK.shared().getMeetingService(),
              let container = service.getVideoContainer(),
              let me = service.getMeetingActionController().getMyself()?.getUserID() else { return nil }
        adopt(container: container)
        var element = ZoomSDKNormalVideoElement(frame: frame)
        guard container.createNormalVideoElement(&element) == ZoomSDKError_Success else { return nil }
        element.userid = me
        // Capped at 360p regardless of how large the rail draws it. This is a
        // monitor of our own outgoing composite, and letting it claim 720p was
        // starving the students' tiles of the subscription quota.
        _ = element.setResolution(ZoomSDKVideoRenderResolution_360p)
        guard element.subscribeVideo(true) == ZoomSDKError_Success else {
            _ = container.clean(element)
            return nil
        }
        _ = element.showVideo(true)
        railSelfElement = element
        return element.getVideoView()
    }

    // MARK: - Speaker window (active element, clean test)

    /// Zoom's own auto-following speaker element, hosted in the Speaker window.
    ///
    /// Every earlier run of this element was black - and every earlier run had
    /// one or two participants, when the element is DOCUMENTED to operate with
    /// three or more. So none of those runs proved anything, and the window-
    /// binding conclusion drawn from them was premature. This is the clean
    /// test: created once, startActiveView(true), 3+ rule respected, and no
    /// competing element anywhere (Zoom's reference example runs an active
    /// element alongside normal elements for the same people - the
    /// one-element-per-user collision was two NORMAL elements).
    ///
    /// If this still draws black with three people in the room, the capability
    /// matrix ("Multiple windows: No - regions in 1 container") wins for good,
    /// and a separate window means the raw-data pipeline (ZoomSDKRenderer).
    private var activeSpeakerElement: ZoomSDKActiveVideoElement?
    private var lastActiveSpeakerFrame: NSRect = .zero

    func activeSpeakerWindowView(frame: NSRect) -> NSView? {
        guard didUseCustomUI else { return nil }
        // "Three or more participants", self included - below that the element
        // is documented not to run, and the panel's featured tile covers it.
        guard meetingRoster().count >= 3 else { return nil }
        if let existing = activeSpeakerElement {
            if lastActiveSpeakerFrame != frame {
                lastActiveSpeakerFrame = frame
                _ = existing.resize(frame)
            }
            return existing.getVideoView()
        }
        guard let container = ZoomSDK.shared().getMeetingService()?.getVideoContainer() else { return nil }
        adopt(container: container)
        var element = ZoomSDKActiveVideoElement(frame: frame)
        guard container.createActiveVideoElement(&element) == ZoomSDKError_Success else {
            Self.videoLog("activeSpeaker createActiveVideoElement FAILED")
            return nil
        }
        _ = element.setResolution(Self.resolution(for: frame,
                                                  openStreams: participantElements.count,
                                                  hero: true))
        let resized = element.resize(frame)
        let started = element.startActiveView(true)
        let shown = element.showVideo(true)
        Self.videoLog("activeSpeaker element created resize=\(resized.rawValue)"
            + " startActiveView=\(started.rawValue) showVideo=\(shown.rawValue)"
            + " participants=\(meetingRoster().count)")
        activeSpeakerElement = element
        lastActiveSpeakerFrame = frame
        return element.getVideoView()
    }

    // MARK: - Featured speaker

    /// The last person known to be talking, so a quiet room does not blank out.
    private var lastKnownSpeaker: UInt32?
    /// Last logged talking/pick state, so the 1Hz poll only writes on change.
    private var lastSpeakerSignature = ""
    /// Fed by the action controller's events (see +ActionEvents.swift) - the
    /// delegate channel Zoom actually documents for active-speaker tracking.
    /// When these have fired, they outrank the isTalking() poll.
    private var eventActiveSpeaker: UInt32?
    private var sawSpeakerEvents = false

    func noteActiveAudio(_ ids: [UInt32]) {
        sawSpeakerEvents = true
        // Silence keeps the last speaker; several at once keeps the first.
        guard let id = ids.first else { return }
        if eventActiveSpeaker != id {
            eventActiveSpeaker = id
            Self.videoLog("event activeAudio -> user=\(id)")
        }
    }

    func noteActiveSpeaker(_ id: UInt32) {
        sawSpeakerEvents = true
        guard id != 0, eventActiveSpeaker != id else { return }
        eventActiveSpeaker = id
        Self.videoLog("event activeSpeaker -> user=\(id)")
    }

    /// Who the panel should feature: whoever is talking, else whoever talked
    /// last, else anyone at all. nil only when the room is empty.
    ///
    /// Sticky on purpose. `isTalking` is momentary - it goes false between
    /// sentences - so following it directly would blank the tile every time
    /// someone drew breath.
    ///
    /// There is deliberately no separate "speaker element" behind this. The
    /// featured person is rendered by an ORDINARY participant element, just
    /// drawn larger, because the SDK allows exactly one video element per user
    /// and puts every element in one container owned by one window. A second
    /// element for the same person broke the first, and hosting one outside
    /// the panel's window rendered black and corrupted the container. One
    /// element, one window, one place on screen.
    func speakerToShow() -> UInt32? {
        let others = meetingRoster().filter { !$0.isMyself }
        guard !others.isEmpty else {
            if let element = activeSpeakerElement {
            _ = element.startActiveView(false)
            _ = videoContainer?.clean(element)
        }
        activeSpeakerElement = nil
        lastActiveSpeakerFrame = .zero
        lastKnownSpeaker = nil
        eventActiveSpeaker = nil
        sawSpeakerEvents = false
            return nil
        }
        // Events first, poll second. The events are the documented signal and
        // update the instant someone speaks; the poll is the fallback for the
        // stretch before the first event arrives. Self is excluded here for
        // the same reason it is excluded from the grid - the featured tile is
        // for the class, and the teacher already has a self view.
        if sawSpeakerEvents, let fromEvent = eventActiveSpeaker,
           others.contains(where: { $0.id == fromEvent }) {
            lastKnownSpeaker = fromEvent
        } else if let talking = others.first(where: { $0.isTalking }) {
            lastKnownSpeaker = talking.id
        } else if lastKnownSpeaker == nil
                    || !others.contains(where: { $0.id == lastKnownSpeaker }) {
            // Nobody has spoken yet, or the last speaker has left - a frozen
            // tile of someone who is gone is worse than showing anyone.
            lastKnownSpeaker = others.first?.id
        }
        // Is isTalking() actually usable?
        //
        // It is a POLL, and the signals Zoom documents for this
        // (onActiveVideoUserChanged, onUserActiveAudioChange) are delegate-only
        // on a 51-method all-required protocol. Worth knowing whether the cheap
        // path works before paying for the expensive one: if `talking=[]` never
        // becomes non-empty while someone is plainly speaking, polling is dead
        // and the delegate is the only way.
        let talking = others.filter(\.isTalking).map(\.id).sorted()
        let signature = "talking=\(talking) pick=\(lastKnownSpeaker.map(String.init) ?? "nil")"
        if signature != lastSpeakerSignature {
            lastSpeakerSignature = signature
            Self.videoLog("speakerToShow \(signature)")
        }
        return lastKnownSpeaker
    }

    /// Whether anyone other than us is in the meeting - the thing that decides
    /// between the empty message and the speaker view.
    var hasOtherParticipants: Bool {
        !participantUserIDs(excludingSelf: true).isEmpty
    }

    /// Unsubscribes and drops elements for anyone no longer in the list, so a
    /// class that churns all morning does not accumulate dead subscriptions.
    func pruneParticipantViews(keeping keep: Set<UInt32>) {
        for (userID, element) in participantElements where !keep.contains(userID) {
            _ = element.subscribeVideo(false)
            _ = videoContainer?.clean(element)
            participantElements.removeValue(forKey: userID)
            lastRequestedFrame.removeValue(forKey: userID)
        }
    }

    /// Releases the render elements. Called on leave so the SDK is not left
    /// drawing into views that are about to disappear.
    func releaseCustomUIVideo() {
        if let element = railSelfElement {
            _ = videoContainer?.clean(element)
            railSelfElement = nil
        }
        lastKnownSpeaker = nil
        for (_, element) in participantElements {
            _ = element.subscribeVideo(false)
            _ = videoContainer?.clean(element)
        }
        participantElements.removeAll()
        lastRequestedFrame.removeAll()
        lastSelfFrame = .zero
        videoContainer = nil
    }
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
            // Custom UI: the SDK stops creating its own meeting windows and
            // hands us NSViews to render video into instead (see
            // makeActiveSpeakerView). This is an INIT param, not a runtime
            // property, and the SDK initialises once per process - so
            // switching modes needs an app restart, which is why it is read
            // from defaults rather than passed in.
            params.needCustomizedUI = Self.customUIModeEnabled
            didUseCustomUI = Self.customUIModeEnabled
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
    /// Waits for the SDK to be genuinely IDLE, before a new meeting starts.
    ///
    /// The SDK carries one meeting state for the whole process, and a start
    /// issued while the previous meeting is still tearing down loses the race:
    /// the OLD meeting's terminal status arrives after `joinCompletion` has
    /// been armed and resolves the NEW join as a failure. It surfaces as "the
    /// meeting ended before Greenroom finished joining" - a start that looks
    /// hung on the Meeting step for half a minute and then gives up. Seen live
    /// 18 seconds after ending the previous session.
    ///
    /// Distinct from `awaitMeetingClosed`, which accepts Ended and Failed
    /// because it runs at QUIT, where "on its way out" is good enough. Here
    /// only Idle will do: Ended is the state whose late event causes the bug.
    ///
    /// Costs nothing on the common path - the first check returns immediately
    /// when no meeting has been running. On timeout it proceeds anyway, which
    /// is no worse than the unguarded behaviour it replaces.
    func awaitMeetingIdle(timeout: TimeInterval = 15) async -> Bool {
        guard didInit, let service = ZoomSDK.shared().getMeetingService() else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if service.getMeetingStatus() == ZoomSDKMeetingStatus_Idle { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

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
        // Zoom draws its own name label INTO each video view. In default-UI mode
        // that is Zoom's own chrome and belongs there. In custom-UI mode our
        // participant panel draws a richer label of its own - name plus host or
        // co-host role - a few points away, so both rendered on top of each
        // other. Confirmed live in the accessibility tree: two overlapping
        // labels, "Sibhimanyu V" and "Sibhimanyu V (you) - host".
        // Local rendering only; it does not touch what the class sees or what
        // OBS records.
        if didUseCustomUI {
            _ = ZoomSDK.shared().getSettingService()?.getVideoSetting()?.displayUserName(onVideo: false)
        }
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

// MARK: - Video container delegate

/// Subscription failures were the cause of participant tiles rendering black,
/// and nothing was listening for them. Now every refusal reaches the status log
/// with the SDK's own reason.
extension ZoomMeetingSDKClient: ZoomSDKVideoContainerDelegate {

    func onSubscribeUserFail(_ error: ZoomSDKVideoSubscribeFailReason,
                             videoElement element: ZoomSDKVideoElement) {
        let reason: String
        switch error {
        case ZoomSDKVideoSubscribe_Fail_ViewOnly:
            reason = "this account is in view-only mode"
        case ZoomSDKVideoSubscribe_Fail_NotInMeeting:
            reason = "that person is no longer in the meeting"
        case ZoomSDKVideoSubscribe_Fail_HasSubscribe1080POr720P,
             ZoomSDKVideoSubscribe_Fail_HasSubscribe720P,
             ZoomSDKVideoSubscribe_Fail_HasSubscribeTwo720P:
            reason = "too many high-quality streams already open"
        case ZoomSDKVideoSubscribe_Fail_HasSubscribeExceededLimit:
            reason = "Zoom's limit on simultaneous video streams was reached"
        case ZoomSDKVideoSubscribe_Fail_TooFrequentCall:
            reason = "requests came too quickly"
        default:
            reason = "reason code \(error.rawValue)"
        }
        let userID = element.userid
        let now = Date()
        // A run of refusals is one problem, not many. Anything after a quiet
        // minute starts the backoff again from the beginning.
        let continuing = lastSubscriptionFailure[userID]
            .map { now.timeIntervalSince($0) < 60 } ?? false
        let attempts = continuing ? (subscriptionAttempts[userID] ?? 0) + 1 : 1
        subscriptionAttempts[userID] = attempts
        lastSubscriptionFailure[userID] = now
        // 2, 4, 8, 16, 32 seconds, then hold there. The poll runs at 1Hz, so
        // even the first step takes the pressure off the rate limiter.
        let delay = min(32, pow(2.0, Double(min(attempts, 5))))
        subscriptionCooldown[userID] = now.addingTimeInterval(delay)

        lastFailureReason[userID] = error
        // Which element was refused, and how many the container holds.
        //
        // Worth keeping: one subscribe reliably produces TWO refusals at the
        // same instant, and this is what proved they are the same element
        // refused twice rather than the grid tile and the active-speaker view
        // fighting over one person. It also shows the start-up burst - three
        // elements subscribing in one tick - that trips the limiter.
        let owner: String
        if let grid = participantElements[userID], grid === element { owner = "gridTile" }
        else if let rail = railSelfElement, rail === element { owner = "railSelf" }
        else { owner = "UNTRACKED" }
        let elementCount = videoContainer?.getVideoElementList()?.count ?? -1
        Self.videoLog("SUBSCRIBE FAIL code=\(error.rawValue) user=\(userID) \(reason)"
            + " owner=\(owner) containerElements=\(elementCount)"
            + " \u{2014} backing off \(Int(delay))s (attempt \(attempts))")
        // Only worth telling the teacher about things they can act on. A
        // too-frequent refusal is Greenroom's own pacing and recovers itself;
        // saying so would be noise during a class.
        if error != ZoomSDKVideoSubscribe_Fail_TooFrequentCall {
            onVideoSubscribeFailure?("A participant's video could not start \u{2014} \(reason).")
        }
    }

    func onRenderUserChanged(_ element: ZoomSDKVideoElement?, user userid: UInt32) {
        Self.videoLog("renderUserChanged element=\(element?.userid ?? 0) -> user=\(userid)")
    }

    /// Avatar instead of video is the other way a tile ends up looking blank,
    /// and it is NOT a failure - it is what the SDK draws when someone's camera
    /// is off. Logged so the two are never confused again.
    func onRenderDataTypeChanged(_ element: ZoomSDKVideoElement?, dataType type: VideoRenderDataType) {
        Self.videoLog("dataTypeChanged user=\(element?.userid ?? 0) type=\(type.rawValue)")
        // Someone's camera coming back on is the moment a previously refused
        // subscription is most worth retrying: the rate limiter has long since
        // forgotten the start-up burst that caused the refusal, and until the
        // retry happens this tile is the black rectangle the teacher sees.
        //
        // Only the cooldown is cleared here. Calling subscribeVideo from
        // inside an SDK callback is precisely the kind of re-entrant traffic
        // the limiter counts, so the next layout pass does the real work.
        guard let userID = element?.userid, type == VideoRenderDataType_Video else { return }
        if lastFailureReason[userID] != nil { subscriptionCooldown[userID] = Date() }
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
    case joinRejected(ZoomSDKMeetingError, status: ZoomSDKMeetingStatus)

    /// Zoom refused because the meeting is hosted on a different Zoom
    /// account than the one owning this Marketplace app (error 63).
    /// Exposed as a plain Bool so callers outside App/Zoom/ can branch on
    /// it without importing ZoomSDK - the Zoom types stay behind this
    /// wrapper layer.
    var isCrossAccountRejection: Bool {
        if case .joinRejected(let reason, _) = self {
            return reason == ZoomSDKMeetingError_UnableToJoinExternalMeeting
        }
        return false
    }

    /// Says what actually happened, in words a teacher can act on.
    ///
    /// This used to print the raw enum, which produced
    /// "join was rejected (ZoomSDKMeetingError(rawValue: 101))" - and 101 is
    /// ZoomSDKMeetingError_None, the SDK's way of saying it had no reason to
    /// give. Reporting "rejected" for that is doubly wrong: nobody refused
    /// anything, and the number tells the reader nothing.
    static func joinFailureText(_ error: ZoomSDKMeetingError,
                                status: ZoomSDKMeetingStatus) -> String {
        switch error {
        case ZoomSDKMeetingError_PasswordError:
            return "Zoom rejected the meeting passcode. Check it in Settings \u{2192} Start Meeting."
        case ZoomSDKMeetingError_MeetingNotStart:
            return "That meeting has not been started yet by its host."
        case ZoomSDKMeetingError_MeetingNotExist:
            return "Zoom has no meeting with that number."
        case ZoomSDKMeetingError_MeetingOver:
            return "That meeting has already ended."
        case ZoomSDKMeetingError_MeetingLocked:
            return "The host has locked that meeting."
        case ZoomSDKMeetingError_UserFull:
            return "That meeting is full."
        case ZoomSDKMeetingError_UnableToJoinExternalMeeting,
             ZoomSDKMeetingError_HostDisallowOutsideUserJoin:
            return "This Zoom account is not allowed to join that meeting."
        case ZoomSDKMeetingError_RemovedByHost:
            return "The host removed this account from the meeting."
        case ZoomSDKMeetingError_ConnectionError, ZoomSDKMeetingError_ReconnectFailed,
             ZoomSDKMeetingError_NoMMR, ZoomSDKMeetingError_MMRError:
            return "Couldn't reach Zoom's servers. Check the network and try again."
        case ZoomSDKMeetingError_None, ZoomSDKMeetingError_Success:
            // The SDK ended the attempt without giving a reason. Almost always
            // the previous meeting still tearing down underneath a new Start.
            return status == ZoomSDKMeetingStatus_Ended
                ? "The meeting ended before Greenroom finished joining. If the last session only just stopped, give it a few seconds and press Start again."
                : "Zoom ended the join without saying why. If the last session only just stopped, give it a few seconds and press Start again."
        default:
            return "Zoom refused the join (code \(error.rawValue))."
        }
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
        case .joinRejected(let error, let status):
            return Self.joinFailureText(error, status: status)
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
        // Claim the video container as early as the SDK will give it to us.
        //
        // Zoom's own custom-UI guidance is explicit: build the custom UI on
        // CONNECTING, not IN_MEETING, "the SDK needs the video container ready
        // before it starts rendering" - and macOS lists "delegate/controller
        // ordering issues in custom UI mode" as a named failure domain.
        //
        // Greenroom used to take the container lazily, on the first tile the
        // panel asked for, which is seconds after the meeting is up. Until
        // then nothing was listening to the container delegate, so any early
        // subscription refusal went unreported - the exact blindness that made
        // the first black-tile hunt so slow.
        if state == ZoomSDKMeetingStatus_Connecting || state == ZoomSDKMeetingStatus_InMeeting,
           videoContainer == nil, didUseCustomUI,
           let container = ZoomSDK.shared().getMeetingService()?.getVideoContainer() {
            adopt(container: container)
            Self.videoLog("video container adopted at status=\(state.rawValue)")
            // Same moment, same reasoning: register event listeners before the
            // meeting starts producing events, per the SDK's own lifecycle
            // guidance. Nothing else in the app claims this delegate.
            ZoomSDK.shared().getMeetingService()?.getMeetingActionController().delegate = self
            Self.videoLog("action controller delegate wired")
        }
        switch state {
        case ZoomSDKMeetingStatus_InMeeting:
            isJoined = true
            joinCompletion?(.success(()))
            joinCompletion = nil
        case ZoomSDKMeetingStatus_Disconnecting:
            // Transitional, not terminal - it sits between InMeeting and Ended,
            // and the SDK also passes through it while tearing the PREVIOUS
            // meeting down. Failing a join here reported "rejected" for a
            // meeting that had not been refused by anyone, with reason _None
            // because nothing had actually gone wrong.
            isJoined = false
        case ZoomSDKMeetingStatus_Failed, ZoomSDKMeetingStatus_Ended:
            if !isJoined {
                joinCompletion?(.failure(ZoomMeetingSDKError.joinRejected(error, status: state)))
                joinCompletion = nil
            }
            isJoined = false
        default:
            break
        }
    }
}
