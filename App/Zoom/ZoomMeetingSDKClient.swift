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
import os
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

    /// Whether this class runs a layout (a template is active), set by the
    /// coordinator at Start. Read when a meeting is joined: an arranged class
    /// parks Zoom's window as a tile, so it drops the thumbnail and info button.
    var arrangesWindows = false

    /// On unless the teacher turned it off (2026-11-11: Greenroom's own meeting
    /// window runs every meeting). App-restart-scoped: `needCustomizedUI` is an
    /// initSDK parameter, so it cannot change while the process lives.
    static var customUIModeEnabled: Bool {
        (UserDefaults.standard.object(forKey: "customUIMode") as? Bool) ?? true
    }

    /// One-time flip for Macs that already stored `customUIMode = false` from
    /// the days it defaulted off: they get the new default once, after which
    /// the setting is theirs again. Runs at launch, before anything reads it.
    static func migrateCustomUIDefault() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "customUIMode.migratedV2") else { return }
        defaults.set(true, forKey: "customUIMode")
        defaults.set(true, forKey: "customUIMode.migratedV2")
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

    /// Fired whenever the participant count may have changed - InMeeting,
    /// joins, leaves - so the meeting window can redraw at once rather than at
    /// its next one-second poll.
    var onParticipantCountChanged: (() -> Void)?
    /// The lock state Zoom last reported; there is no getter, only the event.
    var meetingIsLocked = false

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
        // Sized against Zoom's PUBLISHED desktop budget: 1x1080p, 2x720p,
        // 4x360p, 17x180p, 34x90p concurrent remote subscriptions (self video
        // does not count). The hero gets one modest slot; every gallery tile
        // is a thumbnail stream. A slightly soft tile beats a black one, and
        // 17 x 180p covers a whole class.
        //
        // The height trap, learned the hard way: when setResolution is not in
        // effect the SDK derives the request from the VIEW HEIGHT (>=850pt ->
        // 1080p). Our featured tile is ~1030pt tall, so every setResolution
        // failure silently became a 1080p request - the whole budget - and
        // the other views went black. That is the "one works, the other
        // blacks out" seesaw in one sentence.
        if hero {
            return openStreams == 0 ? ZoomSDKVideoRenderResolution_720p
                                    : ZoomSDKVideoRenderResolution_360p
        }
        return frame.height < 200 ? ZoomSDKVideoRenderResolution_90p
                                  : ZoomSDKVideoRenderResolution_180p
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

    /// Tiles that have asked for their stream while their view was on screen.
    ///
    /// A tile's element is created and subscribed inside this call, BEFORE the
    /// caller puts its view in the window - and a subscription made then never
    /// draws. Four classes, every tile: the ones that showed video were exactly
    /// the ones that asked a second time (a code-7 retry, a second after being
    /// attached); every one that asked only once stayed blank with its camera
    /// on, reporting dataType=Video the whole time. The speaker window needs
    /// the same thing and says so in its header: in a visible window first.
    private var subscribedOnScreen: Set<UInt32> = []
    /// One re-ask at a time, half a second apart: several in one breath is the
    /// burst the SDK refuses with code 7.
    private var nextResubscribeAt = Date.distantPast

    /// A view rendering one participant, reused across layout passes.
    func participantView(userID: UInt32, frame: NSRect, hero: Bool = false) -> NSView? {
        guard didUseCustomUI else { return nil }
        // A tile whose only subscription was made off screen asks again, on
        // the SAME element, once its view is in a visible window.
        if let existing = participantElements[userID],
           !subscribedOnScreen.contains(userID),
           subscriptionCooldown[userID] == nil,
           existing.getVideoView().window?.isVisible == true,
           Date() >= nextResubscribeAt {
            let again = existing.subscribeVideo(true)
            subscribedOnScreen.insert(userID)
            nextResubscribeAt = Date().addingTimeInterval(0.5)
            Self.videoLog("user=\(userID) re-subscribed now that its tile is on screen"
                + " result=\(again.rawValue)")
        }
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
                if existing.getVideoView().window?.isVisible == true { subscribedOnScreen.insert(userID) }
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
            if resolutionResult != ZoomSDKError_Success, frame.height >= 720 {
                // Both asks refused on a tall tile: the SDK will derive the
                // request from view height, and >=850pt means 1080p - the
                // entire concurrent budget on one tile. Named in the log
                // because this is the single most destructive silent state.
                Self.videoLog("WARNING user=\(userID) tall tile with no explicit"
                    + " resolution - height-derived request may consume the whole budget")
            }
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
        subscribedOnScreen.remove(userID)
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

    // MARK: - Stage (the meeting window's Speaker view)

    /// ONE element for the stage, whoever is on it. A view has one superview, so
    /// the filmstrip tile for a person cannot be reused for the big picture; the
    /// stage gets its own element and `userid` is reassigned when the speaker
    /// changes, which keeps it to one subscription however often people talk.
    /// A normal element, not ZoomSDKActiveVideoElement: the active-video element
    /// only draws with three or more people, and this one works in a 1:1.
    private var stageElement: ZoomSDKNormalVideoElement?
    private var stageUserID: UInt32?
    /// The subscription is made once the view is in a visible window, the same
    /// lesson as `subscribedOnScreen`: one made before it never draws.
    private var stageSubscribed = false
    private var lastStageFrame: NSRect = .zero
    /// A speaker change is a subscription change, and Zoom refuses bursts of
    /// them (code 7). Two people trading a sentence should not flip the stage.
    private var nextStageSwitchAt = Date.distantPast

    func stageView(userID: UInt32, frame: NSRect) -> NSView? {
        guard didUseCustomUI else { return nil }
        if let element = stageElement {
            if lastStageFrame != frame {
                lastStageFrame = frame
                _ = element.resize(frame)
            }
            if stageUserID != userID, Date() >= nextStageSwitchAt {
                _ = element.subscribeVideo(false)
                element.userid = userID
                stageUserID = userID
                nextStageSwitchAt = Date().addingTimeInterval(2)
                stageSubscribed = false
                Self.videoLog("stage -> user=\(userID)")
            }
            if !stageSubscribed, element.getVideoView().window?.isVisible == true {
                let subscribed = element.subscribeVideo(true)
                _ = element.showVideo(true)
                stageSubscribed = subscribed == ZoomSDKError_Success
                Self.videoLog("stage subscribe user=\(stageUserID ?? 0) result=\(subscribed.rawValue)")
            }
            return element.getVideoView()
        }
        guard let container = ZoomSDK.shared().getMeetingService()?.getVideoContainer() else { return nil }
        adopt(container: container)
        var element = ZoomSDKNormalVideoElement(frame: frame)
        guard container.createNormalVideoElement(&element) == ZoomSDKError_Success else { return nil }
        element.userid = userID
        // One 720p slot of Zoom's published budget (1x1080p, 2x720p, 4x360p); the
        // filmstrip tiles are thumbnails.
        var result = element.setResolution(ZoomSDKVideoRenderResolution_720p)
        if result != ZoomSDKError_Success { result = element.setResolution(ZoomSDKVideoRenderResolution_720p) }
        stageElement = element
        stageUserID = userID
        stageSubscribed = false
        lastStageFrame = frame
        nextStageSwitchAt = Date().addingTimeInterval(2)
        Self.videoLog("stage created user=\(userID) setResolution=\(result.rawValue)")
        return element.getVideoView()
    }

    /// Gallery view, or the window closing: give the stream back.
    func releaseStage() {
        guard let element = stageElement else { return }
        _ = element.subscribeVideo(false)
        _ = videoContainer?.clean(element)
        element.getVideoView().removeFromSuperview()
        stageElement = nil
        stageUserID = nil
        stageSubscribed = false
        lastStageFrame = .zero
    }

    #if DEBUG
    // MARK: - View spike (phase 0 of .context/meeting-views-plan.md)
    //
    // One extra render element for ONE extra window, behind the hidden default
    // `meetingViews.spike`. Kept apart on purpose: it is never in
    // participantElements, stageElement or railSelfElement, so nothing that
    // reconciles those can touch it. Drawn by ViewSpike.swift.

    private(set) var spikeElement: ZoomSDKNormalVideoElement?
    /// The render data type the SDK reported for the spike element.
    var onSpikeDataType: ((VideoRenderDataType) -> Void)?
    /// A subscription the SDK refused for the spike element (code, user).
    var onSpikeSubscribeFail: ((Int, UInt32) -> Void)?

    /// A fresh normal element (NOT the deprecated createVideoElement: / active
    /// element) from the same process-wide container. Not subscribed yet.
    func spikeCreateElement(frame: NSRect, userID: UInt32) -> (element: ZoomSDKNormalVideoElement?, code: Int) {
        guard didUseCustomUI,
              let container = ZoomSDK.shared().getMeetingService()?.getVideoContainer() else { return (nil, -1) }
        adopt(container: container)
        var element = ZoomSDKNormalVideoElement(frame: frame)
        let made = container.createNormalVideoElement(&element)
        guard made == ZoomSDKError_Success else { return (nil, Int(made.rawValue)) }
        element.userid = userID
        spikeElement = element
        return (element, 0)
    }

    func spikeReleaseElement() {
        guard let element = spikeElement else { return }
        _ = element.subscribeVideo(false)
        _ = videoContainer?.clean(element)
        element.getVideoView().removeFromSuperview()
        spikeElement = nil
    }

    /// Who the stage shows, the way the meeting window picks: spotlight, then a
    /// local pin, then whoever speaks.
    func spikeStagePerson() -> RosterEntry? {
        let roster = meetingRoster()
        let id = roster.first(where: \.isSpotlighted)?.id ?? roster.first(where: \.isPinned)?.id ?? speakerToShow()
        return roster.first { $0.id == id }
    }
    #endif

    // MARK: - Featured speaker
    //
    // speakerToShow() below picks who the stage shows; the old per-window
    // speaker code is gone (see the meeting window, ParticipantGridWindow.swift).

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
    /// Who the Speaker window and the panel's featured tile should show:
    /// whoever is talking, else whoever talked last, else anyone at all.
    /// nil only when the room is empty. Sticky, because isTalking flickers
    /// between sentences. The same person may be rendered in both places -
    /// two subscriptions to one user is supported and simply counts twice
    /// against the published budget.
    func speakerToShow() -> UInt32? {
        let others = meetingRoster().filter { !$0.isMyself }
        guard !others.isEmpty else {
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

    /// Event-driven leave handling: the subscription is released the moment
    /// the SDK says someone left, instead of when the 1s poll next notices.
    /// The freed budget slot matters as much as the stale tile.
    func noteUsersLeft(_ ids: [UInt32]) {
        for id in ids {
            if let element = participantElements.removeValue(forKey: id) {
                _ = element.subscribeVideo(false)
                _ = videoContainer?.clean(element)
                lastRequestedFrame.removeValue(forKey: id)
                Self.videoLog("released element for user=\(id) - left the meeting")
            }
        }
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
        #if DEBUG
        spikeReleaseElement()
        #endif
        releaseStage()
        if let element = railSelfElement {
            _ = videoContainer?.clean(element)
            railSelfElement = nil
        }
        lastKnownSpeaker = nil
        eventActiveSpeaker = nil
        sawSpeakerEvents = false
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
    private var authedClientSecret: String?
    private var authenticationTask: Task<Void, Error>?
    private var authenticationCredentials: [String] = []
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
            Self.logLicenceLine("Zoom sign-in: no answer from the SDK after \(Int(seconds)) s.")
            completion(.failure(ZoomMeetingSDKError.timedOut(
                what: "Signing Greenroom\u{2019}s meeting client in to Zoom", seconds: Int(seconds),
                advice: "Check your internet connection, then press Try again. If it keeps happening, quit and reopen Greenroom.")))
        }
    }

    /// 45 s, not the 120 it was: a join that has not reached the meeting in
    /// 45 s is not coming (a live run sat in Connecting for two minutes and
    /// then gave up), and every second of it is a teacher watching a card.
    private func armJoinWatchdog(seconds: TimeInterval = 45) {
        callbackGeneration += 1
        let generation = callbackGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.callbackGeneration == generation,
                  let completion = self.joinCompletion else { return }
            self.joinCompletion = nil
            let status = ZoomSDK.shared().getMeetingService().map { Self.statusName($0.getMeetingStatus()) } ?? "unknown"
            Self.logLicenceLine("Meeting: no answer from the SDK after \(Int(seconds)) s; it is still \(status).")
            completion(.failure(ZoomMeetingSDKError.timedOut(
                what: "Getting into the meeting (Zoom\u{2019}s client was still \(status.lowercased()))", seconds: Int(seconds),
                advice: "Nothing was left running. If you plugged or unplugged a display while it was starting, wait a few seconds after doing that, then press Try again.")))
        }
    }

    /// End Session or a cancelled start: whoever is awaiting the SDK is let
    /// go NOW, with a cancellation, rather than when a watchdog fires.
    func abandonPendingCallbacks() {
        callbackGeneration += 1
        if let completion = authCompletion { authCompletion = nil; completion(.failure(CancellationError())) }
        if let completion = joinCompletion { joinCompletion = nil; completion(.failure(CancellationError())) }
    }

    nonisolated static func statusName(_ s: ZoomSDKMeetingStatus) -> String {
        switch s {
        case ZoomSDKMeetingStatus_Idle: return "Idle"
        case ZoomSDKMeetingStatus_Connecting: return "Connecting"
        case ZoomSDKMeetingStatus_WaitingForHost: return "WaitingForHost"
        case ZoomSDKMeetingStatus_InMeeting: return "InMeeting"
        case ZoomSDKMeetingStatus_Disconnecting: return "Disconnecting"
        case ZoomSDKMeetingStatus_Reconnecting: return "Reconnecting"
        case ZoomSDKMeetingStatus_Failed: return "Failed"
        case ZoomSDKMeetingStatus_Ended: return "Ended"
        case ZoomSDKMeetingStatus_AudioReady: return "AudioReady"
        case ZoomSDKMeetingStatus_OtherMeetingInProgress: return "OtherMeetingInProgress"
        case ZoomSDKMeetingStatus_InWaitingRoom: return "InWaitingRoom"
        default: return "status #\(s.rawValue)"
        }
    }

    /// Brings the SDK up and authorizes it. Genuinely idempotent: a repeat
    /// call with the same credentials returns immediately instead of
    /// re-running the ~1-2s SDK auth round trip - which lets the start
    /// flow prefetch this in parallel with the picture coming up and lets the
    /// meeting flows call it again for free.
    func ensureReady(clientID: String, clientSecret: String, forceAuthentication: Bool = false) async throws {
        let credentials = [clientID, clientSecret]
        if let pending = authenticationTask {
            if authenticationCredentials == credentials {
                return try await pending.value
            }
            _ = try? await pending.value
            return try await ensureReady(clientID: clientID, clientSecret: clientSecret,
                                         forceAuthentication: forceAuthentication)
        }
        if !forceAuthentication && isAuthed && authedClientID == clientID && authedClientSecret == clientSecret { return }
        authenticationCredentials = credentials
        let task = Task { @MainActor in
            defer {
                authenticationTask = nil
                authenticationCredentials = []
            }
            try await authenticate(clientID: clientID, clientSecret: clientSecret)
        }
        authenticationTask = task
        try await task.value
    }

    private func authenticate(clientID: String, clientSecret: String) async throws {
        // A failed recheck must not leave the previous credentials marked valid.
        isAuthed = false
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
        authedClientSecret = clientSecret
        checkRawVideoLicence(when: "after sign-in")
        #if DEBUG
        startDebugTestPatternIfEnabled()
        #endif
        applyStageVideo()
    }

    /// Piece 0 of docs/drop-obs-plan.md: does this SDK app have the raw-data
    /// licence? Logged in every build, in plain words, because it is the
    /// evidence the go / no-go decision needs. Reads with
    /// `log show --predicate 'subsystem == "com.sibhimanyu.greenroom"'`.
    private func checkRawVideoLicence(when: String) {
        guard let controller = ZoomSDK.shared().getRawDataController() else {
            Self.logLicenceLine("Raw video licence (\(when)): unknown (the SDK gave no raw data controller)")
            return
        }
        let result = controller.hasRawDataLicense()
        guard result != ZoomSDKError_Success else {
            Self.logLicenceLine("Raw video licence (\(when)): yes")
            return
        }
        var line = "Raw video licence (\(when)): no (\(Self.errorName(result)) = \(result.rawValue))"
        if when == "in meeting", stageVideoSender?.isSending == true {
            line += " (sending our own video works without it; this licence is likely only for receiving raw data)"
        }
        Self.logLicenceLine(line)
    }

    /// Every name in ZoomSDKErrors.h, in the header\u{2019}s own order (Success is 0, so
    /// Malloc_Failed is 22 and NoLicense 21). The log says the name, not only
    /// a number someone has to count to.
    nonisolated static func errorName(_ e: ZoomSDKError) -> String {
        switch e {
        case ZoomSDKError_Success: return "ZoomSDKError_Success"
        case ZoomSDKError_Failed: return "ZoomSDKError_Failed"
        case ZoomSDKError_Uninit: return "ZoomSDKError_Uninit"
        case ZoomSDKError_ServiceFailed: return "ZoomSDKError_ServiceFailed"
        case ZoomSDKError_WrongUsage: return "ZoomSDKError_WrongUsage"
        case ZoomSDKError_InvalidParameter: return "ZoomSDKError_InvalidParameter"
        case ZoomSDKError_NoPermission: return "ZoomSDKError_NoPermission"
        case ZoomSDKError_NoRecordingInProgress: return "ZoomSDKError_NoRecordingInProgress"
        case ZoomSDKError_TooFrequentCall: return "ZoomSDKError_TooFrequentCall"
        case ZoomSDKError_UnSupportedFeature: return "ZoomSDKError_UnSupportedFeature"
        case ZoomSDKError_EmailLoginIsDisabled: return "ZoomSDKError_EmailLoginIsDisabled"
        case ZoomSDKError_ModuleLoadFail: return "ZoomSDKError_ModuleLoadFail"
        case ZoomSDKError_NoVideoData: return "ZoomSDKError_NoVideoData"
        case ZoomSDKError_NoAudioData: return "ZoomSDKError_NoAudioData"
        case ZoomSDKError_NoShareData: return "ZoomSDKError_NoShareData"
        case ZoomSDKError_NoVideoDeviceFound: return "ZoomSDKError_NoVideoDeviceFound"
        case ZoomSDKError_DeviceError: return "ZoomSDKError_DeviceError"
        case ZoomSDKError_NotInMeeting: return "ZoomSDKError_NotInMeeting"
        case ZoomSDKError_initDevice: return "ZoomSDKError_initDevice"
        case ZoomSDKError_CanNotChangeVirtualDevice: return "ZoomSDKError_CanNotChangeVirtualDevice"
        case ZoomSDKError_PreprocessRawdataError: return "ZoomSDKError_PreprocessRawdataError"
        case ZoomSDKError_NoLicense: return "ZoomSDKError_NoLicense"
        case ZoomSDKError_Malloc_Failed: return "ZoomSDKError_Malloc_Failed"
        case ZoomSDKError_ShareCannotSubscribeMyself: return "ZoomSDKError_ShareCannotSubscribeMyself"
        case ZoomSDKError_NeedUserConfirmRecordDisclaimer: return "ZoomSDKError_NeedUserConfirmRecordDisclaimer"
        case ZoomSDKError_UnKnown: return "ZoomSDKError_UnKnown"
        case ZoomSDKError_NotJoinAudio: return "ZoomSDKError_NotJoinAudio"
        case ZoomSDKError_HardwareDontSupport: return "ZoomSDKError_HardwareDontSupport"
        case ZoomSDKError_DomainDontSupport: return "ZoomSDKError_DomainDontSupport"
        case ZoomSDKError_FileTransferError: return "ZoomSDKError_FileTransferError"
        case ZoomSDKError_Breakout_Room_Not_Created: return "ZoomSDKError_Breakout_Room_Not_Created"
        default: return "ZoomSDKError_#\(e.rawValue)"
        }
    }

    /// One line to the session log file (what the in-app log shows) and to
    /// os_log under the app's bundle id.
    nonisolated static func logLicenceLine(_ message: String) {
        Task { @MainActor in CoordinatorController.sessionLog(message) }
        Logger(subsystem: "com.sibhimanyu.greenroom", category: "zoom").notice("\(message, privacy: .public)")
    }

    // MARK: Stage video (docs/drop-obs-plan.md, piece 2)

    /// The picture the meeting should show as our camera, or nil for none.
    ///
    /// ONE `ZoomVideoSender` is installed in the SDK and kept for as long as
    /// the SDK stays signed in. A session only points it at a picture
    /// (`attach`) and, when it ends, away from it (`detach`, then black). The
    /// SDK is never asked to swap or clear its source between meetings.
    ///
    /// Why this and not "clear it with nil, wait for onUninitialize, install a
    /// new one" every time: the SDK's raw-data source slot is process-wide and
    /// its header says nothing about when it may be changed. A live run got
    /// `ZoomSDKError_Malloc_Failed` (22) from `setExternalVideoSource` on its
    /// install, seconds after sign-in and while a display was being unplugged.
    /// Installing is the risky call, so it is done once, at the quietest moment
    /// available (after sign-in, with no display event in flight), and never
    /// again unless the SDK itself lets go of the source (`onReleased`, which
    /// the SDK may do when a meeting ends). Clear-and-reinstall is kept only as
    /// the retry for a failed install, where the slot may be half-set.
    private var requestedStageSource: StageFrameSource?
    /// Kept alive here; the SDK holds its source delegate weakly.
    private var stageVideoSender: ZoomVideoSender?
    /// The SDK currently holds `stageVideoSender` as its external source.
    private var stageVideoInstalled = false
    private var stageInstallTask: Task<Bool, Never>?
    /// Zoom's own words for the last install that failed, nil otherwise.
    private(set) var stageVideoFailure: String?
    /// True when our own video source is installed in the SDK.
    var stageVideoActive: Bool { stageVideoInstalled }
    #if DEBUG
    private var debugTestPattern: StageTestPattern?
    #endif

    func useStageVideo(_ source: StageFrameSource?) {
        requestedStageSource = source
        if isAuthed { applyStageVideo() }
    }

    private func applyStageVideo() {
        guard let source = requestedStageSource else {
            // Session over: the picture goes, the source stays installed.
            stageVideoSender?.detach()
            stageVideoSender?.resetPicture()
            return
        }
        if stageVideoInstalled, let sender = stageVideoSender {
            sender.attach(source)   // already installed: just change the picture
            return
        }
        guard stageInstallTask == nil else { return }   // running; attaches what is requested when done
        stageInstallTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            let ok = await self.installStageVideoWithRetry()
            self.stageInstallTask = nil
            return ok
        }
    }

    /// Waits for the picture to be installed in the SDK (starting the install
    /// if it has not been), and says whether it is. The start flows await this
    /// before joining, so a picture that cannot be installed stops the start
    /// with a plain message instead of becoming a meeting with a blank camera.
    func awaitStageVideo() async -> Bool {
        if stageVideoInstalled { return true }
        if stageInstallTask == nil { applyStageVideo() }
        if let task = stageInstallTask { return await task.value }
        return stageVideoInstalled
    }

    /// Three tries, each at a moment with no display event in flight. After
    /// the first, the slot is cleared first (the install may have half-taken)
    /// and the SDK given up to a second to say it let go.
    private func installStageVideoWithRetry() async -> Bool {
        let pauses: [TimeInterval] = [0, 1.0, 2.5]
        var lastDetail = "no answer"
        for (index, pause) in pauses.enumerated() {
            if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
            if Task.isCancelled { return false }
            if !(await DisplayMonitor.shared.awaitQuiet(quietFor: 1.0, timeout: 4)) {
                ZoomVideoSender.log("a display is still being plugged or unplugged; trying to install the picture anyway.")
            }
            guard isAuthed, requestedStageSource != nil else { return false }   // signed out, or the session ended meanwhile
            guard let controller = ZoomSDK.shared().getRawDataController() else {
                lastDetail = "the SDK gave no raw data controller"
                ZoomVideoSender.log("attempt \(index + 1) of \(pauses.count): \(lastDetail).")
                continue
            }
            var helper: ZoomSDKRawDataVideoSourceController?
            let got = controller.getRawDataVideoSourceHelper(&helper)
            guard got == ZoomSDKError_Success, let helper else {
                lastDetail = "getRawDataVideoSourceHelper returned \(Self.errorName(got))"
                ZoomVideoSender.log("attempt \(index + 1) of \(pauses.count): \(lastDetail).")
                continue
            }
            let sender = stageVideoSender ?? ZoomVideoSender()
            sender.onReleased = { [weak self] in
                self?.stageVideoInstalled = false
                ZoomVideoSender.log("the SDK let go of our video source; it will be installed again at the next start.")
            }
            if index > 0 {
                let cleared = helper.setExternalVideoSource(nil, videoDataFormat: ZoomSDKFrameDataFormat_I420_Limited)
                ZoomVideoSender.log("attempt \(index + 1) of \(pauses.count): cleared the video source first (\(Self.errorName(cleared))).")
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            let set = helper.setExternalVideoSource(sender, videoDataFormat: ZoomSDKFrameDataFormat_I420_Limited)
            if set == ZoomSDKError_Success {
                stageVideoSender = sender
                stageVideoInstalled = true
                stageVideoFailure = nil
                sender.attach(requestedStageSource)
                ZoomVideoSender.log("installed as the external video source (I420 limited)" + (index > 0 ? ", on attempt \(index + 1)" : "") + "; there is no camera to pick.")
                return true
            }
            lastDetail = "setExternalVideoSource returned \(Self.errorName(set)) (\(set.rawValue))"
            ZoomVideoSender.log("attempt \(index + 1) of \(pauses.count): \(lastDetail).")
        }
        stageVideoFailure = lastDetail
        ZoomVideoSender.log("failed after \(pauses.count) attempts: \(lastDetail). The meeting would have no video from Greenroom.")
        return false
    }

    #if DEBUG
    /// UserDefaults bool `GreenroomRawVideoSpike`: feed a moving test pattern
    /// through the real sender, so the meeting path can be tested end to end.
    private func startDebugTestPatternIfEnabled() {
        guard ZoomVideoSender.debugTestPatternEnabled, requestedStageSource == nil else { return }
        let pattern = debugTestPattern ?? StageTestPattern()
        debugTestPattern = pattern
        pattern.start()
        requestedStageSource = pattern
        ZoomVideoSender.log("debug test pattern switched on (GreenroomRawVideoSpike).")
    }
    #endif

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
        stageVideoSender?.detach()
        stageVideoSender?.onReleased = nil
        stageVideoSender = nil   // the SDK let go of the source; the next sign-in installs it again
        stageVideoInstalled = false
        stageInstallTask?.cancel()
        stageInstallTask = nil
        authedClientID = nil
        authedClientSecret = nil
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
        // Join the computer's audio without asking. In custom UI there is no Zoom
        // dialog to answer, so without this a meeting can start with no audio at
        // all and nothing on screen saying why; the toolbar's "Join audio" is
        // the way back if it still does not.
        _ = ZoomSDK.shared().getSettingService()?.getAudioSetting()?.enableAutoJoinVoip(true)
        let configuration = meetingService.getMeetingConfiguration()
        // Both were meant for the parked tile of an ARRANGED session. When
        // nothing is arranged and Zoom draws its own UI, its window is the main
        // one, so it keeps its thumbnail and info button. In custom UI there is
        // no Zoom window at all, so the setting is moot either way.
        // Assigned both ways: the configuration outlives a session.
        let hidesForTile = arrangesWindows
        configuration.hideThumbnailVideoWindow = hidesForTile
        configuration.hideMeetingInfoButtonOnVideo = hidesForTile
        // Zoom's "Hide Self View" - a USER PREFERENCE, not hardcoded:
        // hidden (the default) keeps the speaker tile and gallery to just
        // the others; shown puts your tile among them like anyone else's.
        // Either way your video keeps sending - this only affects local
        // rendering (ZoomSDKSettingVideoController.h).
        ZoomSDK.shared().getSettingService()?.getVideoSetting()?.enableHideSelfView(hideSelfViewPreference)
        // "Mirror my video" OFF (persisted setting, asserted every
        // connect): mirroring only affects the LOCAL self-view - others
        // always see the feed un-mirrored - and this feed is the Greenroom
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
        // is recorded.
        if didUseCustomUI {
            _ = ZoomSDK.shared().getSettingService()?.getVideoSetting()?.displayUserName(onVideo: false)
        }
        // PERSISTED setting, asserted off before every connect (same
        // never-trust doctrine as DualScreenMode below): when it sticks
        // on, the SDK fullscreens its meeting windows at join - and a
        // fullscreen meeting window on the main display gets filmed by
        // the screen capture, feeding the meeting back into itself
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

    /// Forces a specific camera
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

    /// The meeting's microphone: the one picked on the Webcam page, or the
    /// system's input when none is. Matched by the CoreAudio UID first (what
    /// AVFoundation uses) and by name second, since the SDK's own IDs
    /// are not documented to be that UID. Works before and during a meeting.
    func selectMicrophone(uid: String, name: String?) -> Bool {
        guard let audio = ZoomSDK.shared().getSettingService()?.getAudioSetting() else { return false }
        if uid.isEmpty {
            return audio.selectSameAudioDevice(asSystem: true) == ZoomSDKError_Success
        }
        let devices = (audio.getAudioDeviceList(true) ?? []).compactMap { $0 as? SDKDeviceInfo }
        let match = devices.first { $0.getDeviceID() == uid }
            ?? name.flatMap { wanted in devices.first { $0.getDeviceName() == wanted } }
        guard let device = match else { return false }
        return audio.selectAudioDevice(true, deviceID: device.getDeviceID(),
                                       deviceName: device.getDeviceName()) == ZoomSDKError_Success
    }

    /// The Mac's output devices as the SDK lists them, with the one in use.
    func speakerDevices() -> (devices: [(id: String, name: String)], selectedID: String?) {
        guard let audio = ZoomSDK.shared().getSettingService()?.getAudioSetting() else { return ([], nil) }
        let list = (audio.getAudioDeviceList(false) ?? []).compactMap { $0 as? SDKDeviceInfo }
        let devices = list.map { (id: $0.getDeviceID() ?? "", name: $0.getDeviceName() ?? "Speaker") }
        let selected = list.first { $0.isSelectedDevice() }?.getDeviceID()
        return (devices, selected)
    }

    /// Picks where the meeting's sound plays, matched by the id the list gave.
    func selectSpeaker(id: String, name: String) -> Bool {
        guard let audio = ZoomSDK.shared().getSettingService()?.getAudioSetting() else { return false }
        return audio.selectAudioDevice(false, deviceID: id, deviceName: name) == ZoomSDKError_Success
    }

    /// The microphones, same shape, for the toolbar's mic menu.
    func microphoneDevices() -> (devices: [(id: String, name: String)], selectedID: String?) {
        guard let audio = ZoomSDK.shared().getSettingService()?.getAudioSetting() else { return ([], nil) }
        let list = (audio.getAudioDeviceList(true) ?? []).compactMap { $0 as? SDKDeviceInfo }
        let devices = list.map { (id: $0.getDeviceID() ?? "", name: $0.getDeviceName() ?? "Microphone") }
        let selected = list.first { $0.isSelectedDevice() }?.getDeviceID()
        return (devices, selected)
    }

    func selectMicrophone(id: String, name: String) -> Bool {
        guard let audio = ZoomSDK.shared().getSettingService()?.getAudioSetting() else { return false }
        return audio.selectAudioDevice(true, deviceID: id, deviceName: name) == ZoomSDKError_Success
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

    /// Leaves the meeting. When this connection is the HOST (New Meeting
    /// mode), leaving ends the meeting for everyone - Stop means the
    /// session is over, not "the host vanished and the meeting lingers".
    /// Safe to call when not in one. The isJoined flip also feeds the
    /// coordinator's meeting-ended observer, which closes the chat window.
    /// Returns whether it asked Zoom to END the meeting (as host) rather than
    /// just leave. Zoom's leaveMeeting reports nothing back, so an end it
    /// turned down looks exactly like one it honoured - see the coordinator's
    /// endMeetingForEveryone for what covers that.
    @discardableResult
    func leave() -> Bool {
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
        return cmd == LeaveMeetingCmd_End
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
        // The spike's element has no bookkeeping here: no cooldown, no retry.
        #if DEBUG
        if let spike = spikeElement, spike === element {
            Self.videoLog("View spike: SUBSCRIBE FAIL code=\(error.rawValue) user=\(userID) \(reason)")
            onSpikeSubscribeFail?(Int(error.rawValue), userID)
            return
        }
        #endif
        let now = Date()
        // The active element FIRST, and return: it shares no user bookkeeping
        // with the tiles, and falling through armed a cooldown nothing ever
        // consumed - the refusal was logged UNTRACKED and never retried,
        // which is why the Speaker window stayed black while the tiles,
        // refused identically in the same burst, recovered.
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
        #if DEBUG
        if let spike = spikeElement, let element, spike === element {
            Self.videoLog("View spike: render data type user=\(element.userid) type=\(type.rawValue)"
                + " (\(type == VideoRenderDataType_Video ? "video" : type == VideoRenderDataType_Avatar ? "avatar" : "none"))")
            onSpikeDataType?(type)
            return
        }
        #endif
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
    /// A callback the SDK never made. `what` is the step, `advice` the way out.
    case timedOut(what: String, seconds: Int, advice: String)
    /// Greenroom's picture could not be installed as the meeting's camera,
    /// after retrying. `detail` carries Zoom's own error name.
    case videoInstallFailed(detail: String)
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
            return "Zoom rejected the meeting passcode. Check it in Settings \u{2192} Zoom."
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
        case .initFailed(let error): return "Meeting SDK init failed (\(ZoomMeetingSDKClient.errorName(error)))."
        case .jwtGenerationFailed: return "Couldn't build the Meeting SDK auth token."
        case .authServiceUnavailable: return "Zoom Meeting SDK's auth service isn't available."
        case .authCallFailed(let error): return "Meeting SDK auth call failed immediately (\(ZoomMeetingSDKClient.errorName(error)))."
        case .authRejected(let error): return "Meeting SDK auth was rejected (\(error))."
        case .meetingServiceUnavailable: return "Zoom Meeting SDK's meeting service isn't available."
        case .invalidMeetingNumber: return "Meeting number must be numeric."
        case .joinFailed(let error): return "Zoom Meeting SDK join call failed immediately (\(ZoomMeetingSDKClient.errorName(error)))."
        case .joinRejected(let error, let status):
            return Self.joinFailureText(error, status: status)
        case .timedOut(let what, let seconds, let advice):
            return "\(what) didn\u{2019}t finish in \(seconds) seconds. \(advice)"
        case .videoInstallFailed(let detail):
            return "Greenroom couldn\u{2019}t put your picture into the meeting, so the class would see nothing from you (Zoom said: \(detail)). Nothing was left running. Press Try again; if it keeps happening, quit and reopen Greenroom."
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
        // Every status the SDK reports, in plain words. A start that stalls in
        // Connecting is only diagnosable if the log shows where it stopped.
        Self.logLicenceLine("Meeting status: \(Self.statusName(state))" + (error.rawValue != 0 || reason.rawValue != 0 ? " (error \(error.rawValue), end reason \(reason.rawValue))" : ""))
        // The raw-data licence is often only known once we are in a meeting,
        // so a "no" after sign-in may be wrong. Log it again here, once.
        if state == ZoomSDKMeetingStatus_InMeeting {
            checkRawVideoLicence(when: "in meeting")
        }
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
            onParticipantCountChanged?()
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
