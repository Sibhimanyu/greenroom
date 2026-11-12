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
        stopCues()
        layoutFollowTask?.cancel()
        peopleViewTask?.cancel()
        stopShapePreview()
        ChatWindowController.close()
        customUIGridTask?.cancel()
        customUIGridTask = nil
        MeetingControlBarController.close()
        SpeakerWindowController.close()
        ParticipantGridWindowController.close()
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
            isRecording = false
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
        // Custom UI only (and a start that arranges nothing, which leaves
        // Greenroom's window frontmost for the card to ride in). Readiness exists
        // because custom UI replaces Zoom's windows with Greenroom's own, so there
        // is genuinely nothing on screen during a start. In default Zoom-UI mode the teacher already has Zoom's
        // interface coming up in front of them and did not ask for another
        // floating surface on top of it.
        // A failed start is the exception to both guards below: it always needs
        // a card with a way out, wherever the panel is or is not.
        let failed = startReadiness.failure != nil
        guard customUIMode || !sessionArranges || failed else {
            ReadinessHUDController.close()
            return
        }
        // Arranged: a panel on the reference display carries the card, so the
        // HUD is only for a start with none. Nothing arranged: the panel opens
        // on demand, so the HUD carries the card until the teacher opens it.
        let panelCarriesCard = sessionArranges
            ? peopleViewTargetScreen() != nil
            : ParticipantGridWindowController.isOpen
        guard !panelCarriesCard || (failed && !ParticipantGridWindowController.isOpen) else {
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
        case workspace, camera, meeting, recording, tiling

        var label: String {
            switch self {
            case .workspace: return "Workspace"
            case .camera: return "Picture"
            case .meeting: return "Meeting"
            case .recording: return "Recording"
            case .tiling: return "Tiling windows"
            }
        }
    }

    private func resetStartReadiness() {
        startReadiness = .init(steps: StartStep.allCases.map {
            .init(label: $0.label, state: .pending)
        })
    }

    private func mark(_ step: StartStep, _ state: ParticipantGridWindowController.Readiness.State) {
        guard startReadiness.steps.indices.contains(step.rawValue) else { return }
        startReadiness.steps[step.rawValue].state = state
    }

    /// Ends the progress display. Clearing the steps makes `isLive` true, which
    /// is what returns the panel to its ordinary behaviour.
    private func finishStartReadiness() {
        startReadiness = .init()
    }

    private func failStartReadiness(_ message: String) {
        if let active = startReadiness.steps.firstIndex(where: { $0.state == .active }) {
            startReadiness.steps[active].state = .failed
        }
        startReadiness.failure = message
    }
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
            Analytics.setting("camera_director", on: cameraDirectorSettings.isUsable)
            // Applied live: a teacher who turns it on mid-class should not
            // have to end the session to get it.
            if sceneInUse, stage != nil {
                applyCameraDirectorLive(from: oldValue)
            }
        }
    }
    @Published private(set) var isStopping = false
    private var startTask: Task<Void, Never>?

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

    /// One-click fill of the Join Existing fields from a saved preset.
    func applyPreset(_ preset: MeetingPreset) {
        Analytics.feature("preset")
        meetingMode = .join
        meetingNumber = preset.number
        meetingPassword = preset.password
        log("Filled \u{201C}\(preset.name)\u{201D} (\(preset.number)).")
    }

    /// Saves the current Join Existing fields as a named preset. The
    /// number is stored normalized (digits only); a blank name falls back
    /// to the number itself.
    func saveCurrentAsPreset(name: String) {
        Analytics.feature("preset_save")
        let digits = meetingNumberDigits
        guard !digits.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meetingPresets.append(MeetingPreset(name: trimmed.isEmpty ? digits : trimmed,
                                            number: digits, password: meetingPassword))
        log("Saved preset \u{201C}\(meetingPresets.last?.name ?? digits)\u{201D}.")
    }

    func deletePreset(_ preset: MeetingPreset) {
        meetingPresets.removeAll { $0.id == preset.id }
    }

    // MARK: First-run onboarding - shown once automatically, reopenable
    // from the main window's ? button.

    @Published var showOnboarding: Bool

    func presentOnboarding() {
        showOnboarding = true
    }

    func completeOnboarding() {
        showOnboarding = false
        defaults.set(true, forKey: "hasCompletedOnboarding")
    }

    // MARK: Meeting SDK chat (separate window, second participant - see
    // Vendor/ZoomSDK/README.md). Both the Client ID and Secret are stored
    // in plain UserDefaults via SecretStore (Greenroom does not use the
    // Keychain); the secret is loaded lazily.

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

    /// Loads both Zoom secrets on first use rather than at launch, so the
    /// stored values are only touched when a Zoom feature is actually
    /// used. (Storage is plain UserDefaults via SecretStore - see that
    /// file; no Keychain, so no password prompt was ever involved.)
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
    let zoomChatBridge = ZoomChatBridge()
    @Published private(set) var isConnectingChat = false

    // MARK: Start-a-meeting (Server-to-Server OAuth app - a SECOND
    // Marketplace app, separate from the Meeting SDK one above; see
    // Vendor/README.md, including why a one-app OAuth consolidation was
    // built and then abandoned). Account ID, Client ID and Secret are all
    // stored in plain UserDefaults via SecretStore (no Keychain), the
    // secret loaded lazily like the SDK secret.

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
    @Published var hideSelfView: Bool {
        didSet {
            defaults.set(hideSelfView, forKey: "hideSelfView")
            Analytics.setting("hide_self_view", on: hideSelfView)
            zoomChatClient.setHideSelfView(hideSelfView)
        }
    }
    /// The \u{2325}\u{2318}Z quick-hide MODE. Off: the normal
    /// tile-above-chat layout persists and the shortcut is inert. On:
    /// sessions START with the speaker tile hidden and the chat owning
    /// the full side column; the shortcut shows the tile (chat resizes
    /// below it) and hides it again (chat refills the column). Flipping
    /// the setting mid-session applies immediately.
    @Published var speakerTileShortcutEnabled: Bool {
        didSet {
            defaults.set(speakerTileShortcutEnabled, forKey: "speakerTileShortcutEnabled")
            Analytics.setting("quick_hide_mode", on: speakerTileShortcutEnabled)
            // Zoom's own tile only: the custom-UI meeting window is shown by default
            // and hidden by the shortcut, whatever the mode says.
            guard sessionArranges, ChatWindowController.isOpen, !zoomChatClient.didUseCustomUI else { return }
            speakerTileQuickHidden = speakerTileShortcutEnabled
            parkBuiltInMeetingWindow() // restart the loop to assert the new default
        }
    }

    /// Quick-hide state: the tile is off-screen and the chat owns the
    /// FULL side column. Defaults to the setting at each session start
    /// and after Snap Windows Back; \u{2325}\u{2318}Z flips it.
    /// Published (read-only) so the menu bar can label its toggle with
    /// the ACTUAL next action ("Show/Hide Speaker Tile").
    @Published private(set) var speakerTileQuickHidden = false

    /// \u{2325}\u{2318}Z: shows the speaker tile in its slot
    /// (the chat resizes to sit below it) or hides it again (the chat
    /// takes the full column back). Only active when the quick-hide mode
    /// is enabled in Settings.
    func toggleSpeakerTile() {
        guard layoutToolsAvailable else {
            log("Speaker tile skipped \u{2014} this session arranges no windows.")
            return
        }
        guard speakerTileShortcutEnabled else { return }
        Analytics.track(.quickHide)
        // Custom UI: the meeting window is ours, so hiding it is just ordering
        // it out - no SDK window to find, and no risk of the toggle pointing at
        // a panel that got mistaken for the tile. Only the window in Zoom's old
        // slot is a "tile"; a full window on the reference display or a free one
        // is the teacher's to close.
        if zoomChatClient.didUseCustomUI {
            guard ParticipantGridWindowController.isSlot else {
                log("No meeting window in the speaker slot to hide \u{2014} this layout uses a full window.")
                return
            }
            if speakerTileQuickHidden {
                speakerTileQuickHidden = false
                openMeetingWindow()
                log("Meeting window shown \u{2014} \u{2325}\u{2318}Z hides it again.")
            } else {
                speakerTileQuickHidden = true
                ParticipantGridWindowController.hide()
                ChatWindowController.fillSideColumn(layout: workspaceLayout)
                log("Meeting window hidden \u{2014} chat has the full column. \u{2325}\u{2318}Z shows it.")
            }
            return
        }
        guard let window = builtInMeetingWindow, ChatWindowController.isOpen else {
            // Surfaced, not just logged: the status log is collapsed by
            // default, so pressing the shortcut before the tile exists looked
            // like the shortcut was simply broken.
            log("No speaker tile to toggle yet \u{2014} waiting for Zoom's meeting window.")
            Notifier.post(title: "Speaker tile isn't ready yet",
                          body: "Zoom's meeting window is still coming up. Try \u{2325}\u{2318}Z again in a moment.")
            return
        }
        if speakerTileQuickHidden {
            speakerTileQuickHidden = false
            window.level = .normal
            if let slot = ChatWindowController.zoomSlotNSFrame(for: workspaceLayout) {
                window.setFrame(slot, display: true)
                // Chat shrinks below the tile immediately (the follow
                // loop would also do this, but a beat later).
                if let screen = DisplayResolver.mainDisplayScreen() {
                    let ax = CGRect(x: slot.origin.x, y: screen.frame.height - slot.maxY,
                                    width: slot.width, height: slot.height)
                    ChatWindowController.adjustBelowZoom(actualZoomFrameAX: ax, layout: workspaceLayout)
                }
            }
            window.orderFrontRegardless()
            log("Speaker tile shown \u{2014} \u{2325}\u{2318}Z hides it again.")
        } else {
            speakerTileQuickHidden = true
            window.orderOut(nil)
            ChatWindowController.fillSideColumn(layout: workspaceLayout)
            log("Speaker tile hidden \u{2014} chat has the full column. \u{2325}\u{2318}Z shows it.")
        }
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
                    showsContent: shareTarget.kind != .nothing,
                    showsCamera: !cameraIsOff)
    }

    /// "No camera" picked on the Webcam page, and honoured.
    ///
    /// Not with switching on: that is a choice to have cameras. And not with
    /// nothing shared either, since the picture would then be an empty
    /// backdrop - the page refuses that pair, and this is the backstop for a
    /// pair that arrived anyway (an imported settings file, say).
    var cameraIsOff: Bool {
        cameraDirectorSettings.noCamera && !cameraDirectorSettings.enabled
            && shareTarget.kind != .nothing
    }

    /// The Webcam page's picture is in use by a session - a meeting, or a
    /// recording made from Home's Record mode. The Settings preview then
    /// mirrors that session's picture instead of starting one of its own.
    var sceneInUse: Bool { stageLive || recordOnlyActive }

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
        // No camera means none opened.
        if cameraIsOff { return [] }
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
        if recordOnlyActive, !isRunning {
            if sessionCameraUIDs(cameraDirectorSettings).count < 2 {
                stageCameraUIDs = sceneCameraUIDs(limit: 1)
                requestShapeApply()
            }
            return
        }
        guard !sceneInUse, !isRunning, shapePreviewOn else { return }
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

    @Published var webcamShape: WebcamShape {
        didSet {
            defaults.set(webcamShape.rawValue, forKey: "webcamShape")
            Analytics.setting("webcam_shape", webcamShape.rawValue)
        }
    }
    /// The main pane + side column arrangement - see WorkspaceLayout.
    /// Stored as one JSON blob (it's several coupled fields, not a flat
    /// value like the keys around it).
    @Published var workspaceLayout: WorkspaceLayout {
        didSet {
            workspaceLayout.save(to: defaults)
            // The toggles and the side, not the fractions: a drag emits dozens
            // of values a second and the number itself says nothing useful.
            if oldValue.sideShowsZoomTile != workspaceLayout.sideShowsZoomTile {
                Analytics.setting("zoom_tile", on: workspaceLayout.sideShowsZoomTile)
            }
            if oldValue.sideShowsChat != workspaceLayout.sideShowsChat {
                Analytics.setting("chat_window", on: workspaceLayout.sideShowsChat)
            }
            if oldValue.mainOnLeft != workspaceLayout.mainOnLeft {
                Analytics.setting("main_pane_side", workspaceLayout.mainOnLeft ? "left" : "right")
            }
            scheduleLiveLayoutApply()
        }
    }

    /// The layout library (Settings -> Layout): named templates, and which one a
    /// class start uses (nil = None). Saved as one JSON blob under `layoutLibrary`.
    ///
    /// Until the runtime reads templates (phase B), the choice is bridged to the
    /// old switch: None turns `arrangeWindowsOnStart` off, any template turns it
    /// on, so today's arranging keeps working.
    @Published var layoutLibrary: LayoutLibrary {
        didSet {
            guard layoutLibrary != oldValue else { return }
            layoutLibrary.save(to: defaults)
            let arranges = layoutLibrary.active != nil
            if workspaceLayout.arrangeWindowsOnStart != arranges {
                workspaceLayout.arrangeWindowsOnStart = arranges
            }
        }
    }

    private var layoutApplyTask: Task<Void, Never>?

    /// Layout edits made mid-session (dragging the divider in Settings)
    /// apply to the LIVE windows automatically - no Snap Windows Back
    /// needed. Debounced: a drag emits dozens of changes a second, and
    /// re-tiling real windows (AppleScript/AX calls) at that rate would
    /// thrash; 400ms after the last change, everything re-tiles once.
    private func scheduleLiveLayoutApply() {
        // A session that arranges nothing must never reposition anything - the
        // chat can be open on demand, and stageLive alone would pass.
        guard sessionArranges || !(isRunning || stageLive) else { return }
        guard ChatWindowController.isOpen || stageLive else { return }
        layoutApplyTask?.cancel()
        layoutApplyTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            _ = await MainPaneManager.repositionFrontWindow(bundleID: mainAppBundleID, layout: workspaceLayout)
            if ChatWindowController.isOpen {
                if speakerTileQuickHidden {
                    ChatWindowController.fillSideColumn(layout: workspaceLayout)
                } else {
                    ChatWindowController.show(chat: zoomChatBridge, layout: workspaceLayout)
                }
            }
            // Re-parks the tile into the resized slot; preserves the
            // current quick-hide state (a mid-class toggle must not be
            // undone by resizing a pane).
            parkBuiltInMeetingWindow()
        }
    }
    /// Which app occupies the main pane. Chrome (the default, and what
    /// this used to hardcode) goes through its AppleScript special case;
    /// anything else is tiled via the Accessibility API.
    @Published var mainAppBundleID: String {
        didSet {
            defaults.set(mainAppBundleID, forKey: "mainAppBundleID")
            Analytics.setting("main_app", Analytics.mainAppKind(bundleID: mainAppBundleID))
        }
    }
    @Published var mainAppURL: String {
        // Stored sanitised. A control character typed in here once made the
        // preferences plist unparseable as XML, and the address unopenable.
        didSet { defaults.set(AppCatalog.sanitizedURLText(mainAppURL), forKey: "mainAppURL") }
    }
    @Published var mainAppOnStart: Bool {
        didSet {
            defaults.set(mainAppOnStart, forKey: "mainAppOnStart")
            Analytics.setting("main_app_on_start", on: mainAppOnStart)
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
    /// Whether End Session also closes the browser window Start opened.
    /// Greenroom Browser's window, or the one window a Chromium browser
    /// (Chrome, Ulaa, Edge...) was asked to make for this session - never the
    /// teacher's other windows. Off by default.
    @Published var browserClosesOnStop: Bool {
        didSet {
            defaults.set(browserClosesOnStop, forKey: "browserClosesOnStop")
            Analytics.setting("browser_close_on_stop", on: browserClosesOnStop)
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
    @Published var youtubeConnected = YouTubeAuth.isConnected
    @Published var isUploadingToYouTube = false
    /// 0...1 while an upload runs, for the menu bar; nil otherwise.
    @Published var youtubeUploadProgress: Double?
    /// The last connect / disconnect outcome, shown under the button.
    @Published var youtubeStatus = ""
    /// People view: on Start, the built-in client's dual-screen gallery
    /// window (every participant) goes full-screen onto a chosen display
    /// - your reference monitor, not the class mirror. No-op with a
    /// single display.
    @Published var peopleViewOnStart: Bool {
        didSet {
            defaults.set(peopleViewOnStart, forKey: "peopleViewOnStart")
            Analytics.setting("people_view_on_start", on: peopleViewOnStart)
        }
    }
    /// Whether the custom-UI participants panel may open on the MAIN display
    /// when no second display is attached.
    ///
    /// Off by default, and it should stay off for normal use. The panel is a
    /// private control surface for a display the teacher alone can see; on a
    /// single screen it covers the tiled workspace the whole app exists to
    /// arrange. It is here so the panel can be exercised without a reference
    /// monitor plugged in, not as a way to work.
    @Published var participantPanelOnMainDisplay: Bool {
        didSet {
            defaults.set(participantPanelOnMainDisplay, forKey: "participantPanelOnMainDisplay")
            Analytics.setting("panel_on_main_display", on: participantPanelOnMainDisplay)
        }
    }
    /// Whether anonymous usage analytics are sent. On by default, and the switch
    /// is honoured immediately as well as on the next launch.
    @Published var analyticsEnabled: Bool {
        didSet {
            defaults.set(analyticsEnabled, forKey: "analyticsEnabled")
            Analytics.setEnabled(analyticsEnabled)
        }
    }
    /// Which display the participant gallery opens on, by stable CGDisplay
    /// UUID. Empty = Automatic (the first non-main display). Persisted and
    /// carried in the transfer file so a saved setup targets the same
    /// physical monitor.
    /// Which display the screen capture shares. Empty means "the main one",
    /// which is what almost everyone wants and what this always did. Stored by
    /// display UUID so the choice survives unplugging and reconnecting, the
    /// same way peopleViewDisplayUUID does.
    /// Custom-UI mode. Read by the SDK client at initSDK, which happens once
    /// per process - so changing this only takes effect after a restart, and
    /// the Settings copy says so.
    @Published var customUIMode: Bool {
        didSet {
            defaults.set(customUIMode, forKey: "customUIMode")
            Analytics.setting("custom_ui", on: customUIMode)
        }
    }
    /// True when the toggle no longer matches the mode actually running.
    ///
    /// `needCustomizedUI` is an initSDK parameter and the SDK initialises once
    /// per process, at the first session start. Change the toggle after that and
    /// nothing happens until relaunch - which looked exactly like a broken
    /// switch until Settings started saying so.
    var customUIModeNeedsRelaunch: Bool {
        zoomChatClient.didInit
            && zoomChatClient.didUseCustomUI != customUIMode
    }

    @Published var screenCaptureDisplayUUID: String {
        didSet { defaults.set(screenCaptureDisplayUUID, forKey: "screenCaptureDisplayUUID") }
    }

    /// The whole display, one app or one window. Changes apply live: the
    /// compositor starts the new share beside the old one and swaps when its
    /// first frame arrives.
    @Published var shareTarget: ShareTarget {
        didSet {
            if let data = try? JSONEncoder().encode(shareTarget) {
                defaults.set(data, forKey: "shareTarget")
            }
        }
    }

    @Published var peopleViewDisplayUUID: String {
        didSet { defaults.set(peopleViewDisplayUUID, forKey: "peopleViewDisplayUUID") }
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
    private let defaults = UserDefaults.standard

    init() {
        defer {
            Self.shared = self
            observeDisplays()
        }
        webcamShape = WebcamShape(rawValue: defaults.string(forKey: "webcamShape") ?? "") ?? .circle
        backgroundRemoval = BackgroundRemoval(rawValue: defaults.string(forKey: "backgroundRemoval") ?? "") ?? .automatic
        micDeviceUID = defaults.string(forKey: "micDeviceUID") ?? ""
        // load(from:) migrates the Chrome-only era's "chromeLayout" key,
        // and the ?? fallbacks below migrate its URL/on-Start keys - an
        // existing setup keeps its layout without re-configuring.
        workspaceLayout = WorkspaceLayout.load(from: defaults)
        // First launch with this key migrates today's settings into "Your previous
        // layout" (see LayoutLibrary.loadOrMigrate); the old keys stay as they were.
        layoutLibrary = LayoutLibrary.loadOrMigrate(from: defaults, defaultSiteURL: AppLinks.site)
        mainAppBundleID = defaults.string(forKey: "mainAppBundleID") ?? ChromeWindowManager.chromeBundleID
        // Fresh installs open the Greenroom site until the teacher sets
        // their own page - a friendly first Start instead of a blank tab.
        let bubbleDefaults = StageLayout()
        bubbleWidthFraction = (defaults.object(forKey: "bubbleWidthFraction") as? Double) ?? bubbleDefaults.widthFraction
        bubbleRightInset = (defaults.object(forKey: "bubbleRightInset") as? Double) ?? bubbleDefaults.rightInset
        bubbleBottomInset = (defaults.object(forKey: "bubbleBottomInset") as? Double) ?? bubbleDefaults.bottomInset
        className = defaults.string(forKey: "className") ?? ""
        // Defaults ON: the shortcuts are useless without it, and bool(forKey:)
        // alone cannot tell "never set" from "deliberately off".
        clipBufferEnabled = (defaults.object(forKey: "clipBufferEnabled") as? Bool) ?? true
        cutoutHeightFraction = (defaults.object(forKey: "cutoutHeightFraction") as? Double) ?? bubbleDefaults.cutoutHeightFraction
        cutoutRightInset = (defaults.object(forKey: "cutoutRightInset") as? Double) ?? bubbleDefaults.cutoutRightInset
        mainAppURL = AppCatalog.sanitizedURLText(
            defaults.string(forKey: "mainAppURL") ?? defaults.string(forKey: "chromeURL") ?? AppLinks.site)
        // Defaults to ON for fresh installs (bool(forKey:) alone can't
        // distinguish "never set" from "explicitly off") - the one-button
        // session flow treats the main app window as part of the setup,
        // and the Settings toggle is the opt-out.
        mainAppOnStart = (defaults.object(forKey: "mainAppOnStart") as? Bool)
            ?? (defaults.object(forKey: "chromeOnStart") as? Bool)
            ?? true
        // ON by default: the point of the built-in browser is that the
        // morning's tabs are where they were left. didSet does not run in
        // init, so the controller's flag is set by hand here.
        let restoresTabs = (defaults.object(forKey: "browserRestoresTabs") as? Bool) ?? true
        browserRestoresTabs = restoresTabs
        BrowserWindowController.restoresTabs = restoresTabs
        let searchSuggestions = (defaults.object(forKey: "browserSearchSuggestions") as? Bool) ?? true
        browserSearchSuggestions = searchSuggestions
        BrowserWindowController.searchSuggestions = searchSuggestions
        browserClosesOnStop = defaults.bool(forKey: "browserClosesOnStop")
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
        peopleViewOnStart = defaults.bool(forKey: "peopleViewOnStart")
        participantPanelOnMainDisplay = defaults.bool(forKey: "participantPanelOnMainDisplay")
        // Absent means never answered, which is opted IN - matching the consent
        // the Apptics setup already carries. An explicit false stays false.
        analyticsEnabled = (defaults.object(forKey: "analyticsEnabled") as? Bool) ?? true
        peopleViewDisplayUUID = defaults.string(forKey: "peopleViewDisplayUUID") ?? ""
        screenCaptureDisplayUUID = defaults.string(forKey: "screenCaptureDisplayUUID") ?? ""
        shareTarget = defaults.data(forKey: "shareTarget")
            .flatMap { try? JSONDecoder().decode(ShareTarget.self, from: $0) } ?? ShareTarget()
        // On unless the teacher turned it off; Macs that stored the old default
        // (off) are flipped once, so the new default actually reaches them.
        ZoomMeetingSDKClient.migrateCustomUIDefault()
        customUIMode = (defaults.object(forKey: "customUIMode") as? Bool) ?? true
        autoRecordOnStart = defaults.bool(forKey: "autoRecordOnStart")
        meetingMode = MeetingMode(rawValue: defaults.string(forKey: "meetingMode") ?? "") ?? .create
        meetingPresets = Self.loadPresets(from: defaults)
        showOnboarding = !defaults.bool(forKey: "hasCompletedOnboarding")
        sdkClientID = defaults.string(forKey: "zoomSDKClientID") ?? ""
        sdkClientSecret = "" // loaded lazily via loadSecretsIfNeeded() - never at launch
        s2sAccountID = defaults.string(forKey: "zoomS2SAccountID") ?? ""
        s2sClientID = defaults.string(forKey: "zoomS2SClientID") ?? ""
        s2sClientSecret = "" // loaded lazily via loadSecretsIfNeeded() - never at launch
        userDisplayName = defaults.string(forKey: "userDisplayName") ?? NSFullUserName()
        // Default OFF (show self): the teacher's own tile belongs in the
        // extended display's participant grid alongside the students
        // (explicit request); the speaker tile stays clean regardless
        // because spotlight-my-video and the thumbnail strip are disabled.
        hideSelfView = (defaults.object(forKey: "hideSelfView") as? Bool) ?? false
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

        // The switch countdown over the self view. Pushed rather than polled:
        // it changes three times a second while counting and not at all
        // otherwise.
        cameraDirector.$pendingSwitch
            .removeDuplicates()
            .sink { pending in
                Task { @MainActor in ParticipantGridWindowController.applyCameraSwitch(pending) }
            }
            .store(in: &cancellables)

        cameraDirector.log = { [weak self] line in self?.log(line) }
    }

    private var cancellables = Set<AnyCancellable>()

    private func chatSessionDidEnd() {
        layoutFollowTask?.cancel()
        peopleViewTask?.cancel()
        MeetingControlBarController.close()
        if !sessionArranges { closeMeetingWindow() }
        meetingControls?.stop()
        meetingControls = nil
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
        if stageLive || isRunning {
            log("Meeting over \u{2014} ending the session.")
            stop()
        } else {
            log("Meeting over \u{2014} chat window closed.")
        }
    }

    // MARK: The stage (the class picture, made in-process)

    /// The one compositor: the picture the meeting sees, the recorder films and
    /// Settings previews. Made when something needs it, dropped (and its
    /// cameras let go) when nothing does.
    private var stage: StageCompositor?
    /// Films the stage. Made with a session; nil outside one.
    private var recorder: SessionRecorder?
    /// The cameras the stage holds right now, while a session runs. Nil means
    /// "the first camera only", which is what Start and the idle preview open.
    private var stageCameraUIDs: [String]?
    private var stageObservers = Set<AnyCancellable>()
    private var lastReportedStageError: String?
    private var permissionWatcher: Task<Void, Never>?

    /// Everything the compositor is told, from the same settings the Layout
    /// and Webcam pages edit.
    func makeStageConfiguration() -> StageConfiguration {
        StageConfiguration(layout: stageLayout,
                           share: shareTarget,
                           displayUUID: screenCaptureDisplayUUID,
                           backgroundRemoval: backgroundRemoval,
                           cameraUIDs: stageCameraUIDs ?? sceneCameraUIDs(limit: 1))
    }

    private func ensureStage() -> StageCompositor? {
        if let stage { return stage }
        guard let made = StageCompositor() else { return nil }
        stage = made
        stageObservers.removeAll()
        made.status.$personInView.removeDuplicates()
            .sink { [weak self] in self?.cameraSeesYou = $0 }
            .store(in: &stageObservers)
        made.status.$lastError.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] in self?.reportStageError($0) }
            .store(in: &stageObservers)
        made.status.$camerasLive.removeDuplicates()
            .sink { [weak self] in self?.camerasLiveChanged($0) }
            .store(in: &stageObservers)
        return made
    }

    /// Stops the picture and lets every camera and the screen capture go.
    private func stopStage() {
        permissionWatcher?.cancel()
        permissionWatcher = nil
        guard let stage else { return }
        if previewAttached { stage.removeSink(previewSink); previewAttached = false }
        stage.stop()
        self.stage = nil
        stageObservers.removeAll()
        stageCameraUIDs = nil
        lastReportedStageError = nil
        cameraSeesYou = true
    }

    /// Plain words for whatever the compositor could not do. Shown once per
    /// distinct message, in the status log and, mid-class, as a notification.
    private func reportStageError(_ message: String) {
        guard message != lastReportedStageError else { return }
        lastReportedStageError = message
        log(message)
        if stageLive, !isRunning {
            Notifier.post(title: "Greenroom picture problem", body: message)
        }
    }

    private var lastCameraLive: Bool?
    private func camerasLiveChanged(_ live: [Bool]) {
        guard stageLive || recordOnlyActive, !isRunning, let first = live.first else { return }
        defer { lastCameraLive = first }
        guard lastCameraLive != first else { return }
        log(first ? "The camera is sending a picture again."
                  : "The camera stopped sending a picture \u{2014} the class sees the last one. Check it is plugged in and not in use by another app.")
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
                    self.log("Screen Recording is on \u{2014} the class now sees your screen.")
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
        guard !isRunning, !sceneInUse, !isStopping else { return }
        if meetingMode == .record {
            getReadyToRecord()
            return
        }
        loadSecretsIfNeeded()

        // Greenroom's own Zoom client sends the picture, so it is needed for
        // every meeting, created or joined.
        if meetingMode != .record, sdkClientID.isEmpty || sdkClientSecret.isEmpty {
            log("Can't start yet \u{2014} add the Meeting SDK Client ID and Secret in Settings (\u{2318},) \u{2192} Zoom. Greenroom sends your screen and camera through its own Zoom client, so it needs them.")
            return
        }
        switch meetingMode {
        case .record:
            return
        case .create:
            guard !s2sAccountID.isEmpty, !s2sClientID.isEmpty, !s2sClientSecret.isEmpty else {
                log("Can't create a meeting yet \u{2014} add the Server-to-Server credentials in Settings (\u{2318},) \u{2192} Zoom.")
                return
            }
        case .join:
            guard !meetingNumberDigits.isEmpty else {
                log("Paste a meeting link or enter a meeting ID first.")
                return
            }
        }

        isRunning = true
        stageLive = false
        statusLines = []
        sessionArranges = workspaceLayout.arrangeWindowsOnStart
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
            .customUI: customUIMode ? "yes" : "no",
            .displays: String(NSScreen.screens.count),
            .mainApp: Analytics.mainAppKind(bundleID: mainAppBundleID)
        ])

        resetStartReadiness()
        // Before anything else, so the reference display has something on it
        // from the first frame rather than after the meeting connects. Gated on
        // the SETTING rather than on zoomChatClient.didUseCustomUI, which is not
        // known until the SDK has initialised - by which point the blank this
        // exists to fill is already over. presentMeetingSurfaces closes the
        // panel again if custom UI turns out not to have happened.
        // (Only the reference-display panel opens this early: the meeting window
        // needs a meeting, and a single-display class has the floating card.)
        if customUIMode && sessionArranges && peopleViewWanted { startCustomUIGridFollow() }

        startTask = Task {
            do {
                // Perceived speed: the main app doesn't depend on
                // anything else - open it first so something visibly
                // happens the instant Start is pressed.
                let opensMainApp = mainAppOnStart && sessionArranges
                mark(.workspace, opensMainApp ? .active : .skipped)
                if opensMainApp {
                    log("Opening the \(mainAppDisplayName) window (\(workspaceLayout.label))\u{2026}")
                    openMainAppWindow()
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

                mark(.meeting, .active)
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
                    try await hostAllInOne(meeting: meeting)
                case .join:
                    try await joinAllInOne()
                case .record:
                    break // routed to getReadyToRecord before any of this
                }

                try Task.checkCancellation()
                mark(.meeting, .done)
                // Nothing arranged: Greenroom's own meeting window is the first
                // surface, and the pill is what is left when it is closed,
                // minimised or covered. With Zoom's own window as the picture
                // (custom UI off) there is no meeting window, so the pill stays.
                if !sessionArranges {
                    ensureMeetingControls()
                    if zoomChatClient.didUseCustomUI { openMeetingWindow() }
                    if let controls = meetingControls {
                        MeetingControlBarController.install(coordinator: self, model: controls)
                    }
                }
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
                    log("Starting the recording automatically (Settings \u{2192} Webcam).")
                    toggleRecording()
                    mark(.recording, .done)
                }
                mark(.tiling, sessionArranges ? .active : .skipped)

                if sessionArranges { mark(.tiling, .done) }
                // Clearing the steps is what makes Readiness.isLive true, which
                // hands the panel back to its ordinary behaviour: the class side
                // returns to "waiting for students" and the controls come up.
                finishStartReadiness()
                // A display was plugged or pulled while this was starting:
                // anything placed before that settled is placed against a screen
                // arrangement that no longer exists. Everything placed after it
                // read the live arrangement, so this is a no-op for those.
                if displayChangedDuringStart {
                    displayChangedDuringStart = false
                    if sessionArranges { snapWindowsBack(userInitiated: false) }
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
                    isRunning = false
                    return
                }
                let message = error.localizedDescription
                log("Failed: \(message)")
                Analytics.failure("start")
                // Left on screen rather than cleared. The panel is the surface
                // the teacher has been watching for the last several seconds,
                // so it is where the failure belongs, named against the step it
                // happened on - with Try again and Close on it.
                failStartReadiness(message)
                Notifier.post(title: "Greenroom couldn\u{2019}t start", body: message)
                // And the unwind: a failed start used to leave the cameras, the
                // recorder and the half-started meeting running behind the card
                // (the CPU in Vision and AAC after a hung Start). Same teardown as
                // End Session, minus closing the failure card.
                stop(failure: message)
            }
            isRunning = false
        }
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
        if failure == nil, recordOnlyActive || (isRunning && startingRecordOnly) {
            stopRecordingSession()
            return
        }
        isStopping = true
        Analytics.track(.sessionEnd, [
            .durationBand: Analytics.band(seconds: sessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0),
            .customUI: customUIMode ? "yes" : "no"
        ])
        sessionStartedAt = nil
        discardEmptySessionFolder()
        sessionFolder = nil
        // A start still in flight gets abandoned at its next checkpoint -
        // without this, its meeting setup raced the teardown below.
        startTask?.cancel()
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
            layoutFollowTask?.cancel()
                peopleViewTask?.cancel()
            MeetingControlBarController.close()
            meetingControls?.stop()
            meetingControls = nil
            if ChatWindowController.isOpen {
                ChatWindowController.close()
                log("Left the meeting chat.")
            }
            zoomChatBridge.reset()
            // The browser is the teacher's, not the meeting's, so by default
            // it stays open like Chrome would. Closing it with the session is
            // a choice (Settings → Layout); its tabs survive for the next Start.
            if !sessionArranges {
                // Nothing was opened, so nothing is closed.
            } else if browserClosesOnStop, AppCatalog.isBuiltInBrowser(mainAppBundleID), BrowserWindowController.isOpen {
                BrowserWindowController.close()
                log("Closed the Greenroom Browser window.")
            } else if browserClosesOnStop, AppCatalog.isBrowser(mainAppBundleID),
                      let line = await ChromeWindowManager.closeSessionWindow(bundleID: mainAppBundleID) {
                log(line)
            }
            // Custom UI: stop the SDK rendering into views that are about to
            // go away, then drop our window.
            if failure == nil {
                customUIGridTask?.cancel()
                customUIGridTask = nil
                finishStartReadiness()
                ReadinessHUDController.close()
            }
            recorder?.disarmClipBuffer()
            zoomChatClient.onParticipantCountChanged = nil
            SpeakerWindowController.close()
            if failure == nil { ParticipantGridWindowController.close() }
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
                isRecording = false
                isSavingRecording = true
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
                    self.isSavingRecording = false
                    return saved
                }
            }
            await tearDownStage()
            log("Session ended \u{2014} the camera and screen capture are off.")
            stageLive = false
            isRunning = false
            isStopping = false
            resumePreviewIfWanted()
            // The session pushed Greenroom to the back (finalizeLayout) so
            // the main app could take the stage - with the meeting over,
            // bring it home to front for the next thing.
            showMainWindow()
            // Everything is over now - the meeting, the recording, the picture - so
            // the upload question is the last thing, and nothing waits on it.
            if let saving = savingTask {
                savingTask = nil
                Task { if let path = await saving.value { recordingFinished(path: path) } }
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
        guard !s2sAccountID.isEmpty, !s2sClientID.isEmpty, !s2sClientSecret.isEmpty else {
            if !askedSDKToEnd {
                log("Zoom may have kept the meeting running without you \u{2014} end it from zoom.us if students are still in it.")
            }
            return
        }
        let (account, client, secret) = (s2sAccountID, s2sClientID, s2sClientSecret)
        Task {
            let answer = await ZoomServerToServerClient.endMeetingReporting(
                id: id, accountID: account, clientID: client, clientSecret: secret)
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
        log("Clip buffer armed \u{2014} the last \(minutes) minutes stay clippable with \u{2325}\u{2318}1, \u{2325}\u{2318}2 or \u{2325}\u{2318}5, recording or not.")
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
                                     detail: "Start the class first.", kind: .failure)
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
                                 detail: "Marked in \(folder.lastPathComponent) \u{2014} in Recordings after the class.")
        }
    }

    /// Writes the rolling buffer out and trims it to the minutes asked for.
    ///
    /// Unlike marking, this produces a finished clip there and then - there is
    /// no master to cut from later, so the file has to exist now.
    private func clipFromBuffer(minutes: Int, into folder: URL) async {
        guard clipBufferEnabled else {
            log("Nothing to clip \u{2014} the clip buffer is off (Settings \u{2192} Webcam) and nothing is recording.")
            ToastController.show("Nothing to clip",
                                 detail: "Turn on the clip buffer in Settings, or press Record.", kind: .failure)
            return
        }
        guard let recorder, recorder.isClipBufferArmed else {
            log("Nothing to clip \u{2014} the clip buffer is not running. Press Record (\u{2325}\u{2318}R) to capture from here.")
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
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: folder)
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

    func toggleRecording() {
        // A press while the last file is still closing must never start a
        // second recording (it once did, and wrote one outside any session).
        guard !isSavingRecording, !isStopping else {
            log("Recording is still saving \u{2014} wait a moment.")
            return
        }
        // In the Record view the picture outlives each take: the shortcut
        // starts or stops a take and leaves the picture up for the next.
        if recordOnlyActive {
            if isRecording { stopTake() } else { startTake() }
            return
        }
        Task {
            do {
                if isRecording {
                    isSavingRecording = true
                    isRecording = false
                    let url = await recorder?.stop()
                    isSavingRecording = false
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
                    try await beginRecording()
                }
            } catch {
                isSavingRecording = false
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
                              body: "Only \(readable) free, which may not fit a full class.")
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
        try recorder.start(in: folder)
        isRecording = true
        recordingStartedAt = Date()
        Analytics.track(.recordingStart)
        log("Recording\u{2026} (screen + webcam composite)")
        // Confirmation where it can be seen - mid-session the
        // main window is buried behind the main app. The menu
        // bar's GR also flips to a REC glyph via isRecording.
        Notifier.post(title: "Recording started",
                      body: "Greenroom is recording the composite. \u{2325}\u{2318}R stops it.")
    }

    // MARK: Record mode - get ready, then record, as often as you like

    /// The Record view is open: the picture is up (compositor, cameras, screen
    /// share) and the tape may or may not be rolling. No meeting, so neither
    /// `stageLive` nor anything keyed to the meeting is set. `isRecording` says
    /// whether a take is running.
    @Published private(set) var recordOnlyActive = false
    /// A Get Ready is in flight, so Stop knows which teardown the half-started
    /// picture needs, and the window can show the Record view straight away.
    @Published private(set) var startingRecordOnly = false
    /// A take is starting or finishing, so the Record button waits.
    @Published private(set) var takeBusy = false
    /// The Record view wants the live picture, whether or not Settings does.
    /// Held apart from `shapePreviewOn` so closing the Webcam tab does not
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

        var isHome: Bool { self == .home }
    }

    @Published var mainPage: MainPage = .home

    /// One step back: report to its session, session to the grid, grid to Home.
    func goBack() {
        switch mainPage {
        case .report(let id): mainPage = .detail(id)
        case .detail: mainPage = .sessions
        case .sessions: mainPage = .home
        case .home: break
        }
    }

    /// The full report for the session being looked at.
    func openReport() {
        if case .detail(let id) = mainPage { mainPage = .report(id) }
    }

    /// The Record view is showing, or is about to.
    var recordStudioShown: Bool { recordOnlyActive || startingRecordOnly }
    /// The Record view is up and nothing is being recorded.
    var recordStudioIdle: Bool { recordOnlyActive && !isRecording && !takeBusy }

    /// Get Ready, in Record mode: the picture half of a meeting's Start, with
    /// the tape left stopped.
    ///
    /// The same picture as a meeting - same look, same share, same camera and
    /// microphone - because the Webcam page is the one description of the
    /// picture and Record is just another place to send it. Everything else a
    /// Start does is left out: no meeting, no chat window, no tiling.
    ///
    /// Nothing is recorded and no folder is made: that waits for Record, so
    /// the picture can be looked at, adjusted and named first.
    func getReadyToRecord() {
        guard !isRunning, !sceneInUse, !isStopping else { return }
        isRunning = true
        startingRecordOnly = true
        studioPreviewOn = true
        statusLines = []
        Analytics.track(.sessionStart, [
            .mode: "record",
            .displays: String(NSScreen.screens.count)
        ])

        startTask = Task {
            do {
                try await buildScene()
                try Task.checkCancellation()
                recordOnlyActive = true
                // A second camera, if switching is on, and the director to cut
                // to it - the same as a meeting.
                bringInExtraCameras()
                log("Ready to record. Press Record when you are.")
            } catch {
                if error is CancellationError {
                    log("Get Ready cancelled.")
                } else {
                    log("Couldn\u{2019}t get ready to record: \(error.localizedDescription)")
                    Analytics.failure("record_start")
                }
                // Left as Stop would leave it, so the next try begins clean
                // and no camera stays open behind an abandoned attempt.
                await tearDownRecordingScene()
            }
            isRunning = false
            startingRecordOnly = false
        }
    }

    /// Record: a take, into a session folder of its own.
    ///
    /// Each take is a session in Sessions (kind "recording"), named by the
    /// name typed at the moment Record is pressed. No clip buffer: the whole
    /// take is on disk, so the clip shortcuts mark the recording itself, as
    /// they do whenever one is running.
    func startTake() {
        guard recordOnlyActive, !isRecording, !isSavingRecording, !takeBusy, !isStopping else { return }
        takeBusy = true
        let startedAt = Date()
        let folder = SessionFolders.uniqueSessionFolder(
            named: SessionFolders.sessionFolderName(className: className, started: startedAt,
                                                    fallback: "Recording"),
            in: SessionFolders.recordingsDirectory)
        sessionFolder = folder
        sessionStartedAt = startedAt
        Task {
            do {
                try await beginRecording()
                // Only once the tape is rolling: a take that fails before
                // this leaves an empty folder, which is then removed.
                var metadata = SessionMetadata()
                metadata.kind = SessionMetadata.Kind.recording.rawValue
                let typed = SessionFolders.sanitizedClassName(className)
                metadata.title = typed.isEmpty ? nil : typed
                metadata.save(in: folder)
                log("Recording into \u{201C}\(folder.lastPathComponent)\u{201D} in Documents/Greenroom.")
            } catch {
                log("Couldn\u{2019}t start recording: \(error.localizedDescription)")
                Analytics.failure("record_start")
                discardEmptySessionFolder()
                sessionFolder = nil
                sessionStartedAt = nil
            }
            takeBusy = false
        }
    }

    /// Stop, in the Record view: the file is finished and saved, the picture
    /// stays up for the next take.
    func stopTake() {
        guard recordOnlyActive, isRecording, !takeBusy else { return }
        takeBusy = true
        Task {
            let saved = await finishTake()
            takeBusy = false
            // Last, as after a class: the upload question waits for
            // everything else to have finished.
            if let saved { recordingFinished(path: saved) }
        }
    }

    /// Finishes the tape, adopts the clip marks and closes the take's
    /// session. Returns the saved file's path.
    private func finishTake() async -> String? {
        var saved: String?
        if isRecording {
            isSavingRecording = true
            isRecording = false
            let stopped = await recorder?.stop()
            isSavingRecording = false
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

    /// Done, in the Record view: asks first when a take is rolling, because
    /// leaving is the one button that would end it. Cancel keeps recording.
    func confirmAndCloseRecordStudio() {
        guard recordStudioShown, !isStopping else { return }
        if isRecording {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Stop recording and leave?"
            alert.informativeText = "The recording is finished and saved to Documents/Greenroom first, then the camera turns off."
            alert.addButton(withTitle: "Stop and Save")
            alert.addButton(withTitle: "Keep Recording")
            // The reflex answer is the one that loses nothing.
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        stopRecordingSession()
    }

    /// Leaves the Record view: any take finished and saved first, then the
    /// picture torn down exactly as End Session leaves it, so the camera light
    /// goes off.
    ///
    /// A Get Ready still in flight is cancelled and then WAITED for, unlike a
    /// meeting's. Its steps are not cancellation-aware, so without the wait a
    /// take could start after this had already decided there was none to stop.
    func stopRecordingSession() {
        guard !isStopping else { return }
        isStopping = true
        let pending = startTask
        pending?.cancel()
        Task {
            await pending?.value
            log("Stopping\u{2026}")
            let saved = await finishTake()
            // A start that failed has already torn down; this one has not.
            if recordOnlyActive { await tearDownRecordingScene() }
            recordOnlyActive = false
            isStopping = false
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
        stopStage()
    }

    private func tearDownRecordingScene() async {
        studioPreviewOn = false
        await tearDownStage()
        publishPreviewFrame(nil)
        resumePreviewIfWanted()
    }

    /// The chosen main-pane app's user-facing name, for buttons and logs.
    // MARK: Live shape preview (Settings -> Webcam)
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
    private var shapePreviewOn = false
    private var shapePreviewApply: Task<Void, Never>?
    private let previewSink = StagePreviewSink()
    private var previewAttached = false

    /// Starts showing the picture. Outside a session the compositor is started
    /// for it, with the chosen look, so the preview shows what the NEXT
    /// session will send; during a live session it simply mirrors that one.
    /// Never asks for a permission: with Screen Recording off the picture is
    /// the camera alone.
    func startShapePreview() {
        guard !shapePreviewOn else { return }
        shapePreviewOn = true
        StageScreenSource.log("Settings preview opened.")
        attachPreview()
    }

    private func attachPreview() {
        guard shapePreviewOn || studioPreviewOn, !previewAttached else { return }
        if !sceneInUse, !isRunning {
            guard let stage = ensureStage() else { return }
            stage.start(makeStageConfiguration())
        }
        guard let stage else { return }
        previewSink.onPicture = { [weak self] image in self?.publishPreviewFrame(image) }
        stage.addSink(previewSink)
        previewAttached = true
    }

    /// After a session ends, a Settings window still open gets its preview back.
    private func resumePreviewIfWanted() {
        previewAttached = false
        if shapePreviewOn { attachPreview() }
    }

    /// Looks through one camera so Settings can show the angle it reads you
    /// at while it is being aimed.
    ///
    /// CameraProbe opens the camera the same way the stage does (a plain
    /// capture session). Idle only: during a class the director reads the
    /// stage's own frames and this would be a second opener of the camera.
    func aimCamera(uid: String) {
        guard !sceneInUse else { return }
        cameraProbe.start(uid: uid)
    }

    func stopAiming() { cameraProbe.stop() }

    func stopShapePreview() {
        StageScreenSource.log("Settings preview closed\(!sceneInUse && !isRunning ? "; the picture stops with it" : "").")
        shapePreviewOn = false
        shapePreviewApply?.cancel()
        // The Record view is still watching the same picture: one compositor
        // serves both, and the last to leave turns the light off.
        if studioPreviewOn { return }
        if let stage, previewAttached { stage.removeSink(previewSink) }
        previewAttached = false
        // The preview opened the camera; a session that is not running has
        // no use for it, and the camera light should go off.
        if !sceneInUse, !isRunning { stopStage() }
        publishPreviewFrame(nil)
    }

    private func publishPreviewFrame(_ frame: NSImage?) {
        shapePreview.frame = frame
        let aspect = frame?.size
        if aspect != shapePreviewAspect { shapePreviewAspect = aspect }
    }

    /// Applies the current shape, placement, share and cameras to the picture,
    /// latest wins. Every control on the Webcam tab calls this; a burst of
    /// changes (a slider, several clicks) cancels what it supersedes instead
    /// of queuing. Works the same live in a class as in the idle preview.
    /// `rebuild` is kept for the callers that changed what is shared; the
    /// compositor swaps the share without blanking the picture either way.
    func requestShapeApply(rebuild: Bool = false) {
        // Choosing a screen-based tile is asking for the screen: if macOS has
        // not allowed it, say where, once.
        if rebuild, shareTarget.kind != .nothing, !StageCompositor.screenRecordingGranted {
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
        guard let stage, stage.status.isRunning || sceneInUse || isRunning || shapePreviewOn else { return }
        stage.update(makeStageConfiguration())
    }

    var mainAppDisplayName: String {
        AppCatalog.displayName(forBundleID: mainAppBundleID) ?? "Main App"
    }

    /// Opens the main-pane app tiled to its slice, using the saved layout
    /// (+ default website when it's a browser). Chrome goes through its
    /// AppleScript path; everything else launches and AX-tiles, which can
    /// take a few seconds for a cold-started app - hence the Task.
    func openMainAppWindow() {
        Task {
            if let error = await MainPaneManager.openWindow(bundleID: mainAppBundleID,
                                                            urlString: mainAppURL,
                                                            layout: workspaceLayout) {
                log(error)
            }
        }
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
        guard !sdkClientID.isEmpty, !sdkClientSecret.isEmpty else {
            throw NSError(domain: "Greenroom", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Add the Meeting SDK Client ID and Secret in Settings (\u{2318},) \u{2192} Zoom. Greenroom sends your screen and camera through its own Zoom client, so it needs them."
            ])
        }

        isConnectingChat = true
        defer { isConnectingChat = false }

        log("Starting the meeting in Greenroom's built-in Zoom client\u{2026}")
        try await zoomChatClient.ensureReady(clientID: sdkClientID, clientSecret: sdkClientSecret)
        await settleBeforeJoining()
        zoomChatClient.setDualScreenMode(sessionArranges && galleryWindowExists)

        try await ensurePictureInstalled()
        reportMeetingVideo()
        applyMeetingMicrophone()

        let name = userDisplayName.isEmpty ? NSFullUserName() : userDisplayName
        try await zoomChatClient.startAsHost(meetingNumber: meeting.number, zak: zak, displayName: name, enableMedia: true)

        if let controller = zoomChatClient.chatController() {
            zoomChatBridge.attach(to: controller)
        }
        if sessionArranges { ChatWindowController.show(chat: zoomChatBridge, layout: workspaceLayout) }
        log("Meeting is live \u{2014} you're hosting from Greenroom.")

        if sessionArranges {
            presentMeetingSurfaces(resetQuickHideToDefault: true) // session start = the mode's default state
            finalizeLayout()
        }
    }

    /// Join Existing via the built-in client - you as one participant,
    /// camera/mic live, chat as yourself, window parked top-right. The SDK can
    /// only join meetings hosted under the account that owns the Marketplace
    /// app (Zoom rejects others as error 63, confirmed by live testing); that
    /// fails with a plain message saying what to do, rather than handing the
    /// meeting to the Zoom app, which cannot receive Greenroom's picture.
    private func joinAllInOne() async throws {
        guard !sdkClientID.isEmpty, !sdkClientSecret.isEmpty else {
            throw NSError(domain: "Greenroom", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Add the Meeting SDK Client ID and Secret in Settings (\u{2318},) \u{2192} Zoom. Greenroom sends your screen and camera through its own Zoom client, so it needs them."
            ])
        }
        isConnectingChat = true
        defer { isConnectingChat = false }

        log("Joining meeting \(meetingNumber) in Greenroom's built-in Zoom client\u{2026}")
        try await zoomChatClient.ensureReady(clientID: sdkClientID, clientSecret: sdkClientSecret)
        await settleBeforeJoining()
        zoomChatClient.setDualScreenMode(sessionArranges && galleryWindowExists)

        try await ensurePictureInstalled()
        reportMeetingVideo()
        applyMeetingMicrophone()

        let name = userDisplayName.isEmpty ? NSFullUserName() : userDisplayName

        // The account's OWN meetings (the Scheduled list) must be STARTED
        // with a fresh ZAK, not joined: the SDK authenticates the app,
        // not the Zoom user, so a plain join arrives as an anonymous
        // participant and Zoom throws up a "Claim host" key prompt
        // instead of promoting (seen live). Falls back to a normal join
        // if the ZAK fetch fails (e.g. missing user-token scope).
        var startedAsHost = false
        if isOwnScheduledMeeting {
            do {
                log("This meeting is yours \u{2014} starting it as host\u{2026}")
                let zak: String
                if let prefetched = prefetchedZAK, prefetched.meetingNumber == meetingNumberDigits,
                   Date().timeIntervalSince(prefetched.fetchedAt) < 600 {
                    // Warmed when the meeting was picked from the
                    // Scheduled menu - saves the fetch's network time.
                    zak = prefetched.zak
                } else {
                    let (account, client, secret) = (s2sAccountID, s2sClientID, s2sClientSecret)
                    zak = try await withStartTimeout(20, step: "Getting your host key from Zoom",
                                                     advice: "Joining as a participant instead.") {
                        try await ZoomServerToServerClient.fetchZAK(accountID: account, clientID: client, clientSecret: secret)
                    }
                }
                try await zoomChatClient.startAsHost(meetingNumber: meetingNumber, zak: zak, displayName: name, enableMedia: true)
                startedAsHost = true
            } catch {
                log("\(error.localizedDescription) \u{2014} joining as a participant instead.")
            }
        }

        if !startedAsHost {
            do {
                try await zoomChatClient.join(meetingNumber: meetingNumber, password: meetingPassword, displayName: name, enableMedia: true)
            } catch {
                if (error as? ZoomMeetingSDKError)?.isCrossAccountRejection == true {
                    throw NSError(domain: "Greenroom", code: 22, userInfo: [
                        NSLocalizedDescriptionKey: "That meeting is hosted on another Zoom account, and Greenroom's Zoom client can only join meetings hosted under the account that owns your Meeting SDK app. Ask the host to run it from your account, or use New Meeting."
                    ])
                }
                throw error
            }
        }

        if let controller = zoomChatClient.chatController() {
            zoomChatBridge.attach(to: controller)
        }
        if sessionArranges { ChatWindowController.show(chat: zoomChatBridge, layout: workspaceLayout) }
        log(startedAsHost
            ? "Meeting is live \u{2014} you're hosting from Greenroom."
            : "In the meeting.")

        if sessionArranges {
            presentMeetingSurfaces(resetQuickHideToDefault: true) // session start = the mode's default state
            finalizeLayout()
        }
    }

    /// Whether the Join Existing target is one of the account's own
    /// meetings - i.e. it appears in the Scheduled list fetched with the
    /// S2S credentials. Own meetings get host-started; everything else
    /// gets a plain join.
    private var isOwnScheduledMeeting: Bool {
        !s2sAccountID.isEmpty && !s2sClientID.isEmpty && !s2sClientSecret.isEmpty
            && scheduledMeetings.contains { String($0.id) == meetingNumberDigits }
    }

    /// Parks the built-in client's meeting window into the side column's
    /// top slot and keeps the chat aligned below it - all plain NSWindow
    /// work, since the window belongs to this process. Skipped entirely
    /// when the Zoom tile is toggled out of the side column: the meeting
    /// window then stays wherever it is.
    /// Puts the meeting on screen. Two very different mechanisms behind one
    /// call, so the session flows do not have to know which mode they are in.
    ///
    /// Default Zoom UI: the SDK owns its meeting windows, so Greenroom hunts
    /// for them, parks one in the side column and pins the other to the
    /// extended display. That machinery is the source of the tug-of-war, the
    /// gallery landing on the wrong display, and the info popup being adopted
    /// as the tile.
    ///
    /// Custom UI: there are no SDK windows at all. The SDK renders into a view
    /// we own, so there is nothing to hunt, park, pin or defend against. The
    /// participant gallery is not built for this mode yet - the speaker tile is.
    private func presentMeetingSurfaces(resetQuickHideToDefault: Bool) {
        guard zoomChatClient.didUseCustomUI else {
            // The panel is opened optimistically on the first frame of a start,
            // from the customUIMode SETTING, because didUseCustomUI is not known
            // until the SDK has initialised - long after the blank it exists to
            // fill. If the SDK went the other way, take it back down: in default
            // Zoom-UI mode the SDK owns its own gallery and ours would be a
            // second, stale one.
            customUIGridTask?.cancel()
            customUIGridTask = nil
            ParticipantGridWindowController.close()
            parkBuiltInMeetingWindow(resetQuickHideToDefault: resetQuickHideToDefault)
            placePeopleViewWindow()
            return
        }
        ensureMeetingControls()
        startCustomUIGridFollow()
        placeCustomSurfaces()
    }

    /// Puts Greenroom's meeting window and the chat where an arranged custom-UI
    /// session wants them. On a single display the window takes Zoom's old slot
    /// with the chat tucked underneath; on a reference display the full panel
    /// is there and the chat takes the whole column.
    private func placeCustomSurfaces() {
        guard sessionArranges else { return }
        if ParticipantGridWindowController.isSlot, let slot = ChatWindowController.zoomSlotNSFrame(for: workspaceLayout) {
            speakerTileQuickHidden = false
            ParticipantGridWindowController.show()   // Snap Back never leaves it hidden
            ParticipantGridWindowController.place(slot: slot)
            if let screen = DisplayResolver.mainDisplayScreen() {
                let ax = CGRect(x: slot.origin.x, y: screen.frame.height - slot.maxY,
                                width: slot.width, height: slot.height)
                ChatWindowController.adjustBelowZoom(actualZoomFrameAX: ax, layout: workspaceLayout)
            }
        } else {
            speakerTileQuickHidden = true
            ChatWindowController.fillSideColumn(layout: workspaceLayout)
        }
    }

    /// Where Greenroom's meeting window goes right now, and in which form.
    ///
    /// No layout: a window the teacher owns, filling the reference display the
    /// first time if there is one, else centred on the main display. Arranged
    /// with a reference display: the full panel there. Arranged on one display:
    /// the window takes Zoom's old slot. Never borderless but for the full panel.
    /// Worked out every tick, so a display plugged in mid-class moves it.
    private func meetingSurfaceTarget() -> (screen: NSScreen, form: ParticipantGridWindowController.Form)? {
        let reference = peopleViewTargetScreen()
        if !sessionArranges {
            guard let screen = reference ?? DisplayResolver.mainDisplayScreen() else { return nil }
            return (screen, .meeting(fillsScreen: reference != nil))
        }
        if peopleViewWanted, let reference { return (reference, .reference) }
        guard let screen = DisplayResolver.mainDisplayScreen() else { return nil }
        if let slot = ChatWindowController.zoomSlotNSFrame(for: workspaceLayout) {
            return (screen, .slot(slot))
        }
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
        // Idempotent. It is called more than once: on the first frame of a start
        // so the reference panel can show progress, and again once the meeting
        // is live. Restarting would re-stamp the session clock.
        if customUIGridTask != nil { return }
        // Surface subscription refusals. A black tile with no explanation was
        // exactly how this went unnoticed until a second person joined.
        zoomChatClient.onVideoSubscribeFailure = { [weak self] message in
            self?.log(message)
        }
        ParticipantGridWindowController.configure(
            client: zoomChatClient,
            chat: zoomChatBridge,
            controls: meetingControls,
            log: { [weak self] message in self?.log(message) },
            endSession: { [weak self] in self?.stop() },
            showChat: { [weak self] in
                guard let self else { return }
                if self.sessionArranges {
                    ChatWindowController.reveal(layout: self.workspaceLayout)
                } else {
                    ChatWindowController.show(chat: self.zoomChatBridge, layout: nil)
                }
            },
            toggleRecording: { [weak self] in self?.toggleRecording() },
            snapBack: { [weak self] in self?.snapWindowsBack() },
            showMainWindow: { [weak self] in self?.showMainWindow() })
        // The window the teacher closes by hand: stop feeding it, and let the pill
        // (or the slot) take over. After the close that triggered this has finished.
        ParticipantGridWindowController.onUserClosed = { [weak self] in
            Task { @MainActor in self?.meetingWindowClosedByUser() }
        }
        // A join or a leave shows at once rather than at the next poll.
        zoomChatClient.onParticipantCountChanged = {
            ParticipantGridWindowController.refreshNow()
        }
        let startedAt = sessionStartedAt ?? Date()
        let tick: @MainActor () -> Bool = { [weak self] in
            guard let self, let target = self.meetingSurfaceTarget() else { return false }
            if target.form.isMeeting {
                // A display plugged in mid-class can turn the full panel into a
                // meeting window, which needs the controls the panel was
                // configured without.
                self.ensureMeetingControls()
                ParticipantGridWindowController.controls = self.meetingControls
            }
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
        if let target = meetingSurfaceTarget() {
            Analytics.track(.surfaceShown, [
                .surface: "participants",
                .placement: target.form.isMeeting ? "main_window" : "reference_display"
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

    private func parkBuiltInMeetingWindow(resetQuickHideToDefault: Bool = false) {
        // The follow loop is what arranges the chat and the tile; a session
        // that arranges nothing never starts it, even for an on-demand chat.
        guard sessionArranges else { return }
        layoutFollowTask?.cancel()
        layoutFollowTask = Task {
            var parked = false
            var quickHideAnnounced = false
            var lastFrame = CGRect.null
            // True while the tile in use is only a stand-in, adopted because
            // the ideal window had not appeared yet. Drives the handoff below.
            var tileIsFallback = false
            demotedStrayWindowNumbers.removeAll() // fresh session, fresh logs
            rejectedVideoCandidateNumbers.removeAll()
            // The quick-hide MODE's default state: enabled means sessions
            // begin with the tile hidden and the chat full-height;
            // \u{2325}\u{2318}Z brings the speaker up on demand.
            // Only SESSION STARTS reset to the default - a live layout
            // re-apply or snap-back must not undo a mid-class toggle.
            if resetQuickHideToDefault {
                speakerTileQuickHidden = speakerTileShortcutEnabled
            }
            // SDK-level first: both meeting views out of fullscreen. A
            // window in a fullscreen Space ignores setFrame, so nothing
            // below works until this has taken effect.
            zoomChatClient.exitFullScreen()
            var waitedTicks = 0
            gridCorrectionStreak = 0
            gridCorrectionHoldUntilTick = 0
            while !Task.isCancelled, ChatWindowController.isOpen {
                // Ref death (the SDK recreates its windows on activation -
                // a CLICK does it) leaves `parked` stale-true, so the
                // recreated tile would never re-park and camps wherever
                // the SDK put it - usually over the main screen's capture.
                if builtInMeetingWindow == nil { parked = false }
                // Hand off from a stand-in to the real thing. `tile` below
                // short-circuits on builtInMeetingWindow, so without this a
                // stand-in adopted at the 4s mark would stay the tile for the
                // whole session.
                if tileIsFallback, workspaceLayout.sideShowsZoomTile,
                   let preferred = preferredTileWindow(), preferred !== builtInMeetingWindow {
                    let wasStandingIn = builtInMeetingWindow != nil
                    builtInMeetingWindow = preferred
                    tileIsFallback = false
                    parked = false
                    // Only a real swap is worth announcing; reaching here with
                    // nothing adopted yet is just a first pick.
                    if wasStandingIn {
                        log("Speaker tile switched to Zoom's clean speaker view.")
                    }
                }
                // The stray guard below must run even with the Zoom tile
                // toggled off - that's when the primary window has no slot
                // and is most likely to sit fullscreen over the capture.
                var tile: NSWindow? = workspaceLayout.sideShowsZoomTile
                    ? builtInMeetingWindow ?? tileWindowCandidate(waitedTicks: waitedTicks)
                    : nil
                // Geometry sanity: a "tile" living on the people-view
                // display IS the participant grid - stale identity after
                // the SDK recreated its windows, or the SDK swapped roles.
                // Parking/hiding it from here while the pinning loop drags
                // it back was the visible 2s tug-of-war (reported live
                // twice; the identity-only exclusion in
                // tileWindowCandidate dies with the weak ref, this check
                // doesn't).
                if peopleViewWanted, let candidate = tile, windowIsOnPeopleViewTarget(candidate) {
                    if candidate === builtInMeetingWindow {
                        builtInMeetingWindow = nil
                        parked = false
                    }
                    tile = nil
                }
                if tile != nil, builtInMeetingWindow == nil {
                    tileIsFallback = preferredTileWindow() == nil
                }
                if let window = tile {
                    if window.styleMask.contains(.fullScreen) {
                        // Still fullscreen (the exit animates out over ~1s,
                        // or the SDK re-entered it) - kick again, park on a
                        // later tick once it can actually be framed.
                        window.toggleFullScreen(nil)
                        parked = false
                    } else if speakerTileQuickHidden {
                        // Quick-hide mode: the tile stays identified (so
                        // \u{2325}\u{2318}Z can summon it) but
                        // HIDDEN, with the chat owning the full column.
                        // Re-asserts every tick, so the SDK re-showing
                        // the window (state changes do that) gets undone.
                        if builtInMeetingWindow == nil {
                            builtInMeetingWindow = window
                            if !galleryWindowExists { zoomChatClient.simplifyMeetingView() }
                        }
                        if window.isVisible {
                            window.orderOut(nil)
                            ChatWindowController.fillSideColumn(layout: workspaceLayout)
                            if !quickHideAnnounced {
                                quickHideAnnounced = true
                                log("Speaker tile starts hidden (quick-hide mode) \u{2014} chat has the full column; \u{2325}\u{2318}Z shows the speaker.")
                            }
                        }
                        parked = false
                    } else if !parked, let slot = ChatWindowController.zoomSlotNSFrame(for: workspaceLayout) {
                        window.level = .normal // clear any stale floating level
                        if !window.isVisible { window.orderFront(nil) } // e.g. mode just turned off
                        window.setFrame(slot, display: true)
                        // Single-window sessions: strip the tile down to a
                        // plain current-speaker view (needs the window to
                        // exist, hence here and not at connect). DUAL-SCREEN
                        // sessions must NOT do this - the primary view is
                        // switched to the gallery grid by the people-view
                        // placer, and switching to speaker here would flip
                        // it back; the tile (the secondary window) already
                        // shows Zoom's complementary clean speaker view.
                        if !galleryWindowExists {
                            zoomChatClient.simplifyMeetingView()
                        }
                        // Remembered so the people-view placer knows which
                        // window is the tile and which goes to the extended
                        // display.
                        builtInMeetingWindow = window
                        parked = true
                    }
                    let frame = window.frame
                    // Chat-follow only when the tile is actually shown -
                    // in quick-hide the chat owns the full column and must
                    // not be re-snapped under a hidden tile's frame.
                    // Tolerant compare, for the same reason the grid's is:
                    // an exact != on a frame the SDK reports back with
                    // sub-point jitter would re-snap the chat every tick
                    // forever.
                    let tileMoved = abs(frame.origin.x - lastFrame.origin.x) > 2
                        || abs(frame.origin.y - lastFrame.origin.y) > 2
                        || abs(frame.width - lastFrame.width) > 2
                        || abs(frame.height - lastFrame.height) > 2
                    if !speakerTileQuickHidden, tileMoved, let screen = DisplayResolver.mainDisplayScreen() {
                        lastFrame = frame
                        let axFrame = CGRect(x: frame.origin.x,
                                             y: screen.frame.height - frame.maxY,
                                             width: frame.width,
                                             height: frame.height)
                        ChatWindowController.adjustBelowZoom(actualZoomFrameAX: axFrame, layout: workspaceLayout)
                    }
                }
                demoteStrayMeetingWindows()
                maintainPeopleViewPlacement(tick: waitedTicks)
                waitedTicks += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Placement is not one-shot: the SDK re-positions its windows on
    /// meeting state changes, which intermittently dumped the placed
    /// participant gallery back onto the MAIN display over the workspace
    /// (reported live: "stuck on the main app window") - and the stray
    /// guard deliberately ignores the tracked gallery, so nothing fixed
    /// it. Every follow-loop tick: re-frame the gallery whenever it has
    /// drifted off its target display, eject it from fullscreen, and if
    /// its window vanished entirely (SDK recreated it), re-run the placer
    /// every ~30s.
    private func maintainPeopleViewPlacement(tick: Int) {
        guard galleryWindowExists else { return }
        guard let target = peopleViewTargetScreen() else {
            keepBackgroundGalleryBehind()
            return
        }
        if let gallery = peopleViewWindow {
            // Above the menu bar and the Dock, re-asserted every tick because
            // the SDK resets the level whenever it recreates the window. At
            // .normal the grid covers the display's bounds but the menu bar
            // and Dock still draw over it, which is not what "full screen on
            // the reference display" means.
            if windowIsOnPeopleViewTarget(gallery) { gallery.level = .statusBar }
            // The grid STAYS on its display, focused or not (explicit
            // requirement) - clicking it must not strand it wherever the
            // SDK re-homed it. The only interaction respected is an
            // active mouse-drag on the window itself; everything else
            // gets corrected immediately.
            if gallery.isKeyWindow && NSEvent.pressedMouseButtons != 0 { return }
            if tick < gridCorrectionHoldUntilTick { return } // standing down (see below)
            if gallery.styleMask.contains(.fullScreen) {
                gallery.toggleFullScreen(nil) // re-framed on a later tick
            } else if peopleViewHasDrifted(gallery) {
                gridCorrectionStreak += 1
                if gridCorrectionStreak >= 6 {
                    // Corrected 6 consecutive ticks and something moved it
                    // right back each time.
                    //
                    // History worth keeping: this backstop used to fire in
                    // EVERY session about 12s in, and the cause was not an
                    // external mover at all - the drift test compared the
                    // window against the display's full frame, which AppKit
                    // will never grant a titled window (it reserves the
                    // menu-bar strip), so every tick read as drift. That is
                    // fixed; see peopleViewGrantedFrame. Reaching six here
                    // now means a real mover, most likely the SDK's own
                    // dual-monitor manager, which exposes no placement API
                    // to override (ZoomSDKMeetingConfiguration.monitorID is
                    // a screen-share knob, checked).
                    //
                    // Endless correction is a visible bounce - worse than
                    // either stable state. Stand down, retry in ~2 minutes;
                    // Snap Windows Back restarts the loop and re-arms.
                    gridCorrectionHoldUntilTick = tick + 60
                    gridCorrectionStreak = 0
                    log("Something keeps re-placing the participant grid within seconds \u{2014} pausing the tug-of-war for 2 minutes. Snap Windows Back (\u{2325}\u{2318}S) re-places it now.")
                } else if gridCorrectionStreak == 3 {
                    // Raw re-framing isn't sticking: the SDK likely lost or
                    // changed its dual-screen state when it recreated the
                    // window. Re-run the FULL placement once - it re-frames
                    // AND re-asserts gallery-on-primary via the SDK's own
                    // API, resyncing its bookkeeping instead of fighting it.
                    placePeopleViewWindow()
                } else {
                    gallery.setFrame(target.frame, display: true)
                    // Record what we actually GOT, not what we asked for -
                    // see peopleViewGrantedFrame. Only trust the readback if
                    // the window really landed on the target display: if
                    // something yanked it away inside this same tick,
                    // adopting that frame as "correct" would make the loop
                    // stop correcting a genuinely misplaced grid.
                    if windowIsOnPeopleViewTarget(gallery) {
                        peopleViewGrantedFrame = gallery.frame
                    }
                    // orderFront only when actually hidden: ordering an SDK
                    // window front on every correction can itself provoke
                    // the SDK's re-layout, feeding the very loop this fixes.
                    if !gallery.isVisible { gallery.orderFront(nil) }
                    log("Participant grid drifted \u{2014} moved back to \u{201C}\(target.localizedName)\u{201D}.")
                }
            } else {
                gridCorrectionStreak = 0 // stable tick - not a fight
            }
        } else if tick > 0, tick % 15 == 0 {
            placePeopleViewWindow() // window gone (SDK recreated it) - re-hunt
        }
    }

    /// Which SDK window becomes the parked side-column tile.
    /// Single-screen sessions: the primary (only) meeting window.
    /// Dual-screen (people view) sessions: the SECONDARY window - Zoom
    /// puts the meeting controls/toolbar on the PRIMARY, so the primary
    /// belongs full-screen on the extended display (gallery grid +
    /// controls) and the clean video-only secondary makes the tile.
    /// (Parking the primary put a control-cluttered tile on the main
    /// display and the clean speaker view on the extended one - exactly
    /// backwards, reported live.) Falls back to the primary if the
    /// secondary hasn't appeared after ~20s, so the tile never stays
    /// unparked.
    private func tileWindowCandidate(waitedTicks: Int) -> NSWindow? {
        // NEVER the placed participant grid. Two filters, because identity
        // alone failed live: `!== peopleViewWindow` dies the moment the SDK
        // recreates its windows (a click on the grid does exactly that),
        // and the recreated grid then got seized as the tile and parked on
        // the main screen while the pinning loop dragged it back - the 2s
        // tug-of-war, twice reported. Geometry survives recreation: a
        // window living on the people-view display is the grid's, never
        // the tile's, no matter what our weak refs say.
        if let preferred = preferredTileWindow() { return preferred }
        // Nothing ideal yet. Fall back to whatever video window we have after
        // ~4s (2 ticks) rather than the old ~20s.
        //
        // The old wait left the feature DEAD for 20s of every multi-display
        // session: no tile identified means builtInMeetingWindow stays nil,
        // so toggleSpeakerTile bailed out and the column was never parked -
        // about a minute from launch, counting the pipeline. Shortening it is
        // only safe because the follow loop now hands off to the ideal window
        // if it shows up later (see tileIsFallback); without that handoff a
        // short wait would lock the WRONG window in permanently, which is the
        // control-cluttered-tile bug this wait was originally added to avoid.
        return waitedTicks >= 2 ? tileCandidates().first : nil
    }

    /// Video windows that could serve as the tile, newest last. Never the
    /// placed participant grid: identity alone failed live (the weak ref dies
    /// when the SDK recreates its windows, which a click does), so geometry
    /// backs it up - a window on the people-view display is the grid's.
    private func tileCandidates() -> [NSWindow] {
        meetingVideoWindowCandidates().filter {
            $0 !== peopleViewWindow && !(peopleViewWanted && windowIsOnPeopleViewTarget($0))
        }
    }

    /// The window we actually WANT as the tile, or nil if it does not exist
    /// yet. Single-screen: the only meeting window. Dual-screen: the SECONDARY
    /// one, because Zoom puts the meeting controls on the primary and the
    /// clean video-only view on the secondary - taking the primary put a
    /// control-cluttered tile on the main display and the clean speaker view
    /// on the extended one, exactly backwards, reported live.
    private func preferredTileWindow() -> NSWindow? {
        let candidates = tileCandidates()
        guard galleryWindowExists else { return candidates.first }
        return candidates.count >= 2 ? candidates.last : nil
    }

    /// Keeps the no-second-display gallery behind the workspace.
    ///
    /// The SDK raises its own windows on state changes - waiting room, share
    /// start - so one
    /// orderBack at placement time does not hold. Pushed back only when it has
    /// floated to the FRONT without being focused: a teacher who deliberately
    /// clicks into the grid keeps it, and it settles back on its own once they
    /// click away.
    private func keepBackgroundGalleryBehind() {
        guard let gallery = peopleViewWindow, gallery.isVisible else { return }
        guard !gallery.isKeyWindow, gallery.orderedIndex == 0 else { return }
        gallery.orderBack(nil)
    }

    /// Whether a window currently lives on the people-view target display,
    /// judged by its frame's center. This is the recreation-proof role
    /// test: weak identity dies whenever the SDK rebuilds its windows -
    /// which is exactly when roles need re-deriving - but a recreated
    /// window reappears at its old frame, so geometry still knows which
    /// job it had. Both the tile picker and the gallery picker derive
    /// roles from THIS same rule, so they can no longer claim the same
    /// window for opposite placements.
    private func windowIsOnPeopleViewTarget(_ window: NSWindow) -> Bool {
        guard let target = peopleViewTargetScreen() else { return false }
        return target.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
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
        sessionArranges || !(isRunning || stageLive)
    }
    private var customUIGridTask: Task<Void, Never>?
    // MARK: Meeting window (custom UI)

    /// One set of controls per session, read by the meeting window's toolbar and
    /// by the floating pill. Made when the meeting is live, dropped with it.
    private(set) var meetingControls: MeetingControlsModel?

    private func ensureMeetingControls() {
        if meetingControls == nil { meetingControls = MeetingControlsModel(coordinator: self) }
    }

    /// Greenroom's own meeting window exists (on screen or not).
    var meetingWindowOpen: Bool { ParticipantGridWindowController.meetingWindowIsOpen }

    /// Opens the window, or brings it back from minimised, hidden or covered,
    /// without activating the app: the teacher's slides stay in front of
    /// Greenroom's own main window.
    func openMeetingWindow() {
        guard zoomChatClient.didUseCustomUI else { return }
        ensureMeetingControls()
        // The chat is a panel inside the window now; a loose chat window would
        // be a second copy of it. (An arranged session keeps its column.)
        if !sessionArranges, ChatWindowController.isOpen { ChatWindowController.close() }
        let alreadyOpen = ParticipantGridWindowController.meetingWindowIsOpen
        startCustomUIGridFollow()
        if alreadyOpen { ParticipantGridWindowController.show() }
        placeCustomSurfaces()
        MeetingControlBarController.reconcile(immediately: false)
    }

    func closeMeetingWindow() {
        guard customUIGridTask != nil || ParticipantGridWindowController.isOpen else { return }
        customUIGridTask?.cancel()
        customUIGridTask = nil
        ParticipantGridWindowController.close()
        zoomChatClient.onParticipantCountChanged = nil
        MeetingControlBarController.reconcile(immediately: false)
    }

    /// The close button. An arranged column gives the chat the room back.
    private func meetingWindowClosedByUser() {
        closeMeetingWindow()
        if sessionArranges, isRunning || stageLive {
            speakerTileQuickHidden = true
            ChatWindowController.fillSideColumn(layout: workspaceLayout)
        }
    }

    /// The pill's Meeting window button, and People when no window is up. With
    /// the window on screen it closes it; otherwise it brings it forward.
    func toggleMeetingWindow() {
        guard zoomChatClient.didUseCustomUI else { return }
        if ParticipantGridWindowController.meetingWindowIsShowing {
            closeMeetingWindow()
        } else {
            openMeetingWindow()
        }
    }

    private var gridCorrectionStreak = 0
    private var gridCorrectionHoldUntilTick = 0

    /// The frame the window server actually GRANTED the grid, which is not
    /// the frame we asked for. AppKit's constrainFrameRect keeps a titled
    /// window out of the menu-bar strip, so requesting a display's full
    /// frame comes back shorter - measured on this 1920x1080 display: asked
    /// for 1920x1080 at the origin, got 1920x1050 inset 30pt from the top.
    ///
    /// The maintain loop compares against THIS. It used to compare against
    /// the requested `screen.frame`, which therefore NEVER matched: every
    /// tick read as drift, "corrected" a window already sitting where it
    /// was allowed to sit, and tripped the six-strike backstop about 12s
    /// into every session. No external mover was needed to produce that:
    /// the loop did it alone.
    ///
    /// This was one of two self-inflicted halves; the other was the target
    /// display itself flipping with focus (see
    /// DisplayResolver.mainDisplayScreen). With both fixed, a backstop
    /// firing is evidence of a REAL mover - which has not been ruled out.
    private var peopleViewGrantedFrame: NSRect?

    /// Drift worth correcting: the grid left the display it belongs on, or
    /// it moved measurably away from the frame the window server granted
    /// it. Deliberately tolerant - a sub-point difference or the menu-bar
    /// clamp is not drift, and treating it as drift is what made this loop
    /// fight itself.
    private func peopleViewHasDrifted(_ window: NSWindow) -> Bool {
        let f = window.frame
        guard windowIsOnPeopleViewTarget(window) else {
            logGridDrift("left-display", found: f)
            return true
        }
        guard let granted = peopleViewGrantedFrame else { return false }
        let tolerance: CGFloat = 2
        let moved = abs(f.origin.x - granted.origin.x) > tolerance
            || abs(f.origin.y - granted.origin.y) > tolerance
            || abs(f.width - granted.width) > tolerance
            || abs(f.height - granted.height) > tolerance
        if moved { logGridDrift("reframed", found: f) }
        return moved
    }

    /// Diagnostic for the grid fight, to a FILE rather than the status log:
    /// the status log is user-facing and this is per-tick detail. Records
    /// where the grid was FOUND, which is the one thing the old logging
    /// never captured - it reported only where the grid was moved TO, so a
    /// persisting fight could not be attributed to anything.
    private func logGridDrift(_ kind: String, found: NSRect) {
        let granted = peopleViewGrantedFrame
        let line = "\(Self.quitLogStamp.string(from: Date())) grid-drift \(kind)"
            + " found=\(Int(found.origin.x)),\(Int(found.origin.y))"
            + " \(Int(found.width))x\(Int(found.height))"
            + " granted=" + (granted.map {
                "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))"
            } ?? "none")
            + " target=\(peopleViewTargetScreen()?.localizedName ?? "none")"
            + " streak=\(gridCorrectionStreak)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Greenroom-quit.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Single source of truth for whether the Start action can run. The
    /// main window and menu bar previously duplicated PARTIAL versions of
    /// this - the menu bar skipped the credential/meeting-ID checks, so
    /// "Start Meeting" was clickable with no credentials and "Join
    /// Meeting" with no meeting ID (Codex design audit #1).
    var startActionDisabled: Bool {
        if isRunning || sceneInUse || isStopping { return true }
        switch meetingMode {
        // Needs nothing but the camera and screen permissions, which Start checks itself.
        case .record: return false
        case .create: return s2sAccountID.isEmpty || s2sClientID.isEmpty
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
        // The Record view with the tape stopped is only a picture: nothing is
        // lost by quitting from it, so it is not asked about.
        !isStopping && (isRunning || (sceneInUse && !recordStudioIdle) || isRecording)
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
    func confirmQuitWhileLive() -> Bool {
        guard hasLiveSession || isUploadingToYouTube else { return true }
        // The quit may have been triggered from the menu bar while another app
        // held focus, so the alert has to come forward with the app.
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        if !hasLiveSession {
            // Only an upload is in flight: quitting abandons it (the recording
            // itself is safe on disk and can be uploaded again from Recordings).
            let percent = Int(((youtubeUploadProgress ?? 0) * 100).rounded())
            alert.messageText = "Quit Greenroom and cancel the YouTube upload?"
            alert.informativeText = "The upload is \(percent)% done. Quitting cancels it; the recording stays in Documents/Greenroom and can be uploaded again from Recordings."
        } else {
            alert.messageText = recordOnlyActive ? "Quit Greenroom and stop recording?" : "Quit Greenroom and end the class?"
            alert.informativeText = recordOnlyActive
                ? "The recording is finished and saved first."
                : isRecording
                ? "The recording is finished and saved first. Then the Zoom meeting ends for everyone when you're hosting, and your students are dropped from the call."
                : "The Zoom meeting ends for everyone when you're hosting, and your students are dropped from the call."
            if isUploadingToYouTube {
                alert.informativeText += " A YouTube upload in progress is cancelled too."
            }
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit Greenroom")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        // Hand the Return key to Cancel. Escape already maps to it as the
        // second button.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirmAndStop() {
        // Stopping a recording ends nothing for anybody else, so it is not
        // asked about: Stop, and the file is saved.
        if recordOnlyActive || (isRunning && startingRecordOnly) {
            stopRecordingSession()
            return
        }
        guard isRunning || stageLive else { return }
        NSApp.activate(ignoringOtherApps: true) // the hotkey fires while other apps are focused
        let alert = NSAlert()
        alert.messageText = "End the session?"
        alert.informativeText = "Ends the Zoom meeting for everyone when you're hosting (leaves it otherwise), saves any recording in progress, and stops the camera."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "End Session")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            stop()
        }
    }

    /// The menu bar's "Snap Windows Back": re-tiles everything to the
    /// session layout after the user has dragged windows around. Handles
    /// the built-in client's meeting window (ours, a plain NSWindow), and
    /// the follow loops those restart re-align the chat automatically.
    ///
    /// `userInitiated: false` is the same re-tiling after a display change: it
    /// leaves the person's quick-hide choice and the usage count alone.
    func snapWindowsBack(userInitiated: Bool = true) {
        guard layoutToolsAvailable else {
            log("Snap Windows Back skipped \u{2014} this session arranges no windows.")
            return
        }
        if userInitiated {
            Analytics.feature("snap_back")
            // Restore the quick-hide mode's DEFAULT state (hidden when the
            // mode is on, normal tile layout when off) - the parking loop
            // restarted below asserts it.
            speakerTileQuickHidden = speakerTileShortcutEnabled
        }
        builtInMeetingWindow?.level = .normal
        Task {
            if let error = await MainPaneManager.repositionFrontWindow(bundleID: mainAppBundleID, layout: workspaceLayout) {
                log(error)
            }
        }
        if ChatWindowController.isOpen {
            ChatWindowController.show(chat: zoomChatBridge, layout: workspaceLayout)
            // Custom UI places its own surfaces below (presentMeetingSurfaces);
            // Zoom's own tile is parked by the loop that restarts here, and
            // show() lays the chat out with the tile's slot reserved - wrong when
            // the quick-hide default just hid it, which left a ~350pt hole where
            // no tile was coming.
            if !zoomChatClient.didUseCustomUI, speakerTileQuickHidden {
                ChatWindowController.fillSideColumn(layout: workspaceLayout)
            }
        }
        // Snap Back is also the manual "fix the composite" action: hand the
        // picture its settings again alongside the window re-tiling.
        applyShapeForPreview()
        if zoomChatClient.didUseCustomUI {
            // Our own windows: re-place them rather than hunting for the SDK's.
            presentMeetingSurfaces(resetQuickHideToDefault: false)
        } else if !sdkMeetingWindows().isEmpty {
            parkBuiltInMeetingWindow()
            placePeopleViewWindow()
        }
    }

    // MARK: Displays coming and going

    /// One registration, at launch. Everything that reacts to a display being
    /// plugged in or pulled out hangs off the monitor\u{2019}s settled event, so
    /// there is exactly one place to read to learn what happens.
    private func observeDisplays() {
        ParticipantGridWindowController.readinessDismiss = { [weak self] in self?.dismissStartFailure() }
        ParticipantGridWindowController.readinessTryAgain = { [weak self] in self?.retryAfterFailure() }
        DisplayMonitor.shared.onChange { [weak self] change in self?.displaysChanged(change) }
    }

    /// The failure card\u{2019}s Close: clears the card and what drew it.
    private func dismissStartFailure() {
        guard !isRunning else { return }
        customUIGridTask?.cancel()
        customUIGridTask = nil
        ParticipantGridWindowController.close()
        ReadinessHUDController.close()
        finishStartReadiness()
    }

    /// The failure card\u{2019}s Try again: wait for the unwind of the failed start
    /// to finish (the Start guard refuses anything while it runs), then Start.
    private func retryAfterFailure() {
        dismissStartFailure()
        Task {
            for _ in 0..<50 where isRunning || isStopping {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            start()
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
        DisplayMonitor.rescueStrandedWindows { [weak self] line in self?.log(line) }
        syncReadinessHUD()

        if isRunning {
            displayChangedDuringStart = true
        } else if stageLive, zoomChatClient.isJoined, sessionArranges {
            snapWindowsBack(userInitiated: false)
        }
    }

    /// Menu bar's "Show Greenroom" - surfaces the main window.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Greenroom" }?.makeKeyAndOrderFront(nil)
    }

    /// The create-mode meeting, made WHILE the picture comes up (see the async
    /// lets in start()). nil in join mode - the guard at the use site is
    /// unreachable by construction.
    private func prepareMeetingIfNeeded() async throws -> ZoomServerToServerClient.CreatedMeeting? {
        guard meetingMode == .create else { return nil }
        // Both are network calls to Zoom with no limit of their own that a
        // person would call short. The clean-up is a courtesy and is dropped if
        // slow; the creation is the step the whole start needs.
        do {
            try await withStartTimeout(15, step: "Checking for meetings left running",
                                       advice: "Carrying on without it.") { await self.endStaleLiveMeetings() }
        } catch let error as StartTimeoutError {
            Self.sessionLog("Pre-flight: \(error.localizedDescription)")
        }
        return try await withStartTimeout(30, step: "Creating the meeting",
            advice: "Check your internet connection and the Server-to-Server credentials in Settings (\u{2318},) \u{2192} Zoom, then press Try again.") {
            try await self.createMeetingViaAPI()
        }
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
    private func endStaleLiveMeetings() async {
        guard !s2sAccountID.isEmpty, !s2sClientID.isEmpty, !s2sClientSecret.isEmpty else { return }
        let live = await ZoomServerToServerClient.liveMeetings(
            accountID: s2sAccountID, clientID: s2sClientID, clientSecret: s2sClientSecret)
        guard !live.isEmpty else {
            Self.sessionLog("Pre-flight: no meetings already live on the account.")
            return
        }
        log("\(live.count) meeting\(live.count == 1 ? " is" : "s are") still live on your Zoom account "
            + "\u{2014} ending \(live.count == 1 ? "it" : "them") first, or this start would collide.")
        for id in live {
            let ended = await ZoomServerToServerClient.endMeeting(
                id: id, accountID: s2sAccountID, clientID: s2sClientID, clientSecret: s2sClientSecret)
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
        let quietStarted = Date()
        if !(await DisplayMonitor.shared.awaitQuiet()) {
            log("A display is still changing \u{2014} starting anyway. If this start fails, wait a few seconds after plugging or unplugging a screen, then press Try again.")
        } else if Date().timeIntervalSince(quietStarted) > 1 {
            log("Waited for the screens to settle before joining.")
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
        guard !sdkClientID.isEmpty, !sdkClientSecret.isEmpty else { return }
        try? await zoomChatClient.ensureReady(clientID: sdkClientID, clientSecret: sdkClientSecret)
    }

    private func createMeetingViaAPI() async throws -> ZoomServerToServerClient.CreatedMeeting {
        log("Creating a new meeting\u{2026}")
        let meeting = try await ZoomServerToServerClient.startInstantMeeting(
            topic: "Greenroom Meeting",
            accountID: s2sAccountID,
            clientID: s2sClientID,
            clientSecret: s2sClientSecret
        )
        meetingNumber = meeting.number
        meetingPassword = meeting.password
        meetingCreatedHere = meeting.number
        log("Meeting \(meeting.number) created.")
        return meeting
    }

    // MARK: Scheduled meetings - pulled from the Zoom account with the
    // same S2S credentials that create meetings, so "Join Existing" can
    // offer the account's recurring class meeting instead of making the
    // user paste an ID every morning.

    @Published private(set) var scheduledMeetings: [ZoomServerToServerClient.ScheduledMeeting] = []
    @Published private(set) var isLoadingScheduled = false

    func refreshScheduledMeetings() {
        loadSecretsIfNeeded()
        guard !isLoadingScheduled else { return }
        guard !s2sAccountID.isEmpty, !s2sClientID.isEmpty, !s2sClientSecret.isEmpty else {
            log("Can't list your Zoom meetings \u{2014} add the Server-to-Server credentials in Settings (\u{2318},) \u{2192} Zoom first.")
            return
        }
        isLoadingScheduled = true
        Task {
            do {
                let result = try await ZoomServerToServerClient.listScheduledMeetings(
                    accountID: s2sAccountID, clientID: s2sClientID, clientSecret: s2sClientSecret)
                scheduledMeetings = result.meetings
                if let warning = result.warning { log(warning) }
                if scheduledMeetings.isEmpty {
                    log("No scheduled meetings on this Zoom account. Recurring ones scheduled at zoom.us/meeting/schedule will show up here.")
                }
            } catch {
                log(error.localizedDescription)
            }
            isLoadingScheduled = false
        }
    }

    /// Fills the Join Existing fields from a picked scheduled meeting.
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

    private var prefetchedZAK: (meetingNumber: String, zak: String, fetchedAt: Date)?

    private func prefetchZAK(for number: String) {
        guard !s2sAccountID.isEmpty, !s2sClientID.isEmpty, !s2sClientSecret.isEmpty else { return }
        Task {
            if let zak = try? await ZoomServerToServerClient.fetchZAK(
                accountID: s2sAccountID, clientID: s2sClientID, clientSecret: s2sClientSecret) {
                prefetchedZAK = (number, zak, Date())
            }
        }
    }

    /// Fills Meeting ID/Passcode from whatever's on the clipboard - a
    /// pasted zoom.us/zoommtg:// link, or the plain text block Zoom's
    /// calendar invites use. Beats manually copying two separate fields
    /// out of an invite by hand.
    func fillMeetingFromClipboard() {
        Analytics.feature("paste_link")
        guard let clipboard = NSPasteboard.general.string(forType: .string),
              let parsed = ZoomMeetingLinkParser.parse(clipboard) else {
            // Logged AND surfaced: the status log is collapsed by default,
            // so on the log alone this button looked like it did nothing at
            // all when the clipboard held no meeting.
            log("Clipboard doesn't look like a Zoom meeting link/invite.")
            Notifier.post(title: "No meeting in the clipboard",
                          body: "Copy a Zoom invite or meeting link, then try again.")
            return
        }
        meetingNumber = parsed.number
        meetingPassword = parsed.password
        log("Filled meeting ID\(parsed.password.isEmpty ? "" : " + passcode") from clipboard.")
    }

    private var layoutFollowTask: Task<Void, Never>?
    private var peopleViewTask: Task<Void, Never>?
    /// The built-in client's PRIMARY meeting window - the one parked as
    /// the side-column tile. Weak: the SDK owns its windows.
    private weak var builtInMeetingWindow: NSWindow?

    /// The dual-screen gallery window the people-view placer positioned,
    /// so the stray-window guard knows it's accounted for. Weak: the SDK
    /// owns it.
    private weak var peopleViewWindow: NSWindow?

    /// The display the participant gallery should open on: the chosen one
    /// if it's connected, otherwise the first non-main display. nil when
    /// there's nowhere but the main screen to put it (the main screen -
    /// and any class mirror of it - is already showing the tiled
    /// workspace, so the gallery must not land there).
    private func peopleViewTargetScreen() -> NSScreen? {
        if !peopleViewDisplayUUID.isEmpty, let chosen = DisplayResolver.screen(forUUID: peopleViewDisplayUUID) {
            return chosen
        }
        return DisplayResolver.firstSecondaryScreen()
    }

    /// Whether this session should put the gallery on another display:
    /// the toggle is on AND a valid target display exists right now.
    private var peopleViewWanted: Bool {
        peopleViewOnStart && peopleViewTargetScreen() != nil
    }

    /// Whether the SDK runs with TWO meeting windows this session.
    ///
    /// Deliberately separate from `peopleViewWanted`, which asks the narrower
    /// question of whether one of them goes to another DISPLAY. With the
    /// toggle on and no reference monitor connected the gallery still opens -
    /// it just lives behind the workspace instead of on a second screen. The
    /// two were conflated, which is why a single-display session used to get
    /// no participant view at all: dual-screen mode was never enabled, so the
    /// SDK never created the window there was nowhere to put.
    ///
    /// Every window-ROLE decision keys off this (which window is the tile,
    /// whether to simplify the tile's view, what the stray sweep may demote).
    /// Only the placement decisions still key off `peopleViewWanted`.
    private var galleryWindowExists: Bool { peopleViewOnStart }

    /// Sends the built-in client's dual-screen gallery window full-screen
    /// onto the chosen (or default secondary) display. Polls for it
    /// because the SDK creates it a beat after the primary meeting window.
    /// The primary is identified by `builtInMeetingWindow` (set when the
    /// tile parks); the gallery is any other SDK meeting window.
    private func placePeopleViewWindow() {
        guard peopleViewOnStart else { return }
        guard let target = peopleViewTargetScreen() else {
            // Used to give up here. The window is worth having even with
            // nowhere special to put it - it just goes behind the workspace
            // rather than covering it.
            placePeopleViewBehindWorkspace()
            return
        }
        let onChosen = !peopleViewDisplayUUID.isEmpty && DisplayResolver.screen(forUUID: peopleViewDisplayUUID) != nil
        peopleViewTask?.cancel()
        peopleViewTask = Task {
            for _ in 0..<30 {
                if Task.isCancelled { return }
                // The extended display gets the PRIMARY meeting window -
                // the oldest candidate, the one carrying Zoom's meeting
                // controls - switched to the gallery grid below. The
                // secondary (newest) window is the clean video-only view
                // and becomes the tile (tileWindowCandidate). Placing the
                // secondary here instead put the clean speaker view on
                // the extended display and the control clutter in the
                // tile - exactly backwards, reported live.
                let candidates = meetingVideoWindowCandidates().filter { $0 !== builtInMeetingWindow }
                // A candidate ALREADY on the target display is the grid -
                // the SDK recreated it in place (weak ref died, frame
                // survived). Preferring it keeps the re-hunt from grabbing
                // the tile by creation order and pinning THAT to the
                // extended display while the parking loop drags it back.
                let gallery = candidates.first(where: windowIsOnPeopleViewTarget)
                    ?? (builtInMeetingWindow != nil
                        ? candidates.first
                        : (candidates.count > 1 ? candidates.first : nil))
                if let gallery {
                    if gallery.styleMask.contains(.fullScreen) {
                        // Can't be framed while in a fullscreen Space -
                        // kick it out and place on a later tick.
                        gallery.toggleFullScreen(nil)
                    } else {
                        gallery.setFrame(target.frame, display: true)
                        // What we GOT, not what we asked for, and only when
                        // it actually landed on the target (see the same
                        // guard in maintainPeopleViewPlacement).
                        if windowIsOnPeopleViewTarget(gallery) {
                            peopleViewGrantedFrame = gallery.frame
                            // Over the menu bar and Dock - see the same
                            // assert in maintainPeopleViewPlacement.
                            gallery.level = .statusBar
                        }
                        gallery.orderFront(nil)
                        peopleViewWindow = gallery
                        // Grid on the extended display; the secondary tile
                        // then shows Zoom's complementary clean speaker
                        // view (its dual-monitor pairing).
                        zoomChatClient.showGalleryOnPrimaryView()
                        log(onChosen
                            ? "Participant grid (with the meeting controls) is on \u{201C}\(target.localizedName)\u{201D}."
                            : "Participant grid is on \(target.localizedName) (the secondary display). Pick a specific one in Settings \u{2192} Layout if this isn't your reference monitor.")
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            log("People view: the gallery window never appeared \u{2014} is dual-screen mode supported on this meeting?")
        }
    }

    /// The single-display form of `placePeopleViewWindow`: the gallery opens
    /// behind the workspace instead of onto a reference monitor.
    ///
    /// Same hunt as the placer above - the SDK creates the gallery a beat
    /// after the primary window - but the only placement is "not in the way".
    /// It is left at whatever size the SDK chose and simply sent to the back,
    /// so the tiled workspace is untouched and the roster is one Mission
    /// Control (or \u{2318}`) away.
    private func placePeopleViewBehindWorkspace() {
        peopleViewTask?.cancel()
        peopleViewTask = Task {
            for _ in 0..<30 {
                if Task.isCancelled { return }
                // The tile MUST be parked first. Before it is,
                // builtInMeetingWindow is nil and "the first window that is
                // not the tile" matches the ONLY meeting window - this loop
                // then adopted it as the gallery and pushed it behind the
                // workspace, the tile hunt excluded it by identity and found
                // nothing, and \u{2325}\u{2318}Z reported "no speaker tile"
                // for the whole session. Waiting costs one tick; the tile
                // parks within two or three.
                guard let tileWindow = builtInMeetingWindow else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                let gallery = meetingVideoWindowCandidates()
                    .first { $0 !== tileWindow }
                if let gallery {
                    if gallery.styleMask.contains(.fullScreen) {
                        // A window in a Space cannot be ordered back - eject
                        // it and finish on a later tick.
                        gallery.toggleFullScreen(nil)
                    } else {
                        gallery.level = .normal
                        gallery.orderBack(nil)
                        peopleViewWindow = gallery
                        // Same call the dual-display path makes: without it
                        // the second window shows another speaker view rather
                        // than the roster this exists to provide.
                        zoomChatClient.showGalleryOnPrimaryView()
                        log("Participant grid is open behind the workspace \u{2014} no second display to give it. Mission Control or \u{2318}` brings it forward; connect a reference display to have it full-screen there.")
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            log("People view: the gallery window never appeared \u{2014} is dual-screen mode supported on this meeting?")
        }
    }

    /// The SDK's in-process windows - identified by title ("Zoom Meeting",
    /// waiting-room text) or by their class living in Zoom's frameworks
    /// (ZM/ZP prefixes) when title-less. Everything known-ours is
    /// excluded first (the chat window's own title contains "Meeting").
    /// The first one is parked top-right as the actual meeting window.
    private func sdkMeetingWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            guard window.isVisible, !window.isSheet else { return false }
            if ChatWindowController.owns(window) { return false } // "Meeting Chat" - ours
            if SpeakerWindowController.owns(window) { return false } // custom-UI speaker - also ours
            if ParticipantGridWindowController.owns(window) { return false } // custom-UI gallery - ours
            if BrowserWindowController.owns(window) { return false } // built-in browser - title is the page's
            if window.title == "Greenroom" { return false } // main window
            if window.title.localizedCaseInsensitiveContains("settings") { return false }

            let className = String(describing: type(of: window))
            let title = window.title
            return title.localizedCaseInsensitiveContains("zoom")
                || title.localizedCaseInsensitiveContains("meeting")
                || title.localizedCaseInsensitiveContains("waiting")
                || className.hasPrefix("ZM") || className.hasPrefix("ZP") || className.hasPrefix("zm")
        }
    }

    private func hideSDKMeetingWindows() {
        sdkMeetingWindows().forEach { $0.orderOut(nil) }
    }

    /// The windows eligible to be the meeting TILE or the people-view
    /// GALLERY: SDK meeting windows minus side panels the SDK pops open
    /// alongside (its own chat window, etc. - anything "chat"-titled).
    /// Sorted by windowNumber, i.e. creation order: the primary meeting
    /// window is created at join, the dual-screen gallery after it - so
    /// the primary sorts first, deterministically, instead of trusting
    /// NSApp.windows' arbitrary order (which shuffled the tile, gallery
    /// and chat into random slots when several appeared together).
    private func meetingVideoWindowCandidates() -> [NSWindow] {
        sdkMeetingWindows()
            .filter { !$0.title.localizedCaseInsensitiveContains("chat") }
            .filter(isPlausibleVideoWindow)
            .sorted { $0.windowNumber < $1.windowNumber }
    }

    /// Whether an SDK window is plausibly one of Zoom's VIDEO windows, as
    /// opposed to a panel it popped up.
    ///
    /// This gate exists because a panel must never be adopted as the speaker
    /// tile or pinned to the people-view display. Reported live: clicking the
    /// info "i" on the tile made the SDK recreate its windows, which killed
    /// the tile's weak reference; the re-hunt then took the newest candidate -
    /// the just-opened popup - parked it in the side column, and the follow
    /// loop re-asserted that every two seconds. A stuck window that also stole
    /// the quick-hide shortcut, since it had become `builtInMeetingWindow`.
    ///
    /// Geometry is the discriminator on purpose: it survives the window
    /// recreation that destroys identity, the same reason the gallery is
    /// excluded geometrically rather than by reference.
    ///
    /// The floor is a HEURISTIC, and an honest one - Zoom's panel sizes are
    /// not documented and this machine could not open one to measure. It sits
    /// under any real video window (the side-column tile measured 505x351)
    /// while excluding small panels. `logRejectedVideoCandidate` records what
    /// it turns away with title and size, so the first time this is wrong the
    /// log says so and the rule can be tightened from a measurement instead of
    /// another guess.
    private func isPlausibleVideoWindow(_ window: NSWindow) -> Bool {
        // Panels are never the meeting video window. Zoom's popups - the
        // tile's info "i", tooltips, notification bubbles - are NSPanel
        // subclasses (ZMTipPanel observed live), while the real video windows
        // are ordinary NSWindows: they have to be, to support fullscreen.
        // This is the class-level backstop for popups that dodge the title
        // list below by having no title, and dodge the size floor by being
        // big - the info popup is both.
        if window is NSPanel {
            logRejectedVideoCandidate(window, reason: "panels are never the meeting video window")
            return false
        }
        let className = String(describing: type(of: window))
        for marker in ["Tip", "Popover", "Toast", "Notification", "Tooltip"]
        where className.contains(marker) {
            logRejectedVideoCandidate(window, reason: "class \(className) is a popup, not a video window")
            return false
        }
        let title = window.title
        for panel in ["information", "participant", "invite", "security", "keypad", "poll", "breakout", "meeting info"]
        where title.localizedCaseInsensitiveContains(panel) {
            logRejectedVideoCandidate(window, reason: "title looks like the \(panel) panel")
            return false
        }
        let size = window.frame.size
        if size.width < 300 || size.height < 220 {
            logRejectedVideoCandidate(window, reason: "too small for a video window")
            return false
        }
        return true
    }

    /// Logged once per window, to a file rather than the status log: this runs
    /// on every follow-loop tick, so the user-facing log would drown.
    private func logRejectedVideoCandidate(_ window: NSWindow, reason: String) {
        guard rejectedVideoCandidateNumbers.insert(window.windowNumber).inserted else { return }
        let size = window.frame.size
        let line = "\(Self.quitLogStamp.string(from: Date())) ignored-sdk-window"
            + " title=\"\(window.title)\""
            + " \(Int(size.width))x\(Int(size.height))"
            + " class=\(String(describing: type(of: window)))"
            + " reason=\(reason)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Greenroom-quit.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private var rejectedVideoCandidateNumbers = Set<Int>()

    /// Windows already demoted, so each is logged (and re-shrunk) once.
    private var demotedStrayWindowNumbers = Set<Int>()

    /// Anything the SDK opens beyond the tracked tile + gallery must never
    /// blanket the MAIN display: the screen capture films that display,
    /// so a meeting-video window sitting there feeds the meeting back into
    /// itself - the recursive "cascading" camera feed seen live. Strays in
    /// native fullscreen are kicked out of it; strays covering most of the
    /// main screen are miniaturized (recoverable from the Dock). Small
    /// windows (dialogs like "Claim Host") are left alone.
    private func demoteStrayMeetingWindows() {
        guard let main = DisplayResolver.mainDisplayScreen() else { return }
        // While the people-view placer is still hunting for the gallery,
        // don't demote any tile/gallery candidate out from under it -
        // only obvious side panels (e.g. the SDK's chat window).
        let placerHunting = galleryWindowExists && peopleViewWindow == nil
        let protected = placerHunting ? Set(meetingVideoWindowCandidates().map(\.windowNumber)) : []
        let mainArea = main.frame.width * main.frame.height
        for window in sdkMeetingWindows() {
            if window === builtInMeetingWindow || window === peopleViewWindow { continue }
            if protected.contains(window.windowNumber) { continue }
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                continue
            }
            let overlap = window.frame.intersection(main.frame)
            guard !overlap.isNull, mainArea > 0 else { continue }
            let coverage = (overlap.width * overlap.height) / mainArea
            if coverage > 0.6 {
                window.miniaturize(nil)
                if demotedStrayWindowNumbers.insert(window.windowNumber).inserted {
                    let name = window.title.isEmpty ? "an extra meeting window" : "\u{201C}\(window.title)\u{201D}"
                    log("Tucked \(name) into the Dock \u{2014} it was covering the shared screen.")
                }
            }
        }
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
        where window.isVisible && window.title == "Greenroom" && !BrowserWindowController.owns(window) {
            window.orderBack(nil)
        }
        if AppCatalog.isBuiltInBrowser(mainAppBundleID) {
            BrowserWindowController.activate()
        } else {
            NSRunningApplication.runningApplications(withBundleIdentifier: mainAppBundleID).first?.activate()
        }
    }

    private func runPipeline() async throws {
        try await buildScene()
        // Installed before the meeting opens: it applies at once if the SDK is
        // already signed in, and right after sign-in if it is not.
        zoomChatClient.useStageVideo(stage)
        stageLive = true

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
        stageCameraUIDs = sceneCameraUIDs(limit: 1)
        let configuration = makeStageConfiguration()
        let wantsScreen = configuration.share.kind != .nothing

        if wantsScreen, !StageCompositor.screenRecordingGranted {
            log("Greenroom needs Screen Recording permission to share your screen, and it isn\u{2019}t on yet. macOS is asking now (or open System Settings \u{2192} Privacy & Security \u{2192} Screen Recording and turn Greenroom on, then quit and reopen Greenroom). Until then the class sees your camera only.")
            StageCompositor.requestScreenRecordingAccess()
            watchForScreenPermission()
        }

        let recorder = SessionRecorder(source: stage, microphoneUID: micDeviceUID, log: { [weak self] line in
            Task { @MainActor in self?.log(line) }
        })
        recorder.onUnexpectedStop = { [weak self] message in
            Task { @MainActor in self?.recorderStoppedItself(message) }
        }
        self.recorder = recorder

        log("Starting the picture (screen + webcam)\u{2026}")
        let probe = StageFrameProbe()
        stage.addSink(probe)
        defer { stage.removeSink(probe) }
        stage.start(configuration)
        stage.cut(toSlot: 0, fade: 0)
        attachPreview()

        // The first composited frame, with the screen and the camera in it
        // when they are going to be. A source that has not come by then is
        // reported below and the start carries on: a class can begin on
        // the camera alone, but not on a silent failure.
        let wantsCamera = configuration.normalizedLayout.showsCamera && !configuration.cameraUIDs.isEmpty
        let screenExpected = wantsScreen && StageCompositor.screenRecordingGranted
        let began = Date()
        while Date().timeIntervalSince(began) < 8 {
            try Task.checkCancellation()
            if probe.hasFrame,
               !screenExpected || stage.status.screenLive,
               !wantsCamera || stage.status.camerasLive.first == true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        reportStageStart(stage.status, configuration: configuration,
                         wantsScreen: screenExpected, wantsCamera: wantsCamera)
    }

    private func reportStageStart(_ status: StageStatus, configuration: StageConfiguration,
                                  wantsScreen: Bool, wantsCamera: Bool) {
        if configuration.cameraUIDs.isEmpty, cameraIsOff {
            log("No camera, as set in Settings \u{2192} Webcam \u{2014} the picture is what you share.")
        } else if configuration.cameraUIDs.isEmpty {
            log("No webcam connected \u{2014} running screen-only. Plug a camera in and press Start to bring your video back.")
        } else if wantsCamera, status.camerasLive.first != true {
            let name = LocalDeviceResolver.cameraName(uid: configuration.cameraUIDs[0]) ?? "The camera"
            log("\u{201C}\(name)\u{201D} hasn\u{2019}t sent a picture yet. It may be unplugged, or in use by another app. The class sees the screen until it does.")
        }
        if shareTarget.kind == .nothing {
            log("Nothing shared, as set in Settings \u{2192} Webcam \u{2014} your camera fills the picture.")
        }
        if let reason = status.shareFallback {
            log("\(reason) \u{2014} sharing the whole screen instead. Open it and press Start again, or change what you share in Settings (\u{2318},) \u{2192} Layout.")
            Notifier.post(title: "Sharing the whole screen",
                          body: "\(reason), so the class sees your whole screen.")
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
        isRecording = false
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
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
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

/// A saved Join Existing shortcut: a friendly name plus the meeting
/// number (stored as bare digits) and passcode. Codable so it persists
/// and rides the settings-transfer file.
struct MeetingPreset: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var number: String
    var password: String

    init(id: UUID = UUID(), name: String, number: String, password: String) {
        self.id = id
        self.name = name
        self.number = number
        self.password = password
    }

    /// How the preset reads in a menu. Saving with the name left blank
    /// falls the name back to the meeting number, and the old
    /// "name - number" format then rendered that twice
    /// ("78904918702 - 78904918702"). Collapse it to the number alone.
    var menuLabel: String {
        name == number ? number : "\(name) \u{2014} \(number)"
    }
}

/// The one up-front decision in the single-button flow: does Start create
/// a fresh meeting, or join one you already have a link/ID for?
enum MeetingMode: String, CaseIterable, Identifiable {
    case create, join
    /// No meeting: the Webcam page's picture recorded to this Mac. See
    /// `getReadyToRecord`.
    case record

    var id: String { rawValue }

    var label: String {
        switch self {
        case .create: return "New Meeting"
        case .join: return "Join Existing"
        case .record: return "Record"
        }
    }
}

// MARK: - Settings transfer
//
// One exported file = a new machine fully configured, instead of hand-typing
// five credential strings across two Settings tabs. The Zoom credentials are
// app-level, deliberately shareable with a trusted teammate (see
// Vendor/README.md) - and because the chat feature only works in meetings
// hosted under the credential-owning account anyway, the teammate importing
// this file gets working chat in exactly the meetings this app starts.
//
// The exported JSON contains the secrets in PLAINTEXT - hand it over
// directly (AirDrop etc.) and delete it after importing.

/// Every field optional so a partial or older file imports cleanly,
/// touching only what it contains.
struct SettingsTransfer: Codable {
    var sdkClientID: String?
    var sdkClientSecret: String?
    var s2sAccountID: String?
    var s2sClientID: String?
    var s2sClientSecret: String?
    var webcamShape: String?
    var backgroundRemoval: String?
    var mainAppBundleID: String?
    var mainAppURL: String?
    var mainAppOnStart: Bool?
    var browserRestoresTabs: Bool?
    var browserSearchSuggestions: Bool?
    var browserClosesOnStop: Bool?
    // These five keep the old spelling on purpose. They are not internal
    // names: SettingsTransfer is Codable with no CodingKeys, so each property
    // name IS a key in the settings file the teacher exports. Renaming them
    // would make every file exported before the feature became "Cues" fail to
    // import its Cues settings, and pinning them with CodingKeys would mean
    // listing all forty-odd properties of this struct by hand.
    var prompterEnabled: Bool?
    var prompterVideoSearch: Bool?
    var prompterUseModel: Bool?
    var prompterSaveTranscript: Bool?
    var prompterLocaleIdentifier: String?
    var youtubeUploadMode: String?
    var youtubePrivacy: String?
    var youtubeClientID: String?
    var youtubeClientSecret: String?
    var peopleViewOnStart: Bool?
    var peopleViewDisplayUUID: String?
    var screenCaptureDisplayUUID: String?
    var shareTarget: ShareTarget?
    var hideSelfView: Bool?
    var speakerTileShortcutEnabled: Bool?
    var autoRecordOnStart: Bool?
    var meetingPresets: [MeetingPreset]?
    var workspaceLayout: WorkspaceLayout?

    // Added 2026-09-19, after an audit found fourteen real settings that a
    // teacher had set and an export did not carry. A colleague importing the
    // file got a Mac configured most of the way and no sign of which part was
    // missing, which is the worst shape a transfer can take.
    var userDisplayName: String?
    var customUIMode: Bool?
    var clipBufferEnabled: Bool?
    var participantPanelOnMainDisplay: Bool?
    /// Carried whole, including the camera identifiers. They mean nothing on
    /// another Mac, and that is handled where it matters rather than here -
    /// CameraDirectorSettings.availableOnly drops any camera that is not
    /// plugged in, so an imported config degrades to off instead of cutting
    /// to a device that does not exist.
    var cameraDirector: CameraDirectorSettings?
    /// Where the webcam sits in the composite. Dragged into place by hand,
    /// which makes it the most annoying thing in this list to redo.
    var bubbleWidthFraction: Double?
    var bubbleRightInset: Double?
    var bubbleBottomInset: Double?
    var cutoutHeightFraction: Double?
    var cutoutRightInset: Double?
    var cuesUseWhisper: Bool?
    /// The agent command, as JSON. Portable: it is a command line, and the
    /// Mac that imports it either has that CLI or does not.
    var screenroomAgent: String?
    /// The teacher's rubric, as JSON. Authored content - the one thing here
    /// nobody could reconstruct from memory.
    var screenroomRubric: String?
    /// The transcription LANGUAGE only. The model path is deliberately left
    /// behind: it is an absolute path to a file on the Mac that exported it,
    /// and importing it would point a colleague's Greenroom at a model they
    /// do not have. The receiving Mac picks its own best model.
    var screenroomLanguage: String?
    // Legacy fields from Chrome-only-era exports - still imported, never
    // written anymore.
    var chromeLayout: String?
    var chromeURL: String?
    var chromeOnStart: Bool?
}

extension CoordinatorController {

    func exportSettingsData() throws -> Data {
        loadSecretsIfNeeded()
        let transfer = SettingsTransfer(
            sdkClientID: sdkClientID,
            sdkClientSecret: sdkClientSecret,
            s2sAccountID: s2sAccountID,
            s2sClientID: s2sClientID,
            s2sClientSecret: s2sClientSecret,
            webcamShape: webcamShape.rawValue,
            backgroundRemoval: backgroundRemoval.rawValue,
            mainAppBundleID: mainAppBundleID,
            mainAppURL: mainAppURL,
            mainAppOnStart: mainAppOnStart,
            browserRestoresTabs: browserRestoresTabs,
            browserSearchSuggestions: browserSearchSuggestions,
            browserClosesOnStop: browserClosesOnStop,
            prompterEnabled: cuesEnabled,
            prompterVideoSearch: cuesVideoSearch,
            prompterUseModel: cuesUseModel,
            prompterSaveTranscript: cuesSaveTranscript,
            prompterLocaleIdentifier: cuesLocaleIdentifier,
            youtubeUploadMode: youtubeUploadMode.rawValue,
            youtubePrivacy: youtubePrivacy,
            youtubeClientID: youtubeClientID,
            youtubeClientSecret: youtubeClientSecret,
            peopleViewOnStart: peopleViewOnStart,
            peopleViewDisplayUUID: peopleViewDisplayUUID,
            screenCaptureDisplayUUID: screenCaptureDisplayUUID,
            shareTarget: shareTarget,
            hideSelfView: hideSelfView,
            speakerTileShortcutEnabled: speakerTileShortcutEnabled,
            autoRecordOnStart: autoRecordOnStart,
            meetingPresets: meetingPresets,
            workspaceLayout: workspaceLayout,
            userDisplayName: userDisplayName,
            customUIMode: customUIMode,
            clipBufferEnabled: clipBufferEnabled,
            participantPanelOnMainDisplay: participantPanelOnMainDisplay,
            cameraDirector: cameraDirectorSettings,
            bubbleWidthFraction: bubbleWidthFraction,
            bubbleRightInset: bubbleRightInset,
            bubbleBottomInset: bubbleBottomInset,
            cutoutHeightFraction: cutoutHeightFraction,
            cutoutRightInset: cutoutRightInset,
            cuesUseWhisper: cuesUseWhisper,
            screenroomAgent: Self.jsonString(forKey: ScreenroomAgentSettings.key),
            screenroomRubric: Self.jsonString(forKey: "screenroomDefaultRubric"),
            screenroomLanguage: ScreenroomTranscriberSettings.load().language
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(transfer)
    }

    /// Assigning through the @Published properties (not UserDefaults
    /// directly) means every didSet persistence hook fires on its own - the
    /// import needs no separate save step.
    /// A Data-shaped preference, as text, so it survives a JSON round trip.
    ///
    /// ScreenroomAgentSettings and the rubric are stored as encoded JSON in
    /// UserDefaults rather than as individual keys. Carrying them as strings
    /// keeps the transfer file readable and means neither type has to be
    /// imported into SettingsTransfer, which would couple the transfer format
    /// to types that are still moving.
    static func jsonString(forKey key: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setJSONString(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func importSettings(from data: Data) throws {
        let transfer = try JSONDecoder().decode(SettingsTransfer.self, from: data)
        // One import assigns every field; that is not twenty deliberate changes.
        Analytics.suppressSettingEvents = true
        defer { Analytics.suppressSettingEvents = false }
        Analytics.feature("settings_import")
        loadSecretsIfNeeded() // so fields the file omits keep their current values
        if let value = transfer.sdkClientID { sdkClientID = value }
        if let value = transfer.sdkClientSecret { sdkClientSecret = value }
        if let value = transfer.s2sAccountID { s2sAccountID = value }
        if let value = transfer.s2sClientID { s2sClientID = value }
        if let value = transfer.s2sClientSecret { s2sClientSecret = value }
        if let value = transfer.webcamShape, let shape = WebcamShape(rawValue: value) { webcamShape = shape }
        if let value = transfer.backgroundRemoval, let mode = BackgroundRemoval(rawValue: value) { backgroundRemoval = mode }
        if let value = transfer.mainAppBundleID { mainAppBundleID = value }
        // The chrome* fallbacks import Chrome-only-era files (whose main
        // app was implicitly Chrome, so the values carry straight over).
        if let value = transfer.mainAppURL ?? transfer.chromeURL { mainAppURL = value }
        if let value = transfer.mainAppOnStart ?? transfer.chromeOnStart { mainAppOnStart = value }
        if let value = transfer.browserRestoresTabs { browserRestoresTabs = value }
        if let value = transfer.browserSearchSuggestions { browserSearchSuggestions = value }
        if let value = transfer.browserClosesOnStop { browserClosesOnStop = value }
        // A colleague's export can carry prompterEnabled=true. It must not
        // switch on a feature this build is holding back.
        if let value = transfer.prompterEnabled, CuesAvailability.isReleased { cuesEnabled = value }
        if let value = transfer.prompterVideoSearch { cuesVideoSearch = value }
        if let value = transfer.prompterUseModel { cuesUseModel = value }
        if let value = transfer.prompterSaveTranscript { cuesSaveTranscript = value }
        if let value = transfer.prompterLocaleIdentifier { cuesLocaleIdentifier = value }
        // The OAuth client travels (a colleague shares the same Google Cloud
        // app); the connected account never does - each Mac connects its own.
        if let value = transfer.youtubeUploadMode, let mode = YouTubeUploadMode(rawValue: value) { youtubeUploadMode = mode }
        if let value = transfer.youtubePrivacy { youtubePrivacy = value }
        if let value = transfer.youtubeClientID { youtubeClientID = value }
        if let value = transfer.youtubeClientSecret { youtubeClientSecret = value }
        if let value = transfer.peopleViewOnStart { peopleViewOnStart = value }
        if let value = transfer.peopleViewDisplayUUID { peopleViewDisplayUUID = value }
        if let value = transfer.screenCaptureDisplayUUID { screenCaptureDisplayUUID = value }
        if let value = transfer.shareTarget { shareTarget = value }
        if let value = transfer.hideSelfView { hideSelfView = value }
        if let value = transfer.speakerTileShortcutEnabled { speakerTileShortcutEnabled = value }
        if let value = transfer.autoRecordOnStart { autoRecordOnStart = value }
        if let value = transfer.userDisplayName { userDisplayName = value }
        if let value = transfer.customUIMode { customUIMode = value }
        if let value = transfer.clipBufferEnabled { clipBufferEnabled = value }
        if let value = transfer.participantPanelOnMainDisplay { participantPanelOnMainDisplay = value }
        if let value = transfer.cameraDirector { cameraDirectorSettings = value }
        if let value = transfer.bubbleWidthFraction { bubbleWidthFraction = value }
        if let value = transfer.bubbleRightInset { bubbleRightInset = value }
        if let value = transfer.bubbleBottomInset { bubbleBottomInset = value }
        if let value = transfer.cutoutHeightFraction { cutoutHeightFraction = value }
        if let value = transfer.cutoutRightInset { cutoutRightInset = value }
        // Same rule as prompterEnabled: a colleague's file must not switch on
        // a transcriber this Mac cannot run.
        if let value = transfer.cuesUseWhisper {
            // Whisper is checked only where the check exists. On macOS 14/15
            // Cues cannot run at all, so the value is carried and left for
            // the OS that can use it rather than being forced to false and
            // lost on the next export.
            if #available(macOS 26.0, *) {
                cuesUseWhisper = value && CuesWhisperTranscriber.isAvailable
            } else {
                cuesUseWhisper = value
            }
        }
        if let value = transfer.screenroomAgent {
            Self.setJSONString(value, forKey: ScreenroomAgentSettings.key)
        }
        if let value = transfer.screenroomRubric {
            Self.setJSONString(value, forKey: "screenroomDefaultRubric")
        }
        if let value = transfer.screenroomLanguage {
            var settings = ScreenroomTranscriberSettings.load()
            settings.language = value
            settings.save()
        }
        if let value = transfer.meetingPresets { meetingPresets = value }
        if let value = transfer.workspaceLayout {
            workspaceLayout = value
        } else if let raw = transfer.chromeLayout, let migrated = WorkspaceLayout(legacyChromeLayout: raw) {
            workspaceLayout = migrated
        }
        log("Imported settings.")
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
