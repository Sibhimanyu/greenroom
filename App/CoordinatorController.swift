//
//  CoordinatorController.swift
//  Greenroom
//
//  Orchestrates the whole flow: start the in-process picture (StageCompositor:
//  screen + camera) -> install it as the meeting's video -> join or host in the
//  built-in Zoom client, recording with SessionRecorder. This is the only thing
//  the UI talks to.
//
import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class CoordinatorController: ObservableObject {

    /// For the app delegate's termination hook, which has no other path
    /// to the SwiftUI-owned instance. Set in init; there is exactly one
    /// coordinator per app.
    static weak var shared: CoordinatorController?

    /// Called on quit, BEFORE AppKit's termination machinery runs: leaves
    /// any live meeting and cancels the window tasks. Without this, the
    /// Zoom SDK could throw a leave-confirmation modal during quit,
    /// deadlocking the app into
    /// force-quit territory.
    func prepareForTermination() {
        // A deliberate quit: the main window is not shown again on the way out.
        applyMainWindow(mainWindowVisibility.handle(.quitting))
        stopCues()
        for viewer in previewViewers { stopShapePreview(for: viewer) }
        ChatWindowController.close()
        PeoplePopOutController.close()
        customUIGridTask?.cancel()
        customUIGridTask = nil
        MeetingControlBarController.close()
        ParticipantGridWindowController.close()
        MeetingViewWindows.closeAll()
        RoomScreen.close()
        zoomChatClient.releaseCustomUIVideo()
        zoomChatClient.leave() // ends the meeting if we're hosting it
    }

    /// Graceful infrastructure teardown for app quit, awaited via
    /// applicationShouldTerminate's terminateLater. Every step is BOUNDED so a
    /// wedged component can never hang the quit:
    ///  1. finish any live recording (the file must be whole before we go),
    ///  2. let go of the meeting's video, stop the cameras and the screen
    ///     capture,
    ///  3. wait for the SDK meeting to actually CLOSE - the leave/end
    ///     posted by prepareForTermination must reach Zoom before
    ///     unInitSDK/_exit tears the SDK down mid-send, or a hosted
    ///     meeting lingers for the whole class.
    func windDownForQuit() async {
        stopCues()
        // Perceived-instant quit: our windows vanish NOW; the teardown
        // below finishes headless. Cmd-Q sitting on a visible frozen
        // window for 4-10s read as a hang (reported live).
        for window in NSApp.windows { window.orderOut(nil) }

        // Quit-cost breakdown, one line per quit to
        // ~/Library/Logs/Greenroom-quit.log (written at the end of this
        // function). scripts/measure-quit.sh drives the whole thing.
        let quitStarted = Date()
        var phases: [String] = []
        func mark(_ label: String, from start: Date) {
            phases.append("\(label)=\(Int(Date().timeIntervalSince(start) * 1000))ms")
        }

        // prepareForTermination already POSTED the leave/end and Zoom
        // confirms it on its own clock, so it rides ALONGSIDE the recorder
        // and stage teardown rather than after it.
        let meetingClosed = Task { () -> Double in
            let started = Date()
            await self.zoomChatClient.awaitMeetingClosed(timeout: 5)
            return Date().timeIntervalSince(started)
        }

        // The recorder is the authority on whether a recording is live.
        let recordStart = Date()
        if isRecording, let recorder {
            if let url = await Self.boundedStop(recorder, seconds: 8) {
                _ = adoptPendingClips(recordedAt: url.path)
                Notifier.post(title: "Recording saved",
                              body: "\(url.lastPathComponent) \u{2014} in Documents/Greenroom.")
            }
            apply(.takeDroppedAtQuit)
        } else if let saving = savingTask {
            // End Session stopped the tape in the background; Quit still
            // gives the file the same bounded wait.
            _ = await Self.boundedWait(seconds: 8) { await saving.value }
        }
        mark("record", from: recordStart)

        let stageStart = Date()
        cameraDirector.stop()
        zoomChatClient.useStageVideo(nil)
        recorder?.disarmClipBuffer()
        recorder = nil
        stopStage()
        mark("stage", from: stageStart)

        phases.append("meeting-close=\(Int(await meetingClosed.value * 1000))ms")

        // Appended to a file rather than NSLog'd: applicationWillTerminate
        // ends in _exit(0), which skips the unified log's flush - verified
        // live, an NSLog here produced nothing at all in `log show`. A
        // synchronous write survives.
        let line = "\(Self.quitLogStamp.string(from: quitStarted)) "
            + phases.joined(separator: " ")
            + " total=\(Int(Date().timeIntervalSince(quitStarted) * 1000))ms\n"
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Greenroom-quit.log")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    /// Timestamp format for the quit-cost log. Held statically because
    /// building a formatter is not free and quit is latency-sensitive.
    private static let quitLogStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// A recording stop that never waits longer than `seconds`. If the writer
    /// is slow, the file so far is what is on disk (it is written in
    /// fragments, so it plays) and its path is still returned.
    private static func boundedStop(_ recorder: SessionRecorder, seconds: Double) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let once = OnceFlag()
            Task.detached {
                let url = await recorder.stop()
                if once.take() { cont.resume(returning: url) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.take() { cont.resume(returning: recorder.recordingURL) }
            }
        }
    }

    private static func boundedWait<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = OnceFlag()
            Task.detached {
                let value = await op()
                if once.take() { cont.resume(returning: value) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.take() { cont.resume(returning: nil) }
            }
        }
    }

    @Published private(set) var statusLines: [String] = []

    /// How far the start has got, in steps a teacher can name.
    ///
    /// `statusLines` already carried all of this and carried it well, but as
    /// prose in a log that is collapsed by default, in the main window, usually
    /// on a different display from the one being watched. This is the same
    /// information shaped so a panel can draw it.
    @Published private(set) var startReadiness = ParticipantGridWindowController.Readiness() {
        didSet { syncReadinessHUD() }
    }

    /// The HUD carries the start only when the participant panel cannot.
    ///
    /// With a reference display the panel owns a whole screen and nothing can
    /// cover it, so it does the job and the HUD would just be a second copy of
    /// the same list. Without one the panel is either off - it is opt-in on a
    /// single display and off by default - or it is an ordinary window that the
    /// tiling step is about to bury. Either way, nothing on that screen is
    /// telling the teacher what is happening, which is what the HUD is for.
    private func syncReadinessHUD() {
        // Greenroom's own windows replace Zoom's, so there is nothing on screen
        // during a start unless the card shows it.
        // A failed start is the exception to both guards below: it always needs
        // a card with a way out, wherever the panel is or is not.
        let failed = startReadiness.failure != nil
        // A meeting start: the island is the one status surface, with Cancel,
        // until the meeting is live (StartChoreography.surfaces). A failure falls
        // through to the cases below, as it always has. Cleared steps (live, or
        // abandoned) fold the island without a "Live" beat: the bar takes over.
        if !recordFlowHUD, !failed, startInBar {
            guard !startReadiness.steps.isEmpty,
                  let screen = DisplayResolver.mainDisplayScreen() ?? NSScreen.main else {
                ReadinessHUDController.close()
                return
            }
            ReadinessHUDController.show(
                startReadiness, on: screen,
                cancellable: StartChoreography.islandShowsCancel(.starting, recordStart: false),
                onCancel: { [weak self] in self?.cancelStart() })
            return
        }
        // A Record start has no panel and no meeting: the island carries it,
        // its failure and its Try again, always.
        if recordFlowHUD, let screen = DisplayResolver.mainDisplayScreen() ?? NSScreen.main {
            ReadinessHUDController.show(startReadiness, on: screen)
            return
        }
        // Arranged: a panel on the reference display carries the card, so the
        // HUD is only for a start with none. Nothing arranged: the panel opens
        // on demand, so the HUD carries the card until the teacher opens it.
        // The Meeting window has no readiness card any more, so the island never
        // steps aside for it: a failure it dropped was shown nowhere.
        guard StartChoreography.islandCarriesReading(
            failed: failed, arranged: sessionArranges,
            layoutHasMeetingDisplay: sessionArranges && peopleViewTargetScreen() != nil,
            meetingWindowOpen: ParticipantGridWindowController.isOpen) else {
            ReadinessHUDController.close()
            return
        }
        guard let screen = DisplayResolver.mainDisplayScreen() ?? NSScreen.main else { return }
        ReadinessHUDController.show(startReadiness, on: screen)
    }

    /// The steps of a start, in the order they finish.
    ///
    /// Camera and meeting overlap in reality - the REST call and the SDK auth
    /// run concurrently with the picture coming up - but they are reported in
    /// sequence, because the meeting cannot COMPLETE before the picture is live and
    /// that dependency is the one the teacher is actually waiting on.
    enum StartStep: Int, CaseIterable {
        case workspace, camera, creating, meeting, recording, tiling

        var label: String {
            switch self {
            case .workspace: return "Workspace"
            case .camera: return "Picture"
            case .creating: return "Creating meeting"
            case .meeting: return "Meeting"
            case .recording: return "Recording"
            case .tiling: return "Tiling windows"
            }
        }
    }

    /// The island carries a Record start (no meeting panel exists for it).
    private var recordFlowHUD = false

    private func resetStartReadiness() {
        recordFlowHUD = false
        lastStartWasRecordFlow = false
        // Steps this start will skip are marked now, so the island counts only
        // what it will really do ("1/2", not "2/5").
        startReadiness = .init(steps: StartStep.allCases.map { step in
            let label = step.label
            // Creating meeting is the one network wait before the SDK connects: the
            // REST create (instant start) or the host-key fetch (scheduled start).
            // A scheduled start with a warm host key has nothing to wait for.
            let skipped = (step == .tiling && !sessionArranges) || (step == .recording && !autoRecordOnStart)
                || (step == .creating && meetingMode == .join && validPrefetchedZAK() != nil)
            return .init(label: label, state: skipped ? .skipped : .pending)
        })
    }

    private func mark(_ step: StartStep, _ state: ParticipantGridWindowController.Readiness.State) {
        guard startReadiness.steps.indices.contains(step.rawValue) else { return }
        startReadiness.steps[step.rawValue].state = state
        if step == .meeting, state == .active, startBarText != nil {
            startBarText = StartChoreography.barText(.joining)
        }
    }

    /// Ends the progress display. Clearing the steps makes `isLive` true, which
    /// is what returns the panel to its ordinary behaviour.
    private func finishStartReadiness(liveConfirmed: Bool = false) {
        startBarText = nil
        // Still "in the bar" while the steps clear, so the island does not
        // flash its Live beat for a start it never showed. Live is claimed only
        // on the caller's confirmation (StartChoreography.islandEnd).
        startReadiness = .init()
        startReadiness.liveConfirmed = liveConfirmed
        startInBar = false
    }

    /// Set while a meeting starts, nil otherwise: the "starting" flag Cancel
    /// keys off. The words themselves are the island's (NotchStatusRules).
    @Published private(set) var startBarText: String?
    /// This start opened apps, which is what waiting for quiet screens guards.
    private var startOpenedApps = false
    /// The island carries this meeting start (steps and Cancel, then a failure
    /// if one comes). Cleared when the steps clear.
    private var startInBar = false

    /// The click: Home steps aside and the island takes the start's status. The
    /// floating bar waits for the meeting to be live. Before resetStartReadiness,
    /// so the island's first reading already has its steps.
    private func beginStartChoreography() {
        startBarText = StartChoreography.barText(.starting)
        startInBar = true
        ensureMeetingControls()
        // Home only steps aside if it was on screen; a start from the hotkey or
        // the menu bar leaves it alone.
        if MainWindow.current?.isVisible == true {
            applyMainWindow(mainWindowVisibility.handle(.startBegan))
        }
    }

    /// Where Home steps aside toward and comes back from: the bar once it is up,
    /// else the island's spot under the menu bar (no notch needed).
    private var startSurfaceFrame: NSRect? {
        if let bar = MeetingControlBarController.currentFrame { return bar }
        guard let screen = DisplayResolver.mainDisplayScreen() ?? NSScreen.main else { return nil }
        let size = NotchGeometry.bodySize(for: .none)
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 6,
                      width: size.width, height: size.height)
    }

    /// The island's Cancel: abandons a start in flight. Home comes back as it was.
    func cancelStart() {
        guard startBarText != nil, !isStopping else { return }
        log("Start cancelled.")
        stop()
    }

    private func failStartReadiness(_ message: String, fix: StartFailureFix? = nil) {
        if let active = startReadiness.steps.firstIndex(where: { $0.state == .active }) {
            startReadiness.steps[active].state = .failed
        }
        startFailureFix = fix
        startReadiness.failureActionTitle = fix?.title
        startReadiness.failure = message
    }
    /// What the failure card's button does when it is not Try again.
    private var startFailureFix: StartFailureFix?
    /// True only during the Start transition (pipeline + meeting setup).
    /// `stageLive` is the "session is live" flag the buttons key
    /// off once starting completes.
    @Published private(set) var isRunning = false
    /// The class picture is up and (in a meeting) is being sent. Was
    @Published private(set) var stageLive = false

    /// Cuts between a camera on each monitor while a class runs. Owned here
    /// because it lives exactly as long as the session does - see start()
    /// and stop().
    let cameraDirector = CameraDirector()

    /// Looks through one camera directly, for aiming it in Settings. Never
    /// running at the same time as a session - see aimCamera.
    let cameraProbe = CameraProbe()

    @Published var cameraDirectorSettings: CameraDirectorSettings = CameraDirectorSettings.load() {
        didSet {
            guard cameraDirectorSettings != oldValue else { return }
            cameraDirectorSettings.save(defaults)
            syncSavedCameraState()
            Analytics.setting("camera_director", on: cameraDirectorSettings.isUsable)
            // Applied live: a teacher who turns it on mid-class should not
            // have to end the session to get it.
            if sceneInUse, stage != nil {
                applyCameraDirectorLive(from: oldValue)
            } else if !isRunning {
                // The idle preview follows the same settings.
                syncIdleDirector(restart: sessionCameraUIDs(oldValue) != sessionCameraUIDs(cameraDirectorSettings))
            }
        }
    }
    @Published private(set) var isStopping = false
    private var startTask: Task<Void, Never>?

    /// The single source of truth for the eight session and take flags below
    /// (SessionPhase.swift). Events go in through `apply`; the flags are only
    /// ever assigned by `syncFlags`, so they cannot disagree with each other.
    private(set) var phase = SessionPhase()

    /// Reports what happened. Each flag is assigned only when it changes, in
    /// the order the old hand-written assignments used.
    private func apply(_ event: SessionPhase.Event) {
        phase.apply(event)
        // End Session's teardown sets "recording" off before "saving" on, and
        // every other take ending the other way round.
        syncFlags(recordingFirst: event == .takeFinishingAtMeetingEnd)
    }

    private func syncFlags(recordingFirst: Bool) {
        if stageLive != phase.stageLive { stageLive = phase.stageLive }
        if isRunning != phase.isRunning { isRunning = phase.isRunning }
        if isStopping != phase.isStopping { isStopping = phase.isStopping }
        if recordOnlyActive != phase.recordOnlyActive { recordOnlyActive = phase.recordOnlyActive }
        if startingRecordOnly != phase.startingRecordOnly { startingRecordOnly = phase.startingRecordOnly }
        if isRecordingPaused != phase.isRecordingPaused { isRecordingPaused = phase.isRecordingPaused }
        if recordingFirst, isRecording != phase.isRecording { isRecording = phase.isRecording }
        if isSavingRecording != phase.isSavingRecording { isSavingRecording = phase.isSavingRecording }
        if isRecording != phase.isRecording { isRecording = phase.isRecording }
        // The preview drops to its meeting rate while the meeting encodes.
        previewSink.meetingLive = phase.isInMeeting
    }

    /// The cameras the scene should hold for these settings: the director's
    /// list when it can run, otherwise none, which ensureConfigured reads as
    /// "the one webcam it would have picked anyway".
    private func sessionCameraUIDs(_ settings: CameraDirectorSettings) -> [String] {
        let available = settings.availableOnly()
        return available.isUsable ? available.cameraUIDs : []
    }

    /// Opens the cameras past the first and starts the director, once the
    /// meeting is live.
    ///
    /// Not at Start, on purpose. The first camera is what the class sees
    /// first, so it comes up with the picture and the start waits for nothing
    /// else. The others are only there to be cut to, and until there is a
    /// class there is nobody to cut for - while opening one early is not free:
    /// an iPhone used as a camera wakes into Continuity Camera the moment
    /// anything opens it, which is how this was found.
    private func bringInExtraCameras() {
        let uids = sessionCameraUIDs(cameraDirectorSettings)
        guard uids.count > 1, let stage else { return }
        stageCameraUIDs = uids
        stage.update(makeStageConfiguration())
        guard sceneInUse, !cameraDirector.isRunning else { return }
        cameraDirector.start(stage: stage, settings: cameraDirectorSettings)
        log("Watching for which camera you're facing \u{2014} \(uids.count) cameras, all open, switching after \(String(format: "%.1f", cameraDirectorSettings.dwellSeconds))s facing another.")
    }

    /// A change to the camera settings, mid-class.
    ///
    /// Only a change of CAMERAS reopens anything. The dwell slider and the
    /// cut-or-crossfade choice are retuned in place: restarting the director
    /// for them would put it back on the first camera while the class was
    /// seeing another.
    private func applyCameraDirectorLive(from old: CameraDirectorSettings) {
        let before = sessionCameraUIDs(old)
        let after = sessionCameraUIDs(cameraDirectorSettings)
        guard before != after else {
            cameraDirector.retune(cameraDirectorSettings)
            return
        }
        cameraDirector.stop()
        guard let stage else { return }
        let fallback = LocalDeviceResolver.physicalCameraUID().map { [$0] } ?? []
        stageCameraUIDs = after.isEmpty ? fallback : after
        stage.update(makeStageConfiguration())
        stage.cut(toSlot: 0, fade: 0)
        // Only if the cameras did not change again meanwhile.
        guard sceneInUse, sessionCameraUIDs(cameraDirectorSettings) == after else { return }
        cameraDirector.start(stage: stage, settings: cameraDirectorSettings)
    }

    /// The Settings/Home preview, with switching on and two cameras chosen,
    /// is a small class of its own: the stage holds every chosen camera and the
    /// director cuts between them, so the preview is where switching is tested.
    /// The stage is the only opener of those cameras (the probe never opens one
    /// the stage holds; Aim then reads the director's sights). Nothing here
    /// runs while a session owns the picture; a session starts and stops the
    /// director itself.
    private func syncIdleDirector(restart: Bool) {
        guard !phase.isCameraBusy else { return }
        let uids = sessionCameraUIDs(cameraDirectorSettings)
        guard let stage, previewAttached, uids.count > 1 else {
            if cameraDirector.isRunning {
                cameraDirector.stop()
                if let stage, previewAttached {
                    stage.update(makeStageConfiguration())
                    stage.cut(toSlot: 0, fade: 0)
                }
            }
            return
        }
        stage.update(makeStageConfiguration())
        if restart || !cameraDirector.isRunning {
            stage.cut(toSlot: 0, fade: 0)
            cameraDirector.start(stage: stage, settings: cameraDirectorSettings)
        } else {
            cameraDirector.retune(cameraDirectorSettings)
        }
    }

    /// Aim ended on the camera it was measuring: hand the director's reading of
    /// that camera to the probe's meter.
    private func feedAim(from sights: [CameraSight]) {
        guard cameraProbe.isExternal, let uid = cameraProbe.cameraUID,
              let slot = sessionCameraUIDs(cameraDirectorSettings).firstIndex(of: uid),
              sights.indices.contains(slot) else { return }
        cameraProbe.feed(sights[slot])
    }

    @Published var meetingNumber = ""
    @Published var meetingPassword = ""
    /// `meetingNumber` with readability spaces/dashes stripped. The field
    /// keeps whatever the user pasted (e.g. "465 230 8563"); everything
    /// that acts on the number — guards, comparisons, joins — uses this.
    var meetingNumberDigits: String { ZoomMeetingLinkParser.digits(meetingNumber) }
    @Published var meetingMode: MeetingMode {
        didSet { defaults.set(meetingMode.rawValue, forKey: "meetingMode") }
    }

    /// Saved Join Existing shortcuts (name + number + passcode) - one
    /// click to fill the fields for a meeting you join regularly.
    /// Persisted as JSON and carried in the settings-transfer file.
    @Published var meetingPresets: [MeetingPreset] = [] {
        didSet { persistPresets() } // not called during init (Swift skips observers there)
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(meetingPresets) {
            defaults.set(data, forKey: "meetingPresets")
        }
    }

    private static func loadPresets(from defaults: UserDefaults) -> [MeetingPreset] {
        guard let data = defaults.data(forKey: "meetingPresets"),
              let presets = try? JSONDecoder().decode([MeetingPreset].self, from: data) else { return [] }
        return presets
    }

    // MARK: First-run onboarding - shown once automatically, reopenable
    // from the main window's ? button.

    @Published var showOnboarding: Bool

    func presentOnboarding() {
        showOnboarding = true
    }

    /// Where a check's "Show me where" asked the setup guide to open; the
    /// guide jumps there and clears it.
    @Published var zoomGuideSpot: ZoomGuideSpot?
    /// Where Settings -> YouTube's "Set up… / Edit setup…" asked the guide to open; cleared once used.
    @Published var youtubeGuideSpot: YouTubeGuideSpot?

    func completeOnboarding() {
        showOnboarding = false
        defaults.set(true, forKey: "hasCompletedOnboarding")
    }

    // MARK: Meeting SDK chat (separate window, second participant - see
    // Vendor/ZoomSDK/README.md). The Client ID is in UserDefaults, the
    // Secret in the Keychain via SecretStore; the secret is loaded lazily.

    @Published var sdkClientID: String {
        didSet { defaults.set(sdkClientID, forKey: "zoomSDKClientID") }
    }
    @Published var sdkClientSecret: String {
        didSet {
            guard !isRestoringSecret else { return }
            SecretStore.set(sdkClientSecret, forKey: "zoomSDKClientSecret")
        }
    }
    private var secretsLoaded = false
    private var isRestoringSecret = false

    /// Copies the secrets into the published properties on first use.
    /// SecretStore reads the Keychain once per launch and serves from
    /// memory after that (see that file).
    func loadSecretsIfNeeded() {
        guard !secretsLoaded else { return }
        secretsLoaded = true
        isRestoringSecret = true
        sdkClientSecret = SecretStore.get("zoomSDKClientSecret") ?? ""
        s2sClientSecret = SecretStore.get("zoomS2SClientSecret") ?? ""
        youtubeClientSecret = SecretStore.get("youtubeClientSecret") ?? ""
        isRestoringSecret = false
    }

    let zoomChatClient = ZoomMeetingSDKClient()

    // MARK: Where Zoom credentials come from. THE one place that decides.
    // `ZoomRouteRules.route` picks ONE route and Start takes both halves from
    // it: signed in with Zoom (REST as the person, the JWT from the signing
    // function) or your own Zoom apps (the pasted S2S app and SDK keys).
    // `zoomPrefersSignIn` is Settings' choice between them, and the choice IS
    // the route (owner, 2026-11-26): a chosen way that is not ready makes Start
    // say what is missing, never fall back to the other. Settings, Home, Start
    // and the session log all read `zoomRoute`, so none of them can disagree with Start.

    let zoomUser = ZoomUserAuth()

    /// Settings' choice: true = Sign in with Zoom, false = your own Zoom apps. Set at launch by
    /// `ZoomRouteChoiceRules.initialPrefersSignIn` (a saved choice carries over).
    @Published var zoomPrefersSignIn: Bool = false {
        didSet {
            guard zoomPrefersSignIn != oldValue else { return }
            defaults.set(zoomPrefersSignIn, forKey: Self.zoomPrefersSignInKey)
            // The list and a warmed host key belong to the other account.
            scheduledMeetings = []
            personalRoom = nil
            prefetchedZAK = nil
        }
    }
    static let zoomPrefersSignInKey = "zoomPrefersSignIn"

    /// A secret counts once it is stored, even before the lazy load reads it,
    /// so Home's readiness and Settings' line are right from launch.
    private func secretPresent(_ value: String, key: String) -> Bool {
        if secretsLoaded { return !value.isEmpty }
        return !(SecretStore.get(key) ?? "").isEmpty
    }
    private var ownS2SComplete: Bool {
        !s2sAccountID.isEmpty && !s2sClientID.isEmpty && secretPresent(s2sClientSecret, key: "zoomS2SClientSecret")
    }
    private var ownSDKKeysPresent: Bool {
        !sdkClientID.isEmpty && secretPresent(sdkClientSecret, key: "zoomSDKClientSecret")
    }
    private var ownAppsComplete: Bool { ownSDKKeysPresent && ownS2SComplete }

    var zoomRouteFacts: ZoomRouteFacts {
        ZoomRouteFacts(signedIn: zoomUser.isSignedIn,
                       accountName: zoomUser.profile?.name ?? "",
                       accountEmail: zoomUser.profile?.email ?? "",
                       endpointSet: !ZoomOAuth.sdkSignatureEndpoint.isEmpty,
                       ownSDKComplete: ownSDKKeysPresent,
                       ownS2SComplete: ownS2SComplete,
                       sdkClientID: sdkClientID,
                       prefersSignIn: zoomPrefersSignIn,
                       signInComingSoon: ZoomSignInAvailability.isComingSoon)
    }

    /// The route Start will use right now.
    var zoomRoute: ZoomRoute { ZoomRouteRules.route(zoomRouteFacts) }
    /// What Settings -> Zoom shows for the chosen way (`ZoomRouteChoiceRules`).
    var zoomRouteChoice: ZoomRouteChoice {
        ZoomRouteChoiceRules.choice(ZoomRouteChoiceFacts(
            route: zoomRouteFacts,
            ownSDKStarted: !sdkClientID.isEmpty || secretPresent(sdkClientSecret, key: "zoomSDKClientSecret"),
            ownS2SStarted: !s2sAccountID.isEmpty || !s2sClientID.isEmpty
                || secretPresent(s2sClientSecret, key: "zoomS2SClientSecret"),
            signingIn: zoomSigningIn))
    }

    /// REST follows the route. With no usable route the chosen way still
    /// answers if its REST half works, so a half set-up account can be listed
    /// and tested, but never the way that is not chosen.
    var zoomRESTSource: ZoomCredentialRules.RESTSource {
        let route = zoomRoute
        if route.isUsable { return ZoomRouteRules.restSource(route) }
        // While Sign in with Zoom is coming soon a saved sign-in choice never answers.
        if zoomRouteFacts.choosesSignIn { return zoomUser.isSignedIn ? .signedIn : .none }
        return ownS2SComplete ? .ownApps : .none
    }

    /// nil when neither a Zoom sign-in nor pasted S2S credentials exist.
    var zoomAccess: ZoomRESTAccess? {
        switch zoomRESTSource {
        case .signedIn: return .signedIn(zoomUser)
        case .ownApps: return .ownApps(accountID: s2sAccountID, clientID: s2sClientID, clientSecret: s2sClientSecret)
        case .none: return nil
        }
    }

    /// Can Greenroom create, list and host meetings right now?
    var zoomHostingReady: Bool { zoomRESTSource != .none }

    /// The SDK's JWT follows the same route as REST.
    var zoomSDKAuthChoice: ZoomCredentialRules.SDKAuth { ZoomRouteRules.sdkAuth(zoomRoute) }

    /// Can the Meeting SDK be authorised right now?
    var zoomSDKReady: Bool { zoomSDKAuthChoice == .worker || zoomSDKAuthChoice == .ownKeys }

    /// How the SDK gets its JWT, or the plain-words reason it can't.
    func zoomSDKSigner() throws -> ZoomMeetingSDKClient.Signer {
        switch zoomSDKAuthChoice {
        case .ownKeys:
            return .local(clientID: sdkClientID, clientSecret: sdkClientSecret)
        case .worker:
            let user = zoomUser
            let identity = user.profile.map { $0.accountID + "/" + $0.id } ?? "signed-in"
            return .fetched(identity: identity) {
                try await user.sdkSignature(endpoint: ZoomOAuth.sdkSignatureEndpoint)
            }
        case .notFinished:
            throw NSError(domain: "Greenroom", code: 25, userInfo: [NSLocalizedDescriptionKey: ZoomCredentialRules.notFinishedText])
        case .missingKeys:
            throw NSError(domain: "Greenroom", code: 21, userInfo: [
                NSLocalizedDescriptionKey: zoomRouteMissingText
            ])
        }
    }

    /// Why Start can't run, in the route's words.
    private var zoomRouteMissingText: String {
        ZoomRouteWords.line(zoomRoute) + " Settings (\u{2318},) \u{2192} Zoom."
    }

    /// Home's Zoom pill and the menu bar: where their Zoom problem opens
    /// (the setup guide for someone who used Sign in with Zoom while it is coming soon).
    func openZoomFix() {
        switch ZoomRouteWords.homeFix(zoomRoute) {
        case .setupGuide: openZoomSetupGuide()
        case .settings: openZoomSettings()
        }
    }

    /// Where the guide's flow stands, from the keys and the last check.
    var zoomGuideFacts: ZoomGuideFlowFacts {
        ZoomGuideFlowRules.facts(sdkFields: [sdkClientID, secretPresent(sdkClientSecret, key: "zoomSDKClientSecret") ? "x" : ""],
                                 s2sFields: [s2sAccountID, s2sClientID,
                                             secretPresent(s2sClientSecret, key: "zoomS2SClientSecret") ? "x" : ""],
                                 lines: zoomSetupChecker.lines, running: zoomSetupChecker.isRunning)
    }
    /// Settings' one button into the guide: "Set up…" or "Edit setup…", and where it lands.
    var zoomSetupEntry: ZoomSetupEntry { ZoomGuideFlowRules.setupEntry(zoomGuideFacts) }

    /// The setup guide's Zoom step, at a spot (by default the first part that isn't done).
    func openZoomSetupGuide(at spot: ZoomGuideSpot? = nil) {
        let spot = spot ?? zoomSetupEntry.spot
        NSApp.activate(ignoringOtherApps: true)
        zoomGuideSpot = spot
        presentOnboarding()
    }

    func openZoomSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let open = SwiftUIActions.openSettings { open() }
        else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showSettingsTab, object: "zoom")
        }
    }

    #if DEBUG
    /// Settings -> Debug: Sign in with Zoom on for testing while it is coming soon.
    var zoomSignInOnForTesting: Bool {
        get { UserDefaults.standard.bool(forKey: ZoomSignInAvailability.debugSignInOnKey) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: ZoomSignInAvailability.debugSignInOnKey)
            scheduledMeetings = []
            personalRoom = nil
            prefetchedZAK = nil
        }
    }
    #endif

    /// The route the running (or last) start took.
    private(set) var startRoute: ZoomRoute?

    /// Plain-values sign-in state for views (they observe the coordinator).
    var zoomSignedInAs: (name: String, email: String)? {
        guard zoomUser.isSignedIn else { return nil }
        let p = zoomUser.profile
        return (p?.name ?? "", p?.email ?? "")
    }
    var zoomSigningIn: Bool { zoomUser.phase == .signingIn }
    /// Signed in, but the app now needs a scope the sign-in does not carry.
    var zoomNeedsMorePermission: Bool { zoomUser.needsSignInAgain }
    var zoomAttentionTitle: String { zoomUser.attentionTitle }
    /// What Home's Zoom pill and the menu bar say when Start can run but
    /// something about its route needs a look; nil when nothing does.
    var zoomRouteAttention: String? {
        let route = zoomRoute
        if route.usesGreenroomApp && zoomNeedsMorePermission { return zoomAttentionTitle }
        return ZoomRefusalRules.homeWarning(route: route, accountID: zoomAccountID, refused: zoomRefusedAccounts)
    }
    /// Settings' note under the sign-in's status when Zoom refused this account before.
    var zoomRouteNote: String? {
        ZoomRefusalRules.settingsNote(route: zoomRoute, accountID: zoomAccountID, refused: zoomRefusedAccounts)
    }
    private var zoomAccountID: String { zoomUser.profile?.accountID ?? "" }

    /// Signed-in accounts Zoom refused to start a meeting for through
    /// Greenroom's Zoom app (error 63). Cleared by the next Start that works.
    @Published private(set) var zoomRefusedAccounts: Set<String> =
        ZoomRefusalRules.decode(UserDefaults.standard.string(forKey: CoordinatorController.zoomRefusedAccountsKey))
    static let zoomRefusedAccountsKey = "zoomRefusedAccountIDs"

    private func noteStartOutcome(route: ZoomRoute, crossAccountRefusal: Bool) {
        let next = ZoomRefusalRules.afterStart(zoomRefusedAccounts, accountID: zoomAccountID, route: route,
                                               crossAccountRefusal: crossAccountRefusal)
        guard next != zoomRefusedAccounts else { return }
        zoomRefusedAccounts = next
        defaults.set(ZoomRefusalRules.encode(next), forKey: Self.zoomRefusedAccountsKey)
    }

    /// "Check sign-in": what Start needs from Sign in with Zoom, step by step.
    let zoomSignInChecker = ZoomSignInChecker()
    /// "Check Zoom setup": your own Zoom apps. One checker for the setup guide and Settings.
    let zoomSetupChecker = ZoomSetupChecker()
    var zoomSetupCredentials: ZoomSetupChecker.Credentials {
        [sdkClientID, sdkClientSecret, s2sAccountID, s2sClientID, s2sClientSecret]
    }
    func checkZoomSetup() {
        guard !phase.isInMeeting else { return }
        loadSecretsIfNeeded()
        zoomSetupChecker.run(client: zoomChatClient) { [weak self] in self?.zoomSetupCredentials ?? [] }
    }
    func checkZoomSignIn() {
        zoomSignInChecker.run(user: zoomUser, endpoint: ZoomOAuth.sdkSignatureEndpoint, refused: zoomRefusedAccounts)
    }

    /// The failure card's Open Settings (error 63): Settings -> Zoom with your own Zoom apps chosen.
    func openZoomOwnApps() {
        zoomPrefersSignIn = false
        NSApp.activate(ignoringOtherApps: true)
        if let open = SwiftUIActions.openSettings { open() }
        else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showSettingsTab, object: "zoom")
        }
    }
    var zoomAttentionDetail: String { zoomUser.attentionDetail }
    var zoomSignInError: String? { zoomUser.lastError }

    func signInWithZoom() {
        Task {
            try? await zoomUser.signIn()
            // Signing in is choosing it, unless your own Zoom apps already work.
            if zoomUser.isSignedIn {
                zoomPrefersSignIn = ZoomRouteChoiceRules.prefersSignInAfterSigningIn(
                    current: zoomPrefersSignIn, ownAppsComplete: ownAppsComplete)
            }
        }
    }
    func cancelZoomSignIn() { zoomUser.cancelSignIn() }
    /// Returns true when Zoom confirmed the revoke, false when only the local copy was deleted.
    func signOutOfZoom() async -> Bool {
        let revoked = await zoomUser.signOut()
        scheduledMeetings = []
        personalRoom = nil
        prefetchedZAK = nil
        return revoked
    }
    let zoomChatBridge = ZoomChatBridge()
    @Published private(set) var isConnectingChat = false

    // MARK: Start-a-meeting (Server-to-Server OAuth app - a SECOND
    // Marketplace app, separate from the Meeting SDK one above; see
    // Vendor/README.md, including why a one-app OAuth consolidation was
    // built and then abandoned). Account ID and Client ID are in
    // UserDefaults, the Secret in the Keychain via SecretStore, loaded
    // lazily like the SDK secret.

    @Published var s2sAccountID: String {
        didSet { defaults.set(s2sAccountID, forKey: "zoomS2SAccountID") }
    }
    @Published var s2sClientID: String {
        didSet { defaults.set(s2sClientID, forKey: "zoomS2SClientID") }
    }
    @Published var s2sClientSecret: String {
        didSet {
            guard !isRestoringSecret else { return }
            SecretStore.set(s2sClientSecret, forKey: "zoomS2SClientSecret")
        }
    }

    @Published var userDisplayName: String {
        didSet { defaults.set(userDisplayName, forKey: "userDisplayName") }
    }
    /// Zoom's "Hide Self View" for the built-in client. ON (default): the
    /// speaker tile and participant view show only the others. OFF: your
    /// own tile appears among them like anyone else's. Local rendering
    /// only - the class receives your video either way. Applies live.
    /// Layouts -> "Show my camera on my screen". Local only: whether Greenroom
    /// puts the camera bubble on this screen. The meeting, recordings and the
    /// share follow `cameraIsOff` (the Webcam page), never this. Global.
    @Published var cameraShownOnMyScreen: Bool {
        didSet {
            defaults.set(cameraShownOnMyScreen, forKey: "cameraShownOnMyScreen")
            syncSavedCameraState()
        }
    }
    /// The camera state (GLOSSARY.md): the saved default, which is `noCamera` and
    /// `cameraShownOnMyScreen` read as one word, plus the running meeting's own change
    /// from the bar or Home. A live change never writes the default; Start and Snap
    /// Back drop it (`resetPresenceBubbleToLayoutDefault`).
    @Published private(set) var cameraSession = CameraStateSession(saved: .everyoneAndMe)
    var cameraState: CameraState { cameraSession.current }
    /// Stop video (R49): Zoom's own video is off, so nothing goes to the meeting, not even the screen.
    /// Not a camera state. Written only from Zoom's video-status callback (`noteOwnVideoStatus`) and at
    /// Start and the end (`resetPresenceBubbleToLayoutDefault`): CoordinatorController+StopVideo.swift.
    @Published var videoStopped = false
    var savedCameraState: CameraState {
        CameraState(noCamera: cameraDirectorSettings.noCamera, shownOnMyScreen: cameraShownOnMyScreen)
    }
    private func syncSavedCameraState() {
        let saved = savedCameraState
        if cameraSession.saved != saved { cameraSession.setSaved(saved) }
    }
    /// Settings -> Layouts: the saved default for each Start. Writes the two old keys
    /// in step, so a downgrade and every other reader still agree.
    func setSavedCameraState(_ state: CameraState) {
        var next = cameraDirectorSettings
        next.noCamera = state.noCamera
        cameraDirectorSettings = next
        cameraShownOnMyScreen = state.shownOnMyScreen
        if cameraSession.live == nil { applyCameraStateLive() }
    }
    /// The bar and Home: this meeting only. The saved default stays as it was.
    func setLiveCameraState(_ state: CameraState) {
        cameraSession.setLive(state)
        applyCameraStateLive()
    }
    /// Puts the current state on the stage and the bubble: whether everyone sees
    /// the camera (`cameraIsOff`) and whether it shows on this screen.
    private func applyCameraStateLive() {
        presenceBubbleHidden = PresenceVisibility.bubbleStartsHidden(state: cameraState)
        if stage != nil, sceneInUse || isRunning {
            if cameraRuns {
                stageCameraUIDs = sceneCameraUIDs(limit: sessionCameraUIDs(cameraDirectorSettings).count > 1 ? nil : 1)
            }
            stage?.update(makeStageConfiguration())
        } else {
            previewCamerasChanged()
        }
        refreshPresenceBubble()
    }
    @Published var hideSelfView: Bool {
        didSet {
            defaults.set(hideSelfView, forKey: "hideSelfView")
            Analytics.setting("hide_self_view", on: hideSelfView)
            zoomChatClient.setHideSelfView(hideSelfView)
        }
    }
    /// The old "Quick-hide mode" setting. The Settings row is gone (a layout's
    /// Meeting piece has its own "Starts hidden", and \u{2325}\u{2318}Z is now one
    /// of the rebindable shortcuts), and nothing writes this any more: it is
    /// IMPORT-ONLY. A settings file from before layouts still carries it, and
    /// importing it stores the value where "Your previous layout" reads it
    /// (LegacyLayoutSettings), so that migration keeps its old behaviour. Exports
    /// no longer include it.
    var speakerTileShortcutEnabled: Bool {
        didSet { defaults.set(speakerTileShortcutEnabled, forKey: "speakerTileShortcutEnabled") }
    }

    /// The placed Meeting piece is hidden and the neighbour that joins it has
    /// grown into its gap. Starts as the piece's "Starts hidden" at each session
    /// start and after Snap Windows Back; \u{2325}\u{2318}Z flips it. Published
    /// (read-only) so the menu bar can label its toggle with the ACTUAL next
    /// action ("Show/Hide Speaker Tile").
    @Published private(set) var speakerTileQuickHidden = false

    /// A Meeting piece in a rectangle, or a view window, is in the layout right
    /// now, so \u{2325}\u{2318}Z has something to hide. The menu item reads this.
    var canToggleMeeting: Bool {
        guard stageLive, let template = sessionTemplate else { return false }
        return layoutEngine.hasPlacedSurface(template)
    }

    /// \u{2325}\u{2318}Z: hides the placed Meeting piece (the neighbour that
    /// joins it grows into the gap) or shows it again (the neighbour shrinks
    /// back). Only a Meeting in a rectangle toggles; one that fills a display or
    /// a layout with none has nothing to hide.
    func toggleSpeakerTile() {
        guard layoutToolsAvailable else {
            log("Speaker tile skipped \u{2014} this session arranges no windows.")
            return
        }
        guard let template = sessionTemplate, layoutEngine.hasPlacedSurface(template) else {
            log("No meeting window or view in the layout to hide \u{2014} it has none, or it fills a display.")
            return
        }
        let meeting = layoutEngine.placedMeeting(template)
        Analytics.track(.quickHide)
        let hide = !speakerTileQuickHidden
        // The meeting window is ours, so hiding it is just ordering it out.
        speakerTileQuickHidden = hide
        // The Meeting window and every view go together; the neighbours take the room.
        MeetingViewWindows.setHiddenTogether(hide)
        MeetingSurfaceOwner.send(hide ? .tileHidden : .tileShown)
        if hide {
            ParticipantGridWindowController.hide()
        } else if meeting != nil {
            openMeetingWindow()
        } else {
            // The views come back where they were (setHiddenTogether above); one
            // that never opened opens at its rectangle (R45).
            placeCustomSurfaces(trigger: .meetingShown)
        }
        layoutEngine.moveNeighbour(template, meetingHidden: hide)
        log(hide ? "Meeting hidden \u{2014} \(ShortcutStore.phrase(.toggleMeeting)) shows it."
                 : "Meeting shown \u{2014} \(ShortcutStore.phrase(.toggleMeeting)) hides it again.")
    }

    // MARK: Defaults - persisted so Start reproduces the whole setup every time

    /// Where the webcam bubble sits and how big it is, as fractions of the
    /// canvas so it survives a resolution change.
    ///
    /// Clamped on the way in: a bubble placed off-canvas, or a bubble nobody can see, is indistinguishable
    /// from a camera that stopped working.
    @Published var bubbleWidthFraction: Double {
        didSet {
            let clamped = min(max(bubbleWidthFraction, 0.08), 0.6)
            if clamped != bubbleWidthFraction { bubbleWidthFraction = clamped; return }
            defaults.set(bubbleWidthFraction, forKey: "bubbleWidthFraction")
        }
    }
    @Published var bubbleRightInset: Double {
        didSet {
            let clamped = min(max(bubbleRightInset, 0), 0.9)
            if clamped != bubbleRightInset { bubbleRightInset = clamped; return }
            defaults.set(bubbleRightInset, forKey: "bubbleRightInset")
        }
    }
    @Published var bubbleBottomInset: Double {
        didSet {
            let clamped = min(max(bubbleBottomInset, 0), 0.9)
            if clamped != bubbleBottomInset { bubbleBottomInset = clamped; return }
            defaults.set(bubbleBottomInset, forKey: "bubbleBottomInset")
        }
    }

    /// Cutout's height, as a fraction of canvas height. Floored well above zero:
    /// the frame being too small was one of the two problems that made cutout
    /// stop reusing the bubble box, because a raised hand left the frame and
    /// clipped visibly.
    @Published var cutoutHeightFraction: Double {
        didSet {
            let clamped = min(max(cutoutHeightFraction, 0.3), 1.0)
            if clamped != cutoutHeightFraction { cutoutHeightFraction = clamped; return }
            defaults.set(cutoutHeightFraction, forKey: "cutoutHeightFraction")
        }
    }
    /// Cutout's distance from the right edge, as a fraction of canvas width.
    /// Allowed all the way across so the person can stand on the left when the
    /// shared content lives on the right.
    @Published var cutoutRightInset: Double {
        didSet {
            let clamped = min(max(cutoutRightInset, 0), 0.95)
            if clamped != cutoutRightInset { cutoutRightInset = clamped; return }
            defaults.set(cutoutRightInset, forKey: "cutoutRightInset")
        }
    }

    /// Every number plus the shape, as the compositor wants it.
    var stageLayout: StageLayout {
        StageLayout(widthFraction: bubbleWidthFraction,
                    rightInset: bubbleRightInset,
                    bottomInset: bubbleBottomInset,
                    cutoutHeightFraction: cutoutHeightFraction,
                    cutoutRightInset: cutoutRightInset,
                    shape: webcamShape,
                    // The whiteboard is content too (a page behind the camera).
                    showsContent: !shareTarget.sharesNothing,
                    showsCamera: !cameraIsOff,
                    // Only me: open for the bubble, not drawn for everyone (R6.4).
                    mirrorsCamera: cameraIsMirrorOnly)
    }

    /// Only me: a mirror for the owner's bubble. The camera runs, the picture leaves it out.
    var cameraIsMirrorOnly: Bool {
        Visibility.cameraMirrorOnly(state: cameraState, target: Visibility.Target(shareTarget))
    }
    /// Off is the only state that closes the camera (`Visibility.cameraRuns`).
    var cameraRuns: Bool {
        Visibility.cameraRuns(state: cameraState, target: Visibility.Target(shareTarget))
    }

    /// The camera is not in everyone's picture: Off or Only me, whatever else is set
    /// (camera switching included). Not with Just my camera: the picture would be an
    /// empty backdrop, so the camera stays (`Visibility.cameraEveryoneSees` says so).
    /// Every "does everyone see my camera" decision goes through that one rule.
    var cameraIsOff: Bool {
        !Visibility.cameraEveryoneSees(state: cameraState, target: Visibility.Target(shareTarget)).isOn
    }

    /// The owner's own row in People and the view windows (SelfViewRules): struck when the camera is
    /// out of the meeting's picture, or Zoom sends no video at all.
    func ownCameraOff(zoomVideoOn: Bool) -> Bool {
        SelfViewRules.ownRowCameraOff(cameraInPicture: !cameraIsOff, zoomVideoOn: zoomVideoOn)
    }

    /// How the owner's own video is drawn wherever it shows (the Meeting window's "You" tile, the
    /// Self view window): the corner mark while the camera is out of the picture, and the name
    /// while video is stopped (R6.9, R49.7).
    var selfViewLook: SelfViewRules.Look {
        SelfViewRules.look(state: cameraState, cameraInPicture: !cameraIsOff, videoStopped: videoStopped)
    }

    /// The preview's picture is in use by a session - a meeting, or a
    /// recording made from Home's Record mode. The Settings preview then
    /// mirrors that session's picture instead of starting one of its own.
    var sceneInUse: Bool { phase.sceneInUse }

    /// Automatic (no green screen) or a real green screen, for Cutout and
    /// Presenter. Takes effect when the cameras are next opened: at Start, or
    /// straight away in the Settings preview.
    @Published var backgroundRemoval: BackgroundRemoval {
        didSet {
            defaults.set(backgroundRemoval.rawValue, forKey: "backgroundRemoval")
            guard backgroundRemoval != oldValue else { return }
            requestShapeApply()
        }
    }

    /// Blur or a picture behind you, for the bubble shapes (Settings ->
    /// Webcam). Applies live, like the shape.
    @Published var cameraBackground: CameraBackground {
        didSet {
            defaults.set(cameraBackground.rawValue, forKey: "cameraBackground")
            guard cameraBackground != oldValue else { return }
            requestShapeApply()
        }
    }

    /// The picture for `.image`: a preset's name, or `custom-<stamp>`.
    @Published var cameraBackgroundImage: String {
        didSet {
            defaults.set(cameraBackgroundImage, forKey: "cameraBackgroundImage")
            guard cameraBackgroundImage != oldValue else { return }
            requestShapeApply()
        }
    }

    /// Asks for a picture of the user's own and keeps a copy of it.
    func chooseCameraBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose a picture to put behind you"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let key = CameraBackgroundLibrary.importCustom(from: url) else {
            log("Couldn\u{2019}t use \u{201C}\(url.lastPathComponent)\u{201D} as a background. Pick a JPEG or PNG.")
            return
        }
        Collapse.animate { cameraBackground = .image }
        cameraBackgroundImage = key
    }

    /// False while background removal finds nobody in the camera, so the
    /// Webcam page can say why its picture is empty.
    @Published private(set) var cameraSeesYou = true

    /// The camera list a scene build will use, for opening them ahead of it.
    ///
    /// With switching on, the cameras in cut order. With it off, the camera
    /// picked on the Webcam page - the first in the same list, so one choice
    /// serves both - if it is plugged in; otherwise whatever the resolver
    /// likes best, as before there was a choice.
    func sceneCameraUIDs(limit: Int? = nil) -> [String] {
        // Off means none opened. Only me opens it: the bubble mirrors it.
        if !cameraRuns { return [] }
        let listed = sessionCameraUIDs(cameraDirectorSettings)
        let available = Set(LocalDeviceResolver.availableCameras().map(\.id))
        let picked = cameraDirectorSettings.cameraUIDs.first { available.contains($0) }
        let uids = !listed.isEmpty ? listed
            : picked.map { [$0] } ?? LocalDeviceResolver.physicalCameraUID().map { [$0] } ?? []
        return limit.map { Array(uids.prefix($0)) } ?? uids
    }

    /// The microphone the meeting and the recording take. Empty means the
    /// system's input.
    @Published var micDeviceUID: String {
        didSet {
            defaults.set(micDeviceUID, forKey: "micDeviceUID")
            // The meeting can switch microphones mid-class; the recording's
            // source is rebuilt at the next Start, like the other sources.
            if isRunning, zoomChatClient.didInit { applyMeetingMicrophone() }
        }
    }

    /// Points the built-in meeting client at the picked microphone. Only the
    /// built-in client: the separate Zoom app keeps its own audio settings.
    private func applyMeetingMicrophone() {
        let name = LocalDeviceResolver.availableMicrophones().first { $0.id == micDeviceUID }?.name
        if zoomChatClient.selectMicrophone(uid: micDeviceUID, name: name) {
            log("Microphone: \(name ?? "same as the system").")
        } else if !micDeviceUID.isEmpty {
            log("Couldn\u{2019}t switch the meeting to \u{201C}\(name ?? "that microphone")\u{201D} \u{2014} pick it from the meeting\u{2019}s audio menu.")
        }
    }

    /// The camera or microphone picked on the Webcam page changed: reopen the
    /// preview's camera for it. During a class it waits for the next Start,
    /// like everything else that would change a source.
    func previewCamerasChanged() {
        // The Record view applies a camera change at once, like the idle
        // preview: the picture is the thing being set up. With switching on
        // (two or more cameras) the director's own path reopens them.
        if phase.isRecordSessionSettled {
            if sessionCameraUIDs(cameraDirectorSettings).count < 2 {
                stageCameraUIDs = sceneCameraUIDs(limit: 1)
                requestShapeApply()
            }
            return
        }
        guard !phase.isCameraBusy, shapePreviewOn else { return }
        requestShapeApply()
    }

    /// Whether the ACTIVE shape is still where it shipped, so Reset can be
    /// disabled rather than offered as a no-op. Shape-aware: resetting a bubble
    /// you cannot see while looking at a cutout would be a confusing button.
    var bubbleIsAtDefault: Bool {
        let shipped = StageLayout()
        if webcamShape == .cutout {
            return abs(cutoutHeightFraction - shipped.cutoutHeightFraction) < 0.001
                && abs(cutoutRightInset - shipped.cutoutRightInset) < 0.001
        }
        return abs(bubbleWidthFraction - shipped.widthFraction) < 0.001
            && abs(bubbleRightInset - shipped.rightInset) < 0.001
            && abs(bubbleBottomInset - shipped.bottomInset) < 0.001
    }

    /// Back to the values the app shipped with, for the shape on screen.
    func resetBubbleLayout() {
        let shipped = StageLayout()
        if webcamShape == .cutout {
            cutoutHeightFraction = shipped.cutoutHeightFraction
            cutoutRightInset = shipped.cutoutRightInset
            return
        }
        bubbleWidthFraction = shipped.widthFraction
        bubbleRightInset = shipped.rightInset
        bubbleBottomInset = shipped.bottomInset
    }

    /// The camera piece as it is now (the working copy: live changes included).
    var currentLayoutCamera: LayoutCamera { LayoutCamera(shape: webcamShape, box: stageLayout.presenceBox) }

    /// Puts a layout's camera piece and share target into the live settings. The global
    /// defaults keep their own values (they are the fallback with no layout); the live
    /// values are only the working copy.
    /// True while `adoptLayoutPieces` writes the share, so that write is not taken for a choice
    /// the owner made on Home.
    private var adoptingLayoutPieces = false
    /// The owner chose what to share on Home (or the bar) since the layout last set it: it
    /// survives Start, for that meeting only, and Stop or a layout change drops it.
    private var liveShareChosen = false

    /// Settings -> Layouts (a camera drag) edits the saved layout: write the working copy of the
    /// camera piece into the active layout. Home, the bar and the meeting never call this.
    func saveCameraToActiveLayout() {
        var next = layoutLibrary
        if next.updateActive(camera: currentLayoutCamera, share: nil) { layoutLibrary = next }
    }

    func adoptLayoutPieces(_ plan: LayoutPieceAdoption.Plan?) {
        guard let plan else { return }
        let keys = LayoutCamera.defaultsKeys + [LayoutCamera.shareDefaultsKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        if let c = plan.camera {
            webcamShape = c.shape
            bubbleWidthFraction = c.widthFraction
            bubbleRightInset = c.rightInset
            bubbleBottomInset = c.bottomInset
            cutoutHeightFraction = c.cutoutHeightFraction
            cutoutRightInset = c.cutoutRightInset
        }
        if var s = plan.share {
            if s.kind == .app { s.kind = .display }
            adoptingLayoutPieces = true
            if shareTarget != s { shareTarget = s }
            adoptingLayoutPieces = false
            liveShareChosen = false
        }
        for (key, value) in saved { defaults.set(value, forKey: key) }
        refreshCaptureDisplay()
        // The picture (Home's live preview, the bubble) follows the working copy at once.
        if plan.refreshesPicture { requestShapeApply(rebuild: plan.share != nil) }
    }

    @Published var webcamShape: WebcamShape {
        didSet {
            defaults.set(webcamShape.rawValue, forKey: "webcamShape")
            Analytics.setting("webcam_shape", webcamShape.rawValue)
        }
    }
    /// The layout library (Settings -> Layout): named templates, and which one a
    /// class start uses (nil = None). Saved as one JSON blob under `layoutLibrary`.
    ///
    /// Start captures `layoutLibrary.active` as `sessionTemplate`. The old
    /// workspaceLayout / mainApp* / peopleView* keys are no longer written; they are
    /// read once, to build "Your previous layout", and by a settings import.
    /// A deep link to the camera look (the old Webcam tab's id, Home's Look and Share More...) asks
    /// Layouts to select the camera piece and open its look group. The editor clears it once it has.
    @Published var layoutsCameraRequested = false
    @Published var layoutLibrary: LayoutLibrary {
        didSet {
            guard layoutLibrary != oldValue else { return }
            layoutLibrary.save(to: defaults)
            if layoutLibrary.activeID != oldValue.activeID || layoutLibrary.templates.count != oldValue.templates.count {
                Analytics.layoutChanged(layoutLibrary)
            }
            // Only an edit to the layout THIS class is running re-tiles it. Picking
            // another card does not rearrange a class in progress (Settings offers
            // "Apply now" for that), and editing a layout the class is not using
            // touches nothing.
            // The camera and share the layout saves come into the live settings only when
            // the layout itself changes them (a pick, an edit), never from a live change.
            adoptLayoutPieces(LayoutPieceAdoption.forLibraryEdit(old: oldValue, new: layoutLibrary,
                                                                 locked: layoutChoiceLocked, running: sessionTemplate))
            // R32.2: the shared display is not live-edited; only Apply now changes it (`adoptingEdit`).
            // R45: the edit is kept for the next Snap Back; no window moves now.
            if let running = sessionTemplate, let edited = layoutLibrary.template(id: running.id) {
                let adopted = running.adoptingEdit(edited)
                if adopted != running {
                    sessionTemplate = adopted
                    noteLiveLayoutEdit()
                }
            }
            refreshCaptureDisplay()
        }
    }

    /// The layout this class runs, captured at Start. nil when the class
    /// arranges nothing (None) and outside a class. Read by every gate, never the
    /// live choice, so the card picked in Settings mid-class changes nothing.
    @Published private(set) var sessionTemplate: LayoutTemplate?

    /// The Start layout cannot be changed from Home or the menu bar while a class
    /// is live: the class keeps the layout it started with (see sessionTemplate).
    var layoutChoiceLocked: Bool { phase.isInMeeting }

    /// The name the layout lines show: the class's own layout while it is live,
    /// otherwise the Start choice. "None" when nothing is arranged.
    var layoutChoiceName: String {
        (layoutChoiceLocked ? sessionTemplate : layoutLibrary.active)?.name ?? "None"
    }

    /// The class is live and arranged, so another layout can be applied now.
    var liveSessionLayoutID: UUID? { phase.isInMeeting ? sessionTemplate?.id : nil }

    private lazy var layoutEngine = LayoutEngine(chat: zoomChatBridge, log: { [weak self] in self?.log($0) })

    /// The running layout has an edit no Snap Back has placed yet. Only for the log.
    private var liveEditWaitingForSnap = false

    /// A layout edit made mid-meeting (dragging a piece in Settings) moves no
    /// window (R45, owner 2026-11-26: "it should only snap back into place when I
    /// tell it to"). It used to re-tile everything 400ms after the drag, which
    /// raised the meeting windows over Settings and pulled back windows the owner
    /// had moved. The edit is in `sessionTemplate`; Snap Back places it. Said once
    /// per run of edits.
    private func noteLiveLayoutEdit() {
        guard sessionArranges, phase.isInMeeting, !liveEditWaitingForSnap else { return }
        liveEditWaitingForSnap = true
        log("Layout edited. Your windows stay where they are; \(ShortcutStore.phrase(.snapBack)) or Snap Windows Back places the new layout.")
    }

    /// Settings' "Apply now": make this layout the one the live class runs and
    /// place it. Only an arranged class can switch (a class that arranges nothing
    /// has no follow loops, pill or Zoom mode set up for one); the apps the new
    /// layout opens at start are opened.
    func applyLayoutNow(_ id: UUID) {
        guard sessionArranges, sessionTemplate != nil, phase.isInMeeting,
              let template = layoutLibrary.template(id: id) else { return }
        sessionTemplate = template
        speakerTileQuickHidden = layoutEngine.startsHidden(template)
        resetPresenceBubbleToLayoutDefault(at: .layoutSwitch)
        refreshCaptureDisplay()
        log("Applying \u{201C}\(template.name)\u{201D} now\u{2026}")
        reapplyLayout(userInitiated: false, openApps: true, trigger: .switchedLayout)
    }

    /// A "Use layout" shortcut (Settings -> Shortcuts). While an arranged class is
    /// live it is Settings' "Apply now": the live class re-tiles to that layout.
    /// Otherwise it sets the Start layout, like the Layout menu. nil is None, which
    /// a live class cannot switch to (it only sets what the next Start does).
    func useLayout(_ id: UUID?) {
        if phase.isInMeeting {
            guard let id, layoutLibrary.template(id: id) != nil else {
                layoutLibrary.select(nil)
                log("A live class keeps its layout. The next Start will arrange nothing.")
                return
            }
            guard sessionArranges, sessionTemplate != nil else {
                layoutLibrary.select(id)
                log("This class arranges no windows, so the layout is set for the next Start.")
                return
            }
            applyLayoutNow(id)
        } else {
            layoutLibrary.select(id)
            let name = id.flatMap { layoutLibrary.template(id: $0)?.name }
            ToastController.show(name.map { "Layout: \($0)" } ?? "Layout: None", kind: .success)
        }
    }

    /// Built-in browser only: whether Start brings back the tabs that were
    /// open when Greenroom last quit, alongside the configured page.
    @Published var browserRestoresTabs: Bool {
        didSet {
            defaults.set(browserRestoresTabs, forKey: "browserRestoresTabs")
            BrowserWindowController.restoresTabs = browserRestoresTabs
            Analytics.setting("browser_restore_tabs", on: browserRestoresTabs)
        }
    }
    /// Built-in browser only: whether the address bar asks Google for
    /// completions as you type. The one network call the browser makes on
    /// its own account, so it is a switch.
    @Published var browserSearchSuggestions: Bool {
        didSet {
            defaults.set(browserSearchSuggestions, forKey: "browserSearchSuggestions")
            BrowserWindowController.searchSuggestions = browserSearchSuggestions
            Analytics.setting("browser_search_suggestions", on: browserSearchSuggestions)
        }
    }
    // MARK: Cues - see App/Cues/. Off by default. Listens to the
    // teacher's microphone during a class, on this Mac, and offers link cards;
    // the only thing that leaves is the search phrase, and each one is logged.
    @Published var cuesEnabled: Bool {
        didSet {
            defaults.set(cuesEnabled, forKey: "prompterEnabled")
            Analytics.setting("prompter", on: cuesEnabled)
        }
    }
    /// Whether video mentions may use the YouTube Data API (when a Google
    /// account is connected). Off means every video card is a search link.
    @Published var cuesVideoSearch: Bool {
        didSet {
            defaults.set(cuesVideoSearch, forKey: "prompterVideoSearch")
            Analytics.setting("prompter_video_search", on: cuesVideoSearch)
        }
    }
    /// Whether Apple's on-device model finds mentions instead of the word
    /// patterns. Off by default: it finds more and interrupts more - measured
    /// at 264 lookups a class against the patterns' 16.
    @Published var cuesUseModel: Bool {
        didSet {
            defaults.set(cuesUseModel, forKey: "prompterUseModel")
            Analytics.setting("prompter_model_detector", on: cuesUseModel)
        }
    }
    /// Whether the class transcript is written to the session folder beside
    /// the recording. On by default: a teacher who turned Cues on wants
    /// the record of what was said. Off keeps it in memory only.
    @Published var cuesSaveTranscript: Bool {
        didSet {
            defaults.set(cuesSaveTranscript, forKey: "prompterSaveTranscript")
            Analytics.setting("prompter_save_transcript", on: cuesSaveTranscript)
        }
    }
    /// Transcription language, as a locale identifier. Empty = the system's.
    /// Listen through whisper instead of Apple's recogniser.
    ///
    /// Off by default: Apple's is faster and needs nothing installed, and it
    /// is what every measurement in the bench and the plan was taken against.
    /// whisper hears names properly - which is the difference between a card
    /// and no card for a book title - and costs about a second more before a
    /// word is settled. Which matters more is a judgement about the class.
    @Published var cuesUseWhisper: Bool {
        didSet {
            defaults.set(cuesUseWhisper, forKey: "cuesUseWhisper")
            Analytics.setting("cues_whisper", on: cuesUseWhisper)
        }
    }

    @Published var cuesLocaleIdentifier: String {
        didSet { defaults.set(cuesLocaleIdentifier, forKey: "prompterLocaleIdentifier") }
    }
    /// Mirrors for the macOS 14+ UI (menu bar, main window): the engine
    /// itself is macOS 26-only and lives behind `cuesEngine`.
    @Published var cuesListening = false
    @Published var cuesPaused = false
    /// Links Cues has offered this class. Mirrored for the 14+ menu bar, which
    /// cannot see the engine type.
    @Published var cuesLinkCount = 0
    /// True while the participants panel is the surface (the menu-bar label
    /// carries the waveform then); false when the status item is.
    @Published var cuesOnRail = false
    /// The CuesController, held untyped so this class compiles on macOS
    /// 14. See CoordinatorController+Cues.swift.
    var cuesEngine: AnyObject?
    var cuesTickTask: Task<Void, Never>?
    let cuesMenuBar = CuesMenuBar()
    var cuesSurfaceReported = false

    // MARK: YouTube upload - see CoordinatorController+YouTube.swift. Off by
    // default; the one place class content can leave the Mac.
    @Published var youtubeUploadMode: YouTubeUploadMode {
        didSet {
            defaults.set(youtubeUploadMode.rawValue, forKey: "youtubeUploadMode")
            Analytics.setting("youtube_upload", youtubeUploadMode.rawValue)
        }
    }
    /// "unlisted" (anyone with the link) or "private" (the channel's account only).
    @Published var youtubePrivacy: String {
        didSet {
            defaults.set(youtubePrivacy, forKey: "youtubePrivacy")
            Analytics.setting("youtube_privacy", youtubePrivacy)
        }
    }
    @Published var youtubeClientID: String {
        didSet { defaults.set(youtubeClientID, forKey: "youtubeClientID") }
    }
    @Published var youtubeClientSecret: String {
        didSet {
            guard !isRestoringSecret else { return }
            SecretStore.set(youtubeClientSecret, forKey: "youtubeClientSecret")
        }
    }
    /// Settings -> YouTube's choice, "Your own Google app" (true) or
    /// "Greenroom's Google app" (false): what signing in and uploading use
    /// (YouTubeRouteRules, YouTubeAccountRules).
    @Published var youtubeUsesOwnApp: Bool {
        didSet { defaults.set(youtubeUsesOwnApp, forKey: "youtubeUsesOwnApp") }
    }
    /// The Made for Kids answer, nil until the person first gives one (the
    /// upload sheet preselects it; automatic uploads need it).
    @Published var youtubeMadeForKids: Bool? {
        didSet {
            if let youtubeMadeForKids { defaults.set(youtubeMadeForKids, forKey: "youtubeMadeForKids") }
            else { defaults.removeObject(forKey: "youtubeMadeForKids") }
        }
    }
    /// The signed-in account's channel, for "Signed in as".
    @Published var youtubeChannel: YouTubeChannel? {
        didSet { defaults.set(youtubeChannel.flatMap { try? JSONEncoder().encode($0) }, forKey: "youtubeChannel") }
    }
    /// The upload sheet, when it is up (main window).
    @Published var youtubeUploadDraft: YouTubeUploadDraft?
    /// The last upload that failed, with its plain words and buttons.
    @Published var youtubeFailure: YouTubeUploadFailure?
    @Published var youtubeSigningIn = false
    @Published var youtubeConnected = YouTubeAuth.isConnected
    @Published var isUploadingToYouTube = false
    /// 0...1 while an upload runs, for the menu bar; nil otherwise.
    @Published var youtubeUploadProgress: Double?
    /// The last connect / disconnect outcome, shown under the button.
    @Published var youtubeStatus = ""
    /// Whether anonymous usage analytics are sent. On by default, and the switch
    /// is honoured immediately as well as on the next launch.
    @Published var analyticsEnabled: Bool {
        didSet {
            defaults.set(analyticsEnabled, forKey: "analyticsEnabled")
            Analytics.setEnabled(analyticsEnabled)
        }
    }
    /// Which display the screen capture shares. Empty means "the main one",
    /// which is what almost everyone wants and what this always did. Stored by
    /// display UUID so the choice survives unplugging and reconnecting.
    @Published var screenCaptureDisplayUUID: String {
        didSet { defaults.set(screenCaptureDisplayUUID, forKey: "screenCaptureDisplayUUID") }
    }

    /// The whole display, one app or one window. Changes apply live: the
    /// compositor starts the new share beside the old one and swaps when its
    /// first frame arrives.
    /// What was shared before Share \u{2192} Whiteboard was chosen, for "Back to screen".
    private var targetBeforeWhiteboard: ShareTarget?

    @Published var shareTarget: ShareTarget {
        didSet {
            if !adoptingLayoutPieces, shareTarget != oldValue { liveShareChosen = true }
            if let data = try? JSONEncoder().encode(shareTarget) {
                defaults.set(data, forKey: LayoutCamera.shareDefaultsKey)
            }
            targetBeforeWhiteboard = WhiteboardOpenRules.remembered(
                targetBeforeWhiteboard, replaced: oldValue,
                oldIsWhiteboard: oldValue.kind == .whiteboard, newIsWhiteboard: shareTarget.kind == .whiteboard)
        }
    }

    /// Recording starts by itself once the meeting is up (the Record
    /// button and \u{2325}\u{2318}R stay available as the manual
    /// trigger either way).
    @Published var autoRecordOnStart: Bool {
        didSet {
            defaults.set(autoRecordOnStart, forKey: "autoRecordOnStart")
            Analytics.setting("auto_record", on: autoRecordOnStart)
        }
    }
    /// Seconds counted down, on screen, before a recording a person starts
    /// begins: 0 (off), 3, 5 or 10. Not used when a meeting starts the
    /// recording by itself (auto-record).
    @Published var recordingCountdownSeconds: Int {
        didSet { defaults.set(recordingCountdownSeconds, forKey: "recordingCountdownSeconds") }
    }
    /// Also record the Mac's own sound (what is playing from the shared
    /// screen or app), mixed with the microphone into the one audio track.
    /// Off by default. Greenroom's and the meeting's own sound is left out.
    @Published var recordSystemAudio: Bool {
        didSet {
            defaults.set(recordSystemAudio, forKey: "recordSystemAudio")
            Analytics.setting("record_system_audio", on: recordSystemAudio)
            recorder?.recordsSystemAudio = recordSystemAudio
            // The sound comes through the screen capture, which is built with
            // or without it, so a running picture rebuilds its capture.
            if sceneInUse, let stage { stage.update(makeStageConfiguration()) }
        }
    }
    /// The app whose slide show the screen capture has moved to, while it has
    /// (phase 6); drives the quiet "Following Keynote's slide show" line.
    @Published private(set) var followingSlideShowApp: String?
    private let defaults = UserDefaults.standard

    init() {
        defer {
            Self.shared = self
            installStopVideoHooks()
            observeDisplays()
            startPresenceBubble()
            adoptLayoutPieces(LayoutPieceAdoption.atStart(layoutLibrary.active))
        }
        webcamShape = WebcamShape(rawValue: defaults.string(forKey: "webcamShape") ?? "") ?? .circle
        backgroundRemoval = BackgroundRemoval(rawValue: defaults.string(forKey: "backgroundRemoval") ?? "") ?? .automatic
        cameraBackground = CameraBackground(rawValue: defaults.string(forKey: "cameraBackground") ?? "") ?? .normal
        cameraBackgroundImage = defaults.string(forKey: "cameraBackgroundImage") ?? CameraBackgroundPreset.defaultChoice
        micDeviceUID = defaults.string(forKey: "micDeviceUID") ?? ""
        // First launch with this key migrates today's settings into "Your previous
        // layout" (see LayoutLibrary.loadOrMigrate); the old keys stay as they were.
        var library = LayoutLibrary.loadOrMigrate(from: defaults, defaultSiteURL: AppLinks.site)
        // P3, once each: today's global camera and share go into every layout.
        // The keys are set only after the save worked (R16.1); a failure is logged by `save` and retried next launch.
        library.migrateCameraAndShare(camera: .global(from: defaults), share: LayoutCamera.globalShare(from: defaults),
                                      defaults: defaults, save: { [store = defaults] in $0.save(to: store) })
        layoutLibrary = library
        let bubbleDefaults = StageLayout()
        bubbleWidthFraction = (defaults.object(forKey: "bubbleWidthFraction") as? Double) ?? bubbleDefaults.widthFraction
        bubbleRightInset = (defaults.object(forKey: "bubbleRightInset") as? Double) ?? bubbleDefaults.rightInset
        bubbleBottomInset = (defaults.object(forKey: "bubbleBottomInset") as? Double) ?? bubbleDefaults.bottomInset
        className = defaults.string(forKey: "className") ?? ""
        // Defaults ON: the shortcuts are useless without it, and bool(forKey:)
        // alone cannot tell "never set" from "deliberately off".
        clipBufferEnabled = (defaults.object(forKey: "clipBufferEnabled") as? Bool) ?? true
        recordingCountdownSeconds = (defaults.object(forKey: "recordingCountdownSeconds") as? Int) ?? 3
        recordSystemAudio = defaults.bool(forKey: "recordSystemAudio")
        cutoutHeightFraction = (defaults.object(forKey: "cutoutHeightFraction") as? Double) ?? bubbleDefaults.cutoutHeightFraction
        cutoutRightInset = (defaults.object(forKey: "cutoutRightInset") as? Double) ?? bubbleDefaults.cutoutRightInset
        // ON by default: the point of the built-in browser is that the
        // morning's tabs are where they were left. didSet does not run in
        // init, so the controller's flag is set by hand here.
        let restoresTabs = (defaults.object(forKey: "browserRestoresTabs") as? Bool) ?? true
        browserRestoresTabs = restoresTabs
        BrowserWindowController.restoresTabs = restoresTabs
        let searchSuggestions = (defaults.object(forKey: "browserSearchSuggestions") as? Bool) ?? true
        browserSearchSuggestions = searchSuggestions
        BrowserWindowController.searchSuggestions = searchSuggestions
        cuesEnabled = defaults.bool(forKey: "prompterEnabled")
        cuesVideoSearch = (defaults.object(forKey: "prompterVideoSearch") as? Bool) ?? true
        cuesUseModel = defaults.bool(forKey: "prompterUseModel")
        cuesSaveTranscript = (defaults.object(forKey: "prompterSaveTranscript") as? Bool) ?? true
        cuesUseWhisper = defaults.bool(forKey: "cuesUseWhisper")
        cuesLocaleIdentifier = defaults.string(forKey: "prompterLocaleIdentifier") ?? ""
        youtubeUploadMode = YouTubeUploadMode(rawValue: defaults.string(forKey: "youtubeUploadMode") ?? "") ?? .off
        youtubePrivacy = defaults.string(forKey: "youtubePrivacy") ?? "unlisted"
        youtubeClientID = defaults.string(forKey: "youtubeClientID") ?? ""
        youtubeClientSecret = "" // loaded lazily via loadSecretsIfNeeded()
        youtubeUsesOwnApp = YouTubeRouteRules.initialPrefersOwnApp(
            saved: defaults.object(forKey: "youtubeUsesOwnApp") as? Bool,
            ownClientComplete: !(defaults.string(forKey: "youtubeClientID") ?? "").isEmpty
                && !(SecretStore.get("youtubeClientSecret") ?? "").isEmpty)
        youtubeMadeForKids = defaults.object(forKey: "youtubeMadeForKids") as? Bool
        youtubeChannel = defaults.data(forKey: "youtubeChannel").flatMap { try? JSONDecoder().decode(YouTubeChannel.self, from: $0) }
        // Absent means never answered, which is opted IN - matching the consent
        // the Apptics setup already carries. An explicit false stays false.
        analyticsEnabled = (defaults.object(forKey: "analyticsEnabled") as? Bool) ?? true
        screenCaptureDisplayUUID = defaults.string(forKey: "screenCaptureDisplayUUID") ?? ""
        // One app is no longer offered: a saved one shares the whole screen.
        var savedShare = defaults.data(forKey: "shareTarget")
            .flatMap { try? JSONDecoder().decode(ShareTarget.self, from: $0) } ?? ShareTarget()
        if savedShare.kind == .app { savedShare.kind = .display }
        shareTarget = savedShare
        // On unless the teacher turned it off; Macs that stored the old default
        // (off) are flipped once, so the new default actually reaches them.
        autoRecordOnStart = defaults.bool(forKey: "autoRecordOnStart")
        meetingMode = MeetingMode(rawValue: defaults.string(forKey: "meetingMode") ?? "") ?? .create
        meetingPresets = Self.loadPresets(from: defaults)
        showOnboarding = !defaults.bool(forKey: "hasCompletedOnboarding")
        sdkClientID = defaults.string(forKey: "zoomSDKClientID") ?? ""
        sdkClientSecret = "" // loaded lazily via loadSecretsIfNeeded() - never at launch
        s2sAccountID = defaults.string(forKey: "zoomS2SAccountID") ?? ""
        s2sClientID = defaults.string(forKey: "zoomS2SClientID") ?? ""
        s2sClientSecret = "" // loaded lazily via loadSecretsIfNeeded() - never at launch
        // The choice between the two ways is explicit; with none saved (a fresh
        // install, or the first launch after it became explicit), pick and save one.
        // Read from storage: this runs before init finishes (the secrets load lazily later).
        let savedChoice = defaults.object(forKey: Self.zoomPrefersSignInKey) as? Bool
        let store = defaults
        let storedOwnAppsComplete = ["zoomSDKClientID", "zoomS2SAccountID", "zoomS2SClientID"]
            .allSatisfy { !(store.string(forKey: $0) ?? "").isEmpty }
            && !(SecretStore.get("zoomSDKClientSecret") ?? "").isEmpty
            && !(SecretStore.get("zoomS2SClientSecret") ?? "").isEmpty
        let initialChoice = ZoomRouteChoiceRules.initialPrefersSignIn(
            saved: savedChoice, signedIn: zoomUser.isSignedIn, ownAppsComplete: storedOwnAppsComplete)
        zoomPrefersSignIn = initialChoice
        if savedChoice == nil { defaults.set(initialChoice, forKey: Self.zoomPrefersSignInKey) }
        userDisplayName = defaults.string(forKey: "userDisplayName") ?? NSFullUserName()
        // Default OFF (show self): the teacher's own tile belongs in the
        // extended display's participant grid alongside the students
        // (explicit request); the speaker tile stays clean regardless
        // because spotlight-my-video and the thumbnail strip are disabled.
        hideSelfView = (defaults.object(forKey: "hideSelfView") as? Bool) ?? false
        let shownOnMyScreen = (defaults.object(forKey: "cameraShownOnMyScreen") as? Bool) ?? true
        cameraShownOnMyScreen = shownOnMyScreen
        presenceBubbleHidden = PresenceVisibility.bubbleStartsHidden(shownOnMyScreen: shownOnMyScreen)   // init: no method calls yet
        cameraSession = CameraStateSession(saved: CameraState(noCamera: CameraDirectorSettings.load().noCamera, shownOnMyScreen: shownOnMyScreen))
        speakerTileShortcutEnabled = (defaults.object(forKey: "speakerTileShortcutEnabled") as? Bool) ?? true
        // didSet doesn't fire during init, and the SDK isn't up yet anyway
        // - sync just the stored preference; connect-time reads it.
        zoomChatClient.hideSelfViewPreference = hideSelfView

        // The chat window's lifetime is tied to the meeting's: when the SDK
        // reports the meeting over (host ended it, connection dropped, or
        // our own leave()), the window closes itself instead of lingering
        // with a dead session's messages.
        zoomChatClient.$isJoined
            .dropFirst()
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in
                Task { @MainActor in self?.chatSessionDidEnd() }
            }
            .store(in: &cancellables)

        cameraDirector.$slotSights
            .sink { [weak self] sights in
                Task { @MainActor in self?.feedAim(from: sights) }
            }
            .store(in: &cancellables)

        // Sign in with Zoom changes (signing in, signed in, out) redraw whatever shows the coordinator.
        zoomUser.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // So does "Check Zoom setup" (the setup guide reads it through the coordinator).
        zoomSetupChecker.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Countdown, control bar and border follow the recording's state. The
        // values come from the publishers (they fire before the property
        // changes), so they are handed on rather than re-read.
        Publishers.CombineLatest4($isRecording, $isRecordingPaused, $recordOnlyActive, $recordingCountdown)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recording, paused, recordOnly, countdown in
                guard let self else { return }
                self.recordingChrome.update(coordinator: self, recording: recording, paused: paused,
                                            recordOnly: recordOnly, countdownValue: countdown)
            }
            .store(in: &cancellables)

        // The main window steps aside while a class or recording is live. Read
        // one hop later, so the values are the new ones.
        objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileMainWindow() }
            .store(in: &cancellables)
        // Anything that brings the main window forward while it is hidden for a
        // session (a SwiftUI openWindow, a hotkey) is the person opening it on purpose.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self, MainWindow.matches(window) else { return }
                    self.mainWindowOpenedOnPurpose()
                }
            }
            .store(in: &cancellables)

        cameraDirector.log = { [weak self] line in self?.log(line) }
        wireDrawing()
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: The main window steps aside while live

    private var mainWindowVisibility = MainWindowVisibility()
    private var rememberedMainFrame: NSRect?

    /// True once a session is actually live: a meeting joined with the readiness
    /// card done, or a Record take running. nil while it is being torn down, so
    /// the window comes back when the teardown ends, not when it begins.
    private var mainWindowLiveSignal: Bool? {
        if isStopping { return nil }
        if recordOnlyActive { return isRecording }
        return phase.isMeetingFullyLive && startReadiness.failure == nil && startReadiness.steps.isEmpty
    }

    /// Applies the state machine to the current session state. True when it
    /// brought the main window forward itself.
    @discardableResult
    private func reconcileMainWindow() -> Bool {
        guard let live = mainWindowLiveSignal else { return false }
        return applyMainWindow(mainWindowVisibility.handle(.liveChanged(live)))
    }

    /// A start failed at some step: the main window must be visible.
    private func mainWindowStartFailed() {
        applyMainWindow(mainWindowVisibility.handle(.startFailed))
    }

    /// The person asked for the main window (Sessions, Last, Open Greenroom
    /// Window). It stays until the next session starts.
    func mainWindowOpenedOnPurpose() {
        _ = mainWindowVisibility.handle(.openedOnPurpose)
    }

    /// True when the main window is hidden because a session is live.
    var mainWindowHiddenForSession: Bool { mainWindowVisibility.hiddenByUs }

    @discardableResult
    private func applyMainWindow(_ actions: [MainWindowVisibility.Action]) -> Bool {
        var showed = false
        for action in actions {
            switch action {
            case .rememberFrame:
                rememberedMainFrame = MainWindow.current?.frame
            case .hide:
                MainWindow.current?.orderOut(nil)
            case .hideForStart:
                if let window = MainWindow.current {
                    MainWindowTransition.hide(window, toward: startSurfaceFrame)
                }
            case .showAfterStart:
                if let window = MainWindow.current {
                    var frame = window.frame
                    if let remembered = rememberedMainFrame,
                       NSScreen.screens.contains(where: { $0.visibleFrame.intersects(remembered) }) {
                        frame = remembered
                    }
                    MainWindowTransition.show(window, from: startSurfaceFrame, to: frame)
                    showed = true
                }
            case .restoreFrame:
                if let window = MainWindow.current, let frame = rememberedMainFrame,
                   NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }),
                   window.frame != frame, !window.styleMask.contains(.fullScreen) {
                    window.setFrame(frame, display: false)
                }
            case .goHome:
                mainPage = .home
            case .show:
                // orderFront, not activate: a full-screen app keeps the focus.
                MainWindow.current?.orderFront(nil)
                showed = true
            }
        }
        return showed
    }

    private func chatSessionDidEnd() {
        MeetingSurfaceOwner.reset()
        MeetingControlBarController.close()
        if !sessionArranges { closeMeetingWindow() }
        meetingControls?.stop()
        meetingControls = nil
        PeoplePopOutController.close()
        if ChatWindowController.isOpen {
            ChatWindowController.close()
        }
        // Unconditional: an on-demand chat the teacher closed by hand still
        // holds the meeting's messages.
        zoomChatBridge.reset()
        // The meeting is over no matter WHERE it was ended - Zoom's own
        // End button inside the meeting tile included - so wind the whole
        // session down. Without this, ending from the tile closed the
        // chat but left the camera and recording running invisibly,
        // making End-in-the-tile and End Session confusingly different.
        // (When stop() itself triggered this observer, isStopping blocks
        // the re-entry.)
        guard !isStopping else { return }
        // Still starting: the start sees Zoom's status itself and fails with words,
        // rather than this winding it down as a silent cancel.
        if StartChoreography.meetingEnded(startInFlight: startBarText != nil) == .startReportsIt {
            log("Zoom ended the meeting while it was starting.")
            return
        }
        if phase.isInMeeting {
            log("Meeting over \u{2014} ending the session.")
            // Zoom ended it, not the owner (End and Leave set isStopping; quit and
            // both of those call leave() first): say why on the island, then wind
            // down as before. Zoom's Ended, with its reason, can land a moment
            // after the Disconnecting that dropped isJoined, so it is waited for.
            if !zoomChatClient.leaveRequested { tellWhyZoomEndedIt() }
            stop()
        } else {
            log("Meeting over \u{2014} chat window closed.")
        }
    }

    /// The island's one line for a meeting Zoom ended (MeetingEndWords), once
    /// Zoom's own end status has come (up to 2 s; without it, "reason 0").
    private func tellWhyZoomEndedIt() {
        Task { @MainActor [weak self] in
            var end: MeetingEnd?
            for _ in 0..<20 {
                guard let self else { return }
                if let seen = self.zoomChatClient.lastEnd { end = seen; break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let self else { return }
            // The owner's own leave() during the wind-down does not make it theirs.
            var said = end ?? MeetingEnd(failed: false, error: 0, reason: 0, byOwner: false)
            said.byOwner = false
            guard let line = MeetingEndWords.line(for: said) else { return }
            self.log("\(line) (status \(said.failed ? "Failed" : "Ended"), error \(said.error), end reason \(said.reason)).")
            ToastController.show(line, kind: .info)
        }
    }

    // MARK: The stage (the class picture, made in-process)

    /// The one compositor: the picture the meeting sees, the recorder films and
    /// Settings previews. Made when something needs it, dropped (and its
    /// cameras let go) when nothing does.
    var stage: StageCompositor?
    /// The camera as a floating bubble on the shared display (CoordinatorController+Presence.swift).
    let presenceBubble = PresenceBubble()
    /// "Hide my bubble" in the control bar and the Meeting window: the floating
    /// camera bubble leaves the presenter's own screen only. The class and the
    /// recording still see the camera at its last placement. Back to false when
    /// the stage is torn down (the meeting or recording ends).
    @Published var presenceBubbleHidden = false

    /// The camera state goes back to the saved default at Start, Snap Back and the end of the picture
    /// (R6.3). A layout switch mid-meeting keeps it: the camera state is not part of a layout
    /// (`CameraStateSession.dropsLiveChange`).
    func resetPresenceBubbleToLayoutDefault(at moment: CameraStateSession.Moment) {
        let hadLiveChange = cameraSession.reset(at: moment)
        // Stop video is not part of the camera state: only Start and the end clear it (R49).
        let stopped = StopVideoRules.videoStopped(after: moment, was: videoStopped)
        if stopped != videoStopped { videoStopped = stopped }
        presenceBubbleHidden = PresenceVisibility.bubbleStartsHidden(state: cameraState)
        // A live "Off" or "Only me" put the picture back to the default along with it.
        if hadLiveChange, stage != nil { applyCameraStateLive() }
    }

    /// Home's camera and Just me controls: camera on again (not "No camera"), then re-preview.
    /// Same write as Settings > Webcam's camera cards.
    /// This meeting only: the saved default (Settings -> Layouts) is not written (R6.2).
    /// From Off it brings back the last "on" state, like the bar's camera button (R6.6).
    func turnCameraOnFromHome() {
        guard let target = cameraSession.turnOnTarget else { return }
        setLiveCameraState(target)
    }

    /// The bar's and the Meeting toolbar's camera button: Off <-> the last on state, this meeting only.
    func toggleLiveCameraState() {
        setLiveCameraState(cameraSession.clickTarget(
            noCameraAllowed: CameraPanelRules.noCameraEnabled(shareIsNothing: shareTarget.sharesNothing)))
    }
    var presenceTimer: Timer?
    /// A refresh is queued (bursts of changes make one); the timer's tick count; whether the stage has the self-view handler.
    var presenceRefreshPending = false
    var presenceTicks = 0
    var presenceFeedInstalled = false
    var presenceCancellables = Set<AnyCancellable>()
    /// Films the stage. Made with a session; nil outside one.
    private var recorder: SessionRecorder?
    /// Clicks and keys of the running recording; see `wireInputEvents`.
    private let inputEvents = InputEventTracker()
    /// The cameras the stage holds right now, while a session runs. Nil means
    /// "the first camera only", which is what Start and the idle preview open.
    private var stageCameraUIDs: [String]?
    private var stageObservers = Set<AnyCancellable>()
    private var lastReportedStageError: String?
    private var permissionWatcher: Task<Void, Never>?

    /// The display the picture is taken from. A layout's two-display version says which
    /// display everyone sees ("Everyone sees" in Settings -> Layouts) and that wins over
    /// the Screen choice for a whole-screen share while that version is in use; with no
    /// second display connected, a one-display layout or None, the Screen choice stands.
    /// Recordings film the same picture.
    var effectiveCaptureDisplayUUID: String {
        let template = layoutChoiceLocked ? sessionTemplate : layoutLibrary.active
        let layout = LayoutSharedDisplay.uuid(template: template, screens: LayoutEngine.connectedScreens())
        return LayoutSharedDisplay.resolved(wholeScreen: shareTarget.kind == .display || shareTarget.kind == .app,
                                            layout: layout, chosen: screenCaptureDisplayUUID)
    }

    /// Tells a running picture when the layout (or the displays) changed which display it films.
    private func refreshCaptureDisplay() {
        if sceneInUse, let stage { stage.update(makeStageConfiguration()) }
    }

    /// Everything the compositor is told, from the same settings the Layout
    /// and Webcam pages edit.
    func makeStageConfiguration() -> StageConfiguration {
        StageConfiguration(layout: stageLayout,
                           share: shareTarget,
                           displayUUID: effectiveCaptureDisplayUUID,
                           backgroundRemoval: backgroundRemoval,
                           cameraBackground: cameraBackground,
                           cameraBackgroundImage: cameraBackgroundImage,
                           // nil is the idle preview: every chosen camera when
                           // switching is on (the director cuts between them),
                           // otherwise the one.
                           cameraUIDs: stageCameraUIDs
                               ?? sceneCameraUIDs(limit: phase.isCameraBusy ? 1 : nil),
                           captureSystemAudio: recordSystemAudio)
    }

    private func ensureStage() -> StageCompositor? {
        if let stage { return stage }
        guard let made = StageCompositor() else { return nil }
        stage = made
        pushWhiteboardPage(to: made)
        stageObservers.removeAll()
        made.status.$personInView.removeDuplicates()
            .sink { [weak self] in self?.cameraSeesYou = $0 }
            .store(in: &stageObservers)
        made.status.$lastError.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] in self?.reportStageError($0) }
            .store(in: &stageObservers)
        made.status.$followingApp.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.followingSlideShowApp = $0 }
            .store(in: &stageObservers)
        made.status.$camerasLive.removeDuplicates()
            .sink { [weak self] in self?.camerasLiveChanged($0) }
            .store(in: &stageObservers)
        made.status.$cameraStandIn.removeDuplicates().dropFirst()
            .sink { [weak self] in
                self?.log($0 ?? "The camera you chose is back.")
            }
            .store(in: &stageObservers)
        return made
    }

    /// Stops the picture and lets every camera and the screen capture go.
    private func stopStage() {
        permissionWatcher?.cancel()
        permissionWatcher = nil
        endDrawingTools()
        cameraDirector.stop()
        RoomScreen.setCompositor(nil)
        guard let stage else { return }
        if previewAttached { stage.removeSink(previewSink); previewAttached = false }
        stage.stop()
        self.stage = nil
        resetPresenceBubbleToLayoutDefault(at: .end)
        presenceFeedInstalled = false
        stageObservers.removeAll()
        stageCameraUIDs = nil
        followingSlideShowApp = nil
        lastReportedStageError = nil
        cameraSeesYou = true
    }

    /// Plain words for whatever the compositor could not do. Shown once per
    /// distinct message, in the status log and, mid-class, as a notification.
    private func reportStageError(_ message: String) {
        guard message != lastReportedStageError else { return }
        lastReportedStageError = message
        log(message)
        if phase.isMeetingFullyLive {
            Notifier.post(title: "Greenroom picture problem", body: message)
        }
    }

    private var lastCameraLive: Bool?
    private func camerasLiveChanged(_ live: [Bool]) {
        guard phase.isSceneFullyLive, let first = live.first else { return }
        defer { lastCameraLive = first }
        guard lastCameraLive != first else { return }
        log(first ? "The camera is sending a picture again."
                  : "The camera stopped sending a picture \u{2014} everyone sees the last one. Check it is plugged in and not in use by another app.")
    }

    /// The Screen Recording pane in System Settings is the only place a
    /// refusal changes. Until it does the picture is the camera alone; this
    /// asks the compositor to try the screen again once it is granted.
    private func watchForScreenPermission() {
        permissionWatcher?.cancel()
        permissionWatcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let stage = self.stage else { return }
                if StageCompositor.screenRecordingGranted {
                    stage.update(self.makeStageConfiguration())
                    self.log("Screen Recording is on \u{2014} the meeting now sees your screen.")
                    self.permissionWatcher = nil
                    return
                }
            }
        }
    }

    /// The whole session in one click, in dependency order:
    ///  1. The picture (screen + camera) up and installed as the meeting's
    ///     video, BEFORE the meeting opens so the first frame the class sees
    ///     is the real picture, not a placeholder
    ///  2. The meeting - created fresh or joined by ID, per `meetingMode`
    ///  3. The main app's window tiled to its slice of the screen
    ///  4. The chat window tiled to the remaining slice
    /// Prerequisites are checked up front so a missing credential fails
    /// fast instead of after the cameras have already opened.
    func start() {
        // Full lifecycle guard, not just the transition: the UI disables
        // the button mid-session, but the global hotkey has no disabled
        // state - without the extra checks it could stack a second
        // meeting onto a live session.
        guard phase.canStart else { return }
        if meetingMode == .record {
            startRecordingFlow()
            return
        }
        loadSecretsIfNeeded()

        // Greenroom's own Zoom client sends the picture, so it is needed for
        // every meeting, created or joined.
        if meetingMode != .record, !zoomSDKReady {
            let why = zoomSDKAuthChoice == .notFinished
                ? ZoomCredentialRules.notFinishedText
                : zoomRouteMissingText
            refuseStart("Can't start yet \u{2014} \(why)")
            return
        }
        // The permission gap belongs to the sign-in; your own Zoom apps don't need it.
        if meetingMode != .record, zoomRoute.usesGreenroomApp, zoomNeedsMorePermission {
            refuseStart("\(zoomAttentionTitle). Settings (\u{2318},) \u{2192} Zoom \u{2192} Sign in again, then press Start.")
            return
        }
        switch meetingMode {
        case .record:
            return
        case .create:
            guard zoomHostingReady else {
                refuseStart("Can't create a meeting yet \u{2014} \(zoomRouteMissingText)")
                return
            }
        case .join:
            guard !meetingNumberDigits.isEmpty else {
                refuseStart("Choose a scheduled meeting first.")
                return
            }
        }

        apply(.meetingStartRequested)
        // The route this start takes, named in the log and under any failure.
        let route = zoomRoute
        startRoute = route
        log(ZoomRouteWords.logLine(route))
        MeetingSurfaceOwner.coordinator = self
        MeetingSurfaceOwner.send(.startBegan)
        // This start's number: its task reports back with it, so a late end
        // of an older, cancelled start cannot clear this one.
        let startID = phase.startID
        statusLines = []
        // The layout this class runs: the card chosen in Settings right now, held for
        // the whole class. None (nil) arranges nothing.
        sessionTemplate = layoutLibrary.active
        // At Start the layout's camera and What's shared apply; no layout keeps the globals.
        adoptLayoutPieces(LayoutPieceAdoption.atStart(sessionTemplate, keepingLiveShare: liveShareChosen))
        // R6.3: the camera state a live change set before Start is dropped; the saved default stands.
        resetPresenceBubbleToLayoutDefault(at: .start)
        // Leave my windows alone places the camera only: it arranges nothing, as None did.
        sessionArranges = sessionTemplate?.movesWindows ?? false
        if !sessionArranges { LayoutShareChoice.reset() }
        speakerTileQuickHidden = sessionTemplate.map { layoutEngine.startsHidden($0) } ?? false
        // The Meeting window opens at Start only where the layout places a Meeting
        // piece; otherwise the Bar is the surface (MeetingSurface.wentLive).
        meetingWindowWanted = layoutPlacesMeeting
        MeetingViewWindows.reset()
        MeetingViewWindows.layoutActive = sessionArranges
        if let template = sessionTemplate, !layoutEngine.viewPieces(template).isEmpty {
            let names = layoutEngine.viewPieces(template).compactMap { $0.piece.kind.view?.title }.joined(separator: ", ")
            log("Layout has view windows: \(names).")
        }
        let startedAt = Date()
        sessionStartedAt = startedAt
        // Named now, created later - see sessionFolder. Unique, so two
        // starts inside one minute cannot land in each other's folder; the
        // stamp only goes to the minute.
        sessionFolder = SessionFolders.uniqueSessionFolder(
            named: SessionFolders.sessionFolderName(className: className, started: startedAt),
            in: SessionFolders.recordingsDirectory)
        // Shape only. No meeting number, no preset name - see Analytics.swift.
        Analytics.track(.sessionStart, [
            .mode: meetingMode == .join ? "join" : "start",
            .displays: String(NSScreen.screens.count),
            .mainApp: sessionTemplate.flatMap { template in
                layoutEngine.resolve(template).apps.first?.piece.kind.app.map { Analytics.mainAppKind(bundleID: $0.bundleID) }
            } ?? "none",
            .layoutTemplates: String(layoutLibrary.templates.count),
            .layoutPieces: Analytics.layoutPieceKinds(sessionTemplate)
        ])

        beginStartChoreography()
        resetStartReadiness()
        startPlacementFinished = false
        // Before anything else, so the reference display has something on it
        // from the first frame rather than after the meeting connects.
        // (Only the reference-display panel opens this early: the meeting window
        // needs a meeting, and a single-display class has the floating card.)
        // No longer: the Meeting window waits for the meeting to be live (the island
        // carries the start), so a failed start has no window to leave behind.
        if StartChoreography.opensMeetingWindowWhileStarting(layoutFillsADisplay: sessionArranges && peopleViewWanted) {
            startCustomUIGridFollow()
        }

        startTask = Task {
            do {
                // No island to wait for: the Control bar is already up (it is the
                // surface while starting), so the work begins at once.
                // Perceived speed: the main app doesn't depend on
                // anything else - open it first so something visibly
                // happens the instant Start is pressed.
                let opensApps = sessionTemplate.map { template in
                    layoutEngine.resolve(template).apps.contains { $0.piece.kind.app?.opensAtStart == true }
                } ?? false
                startOpenedApps = opensApps
                mark(.workspace, opensApps ? .active : .skipped)
                if opensApps, let template = sessionTemplate {
                    layoutEngine.openApps(template, hidden: speakerTileQuickHidden)
                    mark(.workspace, .done)
                }

                // Overlap everything that doesn't need the picture with the
                // picture coming up: the REST meeting creation and the Zoom
                // SDK auth are pure network/SDK time. The one true dependency
                // in the whole start is "first frame ready before the
                // meeting client starts", enforced by awaiting the
                // pipeline before the meeting flows below.
                mark(.camera, .active)
                async let pipelineDone: Void = runPipeline()
                async let preparedMeeting = prepareMeetingIfNeeded()
                async let sdkPrefetched: Void = prefetchSDKAuth()

                try await pipelineDone
                mark(.camera, .done)
                // Everything this session writes goes in the session's own
                // folder - the recording, and the clip-buffer saves that
                // become clips. Done here rather than only before the tape
                // rolls, because a clip taken without recording is written
                // too and would otherwise land in the recordings root.
                pointOutputsAtSessionFolder()
                // Armed as soon as the picture exists, so the shortcuts work
                // from the first minute of the class rather than from whenever
                // somebody remembers to press Record.
                armClipBuffer()
                await sdkPrefetched
                // Checkpoints between the big phases let Stop abandon a
                // start cleanly (its teardown otherwise races the
                // meeting setup still running here). The steps themselves
                // aren't cancellation-aware; between-steps is enough.
                try Task.checkCancellation()

                // Instant start: the REST create has been running beside the
                // picture; wait for it under its own island step. A scheduled
                // start marks Creating meeting and Meeting inside joinAllInOne.
                if meetingMode == .create { mark(.creating, .active) }
                switch meetingMode {
                case .create:
                    // The SDK IS the meeting client: one participant (you),
                    // hosting directly, sending Greenroom's own picture, chat
                    // sent as you.
                    guard let meeting = try await preparedMeeting else {
                        throw NSError(domain: "Greenroom", code: 30, userInfo: [
                            NSLocalizedDescriptionKey: "Internal: the meeting wasn't prepared."
                        ])
                    }
                    mark(.creating, .done)
                    mark(.meeting, .active)
                    try await hostAllInOne(meeting: meeting)
                case .join:
                    try await joinAllInOne()
                case .record:
                    break // routed to startRecordingFlow before any of this
                }

                try Task.checkCancellation()
                // Done only on Zoom's word: InMeeting, and still in it. A meeting Zoom
                // ended while the last steps ran is this start's failure, in words.
                if case .failed(let reason) = StartChoreography.islandEnd(.live(inMeeting: zoomChatClient.isJoined)) {
                    throw NSError(domain: "Greenroom", code: 31, userInfo: [NSLocalizedDescriptionKey: reason])
                }
                mark(.meeting, .done)
                noteStartOutcome(route: route, crossAccountRefusal: false)
                // The island has carried the start since the click; the floating bar
                // first appears now, live. It is the surface unless the layout places a
                // Meeting window piece (owner, 2026-11-26), whoever is already in the
                // meeting; the Bar's Meeting button and \u{2303}\u{2325}\u{2318}H open the window on demand.
                MeetingSurfaceOwner.send(MeetingSurface.wentLive(layoutPlacesMeeting: layoutPlacesMeeting))
                if !sessionArranges {
                    ensureMeetingControls()
                    // The follow loop still runs: it feeds the window once it is asked for.
                    meetingWindowWanted = false
                    startCustomUIGridFollow()
                }
                // The bar is the surface of last resort, so a live meeting always has
                // one built: Greenroom's own window in a layout can go to the
                // bar too, and every way back must land somewhere.
                startBarText = nil
                // Every live meeting has its bar (R14): the controls exist even if
                // nothing above made them.
                ensureMeetingControls()
                if let controls = meetingControls {
                    MeetingControlBarController.install(coordinator: self, model: controls)
                }
                MeetingSurfaceOwner.syncWindowFacts()
                bringSharedForwardOnABarStart()
                bringInExtraCameras()

                // Only now, with the meeting live: Cues never listens
                // outside a class. Off by default; logs why when it cannot
                // start rather than blocking anything here.
                startCuesIfEnabled()

                // The meeting flow above has returned, so the session is
                // live - start the tape if the setting says so. Uses the
                // same path as the Record button, so End Session's
                // finish-the-file step still applies.
                mark(.recording, autoRecordOnStart && !isRecording ? .active : .skipped)
                if autoRecordOnStart && !isRecording {
                    log("Starting the recording automatically (Settings \u{2192} Devices).")
                    toggleRecording(withCountdown: false)
                    // Done once a frame is in the file, not when Record was asked for.
                    let asked = Date()
                    proof: while true {
                        switch StartChoreography.recordingStep(rolling: isRecording,
                                                               firstFrameWritten: recorder?.elapsedMilliseconds != nil,
                                                               waited: Date().timeIntervalSince(asked)) {
                        case .done:
                            mark(.recording, .done)
                            break proof
                        case .waiting:
                            try await Task.sleep(nanoseconds: 100_000_000)
                        case .failed(let words):
                            // The meeting is live and stays live; the take is what failed.
                            mark(.recording, .failed)
                            log(words)
                            ToastController.show(words, kind: .failure)
                            break proof
                        }
                    }
                }
                // Done once this start's placement pass ran to its end (hostAllInOne / joinAllInOne).
                if sessionArranges {
                    switch StartChoreography.tilingStep(placementFinished: startPlacementFinished) {
                    case .done: mark(.tiling, .done)
                    case .failed(let words):
                        mark(.tiling, .failed)
                        log(words)
                    case .waiting: break
                    }
                } else {
                    mark(.tiling, .skipped)
                }
                // Clearing the steps is what makes Readiness.isLive true, which
                // hands the panel back to its ordinary behaviour: the class side
                // returns to "waiting for students" and the controls come up.
                finishStartReadiness(liveConfirmed: zoomChatClient.isJoined)
                // A display was plugged or pulled while this was starting:
                // anything placed before that settled is placed against a screen
                // arrangement that no longer exists. Everything placed after it
                // read the live arrangement, so this is a no-op for those.
                if displayChangedDuringStart {
                    displayChangedDuringStart = false
                    if sessionArranges { snapWindowsBack(userInitiated: false, trigger: .displaysConnectedOrDisconnected) }
                }
            } catch is CancellationError {
                // Stop abandoned the start on purpose. It closes the panel
                // itself, so there is nothing to report on a surface that is
                // already going away.
                log("Start cancelled.")
                finishStartReadiness()
            } catch {
                guard !isStopping else {
                    // End Session was pressed and the step surfaced it as some
                    // other error (a cancelled request). Not a failure.
                    log("Start cancelled.")
                    finishStartReadiness()
                    apply(.meetingStartTaskFinished(startID: startID))
                    return
                }
                let crossAccount = (error as? ZoomMeetingSDKError)?.isCrossAccountRejection ?? false
                noteStartOutcome(route: route, crossAccountRefusal: crossAccount)
                let failure = ZoomRefusalRules.startFailure(error.localizedDescription, crossAccount: crossAccount, route: route)
                let message = failure.message
                log("Failed: \(message)")
                Analytics.failure("start")
                // Left on screen rather than cleared. The panel is the surface
                // the teacher has been watching for the last several seconds,
                // so it is where the failure belongs, named against the step it
                // happened on - with Try again and Close on it.
                // The bar is not where the error lives (it goes away, Home comes
                // back); the island is, as it always was.
                failStartReadiness(message, fix: failure.fix)
                Notifier.post(title: "Greenroom couldn\u{2019}t start", body: message)
                // And the unwind: a failed start used to leave the cameras, the
                // recorder and the half-started meeting running behind the card
                // (the CPU in Vision and AAC after a hung Start). Same teardown as
                // End Session, minus closing the failure card.
                mainWindowStartFailed()
                stop(failure: message)
            }
            apply(.meetingStartTaskFinished(startID: startID))
        }
    }

    /// A Start refused before any step ran (not signed in, a missing permission):
    /// said on the island with Try again, not only in the collapsed log. The first
    /// Start on a new Mac used to do nothing visible here.
    private func refuseStart(_ reason: String) {
        log(reason)
        recordFlowHUD = false
        lastStartWasRecordFlow = false
        startInBar = false
        var reading = ParticipantGridWindowController.Readiness()
        reading.failure = reason
        startReadiness = reading
    }

    /// A display event that settled while a Start was still running.
    private var displayChangedDuringStart = false

    /// Fully tears down: finishes the recording, lets go of the meeting's
    /// video, and stops the cameras and the screen capture, so nothing carries
    /// over into the next Start.
    ///
    /// `failure` is set only when a Start failed and is being unwound: the
    /// teardown is the same, but the failure card (and the loop that draws it)
    /// is left on screen for the person to read, with Try again and Close.
    func stop(failure: String? = nil) {
        guard !isStopping else { return }
        if failure == nil, phase.isRecordMode {
            stopRecordingSession()
            return
        }
        apply(.stopRequested)
        // A start that never went live: the bar goes (fading) and Home comes back
        // as it was. A failed start has already brought Home back itself.
        let wasStarting = startBarText != nil
        startBarText = nil
        if wasStarting, failure == nil {
            applyMainWindow(mainWindowVisibility.handle(.startFailed))
        }
        // Ending some other way (the menu, Zoom, a failure) answers the End question too.
        disarmExit()
        Analytics.track(.sessionEnd, [
            .durationBand: Analytics.band(seconds: sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
        ])
        sessionStartedAt = nil
        discardEmptySessionFolder()
        sessionFolder = nil
        // A start still in flight gets abandoned at its next checkpoint -
        // without this, its meeting setup raced the teardown below.
        startTask?.cancel()
        cancelRecordingCountdown()
        MeetingSurfaceOwner.reset()
        // Whoever is waiting on the Zoom SDK is let go now, not when a
        // watchdog fires: End during a stuck Start used to leave the Start
        // button dead for the rest of the join timeout.
        zoomChatClient.abandonPendingCallbacks()
        // The microphone tap goes first: the class is over, so is listening.
        stopCues()
        cuesSurfaceReported = false
        Task {
            log("Stopping\u{2026}")
            // Chat teardown first: close the window before leave() flips
            // isJoined, so the meeting-ended observer sees it already
            // closed and doesn't double-log.
            MeetingControlBarController.close(fade: wasStarting)
            meetingControls?.stop()
            meetingControls = nil
            PeoplePopOutController.close()
            if ChatWindowController.isOpen {
                ChatWindowController.close()
                log("Left the meeting chat.")
            }
            zoomChatBridge.reset()
            // The apps are the teacher's, not the meeting's, so by default they
            // stay open like Chrome would. An App piece can ask to close with the
            // class (Close when class ends); its tabs survive for the next Start.
            // Nothing arranged means nothing was opened, so nothing is closed.
            if sessionArranges, let template = sessionTemplate {
                await layoutEngine.closeApps(template)
            }
            // Custom UI: stop the SDK rendering into views that are about to
            // go away, then drop our window. A failed start takes its window and
            // loop down too (the island, not the window, carries the failure);
            // only the island's failure stays.
            let teardown = StartChoreography.teardown(failure.map { .failed($0) } ?? .cancelled)
            if teardown.stopsFollowLoop {
                customUIGridTask?.cancel()
                customUIGridTask = nil
            }
            if !teardown.keepsIslandFailure {
                finishStartReadiness()
                ReadinessHUDController.close()
            }
            recorder?.disarmClipBuffer()
            zoomChatClient.onParticipantCountChanged = nil
            if teardown.closesMeetingWindow { ParticipantGridWindowController.close() }
            RoomScreen.close()
            MeetingViewWindows.reset()
            meetingWindowWanted = true
            zoomChatClient.releaseCustomUIVideo()
            // A beat between cancelling the window-follow loops and the
            // SDK tearing its meeting windows down: the crash logs' seven
            // zVideoUIBridge dealloc SEGVs look like that teardown racing
            // in-flight window manipulation.
            try? await Task.sleep(nanoseconds: 300_000_000)
            endMeetingForEveryone(askedSDKToEnd: zoomChatClient.leave())

            // Stop the tape now, finish the file in the background. The
            // recorder stops taking frames the moment stop() is called, so
            // the cameras can go away at once; waiting for the writer here
            // once held "Ending\u{2026}" up for a minute. Quit still waits for it.
            if isRecording, let rec = recorder {
                apply(.takeFinishingAtMeetingEnd)
                savingTask = Task { [weak self] in
                    let url = await rec.stop()
                    guard let self else { return url?.path }
                    var saved: String?
                    if let url {
                        // End Session stops the tape too, so marks have to be
                        // adopted here as well or a class ended the ordinary way
                        // would strand them in pending-clips.json.
                        let marks = self.adoptPendingClips(recordedAt: url.path)
                        self.log("Recording saved: \(url.path)" + (marks > 0 ? " (\(marks) clip\(marks == 1 ? "" : "s") marked)" : ""))
                        Notifier.post(title: "Recording saved",
                                      body: "\(url.lastPathComponent) \u{2014} in Documents/Greenroom.")
                        saved = url.path
                    } else {
                        self.log("Recording stopped, but no picture was written \u{2014} nothing was saved.")
                    }
                    self.apply(.takeSaved)
                    return saved
                }
            }
            await tearDownStage()
            log("Session ended \u{2014} the camera and screen capture are off.")
            apply(.meetingTornDown)
            warmUpForStart()
            sessionTemplate = nil
            // A live change in the meeting does not outlast it: Home shows the layout's own again.
            liveShareChosen = false
            adoptLayoutPieces(LayoutPieceAdoption.atStart(layoutLibrary.active))
            LayoutShareChoice.reset()
            speakerTileQuickHidden = false
            resumePreviewIfWanted()
            // The session pushed Greenroom to the back (finalizeLayout) so
            // the main app could take the stage - with the meeting over,
            // bring it home to front for the next thing.
            if !reconcileMainWindow() { showMainWindow() }
            // Everything is over now - the meeting, the recording, the picture - so
            // the upload question is the last thing, and nothing waits on it.
            if let saving = savingTask {
                savingTask = nil
                Task { if let path = await saving.value { recordingFinished(path: path) } }
            } else {
                // A recording stopped earlier in the class: its card now.
                presentFinishedSession()
            }
        }
    }

    /// The meeting this session created, if it created one. Only a meeting
    /// Greenroom made is Greenroom's to end for everyone; one the teacher
    /// joined belongs to whoever scheduled it, and End only leaves it.
    private var meetingCreatedHere: String?

    /// End session means the class is over for everyone.
    ///
    /// The SDK's "end for all" is tried first, from inside the meeting. It
    /// was the only attempt, and it cannot be checked - leaveMeeting returns
    /// nothing - so when Zoom did not honour it, reported live, End
    /// session left the meeting, Zoom handed host to a student, and the class
    /// carried on without its teacher. So a meeting this session created is
    /// also ended through the REST API - the same call the pre-flight uses on
    /// stale meetings - which does not depend on this connection still being
    /// host, or still being connected at all. Ending one that is already over
    /// is harmless; Zoom answers and nothing changes.
    private func endMeetingForEveryone(askedSDKToEnd: Bool) {
        Self.sessionLog("End: asked the SDK to \(askedSDKToEnd ? "end the meeting for all" : "leave")")
        guard let number = meetingCreatedHere, let id = Int64(number) else { return }
        meetingCreatedHere = nil
        guard let access = zoomAccess else {
            if !askedSDKToEnd {
                log("Zoom may have kept the meeting running without you \u{2014} end it from zoom.us if students are still in it.")
            }
            return
        }
        Task {
            let answer = await access.endMeetingReporting(id: id)
            Self.sessionLog("End: REST end meeting \(id) HTTP \(answer.status) \(answer.ok ? "ended" : "not ended") \(answer.detail)")
            // Zoom's own codes, not the HTTP status: a 400 was read as "already
            // over" until one turned out to be code 4711, the app lacking the
            // scope to end meetings at all. 3000/3001 and 404 are the meeting
            // not running or not existing - the outcome wanted.
            let alreadyOver = answer.status == 404 || answer.code == 3000 || answer.code == 3001
            if answer.code == 4711 || answer.code == 4700 {
                log("Zoom won't let Greenroom end meetings from the web: add the meeting:update:status:admin scope to your Server-to-Server app (Zoom Marketplace \u{2192} your app \u{2192} Scopes). Until then only the in-meeting end is tried.")
            } else if !answer.ok, !alreadyOver {
                log("Couldn't confirm the meeting ended for everyone \u{2014} check zoom.us if students are still in it.")
            }
        }
    }

    /// What this class is called. Becomes the session folder's name.
    ///
    /// Remembered between runs and pre-filled rather than asked for. A daily
    /// class has the same name five mornings a week, and DESIGN.md's promise is
    /// a whole class in one click - a dialog on the most repeated action in the
    /// product would spend that click on an answer that is almost always
    /// yesterday's. Left empty it falls back to a timestamp, so nothing ever
    /// blocks on it.
    @Published var className: String {
        didSet { defaults.set(className, forKey: "className") }
    }

    /// Keeps the last few minutes clippable even when nothing is being recorded.
    ///
    /// Costs roughly 300MB of RAM for the length of a session and encodes the
    /// composite continuously, so it is a real cost on days you never clip -
    /// hence a setting rather than an assumption. Held in memory, never on disk:
    /// choosing not to record a class still ends with nothing written down.
    @Published var clipBufferEnabled: Bool {
        didSet {
            defaults.set(clipBufferEnabled, forKey: "clipBufferEnabled")
            Analytics.setting("clip_buffer", on: clipBufferEnabled)
        }
    }

    /// Where this session's recording and clips live.
    ///
    /// Decided once at Start so stopping and restarting the tape mid-class
    /// lands in the same folder, but only created on disk when the tape
    /// actually rolls - a session nobody recorded should not leave an empty
    /// folder behind every morning.
    private(set) var sessionFolder: URL?

    @Published private(set) var isRecording = false
    /// The recording file is paused: it is not growing, and everything after
    /// resume is stitched on with no gap (SessionRecorder / PauseClock). The
    /// meeting, if there is one, carries on and still sees and hears you.
    @Published private(set) var isRecordingPaused = false
    /// The number on screen while a recording a person started counts down to
    /// its start; nil when no countdown is running.
    @Published private(set) var recordingCountdown: Int?
    private var countdownToken: UUID?
    /// Draws the countdown, the control bar and the border (RecordingChrome.swift).
    private let recordingChrome = RecordingChrome()
    /// Drawing on the screen and the whiteboard (phase 5, drawing-port-log.md).
    let drawing = ScreenAnnotationController()
    let whiteboardModel = CameraWhiteboardModel()
    /// The whiteboard as the share target (Home's Screen panel).
    private let whiteboardWindow = WhiteboardWindowController()
    /// The display holding the presented whiteboard (where the camera bubble sits during it).
    var presentedWhiteboardScreen: NSScreen? { whiteboardWindow.screen }
    /// The whiteboard opened from the drawing tools: a plain window on the
    /// owner's screen; the share target and the Stage are never touched by it.
    private let localWhiteboardWindow = WhiteboardWindowController(mode: .local)
    /// The drawing tools are up (on the screen, or the whiteboard window).
    @Published private(set) var isDrawing = false
    /// The screen canvas was put away for the whiteboard and comes back after it.
    private var drawingSuspended = false
    private var lastShareKind: ShareTarget.Kind?
    private var whiteboardPushPending = false
    /// A recording has been stopped and its file is still being closed. The
    /// Record control reads "Saving\u{2026}" and is disabled, and nothing may
    /// start a new recording until it is done.
    @Published private(set) var isSavingRecording = false
    /// The file being closed after End Session, so Quit can wait for it
    /// (bounded) and the upload question can follow it.
    private var savingTask: Task<String?, Never>?
    /// For the recording_end duration band, and read by the notes bar to time
    /// a note into the tape (SessionNotes). Never written anywhere.
    private(set) var recordingStartedAt: Date?

    /// Records the composited picture (screen + webcam bubble/cutout) with
    /// SessionRecorder - the same picture the meeting gets, so what's
    /// recorded is exactly what participants saw. Note this captures YOUR
    /// composite, not other participants' video; recording the actual Zoom
    /// meeting is a separate capability (the SDK's record controller).
    ///
    /// Gets the session folder ready for this session's output.
    ///
    /// Nothing Greenroom produces belongs loose in ~/Documents/Greenroom. The
    /// folder is created here rather than lazily at first record, because the
    /// clip buffer can write a clip before any recording exists. `stop()`
    /// removes the folder again if the session left nothing in it, so an
    /// unused session still costs nothing.
    private func pointOutputsAtSessionFolder() {
        guard let folder = sessionFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        recorder?.clipBufferFolder = folder
        // Accepted chat files belong with the class too, so a lesson's
        // recording, clips and whatever a pupil shared all end up together
        // rather than scattered between here and Downloads.
        zoomChatBridge.saveDirectory = folder
    }

    /// Arms the rolling buffer so the clip shortcuts work before anyone presses
    /// Record. Best-effort: a session that cannot buffer is still a session.
    private func armClipBuffer() {
        guard clipBufferEnabled, let recorder else { return }
        recorder.armClipBuffer(seconds: SessionFolders.clipBufferSeconds)
        let minutes = SessionFolders.clipBufferSeconds / 60
        log("Clip buffer armed \u{2014} the last \(minutes) minutes stay clippable with the clip shortcuts, recording or not.")
    }

    // MARK: Pause, countdown, and where the recording is

    /// Pauses the recording file, or carries on. Only the file: the meeting is
    /// untouched. Bound to the Pause shortcut, the menu bar item, the meeting
    /// bar and the Record view's control bar.
    func togglePauseRecording() {
        guard isRecording, !isSavingRecording, let recorder else { return }
        if isRecordingPaused {
            guard recorder.resume() else { return }
            apply(.takeResumed)
            log("Recording resumed.")
        } else {
            guard recorder.pause() else { return }
            apply(.takePaused)
            log("Recording paused \u{2014} nothing is being saved until you resume.")
        }
    }

    /// Seconds of recording so far: wall time since Record, minus time paused.
    /// Frozen while paused. This (not `Date() - recordingStartedAt`) is what
    /// every timer and note position uses; it is the same clock as the file.
    func recordingElapsed(at now: Date = Date()) -> TimeInterval? {
        guard isRecording, let started = recordingStartedAt else { return nil }
        return max(0, now.timeIntervalSince(started) - (recorder?.pausedSeconds ?? 0))
    }

    /// Counts down on screen, then returns true; false when it was cancelled
    /// (Esc, Cancel, the start shortcut again, or the session ending). Returns
    /// at once with true when the countdown is Off.
    private func runRecordingCountdown() async -> Bool {
        let seconds = recordingCountdownSeconds
        guard seconds > 0 else { return true }
        let token = UUID()
        countdownToken = token
        for case .tick(let remaining) in IslandRules.countdownSequence(seconds: seconds) {
            guard countdownToken == token else { return false }
            recordingCountdown = remaining
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let finished = countdownToken == token
        if finished {
            countdownToken = nil
            // "Recording" on the island for a beat, then it retracts.
            NotchStatusController.shared.countdownGo()
        }
        recordingCountdown = nil
        return finished
    }

    /// Stops a countdown before it reaches zero. Nothing is recorded.
    func cancelRecordingCountdown() {
        guard recordingCountdown != nil else { return }
        countdownToken = nil
        recordingCountdown = nil
        log("Recording cancelled during the countdown.")
    }

    /// What the live capture shows, in global CoreGraphics points. For the border.
    func capturedScreenFrame(onThisDesktop: Bool = false) -> CGRect? { stage?.capturedScreenFrame(onThisDesktop: onThisDesktop) }
    /// The window being captured, for the outline to sit just above; nil for a display.
    var capturedWindowID: CGWindowID? { stage?.capturedWindowID() }

    /// A recording just started: the app or window inside the outline comes to
    /// the front, so the person can work in it straight away (owner, 2026-11-16).
    /// A whole display has nothing to raise.
    func bringRecordedForward() {
        guard let front = stage?.capturedFrontTarget() else { return }
        let app: NSRunningApplication?
        if let pid = front.pid {
            app = NSRunningApplication(processIdentifier: pid)
        } else if let bundleID = front.bundleID {
            app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        } else {
            app = nil
        }
        guard let app else { return }
        AppWindowManager.bringForward(app, windowID: front.windowID)
    }

    /// The display being recorded, for the countdown and the control bar to appear on.
    var recordedScreen: NSScreen? {
        guard let frame = capturedScreenFrame() else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return false }
            return CGDisplayBounds(id).contains(centre)
        }
    }

    // MARK: Drawing and the whiteboard (phase 5)

    /// Drawing needs a picture to draw on: a session or the Record view is up
    /// and something is shared (a screen, or the whiteboard).
    var canDraw: Bool {
        stage != nil && phase.isCameraBusy && !shareTarget.sharesNothing
    }

    private func wireDrawing() {
        drawing.onClose = { [weak self] in self?.stopDrawing() }
        drawing.onWhiteboard = { [weak self] in self?.whiteboardFromTools() }
        drawing.onOverlay = { [weak self] overlay in self?.stage?.setMarksOverlay(overlay) }
        drawing.capturedFrame = { [weak self] in self?.capturedScreenFrame() }
        // The page is drawn again for the Stage whenever a stroke changes.
        whiteboardModel.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.scheduleWhiteboardPush() }
            }
            .store(in: &cancellables)
        // What is shared decides which tools make sense.
        $shareTarget
            .map(\.kind)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] kind in
                ShareVisibleWindows.setKind(ShowOnShare.ShareKind(kind))
                self?.shareKindChanged(to: kind)
            }
            .store(in: &cancellables)
        whiteboardWindow.onClosed = { [weak self] in
            guard let self, self.shareTarget.kind == .whiteboard else { return }
            self.isDrawing = false
        }
        localWhiteboardWindow.onClosed = { [weak self] in self?.closeLocalWhiteboard() }
    }

    /// The Draw button, the pill's Draw, and the Draw shortcut.
    func toggleDrawing() {
        if isDrawing { stopDrawing(); return }
        guard canDraw else {
            log("Drawing needs something shared. Pick a screen, app, window or the whiteboard under Behind you, then start the class or the Record view.")
            ToastController.show("Share a screen first, then draw", kind: .failure)
            return
        }
        startDrawing()
    }

    private func startDrawing() {
        switch shareTarget.kind {
        case .whiteboard:
            showWhiteboardWindow()
        case .display, .app, .window:
            guard let screen = recordedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
            drawing.begin(on: screen, followsWindow: stage?.followsWindow() ?? false)
            isDrawing = true
        case .nothing:
            break
        }
    }

    /// Done: the screen canvas goes and its marks are cleared; the whiteboard
    /// window closes (its page stays as drawn while it is the share).
    func stopDrawing() {
        if drawing.isActive || drawingSuspended { drawing.end() }
        drawingSuspended = false
        whiteboardWindow.hide()
        localWhiteboardWindow.hide()
        isDrawing = false
    }

    /// The session or the picture ended: nothing can be drawn on any more.
    private func endDrawingTools() {
        stopDrawing()
    }

    /// The presented whiteboard's "Back to screen": the share goes back to what it was before.
    func leaveWhiteboardShare() {
        guard shareTarget.kind == .whiteboard else { return }
        shareTarget = WhiteboardOpenRules.returnTarget(remembered: targetBeforeWhiteboard, fallback: ShareTarget())
        requestShapeApply(rebuild: true)
    }

    /// W / the toolbar's Whiteboard button. Only OPENS a white window on the
    /// owner's screen; presenting the whiteboard is the Screen panel's choice
    /// (WhiteboardOpenRules says which).
    func whiteboardFromTools() {
        switch WhiteboardOpenRules.toolAction(shareIsWhiteboard: shareTarget.kind == .whiteboard,
                                              localIsOpen: localWhiteboardWindow.isVisible) {
        case .openLocal:
            // The screen canvas steps aside (marks kept) so the window can be drawn on.
            if drawing.isActive { drawingSuspended = true; drawing.suspend() }
            localWhiteboardWindow.show(board: whiteboardModel) { [weak self] in self?.closeLocalWhiteboard() }
            isDrawing = true
        case .closeLocal:
            closeLocalWhiteboard()
        case .raisePresented:
            showWhiteboardWindow()
        }
    }

    /// Done or the window's close button: the canvas comes back over the screen.
    private func closeLocalWhiteboard() {
        localWhiteboardWindow.hide()
        switch WhiteboardOpenRules.closeOutcome(wasSuspended: drawingSuspended,
                                                shareIsWhiteboard: shareTarget.kind == .whiteboard,
                                                shareIsNothing: shareTarget.sharesNothing) {
        case .untouched:
            break
        case .drawingOff:
            drawingSuspended = false
            isDrawing = false
        case .resumeCanvas:
            drawingSuspended = false
            if let screen = recordedScreen ?? NSScreen.main {
                drawing.begin(on: screen, followsWindow: stage?.followsWindow() ?? false)
                isDrawing = true
            } else {
                isDrawing = false
            }
        }
    }

    private func shareKindChanged(to kind: ShareTarget.Kind) {
        defer { lastShareKind = kind }
        guard lastShareKind != nil, lastShareKind != kind else { return }
        switch kind {
        case .whiteboard:
            // The presented whiteboard replaces a locally opened one.
            localWhiteboardWindow.hide()
            pushWhiteboardPage()
            guard canDraw else { return }
            // The screen canvas steps aside (its marks are kept) and the page opens.
            if drawing.isActive { drawingSuspended = true; drawing.suspend() }
            showWhiteboardWindow()
        case .display, .app, .window:
            let wasWhiteboard = whiteboardWindow.isVisible
            whiteboardWindow.hide()
            // A local whiteboard is still open: the canvas stays put away.
            if localWhiteboardWindow.isVisible { break }
            if drawingSuspended || drawing.isActive {
                drawingSuspended = false
                // A different screen or window may now be what is captured:
                // begin again on it. Marks stay.
                if let screen = recordedScreen ?? NSScreen.main {
                    drawing.begin(on: screen, followsWindow: stage?.followsWindow() ?? false)
                    isDrawing = true
                }
            } else if wasWhiteboard {
                isDrawing = false
            }
        case .nothing:
            stopDrawing()
        }
    }

    private func showWhiteboardWindow() {
        whiteboardWindow.show(board: whiteboardModel) { [weak self] in self?.leaveWhiteboardShare() }
        isDrawing = true
    }

    /// Renders the page for the Stage, at most ~30 times a second.
    private func scheduleWhiteboardPush() {
        guard WhiteboardOpenRules.feedsStage(shareIsWhiteboard: shareTarget.kind == .whiteboard), !whiteboardPushPending else { return }
        whiteboardPushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            guard let self else { return }
            self.whiteboardPushPending = false
            self.pushWhiteboardPage()
        }
    }

    private func pushWhiteboardPage() {
        guard let stage else { return }
        pushWhiteboardPage(to: stage)
    }

    private func pushWhiteboardPage(to stage: StageCompositor) {
        guard shareTarget.kind == .whiteboard else { return }
        stage.setWhiteboardPage(whiteboardModel.renderPage(width: Int(stage.outputSize.width)))
    }

    /// Marks the last `minutes` of the recording, ending now.
    ///
    /// A bookmark, not a cut. The recorder's own position in the file it is
    /// writing makes the range exact; nothing is encoded, buffered, or read
    /// back from a file being written to. The clip itself is cut later,
    /// losslessly, from the finished master.
    ///
    /// Ends AT the keypress rather than straddling it: "the last five minutes"
    /// should mean the last five minutes.
    func markClip(minutes: Int) {
        Task {
            guard let folder = sessionFolder else {
                log("Nothing to clip \u{2014} start a session first.")
                ToastController.show("No session running",
                                     detail: "Start the meeting first.", kind: .failure)
                return
            }
            // Recording wins when it is available: marking the master costs
            // nothing and cuts losslessly from the real file. The buffer is for
            // when there is no master to mark.
            guard isRecording else {
                Analytics.feature("clip_\(minutes)", source: "buffer")
                await clipFromBuffer(minutes: minutes, into: folder)
                return
            }
            Analytics.feature("clip_\(minutes)", source: "recording")
            guard let position = recorder?.elapsedMilliseconds else {
                log("Couldn't clip \u{2014} the recording hasn't written a picture yet. Try again in a moment.")
                return
            }

            let end = position
            // Clamps at the start of the file: asking for the last five minutes
            // two minutes in gives you two minutes, which is what you meant.
            let start = max(0, end - minutes * 60_000)
            let clip = SessionClip(startMs: start, endMs: end, markedAt: Date())
            guard SessionClipStore.appendPending(clip, in: folder) else {
                log("Couldn't clip \u{2014} the mark could not be written to \(folder.lastPathComponent).")
                return
            }

            let clipped = clip.durationLabel
            log("Clipped the last \(clipped) (\(Self.offsetLabel(start)) to \(Self.offsetLabel(end))).")
            // Confirmed out loud: the teacher is mid-class looking at the shared
            // screen, not at Greenroom, and a mark that gave no sign of landing
            // would be pressed again and again.
            ToastController.show("Clipped the last \(clipped)",
                                 detail: "Marked in \(folder.lastPathComponent) \u{2014} in Recordings after the meeting.")
        }
    }

    /// Writes the rolling buffer out and trims it to the minutes asked for.
    ///
    /// Unlike marking, this produces a finished clip there and then - there is
    /// no master to cut from later, so the file has to exist now.
    private func clipFromBuffer(minutes: Int, into folder: URL) async {
        guard clipBufferEnabled else {
            log("Nothing to clip \u{2014} the clip buffer is off (Settings \u{2192} Devices) and nothing is recording.")
            ToastController.show("Nothing to clip",
                                 detail: "Turn on the clip buffer in Settings, or press Record.", kind: .failure)
            return
        }
        guard let recorder, recorder.isClipBufferArmed else {
            log("Nothing to clip \u{2014} the clip buffer is not running. Press Record (\(ShortcutStore.phrase(.toggleRecording))) to capture from here.")
            ToastController.show("Clip buffer not running",
                                 detail: "Press Record to capture from here instead.", kind: .failure)
            return
        }

        ToastController.show("Saving the last \(minutes) min\u{2026}",
                             detail: "Writing the clip buffer out.",
                             kind: .working, dismissAfter: nil)
        let replay: URL
        do {
            replay = try await recorder.saveClipBuffer(lastSeconds: minutes * 60)
        } catch {
            log("Couldn't clip \u{2014} \(error.localizedDescription)")
            ToastController.show("Clip failed", detail: error.localizedDescription, kind: .failure)
            return
        }

        do {
            let export = try await SessionClipExporter.exportTail(
                minutes: minutes, of: replay, markedAt: Date(), into: folder)
            log("Clipped the last \(export.requested.durationLabel) from the buffer \u{2014} \(export.url.lastPathComponent).")
            ToastController.show("Clipped the last \(export.requested.durationLabel)",
                                 detail: "Saved to \(folder.lastPathComponent)")
        } catch {
            // If the buffer file cannot be trimmed, keeping
            // the whole buffer under its own name beats losing the moment, and
            // saying so beats a clip that quietly is not the length it claims.
            let kept = SessionClipExporter.clipsFolder(for: replay)
                .appendingPathComponent(replay.lastPathComponent)
            try? FileManager.default.createDirectory(at: kept.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: replay, to: kept)) != nil {
                log("Clipped, but couldn't trim it to \(minutes) min (\(error.localizedDescription)) \u{2014} kept the whole buffer as \(kept.lastPathComponent).")
                ToastController.show("Clipped the whole buffer",
                                     detail: "Couldn't trim to \(minutes) min, so all of it was kept.",
                                     kind: .failure)
            } else {
                log("Couldn't clip \u{2014} \(error.localizedDescription)")
                ToastController.show("Clip failed", detail: error.localizedDescription, kind: .failure)
            }
        }
    }

    /// Removes this session's folder when the class left nothing behind.
    ///
    /// The folder is created at session start now, so that the recorder has somewhere to
    /// write. A session where nobody recorded and nobody clipped would otherwise
    /// leave a dated empty folder every single morning.
    private func discardEmptySessionFolder() {
        guard let folder = sessionFolder else { return }
        // Also counts a folder holding only leftovers as empty (a lone events
        // sidecar, an empty notes.jsonl); see SessionFolderRules for the rule.
        guard SessionFolderRules.isEffectivelyEmpty(folder) else { return }
        try? FileManager.default.removeItem(at: folder)
        log("Removed empty session folder: \(folder.lastPathComponent)")
    }

    /// Marries this session's pending marks to the file the recorder just finished.
    /// Returns how many were adopted, for the log and the notification.
    @discardableResult
    private func adoptPendingClips(recordedAt path: String) -> Int {
        let recording = URL(fileURLWithPath: path)
        // The recording's own folder, not sessionFolder: if the recording
        // went somewhere else, the marks should follow the file
        // rather than be filed next to a recording that is not there.
        let folder = recording.deletingLastPathComponent()
        let pending = SessionClipStore.loadPending(in: folder)
        guard !pending.isEmpty else { return 0 }
        SessionClipStore.adoptPending(in: folder, as: recording)
        return pending.count
    }

    /// mm:ss, or h:mm:ss once a class runs past the hour.
    private static func offsetLabel(_ milliseconds: Int) -> String {
        let total = milliseconds / 1000
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// `withCountdown: false` is for the meeting's own auto-record, which nobody pressed.
    func toggleRecording(withCountdown: Bool = true) {
        // The shortcut that starts a recording also cancels its countdown.
        if recordingCountdown != nil { cancelRecordingCountdown(); return }
        // A press while the last file is still closing must never start a
        // second recording (it once did, and wrote one outside any session).
        guard !isSavingRecording, !isStopping else {
            log("Recording is still saving \u{2014} wait a moment.")
            return
        }
        // Nothing live and nothing starting: the shortcut records, through the
        // same one flow as Home's Start Recording.
        if !phase.hasSessionOrTakeOnScreen {
            startRecordingFlow()
            return
        }
        // A Record-mode take: stopping it also puts the picture away.
        if recordOnlyActive {
            if isRecording { confirmStopTake() }
            return
        }
        Task {
            do {
                if isRecording {
                    apply(.takeFinishing)
                    let url = await recorder?.stop()
                    apply(.takeSaved)
                    Analytics.track(.recordingEnd, [
                        .durationBand: Analytics.band(seconds: recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
                    ])
                    recordingStartedAt = nil
                    if let url {
                        let path = url.path
                        let marks = adoptPendingClips(recordedAt: path)
                        log("Recording saved: \(path)" + (marks > 0 ? " (\(marks) clip\(marks == 1 ? "" : "s") marked)" : ""))
                        recordingFinished(path: path)
                        Notifier.post(title: "Recording saved",
                                      body: marks > 0
                                        ? "\(url.lastPathComponent) \u{2014} \(marks) clip\(marks == 1 ? "" : "s") marked."
                                        : "\(url.lastPathComponent) \u{2014} in Documents/Greenroom.")
                    } else {
                        log("Recording stopped.")
                    }
                } else {
                    // A person pressing Record gets the countdown; the
                    // meeting's auto-record calls beginRecording directly.
                    if withCountdown { guard await runRecordingCountdown() else { return } }
                    guard !isRecording, !isSavingRecording, !isStopping else { return }
                    try await beginRecording()
                }
            } catch {
                apply(.takeSaved)
                log("Recording failed: \(error.localizedDescription) \u{2014} press Start first if the session isn't running.")
                Analytics.failure("record")
            }
        }
    }

    /// Starts the tape. The Record button's half of toggleRecording, and the
    /// whole of what a Record-mode session does once its scene is built.
    private func beginRecording() async throws {
        // Warn about space BEFORE the tape rolls, and warn rather
        // than refuse: running out mid-class loses the tail of a
        // recording, but blocking the button loses the whole
        // thing, and only the teacher knows whether this class is
        // worth the risk. Auto-record comes through here too, so
        // this covers the case nobody pressed anything.
        if let free = SessionFolders.recordingsFreeBytes {
            let readable = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            switch SessionFolders.spaceLevel(freeBytes: free) {
            case .critical:
                log("Only \(readable) free \u{2014} that may not last a full class. Recordings live in Documents/Greenroom.")
                Notifier.post(title: "Low disk space for recording",
                              body: "Only \(readable) free, which may not fit a full meeting.")
            case .low:
                log("\(readable) free \u{2014} room for roughly two more classes.")
            case .ok:
                break
            }
        }
        // Right before the tape rolls, not at session setup: this is
        // the first moment we know a recording is actually going to
        // happen. The recorder creates the folder if it is not there.
        guard let recorder else {
            throw NSError(domain: "Greenroom", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "The picture isn't running, so there is nothing to record."
            ])
        }
        // A recording belongs in a session folder, always. With none (the
        // session has ended) there is nothing to record into: refuse rather
        // than drop a loose file in the root of Documents/Greenroom.
        guard let folder = sessionFolder else {
            log("Not recording: there is no session folder (the session has ended).")
            throw RecorderError.noFolder
        }
        guard !isSavingRecording else { throw RecorderError.stillSaving }
        recorder.microphoneUID = micDeviceUID
        recorder.recordsSystemAudio = recordSystemAudio
        try recorder.start(in: folder)
        apply(.takeBegan)
        recordingStartedAt = Date()
        Analytics.track(.recordingStart)
        log("Recording\u{2026} (screen + webcam composite)")
        // Confirmation where it can be seen - mid-session the
        // main window is buried behind the main app. The menu
        // bar's GR also flips to a REC glyph via isRecording.
        Notifier.post(title: "Recording started",
                      body: "Greenroom is recording the composite. \(ShortcutStore.phrase(.toggleRecording)) stops it.")
    }

    // MARK: Record mode - get ready, then record, as often as you like

    /// A Record-mode session: the picture is up (compositor, cameras, screen
    /// share) for a take that is about to roll or is rolling. No meeting, so neither
    /// `stageLive` nor anything keyed to the meeting is set. `isRecording` says
    /// whether a take is running.
    @Published private(set) var recordOnlyActive = false
    /// A Record start is in flight, so Stop knows which teardown the half-started
    /// picture needs.
    @Published private(set) var startingRecordOnly = false
    /// A take is starting or finishing, so the bar's Stop waits.
    @Published private(set) var takeBusy = false
    /// A Record start wants the live picture, whether or not Settings does.
    /// Held apart from `shapePreviewOn` so closing Settings -> Layouts does not
    /// blank the Record view, and the other way round.
    private var studioPreviewOn = false

    /// Which page the main window is on.
    ///
    /// Greenroom keeps a low profile: Sessions, a session's detail and its
    /// report are pages of the one window, not windows of their own. The page
    /// is only a view - leaving Home never touches Start, Record or the class.
    /// Detail and report carry the session's id (its folder path).
    enum MainPage: Equatable {
        case home
        case sessions
        case detail(String)
        case report(String)
        /// The video editor, in place of the session's page.
        case editor(String)

        var isHome: Bool { self == .home }
    }

    @Published var mainPage: MainPage = .home

    /// One step back: report to its session, session to the grid, grid to Home.
    func goBack() {
        switch mainPage {
        case .report(let id), .editor(let id): mainPage = .detail(id)
        case .detail: mainPage = .sessions
        case .sessions: mainPage = .home
        case .home: break
        }
    }

    /// The full report for the session being looked at.
    func openReport() {
        if case .detail(let id) = mainPage { mainPage = .report(id) }
    }

    /// Which start the failure card's Try again repeats.
    private var lastStartWasRecordFlow = false

    /// Start Recording, from Home, the shortcut or the menu bar: one flow, no
    /// screen of its own. The steps and their order are `RecordStartFlow`'s.
    ///
    ///  1. The picture comes up (the island says "Opening your picture").
    ///  2. The countdown, on the island (Off, 3, 5 or 10 from Settings). Esc or
    ///     Cancel there puts everything away and Home is as it was.
    ///  3. The tape rolls and the main window steps aside (MainWindowVisibility
    ///     hides it once `isRecording`). The floating recording bar is the controller.
    ///
    /// If a step fails the picture is put away, the island keeps the failure
    /// with Try again and Close, and the main window comes back or stays.
    ///
    /// The picture is the same as a meeting's - same look, share, camera and
    /// microphone - because the Webcam page is the one description of it. No
    /// meeting, no chat window, no tiling. No folder is made until the tape is
    /// about to roll.
    func startRecordingFlow() {
        guard phase.canStart else { return }
        apply(.recordStartRequested)
        let startID = phase.startID
        studioPreviewOn = true
        lastStartWasRecordFlow = true
        recordFlowHUD = true
        statusLines = []
        Analytics.track(.sessionStart, [
            .mode: "record",
            .displays: String(NSScreen.screens.count)
        ])
        startReadiness = .init(steps: RecordStartFlow.stepLabels.map { .init(label: $0, state: .pending) })

        startTask = Task {
            var flow = RecordStartFlow()
            var action = flow.handle(.begin)
            do {
                run: while true {
                    switch action {
                    case .buildPicture:
                        // The island grows before the picture work takes the main thread.
                        await ReadinessHUDController.letItOpen()
                        try Task.checkCancellation()
                        startReadiness.steps[0].state = .active
                        try await buildScene()
                        try Task.checkCancellation()
                        apply(.recordPictureUp)
                        // A second camera, if switching is on, and the director
                        // to cut to it - the same as a meeting.
                        bringInExtraCameras()
                        startReadiness.steps[0].state = .done
                        action = flow.handle(.pictureReady)
                    case .countdown:
                        let finished = await runRecordingCountdown()
                        try Task.checkCancellation()
                        action = flow.handle(finished ? .countdownFinished : .cancelled)
                    case .beginTake:
                        startReadiness.steps[1].state = .active
                        try await beginTakeOrThrow()
                        startReadiness.steps[1].state = .done
                        action = flow.handle(.takeStarted)
                    case .finish:
                        // Every step settled: the island's "Live" beat, then it folds.
                        finishStartReadiness(liveConfirmed: isRecording)
                        break run
                    case .putAway:
                        log("Recording cancelled.")
                        await abandonRecordFlow()
                        finishStartReadiness()
                        break run
                    case .showFailure, .idle:
                        break run
                    }
                }
            } catch {
                if error is CancellationError {
                    log("Recording start cancelled.")
                    await abandonRecordFlow()
                    finishStartReadiness()
                } else {
                    let message = error.localizedDescription
                    log("Couldn\u{2019}t start recording: \(message)")
                    Analytics.failure("record_start")
                    await abandonRecordFlow()
                    // The island keeps the failure, with Try again and Close.
                    failStartReadiness(message)
                    Notifier.post(title: "Greenroom couldn\u{2019}t start recording", body: message)
                    mainWindowStartFailed()
                }
            }
            apply(.recordStartTaskFinished(startID: startID))
        }
    }

    /// Puts the half-started picture away exactly as Stop would, so the next try
    /// begins clean and no camera stays open behind an abandoned attempt.
    private func abandonRecordFlow() async {
        discardEmptySessionFolder()
        sessionFolder = nil
        sessionStartedAt = nil
        await tearDownRecordingScene()
        apply(.recordPictureDown)
        revivePreviewIfStalled()
    }

    /// The tape: a take, into a session folder of its own.
    ///
    /// Each take is a session in Sessions (kind "recording"), named by the name
    /// on Home at the moment it starts. No clip buffer: the whole take is on
    /// disk, so the clip shortcuts mark the recording itself, as they do
    /// whenever one is running. Throws when the recorder cannot start.
    private func beginTakeOrThrow() async throws {
        guard recordOnlyActive, !isRecording, !isSavingRecording, !isStopping else {
            throw CancellationError()
        }
        takeBusy = true
        defer { takeBusy = false }
        let startedAt = Date()
        let folder = SessionFolders.uniqueSessionFolder(
            named: SessionFolders.sessionFolderName(className: className, started: startedAt,
                                                    fallback: "Recording"),
            in: SessionFolders.recordingsDirectory)
        sessionFolder = folder
        sessionStartedAt = startedAt
        do {
            try await beginRecording()
            // Only once the tape is rolling: a take that fails before this
            // leaves an empty folder, which is then removed.
            var metadata = SessionMetadata()
            metadata.kind = SessionMetadata.Kind.recording.rawValue
            let typed = SessionFolders.sanitizedClassName(className)
            metadata.title = typed.isEmpty ? nil : typed
            metadata.save(in: folder)
            log("Recording into \u{201C}\(folder.lastPathComponent)\u{201D} in Documents/Greenroom.")
        } catch {
            discardEmptySessionFolder()
            sessionFolder = nil
            sessionStartedAt = nil
            throw error
        }
    }

    /// Stop, from the recording bar, the shortcut or the menu: the file is
    /// finished and saved, the picture is put away and Home comes back.
    func stopTake() {
        guard recordOnlyActive, isRecording, !takeBusy else { return }
        stopRecordingSession()
    }

    /// The Record bar's Stop, the shortcut and the menu. The first press arms
    /// Stop (the button itself turns into Confirm); the second, while armed,
    /// stops. Esc or 15 seconds disarm it.
    func confirmStopTake() {
        guard recordOnlyActive, isRecording, !takeBusy else { return }
        if exitAsk == .stopTake {
            disarmExit()
            stopTake()
            return
        }
        armExit(.stopTake, title: "Stop the recording?",
                detail: "Press Confirm to save it. Esc keeps recording.")
    }

    /// The bar's REC pill during a class: one press arms it (it reads
    /// Confirm), the second stops and saves the recording. No menu in between
    /// (owner, 2026-11-17: "it should not need a menu"; the confirmation stays).
    func confirmStopRecording() {
        // `isRunning` is only true while a start is under way; a live class is
        // `stageLive` (the guard read isRunning alone, and REC did nothing).
        guard phase.isInMeeting, !recordOnlyActive, isRecording, !isSavingRecording else { return }
        if exitAsk == .stopRecording {
            disarmExit()
            toggleRecording()
            return
        }
        armExit(.stopRecording, title: "Stop the recording?",
                detail: "Press Confirm to save it. Esc keeps recording.")
    }

    // MARK: After a session

    /// The card over the main window once a session or a take has ended and
    /// its recording is saved: Watch, Edit, Upload to YouTube, Finder, Done.
    /// It replaces the island's upload question and Home's "Last session"
    /// line (owner, 2026-11-16).
    struct FinishedSession: Equatable, Identifiable {
        let id = UUID()
        /// The session's folder, which is also its page's id.
        let folder: URL
        let file: URL
        let title: String
    }
    @Published var finishedSession: FinishedSession?
    /// The newest recording saved while a session was live, shown on the
    /// card once it ends.
    var lastFinishedRecording: URL?

    func presentFinishedSession() {
        guard let file = lastFinishedRecording else { return }
        lastFinishedRecording = nil
        let folder = file.deletingLastPathComponent()
        let title = SessionMetadata.load(in: folder).title
            ?? { let n = className.trimmingCharacters(in: .whitespaces); return n.isEmpty ? file.deletingPathExtension().lastPathComponent : n }()
        finishedSession = FinishedSession(folder: folder, file: file, title: title)
    }

    // MARK: Asking before End and Stop

    /// What End or Stop is waiting to be pressed again for. Asked in place:
    /// the button that was pressed turns into Confirm, and the island only
    /// says what it means (owner, 2026-11-16: the island shows status, it
    /// has no buttons). The question sits in a callout right above the
    /// button, not in the island: "I should be asked in the same place I'm
    /// supposed to press" (owner, same day).
    enum ExitAsk: Equatable { case end, stopTake, stopRecording }
    @Published private(set) var exitAsk: ExitAsk?
    /// What the armed button's callout says, right above it.
    @Published private(set) var exitAskTitle = ""
    @Published private(set) var exitAskDetail = ""
    /// When the armed End started waiting (drives the button's countdown fill),
    /// and the same wait's length. Nil when nothing is armed.
    @Published private(set) var exitAskStartedAt: Date?
    private(set) var exitAskTimeout: TimeInterval = IslandRules.confirmTimeout
    /// End's own two-step (App/LiveExitRules.swift): idle, confirming, ending.
    private var endConfirm = EndConfirm()
    private var exitAskTimer: Task<Void, Never>?
    private var exitAskMonitors: [Any] = []
    /// Which arming a click belongs to, so a late check never disarms a newer one.
    private var exitArmSerial = 0

    private func armExit(_ ask: ExitAsk, title: String, detail: String) {
        disarmExit()
        exitAskTitle = title
        exitAskDetail = detail
        exitAskTimeout = ask == .end ? EndConfirm.timeout : IslandRules.confirmTimeout
        exitAskStartedAt = Date()
        exitAsk = ask
        let wait = exitAskTimeout
        exitAskTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.disarmExit()
        }
        // Esc keeps going: heard while Greenroom is in front, and while another
        // app is when Accessibility is granted (as the countdown's Esc).
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, self?.exitAsk != nil else { return event }
            self?.disarmExit()
            return nil
        }) { exitAskMonitors.append(local) }
        if AXIsProcessTrusted(),
           let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
               guard event.keyCode == 53 else { return }
               MainActor.assumeIsolated { self?.disarmExit() }
           }) { exitAskMonitors.append(global) }

        // A click anywhere but Confirm puts End back (owner, 2026-11-17). In
        // another app: at once. In Greenroom: checked just after the click is
        // handled, so pressing Confirm (which answers and disarms first) is
        // never mistaken for a click elsewhere. AppKit buttons swallow their
        // mouse-up while tracking, hence the mouse-down check as well.
        exitArmSerial += 1
        let serial = exitArmSerial
        let disarmIfStill: @MainActor () -> Void = { [weak self] in
            guard let self, self.exitAsk != nil, self.exitArmSerial == serial else { return }
            self.disarmExit()
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp], handler: { event in
            if event.type == .leftMouseUp {
                // A beat later: SwiftUI may run a button's action after the event.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { MainActor.assumeIsolated { disarmIfStill() } }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { disarmIfStill() } }
            }
            return event
        }) { exitAskMonitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in
            MainActor.assumeIsolated { disarmIfStill() }
        }) { exitAskMonitors.append(global) }
    }

    /// Takes the question away: answered, timed out, Esc, or ended some other way.
    func disarmExit() {
        exitAskTimer?.cancel()
        exitAskTimer = nil
        for m in exitAskMonitors { NSEvent.removeMonitor(m) }
        exitAskMonitors = []
        endConfirm.cancel()
        exitAskStartedAt = nil
        if exitAsk != nil { exitAsk = nil }
    }

    /// Finishes the tape, adopts the clip marks and closes the take's
    /// session. Returns the saved file's path.
    private func finishTake() async -> String? {
        var saved: String?
        if isRecording {
            apply(.takeFinishing)
            let stopped = await recorder?.stop()
            apply(.takeSaved)
            if let url = stopped {
                let path = url.path
                let marks = adoptPendingClips(recordedAt: path)
                log("Recording saved: \(path)" + (marks > 0 ? " (\(marks) clip\(marks == 1 ? "" : "s") marked)" : ""))
                Notifier.post(title: "Recording saved",
                              body: "\(url.lastPathComponent) \u{2014} in Documents/Greenroom.")
                saved = path
            } else {
                log("Recording stopped, but no picture was written \u{2014} nothing was saved.")
            }
            Analytics.track(.recordingEnd, [
                .durationBand: Analytics.band(seconds: recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
            ])
            recordingStartedAt = nil
        }
        if let started = sessionStartedAt {
            Analytics.track(.sessionEnd, [
                .durationBand: Analytics.band(seconds: Date().timeIntervalSince(started))
            ])
        }
        discardEmptySessionFolder()
        sessionFolder = nil
        sessionStartedAt = nil
        return saved
    }

    /// Ends a Record-mode session: any take finished and saved first, then the
    /// picture torn down exactly as End Session leaves it, so the camera light
    /// goes off.
    ///
    /// A Get Ready still in flight is cancelled and then WAITED for, unlike a
    /// meeting's. Its steps are not cancellation-aware, so without the wait a
    /// take could start after this had already decided there was none to stop.
    func stopRecordingSession() {
        guard !isStopping else { return }
        // Stopping some other way answers the Stop question too.
        disarmExit()
        cancelRecordingCountdown()
        apply(.stopRequested)
        let pending = startTask
        pending?.cancel()
        Task {
            await pending?.value
            log("Stopping\u{2026}")
            let saved = await finishTake()
            // A start that failed has already torn down; this one has not.
            if recordOnlyActive { await tearDownRecordingScene() }
            apply(.recordPictureDown)
            // The teardown tried to bring the preview back while the take
            // still counted as running, so it could not start the camera.
            revivePreviewIfStalled()
            apply(.recordStopFinished)
            reconcileMainWindow()
            // Last, as after a class: the upload question waits for
            // everything else to have finished.
            if let saved { recordingFinished(path: saved) }
        }
    }

    /// The picture half of End Session, and only that: the meeting's video
    /// let go, the clip buffer dropped, the cameras and the screen capture
    /// stopped. Also the Record-mode teardown.
    private func tearDownStage() async {
        cameraDirector.stop()
        zoomChatClient.useStageVideo(nil)
        recorder?.disarmClipBuffer()
        recorder = nil
        lastCameraLive = nil
        resetPresenceBubbleToLayoutDefault(at: .end)
        stopStage()
    }

    private func tearDownRecordingScene() async {
        studioPreviewOn = false
        await tearDownStage()
        publishPreviewFrame(nil)
        resumePreviewIfWanted()
    }

    /// The chosen main-pane app's user-facing name, for buttons and logs.
    // MARK: Live shape preview (Home, Settings -> Layouts)
    // The shape picker shows the REAL picture - actual screen, actual camera,
    // the look as chosen - from the same compositor a class uses. Idle, the
    // preview runs the compositor with no meeting for as long as the page is
    // open, and lets the camera go the moment it closes.

    /// The frames, on an object of their own. As a @Published property of this
    /// controller each one invalidated every view that observes it - the whole
    /// Settings window, rebuilt several times a second. Only the picture
    /// observes `shapePreview`; the rest of the tab watches
    /// `shapePreviewAspect`, which changes only when the picture's shape does.
    let shapePreview = ShapePreviewFeed()
    /// The live picture's size, or nil while the schematic is showing.
    @Published private(set) var shapePreviewAspect: CGSize?
    /// Where the shared content sits on the canvas (canvas px), or nil. Published
    /// only when it CHANGES (never per frame) so Home's card re-crops, and the
    /// window re-sizes, the moment it arrives: `shapePreview` is not observed by Home.
    @Published private(set) var shapePreviewContent: CGRect?
    /// The last real picture shape Home sized its card from. Plain, not
    /// published: it only seeds a recreated window at the right width.
    var lastPictureAspect: CGFloat?
    /// Who is looking at the preview. Home's card and Settings → Layouts share
    /// one picture; it stops only when the last of them leaves, so closing
    /// Settings no longer blanks Home's card (and the other way round).
    /// Each Home carries its own id: SwiftUI can bring a new Home up before
    /// the old one goes, and with one shared `.home` the old one's leaving
    /// turned off the new one's camera.
    enum PreviewViewer: Hashable, CustomStringConvertible {
        case home(UUID)
        /// Settings -> Layouts, while the camera piece is selected or Preview: Everyone is on (R11.3).
        case layoutsCamera
        var description: String {
            switch self {
            case .home: return "home"
            case .layoutsCamera: return "layouts camera"
            }
        }
    }
    private var previewViewers: Set<PreviewViewer> = []
    private var shapePreviewOn: Bool { !previewViewers.isEmpty }
    private var shapePreviewApply: Task<Void, Never>?
    private let previewSink = StagePreviewSink()
    private var previewAttached = false

    /// Starts showing the picture. Outside a session the compositor is started
    /// for it, with the chosen look, so the preview shows what the NEXT
    /// session will send; during a live session it simply mirrors that one.
    /// Never asks for a permission: with Screen Recording off the picture is
    /// the camera alone.
    /// Whether this viewer's claim on the preview is held, for Home's check.
    func isShowingPreview(for viewer: PreviewViewer) -> Bool { previewViewers.contains(viewer) }

    /// The Layouts tab's claim on the picture: held only while someone looks at the camera.
    func setLayoutsCameraPreview(_ on: Bool) {
        if on { startShapePreview(for: .layoutsCamera) } else { stopShapePreview(for: .layoutsCamera) }
    }

    func startShapePreview(for viewer: PreviewViewer) {
        let wasOn = shapePreviewOn
        previewViewers.insert(viewer)
        guard !wasOn else { return }
        StageScreenSource.log("Preview opened (\(viewer)).")
        attachPreview()
    }

    private func attachPreview() {
        guard shapePreviewOn || studioPreviewOn, !previewAttached else { return }
        if !phase.isCameraBusy {
            guard let stage = ensureStage() else { return }
            stage.start(makeStageConfiguration())
        }
        guard let stage else { return }
        previewSink.onPicture = { [weak self] image, mask in self?.publishPreviewFrame(image, mask: mask) }
        previewSink.coverage = { [weak stage] in stage?.lastCameraCoverage }
        stage.addSink(previewSink)
        previewAttached = true
        syncIdleDirector(restart: true)
    }

    /// After a session ends, a Settings window still open gets its preview back.
    private func resumePreviewIfWanted() {
        previewAttached = false
        if shapePreviewOn { attachPreview() }
    }

    /// Someone is waiting on the preview but no picture is coming: the stage
    /// was stopped under it (a Record take ending while `recordOnlyActive`
    /// still read true), or it never started. Starts it again. Safe to call
    /// any time; it does nothing while a session owns the picture or frames
    /// are flowing.
    /// `evenIfRunning`: Home has waited seconds with no frame from a stage
    /// that says it is running, so restart it anyway.
    func revivePreviewIfStalled(evenIfRunning: Bool = false) {
        guard shapePreviewOn || studioPreviewOn, !phase.isCameraBusy else { return }
        if let stage, stage.status.isRunning, previewAttached,
           shapePreviewAspect != nil || !evenIfRunning { return }
        StageScreenSource.log("Preview had no picture; starting it again.")
        if let stage, previewAttached { stage.removeSink(previewSink) }
        previewAttached = false
        if let stage, stage.status.isRunning { stopStage() }
        attachPreview()
    }

    /// Looks through one camera so Settings can show the angle it reads you
    /// at while it is being aimed.
    ///
    /// CameraProbe opens the camera the same way the stage does (a plain
    /// capture session). Idle only: during a class the director reads the
    /// stage's own frames and this would be a second opener of the camera.
    func aimCamera(uid: String) {
        guard !sceneInUse else { return }
        // The preview's director already holds every chosen camera open: read
        // from it rather than open a second time.
        if cameraDirector.isRunning, sessionCameraUIDs(cameraDirectorSettings).contains(uid) {
            cameraProbe.startExternal(uid: uid)
        } else {
            cameraProbe.start(uid: uid)
        }
    }

    func stopAiming() { cameraProbe.stop() }

    func stopShapePreview(for viewer: PreviewViewer) {
        guard previewViewers.remove(viewer) != nil else { return }
        guard previewViewers.isEmpty else {
            StageScreenSource.log("Preview closed (\(viewer)); still shown elsewhere.")
            return
        }
        StageScreenSource.log("Preview closed (\(viewer))\(!phase.isCameraBusy ? "; the picture stops with it" : "").")
        shapePreviewApply?.cancel()
        // The Record view is still watching the same picture: one compositor
        // serves both, and the last to leave turns the light off.
        if studioPreviewOn { return }
        if let stage, previewAttached { stage.removeSink(previewSink) }
        previewAttached = false
        // The preview opened the camera; a session that is not running has
        // no use for it, and the camera light should go off.
        if !phase.isCameraBusy { stopStage() }
        publishPreviewFrame(nil)
    }

    private func publishPreviewFrame(_ frame: NSImage?, mask: NSImage? = nil) {
        let content = frame == nil ? nil : stage?.lastContentRect
        if shapePreview.contentRect != content { shapePreview.contentRect = content }
        if shapePreviewContent != content { shapePreviewContent = content }
        shapePreview.frame = frame
        shapePreview.openMask = mask
        let aspect = frame?.size
        if aspect != shapePreviewAspect { shapePreviewAspect = aspect }
    }

    /// Applies the current shape, placement, share and cameras to the picture,
    /// latest wins. Every camera control (Layouts, Home, the bubble) calls this; a burst of
    /// changes (a slider, several clicks) cancels what it supersedes instead
    /// of queuing. Works the same live in a class as in the idle preview.
    /// `rebuild` is kept for the callers that changed what is shared; the
    /// compositor swaps the share without blanking the picture either way.
    func requestShapeApply(rebuild: Bool = false) {
        // Choosing a screen-based tile is asking for the screen: if macOS has
        // not allowed it, say where, once.
        if rebuild, shareTarget.kind.capturesScreen, !StageCompositor.screenRecordingGranted {
            StageScreenSource.openPermissionPaneOnce()
        }
        shapePreviewApply?.cancel()
        shapePreviewApply = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            applyShapeForPreview()
        }
    }

    /// Hands the compositor the settings as they are now.
    func applyShapeForPreview() {
        guard let stage, stage.status.isRunning || phase.isCameraBusy || shapePreviewOn else { return }
        stage.update(makeStageConfiguration())
    }

    /// The app a Cues card opens in: the first App piece of the layout this class
    /// runs (or of the one chosen in Settings, before a class). nil when there is
    /// none, which means the system's default browser.
    var cueCardAppBundleID: String? {
        (sessionTemplate ?? layoutLibrary.active)?.firstAppBundleID
    }

    /// The Layout chip's "Open This Layout's Apps": opens the apps of the layout this class runs, or
    /// of the layout chosen in Settings when there is no class, each in its frame.
    /// Chrome-family browsers go through AppleScript; everything else launches
    /// and AX-tiles, which can take a few seconds for a cold-started app.
    func openMainAppWindow() {
        guard let template = sessionTemplate ?? layoutLibrary.active else {
            log("No layout is chosen, so there are no apps to open. Pick one in Settings (\u{2318},) \u{2192} Layout.")
            return
        }
        // The owner's own open: these apps come to the front, as from the Dock.
        layoutEngine.openApps(template, hidden: speakerTileQuickHidden, all: true, activates: true)
    }

    /// The meeting window's Chat button when no panel carries the chat: the
    /// window opens at the layout's Chat piece in an arranged class, and where it
    /// lands otherwise.
    func revealChatWindow() {
        ChatWindowController.show(chat: zoomChatBridge,
                                  frame: sessionArranges
                                      ? sessionTemplate.flatMap { layoutEngine.chatFrame($0, meetingHidden: speakerTileQuickHidden) }
                                      : nil)
    }

    /// Where a closed Greenroom Browser reopens (Cues opening a card): its piece
    /// in an arranged class; nil, so it is left to open centred, when nothing is
    /// arranged.
    var builtInBrowserLayoutFrame: NSRect? {
        guard sessionArranges, let template = sessionTemplate else { return nil }
        return layoutEngine.builtInBrowserFrame(template)
    }

    /// There is a layout with at least one App piece to open.
    var layoutHasApps: Bool {
        guard let template = sessionTemplate ?? layoutLibrary.active else { return false }
        return !layoutEngine.resolve(template).apps.isEmpty
    }

    /// The all-in-one path: Greenroom's built-in SDK client IS the meeting
    /// client - starts the meeting as the user (their name, host role),
    /// camera sending Greenroom's own picture, mic live, chat sent as
    /// them. Its meeting window is OURS, so it parks top-right natively
    /// with no Accessibility permission involved.
    private func hostAllInOne(meeting: ZoomServerToServerClient.CreatedMeeting) async throws {
        guard let zak = meeting.zak else {
            throw NSError(domain: "Greenroom", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Zoom's create-meeting response had no host key (zak) - can't start the meeting."
            ])
        }
        let signer = try zoomSDKSigner()

        isConnectingChat = true
        defer { isConnectingChat = false }

        log("Starting the meeting in Greenroom's built-in Zoom client\u{2026}")
        try await zoomChatClient.ensureReady(signer: signer)
        await settleBeforeJoining()

        try await ensurePictureInstalled()
        reportMeetingVideo()
        applyMeetingMicrophone()

        let name = userDisplayName.isEmpty ? NSFullUserName() : userDisplayName
        try await zoomChatClient.startAsHost(meetingNumber: meeting.number, zak: zak, displayName: name, enableMedia: true)

        if let controller = zoomChatClient.chatController() {
            zoomChatBridge.attach(to: controller)
        }
        if let template = sessionTemplate { layoutEngine.openChat(template, meetingHidden: speakerTileQuickHidden) }
        log("Meeting is live \u{2014} you're hosting from Greenroom.")
        copyInviteWhenReady()

        if sessionArranges {
            presentMeetingSurfaces(trigger: .start)
            finalizeLayout()
            startPlacementFinished = true
        }
    }

    /// This start's placement pass (presentMeetingSurfaces + finalizeLayout) ran
    /// to its end: the Tiling step's proof. Reset at each Start.
    private var startPlacementFinished = false

    /// Scheduled: starts one of the account's own scheduled meetings as host
    /// via the built-in client, camera/mic live, chat as yourself. Never joins
    /// as a guest (the name is kept from when this tab was "Join").
    private func joinAllInOne() async throws {
        let signer = try zoomSDKSigner()
        isConnectingChat = true
        defer { isConnectingChat = false }

        log("Starting meeting \(meetingNumber) in Greenroom's built-in Zoom client\u{2026}")
        try await zoomChatClient.ensureReady(signer: signer)
        await settleBeforeJoining()

        try await ensurePictureInstalled()
        reportMeetingVideo()
        applyMeetingMicrophone()

        let name = userDisplayName.isEmpty ? NSFullUserName() : userDisplayName

        // The My Meetings tab only starts the account's OWN meetings, as host.
        // The SDK authenticates the app, not the Zoom user, so a host start
        // needs a fresh ZAK. There is no guest fallback: Greenroom does not
        // join other people's meetings.
        guard let access = zoomAccess else {
            throw NSError(domain: "Greenroom", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't start this meeting as host. \(zoomRouteMissingText)"
            ])
        }
        do {
            // The personal room starts the same way: its PMI with a fresh ZAK.
            // The host needs no passcode and skips the waiting room.
            log(ScheduledListRules.startLine(digits: meetingNumberDigits, room: personalRoom))
            let zak: String
            if let prefetched = validPrefetchedZAK() {
                // Warmed when the meeting was picked from the Scheduled
                // menu - saves the fetch's network time (step stays skipped).
                zak = prefetched
            } else {
                mark(.creating, .active)
                zak = try await withStartTimeout(20, step: "Getting your host key from Zoom",
                                                 advice: "Check your Zoom account in Settings \u{2192} Zoom.") {
                    try await access.fetchZAK()
                }
                mark(.creating, .done)
            }
            mark(.meeting, .active)
            try await zoomChatClient.startAsHost(meetingNumber: meetingNumber, zak: zak, displayName: name, enableMedia: true)
        } catch {
            // Zoom's refusal of the account keeps its type, so Start can explain it.
            if (error as? ZoomMeetingSDKError)?.isCrossAccountRejection == true { throw error }
            throw NSError(domain: "Greenroom", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't start this meeting as host: \(error.localizedDescription)"
            ])
        }

        if let controller = zoomChatClient.chatController() {
            zoomChatBridge.attach(to: controller)
        }
        if let template = sessionTemplate { layoutEngine.openChat(template, meetingHidden: speakerTileQuickHidden) }
        log("Meeting is live \u{2014} you're hosting from Greenroom.")
        copyInviteWhenReady()

        if sessionArranges {
            presentMeetingSurfaces(trigger: .start)
            finalizeLayout()
            startPlacementFinished = true
        }
    }


    /// Puts Greenroom's meeting window and the chat where the session wants them.
    /// The SDK renders into views we own, so there are no SDK windows to find.
    private func presentMeetingSurfaces(trigger: PlacementTrigger) {
        ensureMeetingControls()
        startCustomUIGridFollow()
        placeCustomSurfaces(trigger: trigger)
    }

    /// Puts Greenroom's meeting window and the chat where the layout wants them
    /// (LayoutEngine.placeMeetingAndChat). A Meeting piece in a rectangle takes
    /// that rectangle; one that fills a display is the full panel there; a layout
    /// without a Meeting piece leaves the window free. Hidden (\u{2325}\u{2318}Z or
    /// "Starts hidden"), the neighbour that joins it has grown into the gap.
    ///
    /// `trigger` (R45): Start, a switch, Snap Back and a display coming or going
    /// put every window back; the Meeting coming back (`.meetingShown`) moves
    /// nothing already up and only opens a view that never opened.
    private func placeCustomSurfaces(trigger: PlacementTrigger) {
        guard sessionArranges, let template = sessionTemplate else { return }
        if !layoutEngine.hasPlacedSurface(template) { speakerTileQuickHidden = false }
        // A Meeting in a rectangle that the layout hides (or shows) is the speaker tile's hide.
        if layoutEngine.placedMeeting(template) != nil {
            MeetingSurfaceOwner.send(speakerTileQuickHidden ? .tileHidden : .tileShown)
        }
        // The meeting window's loop takes the layout's form only after a pass like this.
        if LayoutPlacementRules.isExplicit(trigger) { ParticipantGridWindowController.pendingPlacement = trigger }
        layoutEngine.placeMeetingAndChat(template, hidden: speakerTileQuickHidden, trigger: trigger)
    }

    /// Where Greenroom's meeting window goes right now, and in which form.
    ///
    /// No layout: a window the teacher owns, filling the reference display the
    /// first time if there is one, else centred on the main display. Arranged: the
    /// layout's Meeting piece - a Meeting that fills a display is the meeting
    /// window filling it (`.placed(visibleFrame)`), one in a rectangle is `.placed(rect)` (Speaker view
    /// with the toolbar on hover when under 760x520, else the full meeting form),
    /// and a layout without one is the free window. Never borderless but for the
    /// full panel. Worked out every tick, so a display plugged in mid-class moves it.
    private func meetingSurfaceTarget() -> (screen: NSScreen, form: ParticipantGridWindowController.Form)? {
        if !sessionArranges {
            let reference = peopleViewTargetScreen()
            guard let screen = reference ?? DisplayResolver.mainDisplayScreen() else { return nil }
            return (screen, .meeting(fillsScreen: reference != nil))
        }
        if let template = sessionTemplate, let target = layoutEngine.meetingTarget(template) { return target }
        guard let screen = DisplayResolver.mainDisplayScreen() else { return nil }
        return (screen, .meeting(fillsScreen: false))
    }

    /// Keeps the custom-UI meeting window in step with who is actually in the
    /// meeting.
    ///
    /// Polled rather than driven by onUserJoin/onUserLeft because the video
    /// element for a brand-new participant is not necessarily renderable the
    /// instant the join callback fires, and a poll is idempotent - it converges
    /// whether or not any single event was missed. One second, because the
    /// roster carries live state - who is talking, whose hand is up.
    private func startCustomUIGridFollow() {
        // The panel's hooks go in every time: closing the meeting window clears
        // them (ParticipantGridWindowController.close), and the follow loop can
        // outlive it while a view window is open. A reopen with the loop still
        // running must still find the panel configured.
        installGridHooks()
        // Idempotent. It is called more than once: on the first frame of a start
        // so the reference panel can show progress, and again once the meeting
        // is live. Restarting would re-stamp the session clock.
        if customUIGridTask != nil { return }
        startGridFollowLoop()
    }

    /// A view window opened during a meeting: the follow loop feeds it, so it
    /// starts again if closing the Meeting window had stopped it. The Meeting
    /// window stays closed (`meetingWindowWanted` is untouched).
    private func followForViewWindows() {
        guard phase.isInMeeting, customUIGridTask == nil else { return }
        startCustomUIGridFollow()
    }

    /// Configures the meeting window's panel and sets the hooks it calls back
    /// into. Safe to run again and again; the window's close clears them all.
    private func installGridHooks() {
        // Surface subscription refusals. A black tile with no explanation was
        // exactly how this went unnoticed until a second person joined.
        zoomChatClient.onVideoSubscribeFailure = { [weak self] message in
            self?.log(message)
        }
        ParticipantGridWindowController.configure(
            client: zoomChatClient,
            chat: zoomChatBridge,
            controls: meetingControls,
            log: { [weak self] message in self?.log(message) })
        // The window the teacher closes by hand: stop feeding it, and let the pill
        // (or the slot) take over. After the close that triggered this has finished.
        ParticipantGridWindowController.onUserClosed = { [weak self] in
            Task { @MainActor in self?.meetingWindowClosedByUser() }
        }
        // The red light and Command-W: a sheet while live, never a silent close.
        ParticipantGridWindowController.confirmClose = { [weak self] window in
            self?.confirmCloseMeetingWindow(window) ?? true
        }
        // Minimise (the yellow light, Command-M) goes one size down while a meeting
        // is live: the control bar.
        // With no meeting live, the window minimises as any other does.
        ParticipantGridWindowController.shrinkInsteadOfMinimize = { [weak self] in
            guard let self else { return false }
            let live = self.phase.isInMeeting
            let canShrink = self.zoomChatClient.didInit && self.meetingWindowOpen
            guard MeetingMinimize.outcome(meetingLive: live, canShrink: canShrink) == .shrinkToControlBar else {
                // A real minimise while live: the bar has to be there to take over (R14).
                if live { self.ensureMeetingBar() }
                return false
            }
            self.collapseMeeting()
            return true
        }
    }

    /// The one-second follow loop that drives the meeting window and the view
    /// windows. Started once; `startCustomUIGridFollow` guards that.
    private func startGridFollowLoop() {
        // A join or a leave shows at once rather than at the next poll.
        zoomChatClient.onParticipantCountChanged = {
            ParticipantGridWindowController.refreshNow()
            MeetingViewWindows.tick()
        }
        // The view windows (Active speaker, Gallery, Hands up, ...): where the layout
        // puts each, and what a few of their buttons do.
        MeetingViewWindows.configure(
            client: zoomChatClient,
            log: { [weak self] message in self?.log(message) },
            frameFor: { [weak self] view in
                guard let self, self.sessionArranges, let template = self.sessionTemplate else { return nil }
                return self.layoutEngine.viewFrame(template, view)
            },
            copyInvite: { [weak self] in self?.meetingControls?.copyInviteLink() },
            openMeetingWindow: { [weak self] in self?.openMeetingWindow() },
            keepFollowing: { [weak self] in self?.followForViewWindows() })
        let startedAt = sessionStartedAt ?? Date()
        let tick: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            // Always refresh the open view windows; drive the Meeting window only
            // when it is wanted (a layout of views alone, or one the teacher closed,
            // has none).
            MeetingViewWindows.tick()
            self.ensureMeetingBar()
            self.meetingControls?.foldPopOutChatIntoWindow()
            guard self.meetingWindowWanted || ParticipantGridWindowController.isOpen else { return true }
            guard let target = self.meetingSurfaceTarget() else { return false }
            self.ensureMeetingControls()
            ParticipantGridWindowController.controls = self.meetingControls
            let digits = self.meetingNumberDigits
            let session = ParticipantGridWindowController.SessionInfo(
                meetingNumber: digits,
                startedAt: startedAt,
                isRecording: self.isRecording,
                isSavingRecording: self.isSavingRecording,
                presetName: self.meetingPresets.first { $0.number == digits }?.name ?? "",
                readiness: self.startReadiness)
            ParticipantGridWindowController.refresh(on: target.screen, session: session, form: target.form)
            return true
        }
        if meetingSurfaceTarget() != nil {
            Analytics.track(.surfaceShown, [
                .surface: "participants",
                .placement: "main_window"
            ])
        }
        // Once now, so the window exists by the time the caller places it.
        _ = tick()
        customUIGridTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled || !tick() { return }
            }
        }
    }

    /// Consecutive pinning corrections with no stable tick in between -
    /// the fight detector for maintainPeopleViewPlacement. Reset whenever
    /// the follow loop (re)starts: session start, layout re-apply, Snap
    /// Windows Back - each of those is an explicit re-arm.
    /// Custom-UI gallery refresh. Cancelled with the session.
    /// When the current session began, for the coarse duration band reported at
    /// the end. Never sent as a timestamp - see Analytics.band(seconds:).
    /// Readable so the notes bar can time a note taken before the tape rolls.
    /// Published for the control bar's clock.
    @Published private(set) var sessionStartedAt: Date?
    /// Whether THIS session arranges windows, captured once at Start. Every gate
    /// reads this, never the live setting, so flipping the switch mid-class
    /// cannot start (or half-stop) a layout. True until a session says
    /// otherwise, so nothing outside a session behaves differently.
    @Published private(set) var sessionArranges = true

    /// Whether the layout tools (Snap Windows Back, the speaker tile toggle)
    /// mean anything right now. Off only inside a session that arranged nothing.
    var layoutToolsAvailable: Bool {
        sessionArranges || !phase.isInMeeting
    }
    private var customUIGridTask: Task<Void, Never>?
    // MARK: Meeting window (custom UI)

    /// One set of controls per session, read by the meeting window's toolbar and
    /// by the floating pill. Made when the meeting is live, dropped with it.
    private(set) var meetingControls: MeetingControlsModel?

    /// Settings key: the invite link goes on the clipboard as the meeting goes live.
    static let copyInviteOnStartKey = "copyInviteOnStart"

    /// Puts the invite link on the clipboard once the meeting is live, so it can be
    /// pasted straight into a message. On unless turned off in Settings. The link
    /// arrives a moment after the meeting starts, so it waits for it (up to 10s)
    /// rather than copying nothing. Runs once per start, never on a reconnect.
    func copyInviteWhenReady() {
        guard UserDefaults.standard.object(forKey: Self.copyInviteOnStartKey) as? Bool ?? true else { return }
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                guard let self else { return }
                if let controls = self.meetingControls, !controls.meetingFacts.joinURL.isEmpty {
                    controls.copyInviteLink()
                    self.log("Invite link copied as the meeting went live (Settings turns this off).")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self?.log("The invite link was not ready within 10 seconds, so it was not copied. Copy it from the meeting's info menu.")
        }
    }

    private func ensureMeetingControls() {
        if meetingControls == nil { meetingControls = MeetingControlsModel(coordinator: self) }
    }

    /// A live meeting always has a bar to land on: built here if it never was (or was
    /// dropped). Record-only sessions have no meeting surfaces and never get one.
    private func ensureMeetingBar() {
        guard MeetingSurfaceOwner.isLive, zoomChatClient.didInit, !recordOnlyActive,
              !MeetingControlBarController.isInstalled else { return }
        ensureMeetingControls()
        guard let controls = meetingControls else { return }
        MeetingControlBarController.install(coordinator: self, model: controls)
    }

    /// Greenroom's own meeting window exists (on screen or not).
    var meetingWindowOpen: Bool { ParticipantGridWindowController.meetingWindowIsOpen }

    /// Opens the window, or brings it back from minimised, hidden or covered,
    /// without activating the app: the teacher's slides stay in front of
    /// Greenroom's own main window.
    func openMeetingWindow() {
        guard zoomChatClient.didInit else { return }
        ensureMeetingControls()
        // The chat is a panel inside the window now; a loose chat window would
        // be a second copy of it. (An arranged session keeps its column.)
        if !sessionArranges, ChatWindowController.isOpen { ChatWindowController.close() }
        // Likewise the People pop-out: the window opens on its People panel.
        if PeoplePopOutController.isOpen {
            PeoplePopOutController.close()
            meetingControls?.sidePanel = .people
        }
        let alreadyOpen = ParticipantGridWindowController.meetingWindowIsOpen
        meetingWindowWanted = true
        // Brought up some other way: it stays the teacher's choice (the model drops its
        // "started small by itself" mark with the expand).
        MeetingSurfaceOwner.send(.expand)
        // A deliberate reopen: the room the layout gave the neighbour goes back,
        // before the window is placed, so it is placed as shown.
        giveRoomBackToMeeting()
        startCustomUIGridFollow()
        if alreadyOpen { ParticipantGridWindowController.show() }
        // R45: it comes back where it was; nothing else moves or comes forward.
        // (This used to re-place the Chat, every view and the window itself.)
        placeCustomSurfaces(trigger: .meetingShown)
        MeetingSurfaceOwner.syncWindowFacts()
    }

    // MARK: The two sizes

    /// The size the meeting is at now, read from what is on screen. A morph
    /// heading for the window counts as the window; one heading for the bar,
    /// as the bar.
    var meetingSize: MeetingSize {
        if let heading = MeetingControlBarController.morphTarget { return heading == 1 ? .window : .bar }
        guard ParticipantGridWindowController.meetingWindowIsOpen else { return .bar }
        // A live meeting: the model's answer, where a window that is only covered is
        // still the window (it is the person's size that counts, not what is in front).
        if MeetingSurfaceOwner.isLive { return MeetingSurfaceOwner.model.reopenTarget == .window ? .window : .bar }
        return ParticipantGridWindowController.meetingWindowIsHidden ? .bar : .window
    }

    /// What the layout already shows, which changes where a collapse goes.
    private var collapseContext: MeetingCollapseContext {
        MeetingCollapseContext(placedFull: ParticipantGridWindowController.isPlacedFull,
                               meetingIsSlot: ParticipantGridWindowController.isSlot)
    }

    /// One step down: the yellow light, Command-M, the top bar's Smaller button.
    /// Window to bar. The bar is the bottom.
    func collapseMeeting() {
        guard zoomChatClient.didInit else { return }
        let size = meetingSize
        guard size != .bar else { return }
        MeetingShrinkTip.markDone() // shrunk once, by any route: the tip has done its job
        move(from: size, to: MeetingCollapse.next(from: size, step: .down), step: .down, context: collapseContext)
    }

    /// The window goes to the control bar by the morph (the choice in the close
    /// prompt, which names the bar). Where the window is not showing, it is already
    /// the bar.
    func shrinkMeetingToBar() {
        guard zoomChatClient.didInit else { return }
        let size = meetingSize
        guard size != .bar else { return }
        MeetingShrinkTip.markDone()
        move(from: size, to: .bar, step: .down, context: collapseContext)
    }

    /// The bar's Meeting button: straight back to the Meeting window. A click
    /// during a morph turns it round.
    func expandMeetingFromBar() {
        guard zoomChatClient.didInit else { return }
        if MeetingControlBarController.morphTarget != nil {
            MeetingSurfaceOwner.send(.expand)
            if meetingWindowOpen { giveRoomBackToMeeting(); MeetingControlBarController.morph(toward: 1) }
            else { openMeetingWindow() }
            return
        }
        // The bar shows while the window is merely covered: bring the window up.
        guard meetingSize == .bar else { openMeetingWindow(); return }
        move(from: .bar, to: MeetingCollapse.next(from: .bar, step: .up), step: .up, context: collapseContext)
    }

    /// The active layout places a Meeting window piece (on a display that is
    /// connected). Leave my windows alone never does. Read at Start and at go-live.
    private var layoutPlacesMeeting: Bool {
        guard sessionArranges, let template = sessionTemplate else { return false }
        return layoutEngine.placesMeeting(template)
    }

    /// A start on the Bar with nothing arranged: what is shared comes to the front
    /// (a layout hands focus over itself, in finalizeLayout).
    private func bringSharedForwardOnABarStart() {
        guard !sessionArranges, MeetingSurfaceOwner.model.surface == .bar, zoomChatClient.didInit,
              MeetingControlBarController.isInstalled else { return }
        bringRecordedForward()
    }

    /// Goes to a size from wherever the meeting is.
    func moveMeeting(to size: MeetingSize) {
        guard zoomChatClient.didInit else { return }
        let from = meetingSize
        guard from != size else { return }
        move(from: from, to: size, step: size == .bar ? .down : .up, context: collapseContext)
    }

    /// The shortcut and the one click: one step the other way from where it is.
    /// Window goes down; the bar comes up. A click during a morph turns it round.
    func toggleMeetingShrunk() {
        guard zoomChatClient.didInit else { return }
        if let heading = MeetingControlBarController.morphTarget {
            heading == 0 ? expandMeetingFromBar() : shrinkMeetingToBar()
            return
        }
        switch meetingSize {
        case .window: collapseMeeting()
        case .bar: expandMeetingFromBar()
        }
    }

    /// Does the move and keeps the rest in step: the neighbour's room and the
    /// bar's visibility.
    private func move(from: MeetingSize, to wanted: MeetingSize, step: MeetingCollapse.Step,
                      context: MeetingCollapseContext) {
        var target = wanted
        // Where the bar cannot be built, the meeting stays as it is.
        if target == .bar, !MeetingControlBarController.isInstalled { target = from }
        guard target != from else { return }

        switch (from, target) {
        case (.window, .bar):
            MeetingSurfaceOwner.send(.collapse)
            giveRoomToNeighbourIfPlaced(going: .bar, context: context)
            MeetingControlBarController.morph(toward: 0)
        case (.bar, .window):
            MeetingSurfaceOwner.send(.expand)
            showWindowFromBar()
        default:
            break
        }
    }

    /// The window comes back from the bar: by the morph when it is open, else opened.
    private func showWindowFromBar() {
        if meetingWindowOpen {
            giveRoomBackToMeeting()
            MeetingControlBarController.morph(toward: 1)
        } else {
            openMeetingWindow()
        }
    }

    /// A full-size placed Meeting leaves its slot: the neighbour takes the room,
    /// the same as hiding the speaker tile.
    private func giveRoomToNeighbourIfPlaced(going size: MeetingSize, context: MeetingCollapseContext) {
        guard MeetingCollapse.neighbourTakesRoom(going: size, context: context),
              sessionArranges, let template = sessionTemplate else { return }
        speakerTileQuickHidden = true
        layoutEngine.moveNeighbour(template, meetingHidden: true)
    }

    /// The Meeting is coming back: the neighbour gives the room up, and the views
    /// that went with it return. Idempotent.
    private func giveRoomBackToMeeting() {
        guard speakerTileQuickHidden else { return }
        speakerTileQuickHidden = false
        if sessionArranges, let template = sessionTemplate {
            layoutEngine.moveNeighbour(template, meetingHidden: false)
        }
        MeetingViewWindows.setHiddenTogether(false)
    }

    func closeMeetingWindow() {
        guard customUIGridTask != nil || ParticipantGridWindowController.isOpen else { return }
        meetingWindowWanted = false
        // The follow loop also feeds the view windows: it stops only when none is open.
        if !MeetingViewWindows.anyOpen {
            customUIGridTask?.cancel()
            customUIGridTask = nil
            zoomChatClient.onParticipantCountChanged = nil
        }
        ParticipantGridWindowController.close()
        MeetingSurfaceOwner.send(.windowClosedByCode)
    }

    /// Whether the follow loop should keep Greenroom's meeting window open. False
    /// when the layout shows the meeting only as views, or the window was closed.
    private var meetingWindowWanted = true

    /// The close button. A placed Meeting counts as hidden: the neighbour that
    /// joins it grows into the room (\u{2325}\u{2318}Z, or the pill, brings it back).
    private func meetingWindowClosedByUser() {
        closeMeetingWindow()
        if sessionArranges, phase.isInMeeting, let template = sessionTemplate,
           layoutEngine.placedMeeting(template) != nil, !MeetingViewWindows.anyOpen {
            speakerTileQuickHidden = true
            layoutEngine.moveNeighbour(template, meetingHidden: true)
        }
    }

    /// The pill's Meeting window button, and People when no window is up. With
    /// the window on screen it closes it; otherwise it brings it forward.
    func toggleMeetingWindow() {
        guard zoomChatClient.didInit else { return }
        if ParticipantGridWindowController.meetingWindowIsShowing {
            closeMeetingWindow()
        } else {
            openMeetingWindow()
        }
    }

    /// Single source of truth for whether the Start action can run. The
    /// main window and menu bar previously duplicated PARTIAL versions of
    /// this - the menu bar skipped the credential/meeting-ID checks, so
    /// "Start Meeting" was clickable with no credentials and "Join
    /// Meeting" with no meeting ID (Codex design audit #1).
    var startActionDisabled: Bool {
        if !phase.canStart { return true }
        switch meetingMode {
        // Needs nothing but the camera and screen permissions, which Start checks itself.
        case .record: return false
        case .create: return !zoomHostingReady
        // Zoom meeting IDs are 9-11 digits. Gating only on "not empty" let
        // "12345" arm Start, which then ran the whole pipeline - cameras,
        // screen capture - before failing at the join, leaving
        // a half-started session to clean up.
        case .join: return meetingNumberDigits.count < 9
        }
    }


    /// Confirmation gate in front of stop() for every user-facing trigger
    /// (End Session button, menu bar item, \u{2325}\u{2318}X):
    /// ending the session is destructive - it can end the meeting for the
    /// whole class - and the system-wide hotkey especially is one stray
    /// keystroke away. Internal/automatic paths (Zoom-side meeting end,
    /// app quit) still call stop()/prepareForTermination directly: the
    /// destructive event already happened or is separately confirmed.
    /// True while a class is actually live.
    ///
    /// Excludes `isStopping`: a session already being torn down does not need a
    /// second confirmation, and asking again during teardown would be a dialog
    /// nobody can act on usefully.
    var hasLiveSession: Bool {
        phase.isLiveAndNotStopping
    }

    /// Asks before quitting out from under a live class.
    ///
    /// Quitting is not "close the window". It ends the Zoom meeting for everyone
    /// when Greenroom is hosting, drops the students, and finalises whatever is
    /// recording. ⌘Q sits one key from ⌘W and one slip from ending somebody's
    /// lesson in front of their class.
    ///
    /// Cancel is the default button, against the usual convention of making the
    /// titular action default. A teacher who hit ⌘Q by accident is exactly the
    /// person about to hit Return by reflex, and the answer that reflex gives
    /// should be the recoverable one.
    ///
    /// Returns true when quitting should proceed.
    func confirmQuitWhileLive(systemEnding: Bool = false) -> Bool {
        // Logout, shutdown and restart finish cleanly and save; nobody is there
        // to answer a question, and a question would block the system.
        if systemEnding { return true }
        guard hasLiveSession || isUploadingToYouTube else { return true }
        // The quit may have been triggered from the menu bar while another app
        // held focus, so the alert has to come forward with the app.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        if let prompt = LiveExit.quitPrompt(liveExitState) {
            alert.messageText = prompt.title
            alert.informativeText = prompt.message + (isUploadingToYouTube ? " A YouTube upload in progress is cancelled too." : "")
            Self.addButtons(prompt.choices, to: alert)
        } else {
            // Only an upload is in flight: quitting abandons it (the recording
            // itself is safe on disk and can be uploaded again from Recordings).
            let percent = Int(((youtubeUploadProgress ?? 0) * 100).rounded())
            alert.messageText = "Quit Greenroom and cancel the YouTube upload?"
            alert.informativeText = "The upload is \(percent)% done. Quitting cancels it; the recording stays in Documents/Greenroom and can be uploaded again from Recordings."
            Self.addButtons([.endMeetingAndQuit, .cancel], to: alert, firstTitle: "Quit Greenroom")
        }
        alert.alertStyle = .warning
        let response = alert.runModal()
        return response == .alertFirstButtonReturn
    }

    /// What is live, for the close and quit prompts. The host is whoever made the
    /// meeting; joining one makes you a participant.
    var liveExitState: LiveExitState {
        var s = LiveExitState()
        guard hasLiveSession else { return s }
        if phase.isRecordMode {
            s.kind = .recordOnly
        } else {
            s.kind = LiveExit.meetingKind(createdHere: meetingMode == .create, endsForAll: zoomChatClient.endsForAll)
        }
        s.isRecording = isRecording
        s.canShrink = zoomChatClient.didInit && meetingWindowOpen
        return s
    }

    /// Buttons in prompt order. The first is the action; Cancel is the default
    /// (Return) and Escape; a middle choice has no key.
    private static func addButtons(_ choices: [LiveExitChoice], to alert: NSAlert, firstTitle: String? = nil) {
        for (index, choice) in choices.enumerated() {
            let button = alert.addButton(withTitle: index == 0 ? (firstTitle ?? choice.title) : choice.title)
            button.hasDestructiveAction = choice.isDestructive
            button.keyEquivalent = choice == .cancel ? "\r" : ""
        }
        // Escape reaches Cancel, the last button, as the sheet's cancel button.
        alert.buttons.last?.keyEquivalent = "\r"
    }

    /// The meeting window's close button and Command-W. True means close as
    /// usual (nothing is live); false means a sheet is up on `window` and the
    /// close waits for the answer.
    func confirmCloseMeetingWindow(_ window: NSWindow) -> Bool {
        guard let prompt = LiveExit.closePrompt(liveExitState) else { return true }
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        Self.addButtons(prompt.choices, to: alert)
        MeetingSurfaceOwner.send(.closeRequested)
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
                guard prompt.choices.indices.contains(index) else { MeetingSurfaceOwner.send(.closeCancel); return }
                switch prompt.choices[index] {
                case .endMeetingForAll:
                    MeetingSurfaceOwner.send(.closeEnd)
                    self.stop() // hosting ends it
                case .leaveMeeting:
                    MeetingSurfaceOwner.send(.closeLeave)
                    self.stop() // otherwise leaves
                case .shrinkToControlBar:
                    // The shrink reads where the meeting is before it tells the model.
                    self.shrinkMeetingToBar()
                    MeetingSurfaceOwner.send(.closeShrink)
                default:
                    MeetingSurfaceOwner.send(.closeCancel)
                }
            }
        }
        return false
    }

    /// Where a Dock click, Show Greenroom or the menu bar's live header goes.
    private var reopenState: LiveExit.ReopenState {
        var s = LiveExit.ReopenState()
        s.isLive = hasLiveSession
        s.hasMeetingSurfaces = zoomChatClient.didInit && !recordOnlyActive
        s.meetingShrunk = MeetingSurfaceOwner.isLive
            ? MeetingSurfaceOwner.model.reopenTarget == .bar
            : ParticipantGridWindowController.meetingWindowIsHidden
        return s
    }

    /// True when it brought a meeting surface forward (so no main window is
    /// needed); false means the caller shows the main window, which reads the
    /// live state. A deliberate click, so the app activates.
    @discardableResult
    func bringLiveSessionForward() -> Bool {
        let state = reopenState
        guard LiveExit.reopenHandledByMeeting(state) else {
            // Record-only, window hidden for it: the recording bar is the way back,
            // not the main window.
            if state.isLive, mainWindowHiddenForSession {
                recordingChrome.bringBarForward()
                return true
            }
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        switch LiveExit.reopenTarget(state) {
        case .meetingWindow:
            MeetingSurfaceOwner.send(.reopen)
            if ParticipantGridWindowController.meetingWindowIsOpen {
                ParticipantGridWindowController.show()
                ParticipantGridWindowController.makeMeetingWindowKey()
            } else {
                openMeetingWindow()
            }
        case .controlBar:
            // No bar built is a dead end, so fall back to the first surface that
            // exists: the Meeting window.
            if !MeetingControlBarController.bringForward() { openMeetingWindow() }
        case .mainWindow:
            return false
        }
        return true
    }

    func confirmAndStop() {
        // A take that is rolling asks first, the way End does (owner,
        // 2026-11-15). One still starting or counting down has nothing to
        // lose yet, so it stops at once.
        if phase.isRecordMode {
            if recordOnlyActive, isRecording { confirmStopTake() } else { stopRecordingSession() }
            return
        }
        guard phase.isInMeeting else { return }
        // Asked in place, like the meeting window's End: the first press arms
        // End (the button turns into Confirm), the second ends. No alert (it
        // went to the main window's desktop, which may be empty) and no
        // buttons in the island, which only says what Confirm will do.
        if exitAsk == .end, endConfirm.press(now: Date()) == .end {
            // One click on Confirm ends it, whatever else is on screen.
            disarmExit()
            stop()
            endConfirm.reset()
            return
        }
        let ask = LiveExit.endPrompt(liveExitState)
        let action = ask?.choices.first ?? .endMeetingForAll
        let title = action == .leaveMeeting ? "Leave the meeting?" : "End the meeting for everyone?"
        let again = action == .leaveMeeting ? "Press Confirm to leave." : "Press Confirm to end it."
        armExit(.end, title: title, detail: "\(again) Esc keeps it going.")
        _ = endConfirm.press(now: exitAskStartedAt ?? Date())
    }

    /// What the armed End does, for the buttons' Confirm help.
    var exitConfirmHelp: String {
        switch exitAsk {
        case .stopTake, .stopRecording: return "Stop and save the recording"
        case .end: return (LiveExit.endPrompt(liveExitState)?.choices.first ?? .endMeetingForAll).title
        case nil: return ""
        }
    }

    /// The menu bar's "Snap Windows Back": re-tiles everything to the
    /// session layout after the user has dragged windows around - the apps, the
    /// chat and the meeting window - through the same engine that placed them.
    ///
    /// `userInitiated: false` is the same re-tiling after a display change or a
    /// layout edit: it leaves the person's \u{2325}\u{2318}Z choice and the usage
    /// count alone.
    func snapWindowsBack(userInitiated: Bool = true, trigger: PlacementTrigger = .snapBack) {
        guard layoutToolsAvailable else {
            log("Snap Windows Back skipped \u{2014} this session arranges no windows.")
            return
        }
        guard let chosen = sessionTemplate ?? layoutLibrary.active, chosen.movesWindows else {
            log("Snap Windows Back skipped \u{2014} the layout moves no windows.")
            return
        }
        reapplyLayout(userInitiated: userInitiated, openApps: false, trigger: trigger)
    }

    /// Re-places everything from the session's layout (or, outside a class, the
    /// one chosen in Settings), re-resolved against the displays as they are NOW.
    /// `openApps` also opens the apps that open at start (Apply now).
    ///
    /// Only the passes the owner asked for come here (R45): Snap Back, Apply now
    /// and a display plugged in or pulled out. `LayoutPlacementRules` says so.
    private func reapplyLayout(userInitiated: Bool, openApps: Bool, trigger: PlacementTrigger) {
        guard LayoutPlacementRules.isExplicit(trigger) else { return }
        guard let template = sessionTemplate ?? layoutLibrary.active, template.movesWindows else { return }
        liveEditWaitingForSnap = false
        if userInitiated {
            Analytics.feature("snap_back")
            // Back to the layout's own starting state: hidden if the Meeting
            // starts hidden, shown otherwise.
            speakerTileQuickHidden = layoutEngine.startsHidden(template)
            resetPresenceBubbleToLayoutDefault(at: .snapBack)
            // R5.3: the layout's own share returns.
            adoptLayoutPieces(LayoutPieceAdoption.atSnapBack(template))
        } else if !layoutEngine.hasPlacedSurface(template) {
            // A display change can turn a placed Meeting into a whole-display one
            // (or take it away): nothing is hidden then.
            speakerTileQuickHidden = false
        }
        let hidden = speakerTileQuickHidden
        Task {
            await layoutEngine.apply(template, open: openApps, meetingHidden: hidden)
        }
        // Snap Back is also the manual "fix the composite" action: hand the
        // picture its settings again alongside the window re-tiling.
        applyShapeForPreview()
        // The meeting's own windows exist only while a class does.
        guard phase.isInMeeting else { return }
        // Our own windows: re-place them.
        presentMeetingSurfaces(trigger: trigger)
    }

    // MARK: Displays coming and going

    /// One registration, at launch. Everything that reacts to a display being
    /// plugged in or pulled out hangs off the monitor\u{2019}s settled event, so
    /// there is exactly one place to read to learn what happens.
    private func observeDisplays() {
        ParticipantGridWindowController.readinessDismiss = { [weak self] in self?.dismissStartFailure() }
        ParticipantGridWindowController.readinessTryAgain = { [weak self] in self?.retryAfterFailure() }
        DisplayMonitor.shared.onChange { [weak self] change in self?.displaysChanged(change) }
        // R45.6: a desktop switch keeps Greenroom's windows stacked as they were.
        WindowStackKeeper.shared.start { [weak self] line in self?.log(line) }
    }

    /// The failure card\u{2019}s Close: clears the card and what drew it.
    private func dismissStartFailure() {
        guard !isRunning else { return }
        customUIGridTask?.cancel()
        customUIGridTask = nil
        ParticipantGridWindowController.close()
        ReadinessHUDController.close()
        recordFlowHUD = false
        finishStartReadiness()
    }

    /// The failure card\u{2019}s Try again: wait for the unwind of the failed start
    /// to finish (the Start guard refuses anything while it runs), then Start.
    private func retryAfterFailure() {
        if startFailureFix == .openOwnZoomApps {
            startFailureFix = nil
            dismissStartFailure()
            openZoomOwnApps()
            return
        }
        dismissStartFailure()
        Task {
            for _ in 0..<50 where phase.isStartOrStopInFlight {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if lastStartWasRecordFlow { startRecordingFlow() } else { start() }
        }
    }

    /// The displays have settled after a plug or unplug. In order: say what
    /// happened; keep the class picture on a display that exists (it never goes
    /// black meanwhile); bring in any window of ours stranded on a screen that
    /// is gone; and re-tile the workspace against the arrangement that is there
    /// now. The meeting itself is not touched - the picture keeps flowing to
    /// Zoom through the same sender.
    private func displaysChanged(_ change: DisplayMonitor.Change) {
        let now = DisplayMonitor.describe(change.after)
        if change.displaySetChanged {
            var parts: [String] = []
            if !change.removed.isEmpty { parts.append("\(change.removed.count) unplugged") }
            if !change.added.isEmpty { parts.append("\(change.added.count) connected") }
            log("Displays changed (\(parts.joined(separator: ", "))). Now: \(now).")
        } else {
            log("Display settings changed (resolution or arrangement). Now: \(now).")
        }

        stage?.displaysDidChange(connected: DisplayMonitor.connectedForCapture(),
                                 main: LocalDeviceResolver.mainDisplayUUID,
                                 displaySetChanged: change.displaySetChanged)
        refreshCaptureDisplay()
        // R45.7: only after the displays settle, and only a window on no screen.
        DisplayMonitor.shared.scheduleRescue { [weak self] line in self?.log(line) }
        syncReadinessHUD()

        if isRunning {
            displayChangedDuringStart = true
            return
        }
        guard stageLive, zoomChatClient.isJoined, sessionArranges else { return }
        // R45: a display plugged in or pulled out places everything again, as
        // before. The same displays with a new resolution, arrangement or Dock
        // move nothing (stranded windows were rescued above); Snap Back does.
        let trigger: PlacementTrigger = change.displaySetChanged ? .displaysConnectedOrDisconnected : .displaySettingsChanged
        if LayoutPlacementRules.isExplicit(trigger) {
            snapWindowsBack(userInitiated: false, trigger: trigger)
        } else {
            log("Your windows stay where they are. \(ShortcutStore.phrase(.snapBack)) or Snap Windows Back places the layout again.")
        }
    }

    /// The Open Greenroom / Open Sessions shortcuts. From the menu bar, SwiftUI's
    /// openWindow recreates a closed window; here there is no view to ask, so a
    /// closed window is brought back by reopening the app (the same event as a
    /// Dock click, which the Window scene answers by recreating it).
    func bringMainWindowForward() {
        mainWindowOpenedOnPurpose()
        if MainWindow.current != nil {
            showMainWindow()
        } else {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                               configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Menu bar's "Show Greenroom" - surfaces the main window.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        MainWindow.current?.makeKeyAndOrderFront(nil)
    }

    /// The create-mode meeting, made WHILE the picture comes up (see the async
    /// lets in start()). nil in join mode - the guard at the use site is
    /// unreachable by construction.
    private func prepareMeetingIfNeeded() async throws -> ZoomServerToServerClient.CreatedMeeting? {
        guard meetingMode == .create else { return nil }
        // Both are network calls to Zoom. The clean-up is a courtesy and is
        // dropped if slow; the creation is the step the whole start needs.
        // They run side by side: Zoom's one-live-meeting rule only bites when
        // the SDK starts the new meeting, and this function returns (so
        // startAsHost can run) only after the clean-up has finished or timed out.
        async let staleCheck: Void = runStaleCheck()
        let created: ZoomServerToServerClient.CreatedMeeting
        do {
            created = try await withStartTimeout(30, step: "Creating the meeting",
                advice: "Check your internet connection and the Server-to-Server credentials in Settings (\u{2318},) \u{2192} Zoom, then press Try again.") {
                try await self.createMeetingViaAPI()
            }
        } catch {
            await staleCheck
            throw error
        }
        await staleCheck
        // Ended only now that the new meeting's id is known, so it can never
        // be the one that is ended.
        await endStaleMeetings(except: created.number)
        return created
    }

    private var staleLiveFound: [Int64] = []

    private func runStaleCheck() async {
        do {
            try await withStartTimeout(15, step: "Checking for meetings left running",
                                       advice: "Carrying on without it.") { await self.findStaleLiveMeetings() }
        } catch let error as StartTimeoutError {
            Self.sessionLog("Pre-flight: \(error.localizedDescription)")
        } catch {}
    }

    /// Ends any meeting still live on the account before starting a new one.
    ///
    /// Zoom allows a host exactly one live meeting. A previous one left
    /// running - after a crash, a force quit, or anything else that skipped
    /// the termination path that ends it - collides with the new one, and Zoom
    /// resolves the collision by ending a meeting itself. From inside the SDK
    /// that arrives as status Ended with reason None, reported as "the meeting
    /// ended before Greenroom finished joining": a start that sits on the
    /// Meeting step and then gives up, with nothing on screen explaining why.
    ///
    /// Ending it deliberately is strictly better than letting Zoom pick which
    /// of the two dies. It is still someone's live meeting, so it is never
    /// silent - the status log names how many and says it is doing it.
    ///
    /// Logs the clean case too. Finding nothing live is the result that
    /// DISPROVES this being the cause of a failed start, and that is worth as
    /// much as finding something when the next one goes wrong.
    private func findStaleLiveMeetings() async {
        staleLiveFound = []
        guard let access = zoomAccess else { return }
        let live = await access.liveMeetings()
        staleLiveFound = live
    }

    private func endStaleMeetings(except newNumber: String) async {
        let live = staleLiveFound.filter { String($0) != newNumber }
        staleLiveFound = []
        guard !live.isEmpty else {
            Self.sessionLog("Pre-flight: no meetings already live on the account.")
            return
        }
        log("\(live.count) meeting\(live.count == 1 ? " is" : "s are") still live on your Zoom account "
            + "\u{2014} ending \(live.count == 1 ? "it" : "them") first, or this start would collide.")
        for id in live {
            let ended = await zoomAccess?.endMeetingReporting(id: id).ok ?? false
            Self.sessionLog("Pre-flight: ending stale meeting \(id) \(ended ? "succeeded" : "FAILED")")
        }
    }

    /// Lets a previous meeting finish tearing down before a new one starts.
    ///
    /// Silent on the common path - back-to-back sessions are the only time
    /// there is anything to wait for, and that is exactly when the start used
    /// to fail. Says so only if the wait is long enough to notice, so the
    /// readiness card explains the pause rather than just sitting there.
    private func settleBeforeJoining() async {
        // Not in the middle of a cable being plugged or pulled. A live run
        // that lost its display during this exact step got Zoom error 22 on
        // installing the picture and then a meeting that never connected.
        // Only a start that opened apps or places windows has windows to protect;
        // any other start joins without waiting for the screens (up to 6 s).
        if StartChoreography.needsDisplayQuiet(opensApps: startOpenedApps, arranges: sessionArranges) {
            let quietStarted = Date()
            if !(await DisplayMonitor.shared.awaitQuiet()) {
                log("A display is still changing \u{2014} starting anyway. If this start fails, wait a few seconds after plugging or unplugging a screen, then press Try again.")
            } else if Date().timeIntervalSince(quietStarted) > 1 {
                log("Waited for the screens to settle before joining.")
            }
        }
        let started = Date()
        let idle = await zoomChatClient.awaitMeetingIdle()
        let waited = Date().timeIntervalSince(started)
        if !idle {
            log("The previous meeting is still closing \u{2014} starting anyway. If this start fails, wait a moment and press Start again.")
        } else if waited > 1 {
            log("Waited \(Int(waited.rounded()))s for the previous meeting to finish closing.")
        }
    }

    /// Warms the Zoom SDK auth in parallel with the picture coming up.
    /// Errors are swallowed here on purpose: the meeting flows call
    /// ensureReady again (now a no-op on success), and THEIR failure
    /// path carries the real error to the log.
    private func prefetchSDKAuth() async {
        guard let signer = try? zoomSDKSigner() else { return }
        try? await zoomChatClient.ensureReady(signer: signer)
    }

    /// Quietly gets the two slow, silent parts of Start done while idle: the
    /// Server-to-Server token (cached in ZoomServerToServerClient) and the
    /// Meeting SDK init + auth (ensureReady is idempotent and de-duplicates
    /// with a later call). Neither opens UI or asks for a permission; the
    /// secrets are plain UserDefaults, not Keychain. Skipped while a session
    /// is running or starting.
    func warmUpForStart() {
        guard !phase.isStartOrStopInFlight, !isConnectingChat else { return }
        loadSecretsIfNeeded()
        let access = zoomAccess
        Task { [weak self] in
            await access?.warm()
            guard let self, let signer = try? self.zoomSDKSigner() else { return }
            guard !self.phase.isStartOrStopInFlight, !self.isConnectingChat else { return }
            try? await self.zoomChatClient.ensureReady(signer: signer)
        }
    }

    private func createMeetingViaAPI() async throws -> ZoomServerToServerClient.CreatedMeeting {
        log("Creating a new meeting\u{2026}")
        guard let access = zoomAccess else {
            throw NSError(domain: "Greenroom", code: 26, userInfo: [
                NSLocalizedDescriptionKey: zoomRouteMissingText
            ])
        }
        let meeting = try await access.startInstantMeeting(topic: "Greenroom Meeting")
        meetingNumber = meeting.number
        meetingPassword = meeting.password
        meetingCreatedHere = meeting.number
        log("Meeting \(meeting.number) created.")
        return meeting
    }

    // MARK: Scheduled meetings - pulled from the Zoom account with the
    // same S2S credentials that create meetings, so the My Meetings tab can
    // offer the account's recurring class meeting instead of making the
    // user paste an ID every morning.

    @Published private(set) var scheduledMeetings: [ZoomServerToServerClient.ScheduledMeeting] = []
    /// The account's personal room (PMI), pinned first on the My Meetings list.
    /// nil without the scope or a PMI: the list works without it.
    @Published private(set) var personalRoom: ZoomPersonalRoom?
    @Published private(set) var isLoadingScheduled = false

    /// What the My Meetings picker lists: the personal room first, then the meetings.
    var scheduledEntries: [ScheduledEntry] {
        ScheduledListRules.entries(room: personalRoom, meetings: scheduledMeetings)
    }

    func refreshScheduledMeetings() {
        loadSecretsIfNeeded()
        guard !isLoadingScheduled else { return }
        guard let access = zoomAccess else {
            log("Can't list your Zoom meetings \u{2014} \(zoomRouteMissingText)")
            return
        }
        isLoadingScheduled = true
        Task {
            // Its own call, so a missing user scope never costs the list.
            switch await access.personalRoom() {
            case .room(let room): personalRoom = room
            case .noRoom: personalRoom = nil
            case .missingScope:
                personalRoom = nil
                log("Your personal room isn\u{2019}t listed: Zoom didn\u{2019}t allow reading it. Check Zoom setup shows the permission to add.")
            case .failed(let message):
                personalRoom = nil
                log("Couldn\u{2019}t read your personal room: \(message)")
            }
            do {
                let result = try await access.listScheduledMeetings()
                scheduledMeetings = result.meetings
                if let warning = result.warning { log(warning) }
                if scheduledMeetings.isEmpty && personalRoom == nil {
                    log("No scheduled meetings on this Zoom account. Recurring ones scheduled at zoom.us/meeting/schedule will show up here.")
                }
            } catch {
                log(error.localizedDescription)
            }
            isLoadingScheduled = false
        }
    }

    /// Fills the meeting number from a picked scheduled meeting.
    /// The list endpoint omits the raw passcode, but the join URL carries
    /// it in the encrypted pwd= form joins accept - the same parsing as
    /// Paste Link.
    func selectScheduledMeeting(_ meeting: ZoomServerToServerClient.ScheduledMeeting) {
        Analytics.feature("scheduled_pick")
        if let parsed = ZoomMeetingLinkParser.parse(meeting.joinURL) {
            meetingNumber = parsed.number
            meetingPassword = parsed.password
        } else {
            meetingNumber = String(meeting.id)
            meetingPassword = ""
        }
        log("Selected \u{201C}\(meeting.topic)\u{201D} (\(meetingNumber)).")
        // Warm the host key while the human reaches for Start - own
        // meetings get host-started with a ZAK, and this fetch is pure
        // network time otherwise sitting inside the start.
        prefetchZAK(for: meetingNumberDigits)
    }

    /// Fills the meeting number from the personal room: its PMI, and the
    /// passcode its link carries, if any (the host start needs none).
    func selectPersonalRoom(_ room: ZoomPersonalRoom) {
        Analytics.feature("personal_room_pick")
        meetingNumber = room.meetingNumber
        meetingPassword = ZoomMeetingLinkParser.parse(room.joinURL)?.password ?? ""
        log("Selected your personal room (\(room.spacedNumber)).")
        prefetchZAK(for: meetingNumberDigits)
    }

    func selectScheduledEntry(_ entry: ScheduledEntry) {
        switch entry {
        case .personalRoom(let room): selectPersonalRoom(room)
        case .meeting(let meeting): selectScheduledMeeting(meeting)
        }
    }

    /// Schedules a meeting on the Zoom account, then refreshes the list,
    /// picks the new one, and copies its invite link. Throws Zoom's error so
    /// the sheet can show it.
    func createScheduledMeeting(_ spec: NewMeetingRequest) async throws {
        loadSecretsIfNeeded()
        let access = try requireZoomAccess()
        let created = try await access.createScheduledMeeting(spec)
        Analytics.feature("scheduled_create")
        if let result = try? await access.listScheduledMeetings() {
            scheduledMeetings = result.meetings
        }
        let meeting = scheduledMeetings.first { $0.id == created.id }
            ?? ZoomServerToServerClient.ScheduledMeeting(
                id: created.id, topic: created.topic, startTime: nil,
                isRecurring: spec.weekly, joinURL: created.joinURL)
        if !scheduledMeetings.contains(where: { $0.id == created.id }) { scheduledMeetings.append(meeting) }
        selectScheduledMeeting(meeting)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(created.joinURL, forType: .string)
        log("Created \(created.topic). Invite link copied.")
    }

    private func requireZoomAccess() throws -> ZoomRESTAccess {
        guard let access = zoomAccess else {
            throw NSError(domain: "Greenroom", code: 27, userInfo: [
                NSLocalizedDescriptionKey: zoomRouteMissingText
            ])
        }
        return access
    }

    /// What the edit sheet pre-fills from.
    func loadMeetingForEdit(id: Int64) async throws -> NewMeetingRequest {
        loadSecretsIfNeeded()
        return NewMeetingRequest.parse(try await requireZoomAccess().meetingDetails(id: id))
    }

    /// Saves an edit, refreshes the list and keeps the meeting selected.
    func updateScheduledMeeting(id: Int64, _ spec: NewMeetingRequest) async throws {
        loadSecretsIfNeeded()
        let access = try requireZoomAccess()
        try await access.updateScheduledMeeting(id: id, spec)
        if let result = try? await access.listScheduledMeetings() {
            scheduledMeetings = result.meetings
        }
        if let meeting = scheduledMeetings.first(where: { $0.id == id }) { selectScheduledMeeting(meeting) }
        log("Saved \(spec.trimmedName).")
    }

    /// Deletes the meeting, refreshes the list and clears the selection.
    func deleteScheduledMeeting(id: Int64, name: String) async throws {
        loadSecretsIfNeeded()
        let access = try requireZoomAccess()
        try await access.deleteScheduledMeeting(id: id)
        scheduledMeetings.removeAll { $0.id == id }
        if let result = try? await access.listScheduledMeetings() {
            scheduledMeetings = result.meetings
        }
        if meetingNumberDigits == String(id) { meetingNumber = ""; meetingPassword = "" }
        log("Deleted \(name).")
    }

    private var prefetchedZAK: (meetingNumber: String, zak: String, fetchedAt: Date)?

    /// The warmed host key for the chosen scheduled meeting, if it is still fresh.
    private func validPrefetchedZAK() -> String? {
        guard let p = prefetchedZAK, p.meetingNumber == meetingNumberDigits,
              Date().timeIntervalSince(p.fetchedAt) < 600 else { return nil }
        return p.zak
    }

    private func prefetchZAK(for number: String) {
        guard let access = zoomAccess else { return }
        Task {
            if let zak = try? await access.fetchZAK() {
                prefetchedZAK = (number, zak, Date())
            }
        }
    }

    /// The reference display: the one the layout's Meeting piece fills (the
    /// layout's own second-display rule, resolved now), nil when the layout has
    /// no such piece or the display is not connected. A session that arranges
    /// nothing uses the first other display, if there is one.
    private func peopleViewTargetScreen() -> NSScreen? {
        if sessionArranges, let template = sessionTemplate {
            return layoutEngine.referenceScreen(template)
        }
        return DisplayResolver.firstSecondaryScreen()
    }

    /// Whether this session should put the gallery on another display: the layout
    /// has a Meeting that fills one AND that display exists right now. A class that
    /// arranges nothing never does.
    private var peopleViewWanted: Bool {
        sessionArranges && sessionTemplate != nil && peopleViewTargetScreen() != nil
    }

    /// The z-order finale: Zoom reduced to just the parked meeting tile,
    /// Greenroom's own window out of the way at the back, and the main
    /// pane's app active as the thing the user actually works in.
    /// Idempotent - runs after the chat window appears AND after the Zoom
    /// window parks, whichever finishes last wins.
    private func finalizeLayout() {
        // Title match, minus the browser: its title is the page's, and the
        // default home page is our own site.
        for window in NSApp.windows
        where window.isVisible && MainWindow.matches(window) && !BrowserWindowController.owns(window) {
            window.orderBack(nil)
        }
        // The largest App piece on the main display is what the teacher works in.
        if let template = sessionTemplate { layoutEngine.activateLargestApp(template, after: .start) }
    }

    private func runPipeline() async throws {
        try await buildScene()
        // Installed before the meeting opens: it applies at once if the SDK is
        // already signed in, and right after sign-in if it is not.
        zoomChatClient.useStageVideo(stage)
        apply(.meetingPictureUp)

        if cameraDirectorSettings.isUsable {
            // Nothing else may hold a camera once the director owns them.
            cameraProbe.stop()
        }
        log("Ready \u{2014} Greenroom is sending its own picture to the meeting.")
    }

    /// The picture must be IN the meeting before the meeting opens. If Zoom
    /// refuses it (after the client\u{2019}s own retries) the start stops here, with
    /// the reason in plain words, instead of becoming a class that sees nothing.
    private func ensurePictureInstalled() async throws {
        let installed = try await withStartTimeout(25, step: "Putting your picture into the meeting",
            advice: "Press Try again. If it keeps happening, quit and reopen Greenroom.") {
            await self.zoomChatClient.awaitStageVideo()
        }
        guard installed else {
            throw ZoomMeetingSDKError.videoInstallFailed(detail: zoomChatClient.stageVideoFailure ?? "no answer from Zoom")
        }
    }

    /// Said once the meeting client is ready and before it joins, so a picture
    /// that could not be installed is named while it can still be acted on.
    private func reportMeetingVideo() {
        if zoomChatClient.stageVideoActive {
            log("Meeting video: Greenroom sends its own picture. There is no camera to pick in Zoom.")
        } else {
            log("Meeting video: Greenroom couldn\u{2019}t install its picture in the meeting (details in the session log), so your video may be blank. Ending and starting again usually clears it.")
        }
    }

    /// The picture half of a Start: the compositor up, the first camera open,
    /// the screen capture running, and the recorder ready - everything a
    /// meeting and a Record-mode recording share, which is the point of there
    /// being one Webcam page. Says out loud anything that did not come out as
    /// set.
    private func buildScene() async throws {
        guard let stage = ensureStage() else {
            throw NSError(domain: "Greenroom", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Greenroom couldn\u{2019}t set up its picture (the graphics system said no). Quit and open Greenroom again, then try Start."
            ])
        }
        // The first camera only. The rest join once the meeting is live -
        // see bringInExtraCameras.
        // A preview's director holds the extra cameras; a session brings its
        // own in once the meeting is live.
        cameraDirector.stop()
        stageCameraUIDs = sceneCameraUIDs(limit: 1)
        let configuration = makeStageConfiguration()
        let wantsScreen = configuration.share.kind.capturesScreen

        // A first Start on a new Mac: macOS asks now, and applies a yes only after a
        // relaunch. The Picture step fails in words rather than reporting done for a
        // meeting that would see no screen.
        if let reason = StartChoreography.screenRecordingFailure(wantsScreen: wantsScreen,
                                                                 screenRecordingGranted: StageCompositor.screenRecordingGranted) {
            log("Screen Recording is off, so the screen can\u{2019}t be shared. macOS is asking now.")
            StageCompositor.requestScreenRecordingAccess()
            throw NSError(domain: "Greenroom", code: 11, userInfo: [NSLocalizedDescriptionKey: reason])
        }

        let recorder = SessionRecorder(source: stage, microphoneUID: micDeviceUID, log: { [weak self] line in
            Task { @MainActor in self?.log(line) }
        })
        recorder.onUnexpectedStop = { [weak self] message in
            Task { @MainActor in self?.recorderStoppedItself(message) }
        }
        recorder.recordsSystemAudio = recordSystemAudio
        stage.onSystemAudio = { [weak recorder] buffer in recorder?.appendSystemAudio(buffer) }
        self.recorder = recorder
        wireInputEvents(recorder, stage: stage)

        log("Starting the picture (screen + webcam)\u{2026}")
        let probe = StageFrameProbe()
        stage.addSink(probe)
        defer { stage.removeSink(probe) }
        stage.start(configuration)
        RoomScreen.setCompositor(stage)     // a Room screen shows what the meeting now gets
        stage.cut(toSlot: 0, fade: 0)
        attachPreview()

        // The first composited frame, with the screen and the camera in it
        // when they are going to be. A source that has not come by then is
        // reported below and the start carries on: a class can begin on
        // the camera alone, but not on a silent failure.
        let wantsCamera = configuration.normalizedLayout.opensCamera && !configuration.cameraUIDs.isEmpty
        let screenExpected = wantsScreen && StageCompositor.screenRecordingGranted
        let began = Date()
        while Date().timeIntervalSince(began) < 8 {
            try Task.checkCancellation()
            if probe.hasFrame,
               !screenExpected || stage.status.screenLive,
               !wantsCamera || stage.status.camerasLive.first == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        // Done only with a picture: no frame at all is a meeting with no video.
        if let reason = StartChoreography.pictureFailure(gotFrame: probe.hasFrame, waitedSeconds: 8) {
            throw NSError(domain: "Greenroom", code: 12, userInfo: [NSLocalizedDescriptionKey: reason])
        }
        reportStageStart(stage.status, configuration: configuration,
                         wantsScreen: screenExpected, wantsCamera: wantsCamera)
    }

    /// Clicks and keystrokes beside each recording (`<video>.events.json`), for
    /// the editor's click ripples, key chips and auto-zoom. Meeting and
    /// Record-mode recordings both come through `buildScene`, so one hook
    /// covers both. Only while a screen is shared and Accessibility is on;
    /// otherwise the tracker does nothing (no prompt from here).
    /// `t` is the recorder's own clock (seconds since the file's first frame),
    /// and positions come from where the stage drew the screen.
    private func wireInputEvents(_ recorder: SessionRecorder, stage: StageCompositor) {
        recorder.onRecordingStarted = { [weak self, weak recorder, weak stage] in
            guard let self, let recorder, let stage, self.shareTarget.kind.capturesScreen else { return }
            self.inputEvents.start(
                // Seconds into the file on the paused-adjusted clock; nil
                // while paused, so nothing done during a pause is logged.
                elapsed: { [weak recorder] in
                    guard let recorder, !recorder.isPaused else { return nil }
                    return recorder.elapsedMilliseconds.map { Double($0) / 1000 }
                },
                locate: { [weak stage] point in stage?.videoPosition(ofGlobalPoint: point) })
        }
        recorder.onRecordingEnded = { [weak self] url in
            self?.inputEvents.stopAndSave(nextTo: url)
        }
    }

    private func reportStageStart(_ status: StageStatus, configuration: StageConfiguration,
                                  wantsScreen: Bool, wantsCamera: Bool) {
        if configuration.cameraUIDs.isEmpty, !cameraRuns {
            log("No camera, as set in Settings \u{2192} Layouts \u{2014} the picture is what you share.")
        } else if configuration.cameraUIDs.isEmpty {
            log("No webcam connected \u{2014} running screen-only. Plug a camera in and press Start to bring your video back.")
        } else if wantsCamera, status.camerasLive.first != true {
            let name = LocalDeviceResolver.cameraName(uid: configuration.cameraUIDs[0]) ?? "The camera"
            log("\u{201C}\(name)\u{201D} hasn\u{2019}t sent a picture yet. It may be unplugged, or in use by another app. The class sees the screen until it does.")
        }
        if shareTarget.sharesNothing {
            log("Nothing shared, as set in Settings \u{2192} Layouts \u{2014} your camera fills the picture.")
        }
        if shareTarget.kind == .whiteboard {
            log("Sharing the whiteboard \u{2014} what you draw on the page is the picture.")
        }
        if let reason = status.shareFallback {
            log("\(reason) \u{2014} sharing the whole screen instead. Open it and press Start again, or change what you share in Settings (\u{2318},) \u{2192} Layout.")
            Notifier.post(title: "Sharing the whole screen",
                          body: "\(reason), so everyone sees your whole screen.")
        } else if let label = status.shareLabel {
            log("Sharing only \u{201C}\(label)\u{201D}.")
        }
        if status.displayFellBack {
            log("The screen you picked to share isn\u{2019}t plugged in \u{2014} sharing the main display instead. Change it in Settings (\u{2318},) \u{2192} Layout.")
        }
        // Never let a black picture ship silently: this is the one thing a
        // class cannot work without.
        if wantsScreen, !status.screenLive {
            if let label = status.shareLabel {
                // A window or app that came up empty is nearly always one that is
                // minimised or on another Space, not a broken capture.
                log("\u{201C}\(label)\u{201D} came up blank \u{2014} it needs to be open on this screen, not minimised or on another desktop. Bring it here, then End and press Start.")
                Notifier.post(title: "Shared window is blank",
                              body: "\u{201C}\(label)\u{201D} isn\u{2019}t on this screen. Bring it here and start again.")
            } else {
                log("The screen capture hasn\u{2019}t started \u{2014} the class sees your camera only. \(status.lastError ?? "End the session and press Start to try again, or pick a different screen in Settings (\u{2318},) \u{2192} Layout.")")
                Notifier.post(title: "Screen sharing is blank",
                              body: "Greenroom couldn\u{2019}t capture the screen. Check Settings \u{2192} Layout and Screen Recording permission.")
            }
        }
    }

    /// The recorder stopped on its own (disk nearly full, the writer failed).
    /// What was written is kept; this tidies up the same way a normal stop
    /// would, and says so.
    private func recorderStoppedItself(_ message: String) {
        guard isRecording else { return }
        apply(.recorderStoppedItself)
        Analytics.track(.recordingEnd, [
            .durationBand: Analytics.band(seconds: recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
        ])
        recordingStartedAt = nil
        Notifier.post(title: "Recording stopped", body: message)
        if let url = recorder?.recordingURL, FileManager.default.fileExists(atPath: url.path) {
            let marks = adoptPendingClips(recordedAt: url.path)
            log("Recording kept: \(url.path)" + (marks > 0 ? " (\(marks) clip\(marks == 1 ? "" : "s") marked)" : ""))
            recordingFinished(path: url.path)
        }
    }

    /// Names shortcuts another app has already claimed, so a dead key is
    /// explained rather than just dead.
    func reportUnavailableShortcuts(_ labels: [String]) {
        let list = labels.joined(separator: ", ")
        log("These shortcuts are already taken by another app and will not work: \(list). Quit whatever owns them, or use the menu bar icon instead.")
    }

    /// Internal, not private: the YouTube extension lives in its own file
    /// and writes to the same status log.
    func log(_ message: String) {
        statusLines.append(message)
        Self.sessionLog(message)
        // The readiness card shows the step; this shows what that step is
        // actually doing. A start can legitimately sit on "Meeting" for a
        // couple of minutes (the SDK join watchdog alone is 120s), and a bare
        // spinner for that long is indistinguishable from a hang - which is
        // exactly how it was reported.
        if !startReadiness.steps.isEmpty { startReadiness.detail = message }
    }

    /// The same lines the main window shows, on disk with timestamps.
    ///
    /// They only ever lived in `statusLines`, which is an in-window view that
    /// the centred readiness card covers - so when a start stalled, the one
    /// stream of text that says WHY was both invisible to the teacher and gone
    /// the moment the app quit. Every diagnosis of a stalled start starts here.
    static func sessionLog(_ message: String) {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(stamp.string(from: Date())) \(message)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Greenroom-session.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// The one up-front decision in the single-button flow: does Start create
/// a fresh meeting, or start one of your scheduled meetings?
enum MeetingMode: String, CaseIterable, Identifiable {
    case create, join
    /// No meeting: the Webcam page's picture recorded to this Mac. See
    /// `startRecordingFlow`.
    case record

    var id: String { rawValue }

    /// The raw value "join" is what older versions saved, so it keeps loading
    /// into the My Meetings tab.
    static let scheduledHelp = "Your personal room and the meetings scheduled on your Zoom account. To join someone else\u{2019}s meeting, use the Zoom app."

    var label: String {
        switch self {
        case .create: return "New Meeting"
        case .join: return "My Meetings"
        case .record: return "Record"
        }
    }

    /// The toolbar switcher's words: short, so the switcher, Sessions, Help and
    /// Settings all fit a 560pt window without an overflow chevron.
    var shortLabel: String {
        switch self {
        case .create: return "New"
        case .join: return "My Meetings"
        case .record: return "Record"
        }
    }
}

/// Lets exactly one of two racing callers through.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
