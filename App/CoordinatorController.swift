//
//  CoordinatorController.swift
//  Greenroom
//
//  Orchestrates the whole flow: launch OBS hidden -> connect over its
//  automation API -> build/verify the Greenroom scene -> start the virtual
//  camera -> hand off to Zoom. This is the only thing the UI talks to.
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
    /// Zoom SDK could throw a leave-confirmation modal during quit - one
    /// the ghost police may have hidden - deadlocking the app into
    /// force-quit territory.
    func prepareForTermination() {
        layoutFollowTask?.cancel()
        ghostWindowPolice?.cancel()
        peopleViewTask?.cancel()
        stopShapePreview()
        ChatWindowController.close()
        customUIGridTask?.cancel()
        SpeakerWindowController.close()
        ParticipantGridWindowController.close()
        zoomChatClient.releaseCustomUIVideo()
        zoomChatClient.leave() // ends the meeting if we're hosting it
    }

    /// Graceful infrastructure teardown for app quit, awaited via
    /// applicationShouldTerminate's terminateLater. Order matters, and
    /// every step is BOUNDED so a wedged component can never hang the
    /// quit:
    ///  1. finalize any live recording (quitting OBS mid-write - worse,
    ///     force-terminating it 5s later - risks a truncated file),
    ///  2. stop the virtual camera, disconnect the socket,
    ///  3. wait for the SDK meeting to actually CLOSE - the leave/end
    ///     posted by prepareForTermination must reach Zoom before
    ///     unInitSDK/_exit tears the SDK down mid-send, or a hosted
    ///     meeting lingers for the whole class,
    ///  4. ask OBS to quit and wait for its real exit (terminating it
    ///     with capture live crashed it in its own shutdown - the
    ///     "OBS quit unexpectedly" dialog).
    func windDownForQuit() async {
        // Perceived-instant quit: our windows vanish NOW; the teardown
        // below finishes headless. Cmd-Q sitting on a visible frozen
        // window for 4-10s read as a hang (reported live).
        for window in NSApp.windows { window.orderOut(nil) }

        // Quit-cost breakdown, one line per quit to
        // ~/Library/Logs/Greenroom-quit.log (written at the end of this
        // function). Every step here waits on a DIFFERENT process (OBS, the
        // Zoom SDK), so when quit feels slow the only useful question is
        // which one was slow - and quit is not a moment anyone can watch a
        // debugger through. scripts/measure-quit.sh drives the whole thing.
        let quitStarted = Date()
        var phases: [String] = []
        func mark(_ label: String, from start: Date) {
            phases.append("\(label)=\(Int(Date().timeIntervalSince(start) * 1000))ms")
        }

        // prepareForTermination already POSTED the leave/end and Zoom
        // confirms it on its own clock. Nothing in the OBS teardown below
        // reads that confirmation and nothing OBS does affects it, so it
        // rides ALONGSIDE the OBS work. Awaiting it in sequence (as this
        // did from 0.3.4 through 0.3.7) charged its whole timeout to every
        // quit even though the leave had already landed.
        let meetingClosed = Task { () -> Double in
            let started = Date()
            await self.zoomChatClient.awaitMeetingClosed(timeout: 5)
            return Date().timeIntervalSince(started)
        }

        // NOTE: the old "connect to a warm-but-unconnected OBS to check
        // for a recording" step is gone. It existed for recordings
        // started in OBS directly (never through a session), could block
        // several seconds when OBS was half-started, and fragmented MP4
        // (RecFormat2) made it redundant: even a hard-killed recording
        // now loses at most the last few seconds, not the file.
        if client.isConnected {
            // OBS is the authority on whether a recording is live - not
            // just our flag - so even a recording started in OBS directly
            // (or left over from a recovered session) gets finalized.
            let recordStart = Date()
            let obsRecording = (await boundedOBSRequest("GetRecordStatus", seconds: 2)?["outputActive"] as? Bool) == true
            if isRecording || obsRecording {
                if let path = await boundedOBSRequest("StopRecord", seconds: 4)?["outputPath"] as? String {
                    Notifier.post(title: "Recording saved",
                                  body: "\((path as NSString).lastPathComponent) \u{2014} in Documents/Greenroom.")
                }
                isRecording = false
            }
            mark("obs-record", from: recordStart)
            let vcamStart = Date()
            _ = await boundedOBSRequest("StopVirtualCam", seconds: 3)
            mark("obs-vcam", from: vcamStart)
            // Park OBS on an EMPTY scene so the screen capture deactivates
            // through OBS's normal scene-switch path before the process
            // exits. Rationale: the ScreenCaptureKit stream registers a
            // system-audio handler even with capture_audio off (proven by
            // crash stacks), and tearing it down during process exit
            // SEGV'd OBS ("quit unexpectedly" after recording sessions).
            // NOTE: RemoveInput was tried first and DEADLOCKED OBS's main
            // thread in the same teardown (beachball, Apple Events dead) -
            // the scene switch is the gentle, well-tested path instead.
            // The next Start switches back via SetCurrentProgramScene.
            // The park scene must hold NO sources. It used to carry a
            // text_ft2_source_v2 label explaining itself to anyone opening
            // OBS between sessions, and that label CRASHED OBS on every
            // quit: making a freetype source the active scene ~700ms before
            // OBS exits leaves its render thread drawing text through
            // shutdown, and it SEGVs in libfreetype (11 crash reports on
            // the dev machine, all libfreetype -> text-freetype2 -> libobs,
            // every one of them after the label was introduced). The crash
            // also skipped OBS's sentinel cleanup, which is what arms its
            // "Run in Safe Mode?" prompt - and Safe Mode disables
            // websockets, the only channel Greenroom has to OBS.
            //
            // The label was also pointless HERE: this path quits OBS
            // immediately afterwards, so nobody is left looking at the idle
            // scene. If it should explain itself, that belongs on the
            // End-Session path, where keep-warm leaves OBS running.
            //
            // A NEW scene name, because "Greenroom Idle" still holds that
            // label in every OBS profile that ever quit Greenroom, and
            // switching to it would re-activate the crash. The stale label
            // itself is deleted at SETUP time instead (see runPipeline):
            // RemoveInput is safe there, with OBS connected and idle, but
            // not here - it deadlocked OBS's main thread mid-teardown.
            let parkStart = Date()
            await parkOBSOnStandbyScene()
            mark("obs-park", from: parkStart)
            client.disconnect()
        }

        // Two independent waits on two other processes: Zoom acknowledging
        // the meeting closed, and the OBS process actually exiting. Neither
        // observes the other, so they overlap and the quit costs the SLOWER
        // of the two rather than their sum.
        let obsExit = Task { () -> Double in
            let started = Date()
            await self.processManager.quitAndWait() // graceful quit, waits for real exit
            return Date().timeIntervalSince(started)
        }
        phases.append("meeting-close=\(Int(await meetingClosed.value * 1000))ms")
        phases.append("obs-exit=\(Int(await obsExit.value * 1000))ms")

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

    /// Deactivate the screen capture through OBS's normal scene-switch path
    /// and leave OBS sitting on a bare scene.
    ///
    /// This is the only thing between a warm OBS and a SIGSEGV in
    /// ScreenCaptureKit's teardown when OBS later quits: the capture stream
    /// registers a system-audio handler even with capture_audio off, and
    /// tearing that down during process exit crashes on
    /// com.screenCaptureKit.audioSampleHandlerQueue (verified - that is the
    /// crash the park was introduced to prevent, and the crash that came
    /// back the moment the park stopped running).
    ///
    /// It MUST run while the websocket is still connected, because after
    /// disconnect there is no channel left to ask. RemoveInput is
    /// deliberately not used anywhere near this: it deadlocked OBS's main
    /// thread mid-teardown.
    private func parkOBSOnStandbyScene() async {
        _ = await boundedOBSRequest("CreateScene", data: ["sceneName": "Greenroom Standby"], seconds: 2)
        _ = await boundedOBSRequest("SetCurrentProgramScene", data: ["sceneName": "Greenroom Standby"], seconds: 2)
        try? await Task.sleep(nanoseconds: 500_000_000) // let the capture wind down

        // Deliberately NOT removing the capture inputs here. Releasing them
        // was tried, and it worked (no deadlock, sources gone from the
        // collection) but OBS still SEGV'd on exit - just somewhere else.
        // Since OBS is now stopped rather than asked to quit (see
        // quitAndWait), its exit path never runs, so paying ~1.7s and a
        // from-nothing source rebuild on the next Start buys nothing.
    }

    /// An OBS request that never waits longer than `seconds` - quit paths
    /// must stay bounded even when the socket is wedged (the client's own
    /// per-request watchdog is 15s, far too long here).
    private func boundedOBSRequest(_ type: String, data: [String: Any] = [:], seconds: Double) async -> [String: Any]? {
        await withTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { [client] in try? await client.request(type, data: data) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Published private(set) var statusLines: [String] = []
    /// True only during the Start transition (pipeline + meeting setup).
    /// `virtualCamActive` is the "session is live" flag the buttons key
    /// off once starting completes.
    @Published private(set) var isRunning = false
    @Published private(set) var virtualCamActive = false
    @Published private(set) var isStopping = false
    private var startTask: Task<Void, Never>?

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
        meetingMode = .join
        meetingNumber = preset.number
        meetingPassword = preset.password
        log("Filled \u{201C}\(preset.name)\u{201D} (\(preset.number)).")
    }

    /// Saves the current Join Existing fields as a named preset. The
    /// number is stored normalized (digits only); a blank name falls back
    /// to the number itself.
    func saveCurrentAsPreset(name: String) {
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

    /// All-in-one client mode (default ON): New Meeting runs entirely in
    /// the SDK's built-in Zoom client - one participant (you), camera and
    /// mic live, hosting directly. No separate Zoom app, no ghost
    /// participant. OFF falls back to the hybrid flow (native Zoom app +
    /// hidden chat participant).
    @Published var useBuiltInClient: Bool {
        didSet { defaults.set(useBuiltInClient, forKey: "useBuiltInClient") }
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
            zoomChatClient.setHideSelfView(hideSelfView)
        }
    }
    /// The \u{2303}\u{2325}\u{2318}Z quick-hide MODE. Off: the normal
    /// tile-above-chat layout persists and the shortcut is inert. On:
    /// sessions START with the speaker tile hidden and the chat owning
    /// the full side column; the shortcut shows the tile (chat resizes
    /// below it) and hides it again (chat refills the column). Flipping
    /// the setting mid-session applies immediately.
    @Published var speakerTileShortcutEnabled: Bool {
        didSet {
            defaults.set(speakerTileShortcutEnabled, forKey: "speakerTileShortcutEnabled")
            guard ChatWindowController.isOpen else { return }
            speakerTileQuickHidden = speakerTileShortcutEnabled
            parkBuiltInMeetingWindow() // restart the loop to assert the new default
        }
    }

    /// Quick-hide state: the tile is off-screen and the chat owns the
    /// FULL side column. Defaults to the setting at each session start
    /// and after Snap Windows Back; \u{2303}\u{2325}\u{2318}Z flips it.
    /// Published (read-only) so the menu bar can label its toggle with
    /// the ACTUAL next action ("Show/Hide Speaker Tile").
    @Published private(set) var speakerTileQuickHidden = false

    /// \u{2303}\u{2325}\u{2318}Z: shows the speaker tile in its slot
    /// (the chat resizes to sit below it) or hides it again (the chat
    /// takes the full column back). Only active when the quick-hide mode
    /// is enabled in Settings.
    func toggleSpeakerTile() {
        guard speakerTileShortcutEnabled else { return }
        // Custom UI: the speaker is our own window, so hiding it is just
        // ordering it out - no SDK window to find, and no risk of the toggle
        // pointing at a panel that got mistaken for the tile.
        if zoomChatClient.didUseCustomUI {
            guard SpeakerWindowController.isOpen || speakerTileQuickHidden else {
                log("No speaker to toggle yet \u{2014} the meeting is still coming up.")
                return
            }
            if speakerTileQuickHidden {
                speakerTileQuickHidden = false
                SpeakerWindowController.reveal(layout: workspaceLayout)
                if let slot = ChatWindowController.zoomSlotNSFrame(for: workspaceLayout),
                   let screen = DisplayResolver.mainDisplayScreen() {
                    let ax = CGRect(x: slot.origin.x, y: screen.frame.height - slot.maxY,
                                    width: slot.width, height: slot.height)
                    ChatWindowController.adjustBelowZoom(actualZoomFrameAX: ax, layout: workspaceLayout)
                }
                log("Speaker shown \u{2014} \u{2303}\u{2325}\u{2318}Z hides it again.")
            } else {
                speakerTileQuickHidden = true
                SpeakerWindowController.hide()
                ChatWindowController.fillSideColumn(layout: workspaceLayout)
                log("Speaker hidden \u{2014} chat has the full column. \u{2303}\u{2325}\u{2318}Z shows it.")
            }
            return
        }
        guard let window = builtInMeetingWindow, ChatWindowController.isOpen else {
            // Surfaced, not just logged: the status log is collapsed by
            // default, so pressing the shortcut before the tile exists looked
            // like the shortcut was simply broken.
            log("No speaker tile to toggle yet \u{2014} waiting for Zoom's meeting window.")
            Notifier.post(title: "Speaker tile isn't ready yet",
                          body: "Zoom's meeting window is still coming up. Try \u{2303}\u{2325}\u{2318}Z again in a moment.")
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
            log("Speaker tile shown \u{2014} \u{2303}\u{2325}\u{2318}Z hides it again.")
        } else {
            speakerTileQuickHidden = true
            window.orderOut(nil)
            ChatWindowController.fillSideColumn(layout: workspaceLayout)
            log("Speaker tile hidden \u{2014} chat has the full column. \u{2303}\u{2325}\u{2318}Z shows it.")
        }
    }

    // MARK: Defaults - persisted so Start reproduces the whole setup every time

    @Published var webcamShape: WebcamShape {
        didSet { defaults.set(webcamShape.rawValue, forKey: "webcamShape") }
    }
    /// The main pane + side column arrangement - see WorkspaceLayout.
    /// Stored as one JSON blob (it's several coupled fields, not a flat
    /// value like the keys around it).
    @Published var workspaceLayout: WorkspaceLayout {
        didSet {
            workspaceLayout.save(to: defaults)
            scheduleLiveLayoutApply()
        }
    }

    private var layoutApplyTask: Task<Void, Never>?

    /// Layout edits made mid-session (dragging the divider in Settings)
    /// apply to the LIVE windows automatically - no Snap Windows Back
    /// needed. Debounced: a drag emits dozens of changes a second, and
    /// re-tiling real windows (AppleScript/AX calls) at that rate would
    /// thrash; 400ms after the last change, everything re-tiles once.
    private func scheduleLiveLayoutApply() {
        guard ChatWindowController.isOpen || virtualCamActive else { return }
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
        didSet { defaults.set(mainAppBundleID, forKey: "mainAppBundleID") }
    }
    @Published var mainAppURL: String {
        didSet { defaults.set(mainAppURL, forKey: "mainAppURL") }
    }
    @Published var mainAppOnStart: Bool {
        didSet { defaults.set(mainAppOnStart, forKey: "mainAppOnStart") }
    }
    /// People view: on Start, the built-in client's dual-screen gallery
    /// window (every participant) goes full-screen onto a chosen display
    /// - your reference monitor, not the class mirror. No-op with a
    /// single display.
    @Published var peopleViewOnStart: Bool {
        didSet { defaults.set(peopleViewOnStart, forKey: "peopleViewOnStart") }
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
        didSet { defaults.set(customUIMode, forKey: "customUIMode") }
    }

    @Published var screenCaptureDisplayUUID: String {
        didSet { defaults.set(screenCaptureDisplayUUID, forKey: "screenCaptureDisplayUUID") }
    }

    @Published var peopleViewDisplayUUID: String {
        didSet { defaults.set(peopleViewDisplayUUID, forKey: "peopleViewDisplayUUID") }
    }
    /// Recording starts by itself once the meeting is up (the Record
    /// button and \u{2303}\u{2325}\u{2318}R stay available as the manual
    /// trigger either way).
    @Published var autoRecordOnStart: Bool {
        didSet { defaults.set(autoRecordOnStart, forKey: "autoRecordOnStart") }
    }
    /// OBS launches with Greenroom and survives End Session (quitting
    /// only with the app), so Start skips OBS's multi-second cold launch.
    /// Safe against the stale-state lesson that made stop() quit OBS in
    /// the first place: ensureConfigured is fully idempotent now (virtual
    /// cam stopped, canvas/sources/filters reset on every start). Default
    /// ON - this is most of the "make Start fast" win.
    @Published var keepOBSWarm: Bool {
        didSet {
            defaults.set(keepOBSWarm, forKey: "keepOBSWarm")
            if keepOBSWarm { prewarmOBSIfEnabled() }
        }
    }

    private let defaults = UserDefaults.standard

    init() {
        defer { Self.shared = self }
        webcamShape = WebcamShape(rawValue: defaults.string(forKey: "webcamShape") ?? "") ?? .circle
        // load(from:) migrates the Chrome-only era's "chromeLayout" key,
        // and the ?? fallbacks below migrate its URL/on-Start keys - an
        // existing setup keeps its layout without re-configuring.
        workspaceLayout = WorkspaceLayout.load(from: defaults)
        mainAppBundleID = defaults.string(forKey: "mainAppBundleID") ?? ChromeWindowManager.chromeBundleID
        // Fresh installs open the Greenroom site until the teacher sets
        // their own page - a friendly first Start instead of a blank tab.
        mainAppURL = defaults.string(forKey: "mainAppURL") ?? defaults.string(forKey: "chromeURL") ?? AppLinks.site
        // Defaults to ON for fresh installs (bool(forKey:) alone can't
        // distinguish "never set" from "explicitly off") - the one-button
        // session flow treats the main app window as part of the setup,
        // and the Settings toggle is the opt-out.
        mainAppOnStart = (defaults.object(forKey: "mainAppOnStart") as? Bool)
            ?? (defaults.object(forKey: "chromeOnStart") as? Bool)
            ?? true
        peopleViewOnStart = defaults.bool(forKey: "peopleViewOnStart")
        peopleViewDisplayUUID = defaults.string(forKey: "peopleViewDisplayUUID") ?? ""
        screenCaptureDisplayUUID = defaults.string(forKey: "screenCaptureDisplayUUID") ?? ""
        customUIMode = defaults.bool(forKey: "customUIMode")
        autoRecordOnStart = defaults.bool(forKey: "autoRecordOnStart")
        keepOBSWarm = (defaults.object(forKey: "keepOBSWarm") as? Bool) ?? true
        meetingMode = MeetingMode(rawValue: defaults.string(forKey: "meetingMode") ?? "") ?? .create
        meetingPresets = Self.loadPresets(from: defaults)
        showOnboarding = !defaults.bool(forKey: "hasCompletedOnboarding")
        sdkClientID = defaults.string(forKey: "zoomSDKClientID") ?? ""
        sdkClientSecret = "" // loaded lazily via loadSecretsIfNeeded() - never at launch
        s2sAccountID = defaults.string(forKey: "zoomS2SAccountID") ?? ""
        s2sClientID = defaults.string(forKey: "zoomS2SClientID") ?? ""
        s2sClientSecret = "" // loaded lazily via loadSecretsIfNeeded() - never at launch
        useBuiltInClient = defaults.object(forKey: "useBuiltInClient") == nil ? true : defaults.bool(forKey: "useBuiltInClient")
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
    }

    private var cancellables = Set<AnyCancellable>()

    private func chatSessionDidEnd() {
        layoutFollowTask?.cancel()
        ghostWindowPolice?.cancel()
        peopleViewTask?.cancel()
        if ChatWindowController.isOpen {
            ChatWindowController.close()
            zoomChatBridge.reset()
        }
        // The meeting is over no matter WHERE it was ended - Zoom's own
        // End button inside the meeting tile included - so wind the whole
        // session down. Without this, ending from the tile closed the
        // chat but left OBS and the virtual camera running invisibly,
        // making End-in-the-tile and End Session confusingly different.
        // (When stop() itself triggered this observer, isStopping blocks
        // the re-entry.)
        guard !isStopping else { return }
        if virtualCamActive || isRunning {
            log("Meeting over \u{2014} ending the session.")
            stop()
        } else {
            log("Meeting over \u{2014} chat window closed.")
        }
    }

    private let processManager = OBSProcessManager()
    private let client = OBSWebSocketClient()

    /// The whole session in one click, in dependency order:
    ///  1. OBS + virtual camera (must be live BEFORE Zoom opens, so Zoom's
    ///     remembered "OBS Virtual Camera" pick shows a picture, not black)
    ///  2. The meeting - created fresh or joined by ID, per `meetingMode`
    ///  3. The main app's window tiled to its slice of the screen
    ///  4. The chat window tiled to the remaining slice
    /// Prerequisites are checked up front so a missing credential fails
    /// fast instead of after OBS has already spun up.
    func start() {
        // Full lifecycle guard, not just the transition: the UI disables
        // the button mid-session, but the global hotkey has no disabled
        // state - without the extra checks it could stack a second
        // meeting onto a live session.
        guard !isRunning, !virtualCamActive, !isStopping else { return }
        loadSecretsIfNeeded()

        switch meetingMode {
        case .create:
            guard !s2sAccountID.isEmpty, !s2sClientID.isEmpty, !s2sClientSecret.isEmpty else {
                log("Can't create a meeting yet \u{2014} add the Start Meeting credentials in Settings (\u{2318},).")
                return
            }
        case .join:
            guard !meetingNumberDigits.isEmpty else {
                log("Paste a meeting link or enter a meeting ID first.")
                return
            }
        }

        isRunning = true
        virtualCamActive = false
        statusLines = []

        startTask = Task {
            do {
                // Perceived speed: the main app doesn't depend on
                // anything else - open it first so something visibly
                // happens the instant Start is pressed.
                if mainAppOnStart {
                    log("Opening the \(mainAppDisplayName) window (\(workspaceLayout.label))\u{2026}")
                    openMainAppWindow()
                }

                // Overlap everything that doesn't need OBS with OBS's own
                // spin-up: the REST meeting creation and the Zoom SDK
                // auth are pure network/SDK time. The one true dependency
                // in the whole start is "virtual camera live before the
                // meeting client starts", enforced by awaiting the
                // pipeline before the meeting flows below.
                async let pipelineDone: Void = runPipeline()
                async let preparedMeeting = prepareMeetingIfNeeded()
                async let sdkPrefetched: Void = prefetchSDKAuth()

                try await pipelineDone
                await sdkPrefetched
                // Checkpoints between the big phases let Stop abandon a
                // start cleanly (its OBS teardown otherwise races the
                // meeting setup still running here). The steps themselves
                // aren't cancellation-aware; between-steps is enough.
                try Task.checkCancellation()

                switch meetingMode {
                case .create where useBuiltInClient:
                    // All-in-one: the SDK IS the meeting client. One
                    // participant (you), hosting directly, camera/mic
                    // live, chat sent as you. No native Zoom app at all.
                    guard let meeting = try await preparedMeeting else {
                        throw NSError(domain: "Greenroom", code: 30, userInfo: [
                            NSLocalizedDescriptionKey: "Internal: the meeting wasn't prepared."
                        ])
                    }
                    try await hostAllInOne(meeting: meeting)
                case .create:
                    // Hybrid fallback: the SDK connection hosts the
                    // meeting invisibly, then the native Zoom app JOINS,
                    // and host gets handed over once you're in.
                    guard let meeting = try await preparedMeeting else {
                        throw NSError(domain: "Greenroom", code: 30, userInfo: [
                            NSLocalizedDescriptionKey: "Internal: the meeting wasn't prepared."
                        ])
                    }
                    try await hostChatSession(meeting: meeting)
                    log("Joining the meeting in Zoom\u{2026}")
                    ZoomLauncher.join(meetingNumber: meeting.number, password: meeting.password)
                    Task {
                        if await zoomChatClient.promoteFirstOtherParticipantToHost(timeout: 90) {
                            log("Host role handed to your Zoom \u{2014} full host controls live in your client now. (Stop leaves the meeting; end it from Zoom when you're done.)")
                        }
                    }
                case .join where useBuiltInClient && !sdkClientID.isEmpty && !sdkClientSecret.isEmpty:
                    try await joinAllInOne()
                case .join:
                    log("Joining meeting \(meetingNumber) in Zoom\u{2026}")
                    ZoomLauncher.join(meetingNumber: meetingNumber, password: meetingPassword)
                    joinChatOnly() // logs its own reason if skipped (e.g. no SDK credentials)
                }

                try Task.checkCancellation()

                // The meeting flow above has returned, so the session is
                // live - start the tape if the setting says so. Uses the
                // same path as the Record button, so End Session's
                // finalize-before-quitting-OBS still applies.
                if autoRecordOnStart && !isRecording {
                    log("Starting the recording automatically (Settings \u{2192} Webcam).")
                    toggleRecording()
                }

                // The built-in client's window is parked in-process (see
                // hostAllInOne/joinAllInOne) - the AX-based native-window
                // parking would only find nothing and nag for
                // Accessibility permission. sdkMeetingWindows() being
                // non-empty means the built-in client took the session, so
                // it also covers joinAllInOne's cross-account fallback,
                // which DOES need the native parking.
                if sdkMeetingWindows().isEmpty {
                    parkZoomWindow()
                }
            } catch is CancellationError {
                log("Start cancelled.")
            } catch {
                log("Failed: \(error.localizedDescription)")
            }
            isRunning = false
        }
    }

    /// Fully tears down: stops the virtual camera, disconnects, and quits
    /// OBS outright - so leftover state (a stale active output, a mismatched
    /// canvas resolution) can't carry over and cause the next Start to fail,
    /// the way it did when OBS auto-resumed a previous session's state.
    func stop() {
        guard !isStopping else { return }
        isStopping = true
        // A start still in flight gets abandoned at its next checkpoint -
        // without this, its meeting setup raced the OBS teardown below.
        startTask?.cancel()
        Task {
            log("Stopping\u{2026}")
            // Chat teardown first: close the window before leave() flips
            // isJoined, so the meeting-ended observer sees it already
            // closed and doesn't double-log.
            layoutFollowTask?.cancel()
            ghostWindowPolice?.cancel()
            peopleViewTask?.cancel()
            if ChatWindowController.isOpen {
                ChatWindowController.close()
                zoomChatBridge.reset()
                log("Left the meeting chat.")
            }
            // Custom UI: stop the SDK rendering into views that are about to
            // go away, then drop our window.
            customUIGridTask?.cancel()
            SpeakerWindowController.close()
            ParticipantGridWindowController.close()
            zoomChatClient.releaseCustomUIVideo()
            // A beat between cancelling the window-follow loops and the
            // SDK tearing its meeting windows down: the crash logs' seven
            // zVideoUIBridge dealloc SEGVs look like that teardown racing
            // in-flight window manipulation.
            try? await Task.sleep(nanoseconds: 300_000_000)
            zoomChatClient.leave()

            // Finalize any in-progress recording BEFORE OBS is quit -
            // killing OBS mid-record leaves a truncated/unplayable file.
            if isRecording {
                if let path = (try? await client.request("StopRecord"))?["outputPath"] as? String {
                    log("Recording saved: \(path)")
                    Notifier.post(title: "Recording saved",
                                  body: "\((path as NSString).lastPathComponent) \u{2014} in Documents/Greenroom.")
                }
                isRecording = false
            }
            _ = try? await client.request("StopVirtualCam")
            // Park BEFORE disconnecting. windDownForQuit parks too, but it
            // is gated on `client.isConnected` and the disconnect below is
            // exactly what makes that false - so "End Session, then quit",
            // the ordinary way a class ends, skipped the protection and
            // crashed OBS on the way out every single time. Verified: the
            // ScreenCaptureKit crash returned the moment the freetype one
            // was fixed, with no Standby scene ever created.
            if client.isConnected {
                await parkOBSOnStandbyScene()
            }
            client.disconnect()
            if keepOBSWarm {
                log("Session ended \u{2014} OBS stays ready for a fast next start (it quits with Greenroom).")
            } else {
                await processManager.quitAndWait() // clean exit = OBS clears its own sentinel
                log("Stopped OBS and its virtual camera.")
            }
            virtualCamActive = false
            isRunning = false
            isStopping = false
            // The session pushed Greenroom to the back (finalizeLayout) so
            // the main app could take the stage - with the meeting over,
            // bring it home to front for the next thing.
            showMainWindow()
        }
    }

    func launchZoom() {
        ZoomLauncher.launchZoom()
    }

    @Published private(set) var isRecording = false

    /// Records the composited feed (screen + webcam bubble/cutout) straight
    /// through OBS - the same picture the virtual camera sends, so what's
    /// recorded is exactly what participants saw. Note this captures YOUR
    /// composite, not other participants' video; recording the actual Zoom
    /// meeting is a separate capability (the SDK's record controller).
    func toggleRecording() {
        Task {
            do {
                if isRecording {
                    let response = try await client.request("StopRecord")
                    isRecording = false
                    if let path = response["outputPath"] as? String {
                        log("Recording saved: \(path)")
                        Notifier.post(title: "Recording saved",
                                      body: "\((path as NSString).lastPathComponent) \u{2014} in Documents/Greenroom.")
                    } else {
                        log("Recording stopped.")
                    }
                } else {
                    // Warn about space BEFORE the tape rolls, and warn rather
                    // than refuse: running out mid-class loses the tail of a
                    // recording, but blocking the button loses the whole
                    // thing, and only the teacher knows whether this class is
                    // worth the risk. Auto-record comes through here too, so
                    // this covers the case nobody pressed anything.
                    if let free = GreenroomScene.recordingsFreeBytes {
                        let readable = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
                        switch GreenroomScene.spaceLevel(freeBytes: free) {
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
                    _ = try await client.request("StartRecord")
                    isRecording = true
                    log("Recording\u{2026} (screen + webcam composite)")
                    // Confirmation where it can be seen - mid-session the
                    // main window is buried behind the main app. The menu
                    // bar's GR also flips to a REC glyph via isRecording.
                    Notifier.post(title: "Recording started",
                                  body: "Greenroom is recording the composite. \u{2303}\u{2325}\u{2318}R stops it.")
                }
            } catch {
                log("Recording failed: \(error.localizedDescription) \u{2014} press Start first if the session isn't running.")
            }
        }
    }

    /// The chosen main-pane app's user-facing name, for buttons and logs.
    // MARK: Live shape preview (Settings -> Webcam) - when OBS is around
    // (the keep-warm setting's bonus), the shape picker shows the REAL
    // composite instead of a schematic: actual screen, actual camera,
    // the chroma key as tuned.

    @Published private(set) var shapePreviewFrame: NSImage?
    private var shapePreviewTask: Task<Void, Never>?

    /// Starts polling OBS for frames of the composited scene. Outside a
    /// session the scene is first (re)configured for the chosen shape, so
    /// the preview shows what the NEXT session will send; during a live
    /// session it simply mirrors the output. Falls back silently (frame
    /// stays nil -> the schematic renders) when OBS isn't running.
    func startShapePreview() {
        guard shapePreviewTask == nil else { return }
        shapePreviewTask = Task {
            defer { shapePreviewFrame = nil }
            if !virtualCamActive {
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: OBSProcessManager.bundleIdentifier).isEmpty else { return }
                if (try? await client.request("GetVersion")) == nil {
                    client.disconnect()
                    guard (try? await client.connect(port: OBSProcessManager.websocketPort,
                                                     password: OBSProcessManager.websocketPassword)) != nil else { return }
                }
                await applyShapeForPreview()
            }
            while !Task.isCancelled {
                if let response = try? await client.request("GetSourceScreenshot", data: [
                    "sourceName": GreenroomScene.sceneName,
                    "imageFormat": "jpg",
                    "imageWidth": 640
                ]),
                   let dataString = response["imageData"] as? String,
                   let comma = dataString.firstIndex(of: ","),
                   let imageData = Data(base64Encoded: String(dataString[dataString.index(after: comma)...])),
                   let frame = NSImage(data: imageData) {
                    shapePreviewFrame = frame
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    /// Stops the frame polling. The connection deliberately stays up -
    /// Start verifies and reuses it (see connectWithRetry), and a warm
    /// idle OBS holds no session state to corrupt.
    func stopShapePreview() {
        shapePreviewTask?.cancel()
        shapePreviewTask = nil
        shapePreviewFrame = nil
    }

    /// Re-applies the chosen shape to the warm OBS scene so the live
    /// preview tracks the picker immediately. NEVER during a session -
    /// ensureConfigured's first step stops the virtual camera.
    func applyShapeForPreview() async {
        guard shapePreviewTask != nil, !virtualCamActive, !isRunning else { return }
        _ = try? await GreenroomScene.ensureConfigured(client: client,
                                                       bubble: .init(shape: webcamShape),
                                                       preferredDisplayUUID: screenCaptureDisplayUUID)
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

    func joinMeeting() {
        guard !meetingNumberDigits.isEmpty else { return }
        ZoomLauncher.join(meetingNumber: meetingNumber, password: meetingPassword)
    }

    /// Creates a brand-new instant meeting via Zoom's REST API and opens
    /// its `start_url`, which launches the native Zoom app and begins
    /// hosting immediately - the same effect as clicking Zoom's own
    /// "New Meeting" button, just triggered from here. Also fills
    /// Meeting ID/Passcode from the result, so "Open Chat Window" is a
    /// second click away with no copy-pasting.
    ///
    /// Bonus: a meeting started this way is automatically hosted under
    /// the same Zoom account as whichever one owns these Server-to-Server
    /// credentials - if that's the same account as the Meeting SDK app's,
    /// this sidesteps the cross-account join restriction entirely (see
    /// `joinChatOnly()`'s doc comment) without you having to think about it.
    /// The all-in-one path: Greenroom's built-in SDK client IS the meeting
    /// client - starts the meeting as the user (their name, host role),
    /// camera forced to the OBS Virtual Camera, mic live, chat sent as
    /// them. Its meeting window is OURS, so it parks top-right natively
    /// with no Accessibility permission involved.
    private func hostAllInOne(meeting: ZoomServerToServerClient.CreatedMeeting) async throws {
        guard let zak = meeting.zak else {
            throw NSError(domain: "Greenroom", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Zoom's create-meeting response had no host key (zak) - can't start the meeting."
            ])
        }
        guard !sdkClientID.isEmpty, !sdkClientSecret.isEmpty else {
            log("No Meeting Chat credentials \u{2014} starting the meeting via the native Zoom app instead.")
            ZoomLauncher.startAsHost(meetingNumber: meeting.number, zak: zak)
            return
        }

        isConnectingChat = true
        defer { isConnectingChat = false }

        log("Starting the meeting in Greenroom's built-in Zoom client\u{2026}")
        try await zoomChatClient.ensureReady(clientID: sdkClientID, clientSecret: sdkClientSecret)
        zoomChatClient.setDualScreenMode(peopleViewWanted)

        if zoomChatClient.selectCamera(named: "OBS Virtual Camera") {
            log("Camera set to OBS Virtual Camera.")
        } else {
            log("Couldn't auto-select the OBS Virtual Camera \u{2014} pick it from the meeting's video menu if the feed looks wrong.")
        }

        let name = userDisplayName.isEmpty ? NSFullUserName() : userDisplayName
        try await zoomChatClient.startAsHost(meetingNumber: meeting.number, zak: zak, displayName: name, enableMedia: true)

        if let controller = zoomChatClient.chatController() {
            zoomChatBridge.attach(to: controller)
        }
        ChatWindowController.show(chat: zoomChatBridge, layout: workspaceLayout)
        log("Meeting is live \u{2014} you're hosting from Greenroom. No second Zoom app, no ghost participant.")

        presentMeetingSurfaces(resetQuickHideToDefault: true) // session start = the mode's default state
        finalizeLayout()
    }

    /// Join Existing via the built-in client - you as one participant,
    /// camera/mic live, chat as yourself, window parked top-right. Falls
    /// back to the native Zoom app when Zoom rejects the join as
    /// cross-account (error 63): the SDK can only join meetings hosted
    /// under the account that owns the Marketplace app, confirmed by live
    /// testing. That fallback is the same hybrid flow as before, so
    /// someone else's meeting still works - just with the ghost.
    private func joinAllInOne() async throws {
        isConnectingChat = true
        defer { isConnectingChat = false }

        log("Joining meeting \(meetingNumber) in Greenroom's built-in Zoom client\u{2026}")
        try await zoomChatClient.ensureReady(clientID: sdkClientID, clientSecret: sdkClientSecret)
        zoomChatClient.setDualScreenMode(peopleViewWanted)

        if zoomChatClient.selectCamera(named: "OBS Virtual Camera") {
            log("Camera set to OBS Virtual Camera.")
        }

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
                    zak = try await ZoomServerToServerClient.fetchZAK(
                        accountID: s2sAccountID, clientID: s2sClientID, clientSecret: s2sClientSecret)
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
                    log("That meeting is hosted on another Zoom account, which Greenroom's built-in client can't join \u{2014} using the Zoom app instead.")
                    ZoomLauncher.join(meetingNumber: meetingNumber, password: meetingPassword)
                    joinChatOnly()
                    return
                }
                throw error
            }
        }

        if let controller = zoomChatClient.chatController() {
            zoomChatBridge.attach(to: controller)
        }
        ChatWindowController.show(chat: zoomChatBridge, layout: workspaceLayout)
        log(startedAsHost
            ? "Meeting is live \u{2014} you're hosting from Greenroom."
            : "In the meeting \u{2014} no second Zoom app, no ghost participant.")

        presentMeetingSurfaces(resetQuickHideToDefault: true) // session start = the mode's default state
        finalizeLayout()
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
            parkBuiltInMeetingWindow(resetQuickHideToDefault: resetQuickHideToDefault)
            placePeopleViewWindow()
            return
        }
        if resetQuickHideToDefault {
            speakerTileQuickHidden = speakerTileShortcutEnabled
        }
        let slot = ChatWindowController.zoomSlotNSFrame(for: workspaceLayout)
            ?? NSRect(x: 0, y: 0, width: 505, height: 351)
        guard let videoView = zoomChatClient.makeActiveSpeakerView(frame: slot) else {
            log("Custom UI: the SDK didn't hand back a speaker view. Falling back to no tile \u{2014} the meeting audio and your outgoing camera are unaffected.")
            return
        }
        SpeakerWindowController.show(videoView: videoView, layout: workspaceLayout)
        startCustomUIGridFollow()
        if speakerTileQuickHidden {
            SpeakerWindowController.hide()
            ChatWindowController.fillSideColumn(layout: workspaceLayout)
            log("Speaker starts hidden (quick-hide mode) \u{2014} chat has the full column; \u{2303}\u{2325}\u{2318}Z shows it.")
        }
        log("Custom UI: the speaker view is Greenroom's own window \u{2014} no Zoom chrome, nothing to park.")
    }

    /// Keeps the custom-UI gallery in step with who is actually in the meeting.
    ///
    /// Polled rather than driven by onUserJoin/onUserLeft because the video
    /// element for a brand-new participant is not necessarily renderable the
    /// instant the join callback fires, and a poll is idempotent - it converges
    /// whether or not any single event was missed. Two seconds matches the
    /// default-UI follow loop, so the two modes feel the same.
    private func startCustomUIGridFollow() {
        customUIGridTask?.cancel()
        guard peopleViewWanted else { return }
        customUIGridTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let screen = self.peopleViewTargetScreen() else { return }
                let ids = self.zoomChatClient.participantUserIDs(excludingSelf: self.hideSelfView)
                self.zoomChatClient.pruneParticipantViews(keeping: Set(ids))
                let cellHint = NSRect(x: 0, y: 0, width: 640, height: 360)
                let views = ids.compactMap {
                    self.zoomChatClient.participantView(userID: $0, frame: cellHint)
                }
                // show() hides itself when the list is empty, which is the
                // right behaviour for a teacher who opened the room early:
                // nothing on the wall rather than last session's faces.
                ParticipantGridWindowController.show(views: views, on: screen)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func parkBuiltInMeetingWindow(resetQuickHideToDefault: Bool = false) {
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
            // \u{2303}\u{2325}\u{2318}Z brings the speaker up on demand.
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
                        // \u{2303}\u{2325}\u{2318}Z can summon it) but
                        // HIDDEN, with the chat owning the full column.
                        // Re-asserts every tick, so the SDK re-showing
                        // the window (state changes do that) gets undone.
                        if builtInMeetingWindow == nil {
                            builtInMeetingWindow = window
                            if !peopleViewWanted { zoomChatClient.simplifyMeetingView() }
                        }
                        if window.isVisible {
                            window.orderOut(nil)
                            ChatWindowController.fillSideColumn(layout: workspaceLayout)
                            if !quickHideAnnounced {
                                quickHideAnnounced = true
                                log("Speaker tile starts hidden (quick-hide mode) \u{2014} chat has the full column; \u{2303}\u{2325}\u{2318}Z shows the speaker.")
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
                        if !peopleViewWanted {
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
                // Cheap periodic re-assert (~20s): nothing - OBS-side
                // edits included - can leave the webcam under the screen
                // capture for long mid-session.
                if waitedTicks % 10 == 0, client.isConnected {
                    try? await GreenroomScene.enforceLayerOrder(client: client)
                }
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
        guard peopleViewWanted else { return }
        guard let target = peopleViewTargetScreen() else { return }
        if let gallery = peopleViewWindow {
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
                    log("Something keeps re-placing the participant grid within seconds \u{2014} pausing the tug-of-war for 2 minutes. Snap Windows Back (\u{2303}\u{2325}\u{2318}S) re-places it now.")
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
        guard peopleViewWanted else { return candidates.first }
        return candidates.count >= 2 ? candidates.last : nil
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
    private var customUIGridTask: Task<Void, Never>?
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
        if isRunning || virtualCamActive || isStopping { return true }
        switch meetingMode {
        case .create: return s2sAccountID.isEmpty || s2sClientID.isEmpty
        // Zoom meeting IDs are 9-11 digits. Gating only on "not empty" let
        // "12345" arm Start, which then ran the whole pipeline - OBS launch,
        // scene build, virtual camera - before failing at the join, leaving
        // a half-started session to clean up.
        case .join: return meetingNumberDigits.count < 9
        }
    }

    /// Confirmation gate in front of stop() for every user-facing trigger
    /// (End Session button, menu bar item, \u{2303}\u{2325}\u{2318}X):
    /// ending the session is destructive - it can end the meeting for the
    /// whole class - and the system-wide hotkey especially is one stray
    /// keystroke away. Internal/automatic paths (Zoom-side meeting end,
    /// app quit) still call stop()/prepareForTermination directly: the
    /// destructive event already happened or is separately confirmed.
    func confirmAndStop() {
        guard isRunning || virtualCamActive else { return }
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
    /// whichever meeting window exists - the built-in client's (ours,
    /// plain NSWindow) or the native Zoom app's (Accessibility API) - and
    /// the follow loops those restart re-align the chat automatically.
    func snapWindowsBack() {
        // Restore the quick-hide mode's DEFAULT state (hidden when the
        // mode is on, normal tile layout when off) - the parking loop
        // restarted below asserts it.
        speakerTileQuickHidden = speakerTileShortcutEnabled
        builtInMeetingWindow?.level = .normal
        Task {
            if let error = await MainPaneManager.repositionFrontWindow(bundleID: mainAppBundleID, layout: workspaceLayout) {
                log(error)
            }
        }
        if ChatWindowController.isOpen {
            ChatWindowController.show(chat: zoomChatBridge, layout: workspaceLayout)
            // show() lays the chat out with the tile's slot reserved, which is
            // wrong when the quick-hide default just hid the tile: the column
            // kept a ~350pt hole where no tile was coming. Every other
            // quick-hide path pairs the two calls; this one did not.
            if speakerTileQuickHidden {
                ChatWindowController.fillSideColumn(layout: workspaceLayout)
            }
        }
        // Snap Back is also the manual "fix the composite" action: re-assert
        // webcam-above-screen in the OBS scene alongside the window re-tiling.
        if client.isConnected {
            Task { try? await GreenroomScene.enforceLayerOrder(client: client) }
        }
        if !sdkMeetingWindows().isEmpty {
            parkBuiltInMeetingWindow()
            placePeopleViewWindow()
        } else if ZoomWindowManager.hasAccessibilityPermission, ZoomWindowManager.currentMeetingWindowFrame() != nil {
            parkZoomWindow()
        }
    }

    /// Menu bar's "Show Greenroom" - surfaces the main window.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.title == "Greenroom" }?.makeKeyAndOrderFront(nil)
    }

    /// The create-mode meeting, made WHILE OBS spins up (see the async
    /// lets in start()). nil in join mode - the guard at the use site is
    /// unreachable by construction.
    private func prepareMeetingIfNeeded() async throws -> ZoomServerToServerClient.CreatedMeeting? {
        guard meetingMode == .create else { return nil }
        return try await createMeetingViaAPI()
    }

    /// Warms the Zoom SDK auth in parallel with the OBS pipeline.
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
        log("Meeting \(meeting.number) created.")
        return meeting
    }

    /// New Meeting mode's chat connection doesn't JOIN the meeting - it
    /// STARTS it, as host, using the ZAK from the create call. The meeting
    /// is live the moment this returns. Without Meeting SDK credentials it
    /// falls back to the old native zoommtg:// host-start so the meeting
    /// can still begin (chat-less, and subject to that path's known
    /// flakiness).
    private func hostChatSession(meeting: ZoomServerToServerClient.CreatedMeeting) async throws {
        guard let zak = meeting.zak else {
            throw NSError(domain: "Greenroom", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Zoom's create-meeting response had no host key (zak) - can't start the meeting."
            ])
        }
        guard !sdkClientID.isEmpty, !sdkClientSecret.isEmpty else {
            log("No Meeting Chat credentials \u{2014} starting the meeting via the native Zoom app instead (no chat window).")
            ZoomLauncher.startAsHost(meetingNumber: meeting.number, zak: zak)
            return
        }

        isConnectingChat = true
        defer { isConnectingChat = false }

        log("Starting the meeting (Greenroom hosts it, carrying the chat)\u{2026}")
        try await zoomChatClient.ensureReady(clientID: sdkClientID, clientSecret: sdkClientSecret)
        try await zoomChatClient.startAsHost(meetingNumber: meeting.number, zak: zak)
        // Police only after the start completes - see joinChatOnly's note.
        startGhostWindowPolice()
        if let controller = zoomChatClient.chatController() {
            zoomChatBridge.attach(to: controller)
        }
        ChatWindowController.show(chat: zoomChatBridge, layout: workspaceLayout)
        log("Meeting is live \u{2014} chat window ready.")
        finalizeLayout()
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
            log("Can't list your Zoom meetings \u{2014} add the Start Meeting credentials in Settings (\u{2318},) first.")
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

    /// Joins the same meeting as a second, camera/mic-off participant via
    /// the Meeting SDK, purely to drive the standalone chat window -
    /// doesn't touch the native Zoom app or its window at all.
    ///
    /// CONFIRMED LIMITATION (by testing, not speculation): this only works
    /// for meetings hosted under the SAME Zoom account as this app's
    /// Marketplace credentials. Joining a meeting hosted elsewhere fails
    /// with ZoomSDKMeetingError_UnableToJoinExternalMeeting (63). Zoom's
    /// documented fix (OAuth-fetched OBF tokens) was built and abandoned
    /// along with the rest of the OAuth consolidation (see
    /// Vendor/README.md) - the join method still accepts an
    /// `onBehalfToken` should that ever be revisited, but nothing feeds
    /// it. Use this only for meetings hosted under your own account.
    ///
    /// Guarded by `isConnectingChat` - a double-click used to fire two
    /// overlapping join attempts against the same shared
    /// `zoomChatClient`, corrupting its single-slot completion closures
    /// and producing confusing, inconsistent SDK error codes that had
    /// nothing to do with the real failure.
    func joinChatOnly() {
        loadSecretsIfNeeded()
        guard !isConnectingChat, !meetingNumberDigits.isEmpty else { return }
        guard !sdkClientID.isEmpty, !sdkClientSecret.isEmpty else {
            // Reached silently-skippable from the one-button session flow -
            // say why the chat window didn't appear instead of nothing.
            log("Chat window skipped \u{2014} add the Meeting Chat credentials in Settings (\u{2318},) to enable it.")
            return
        }
        isConnectingChat = true
        Task {
            do {
                log("Connecting Meeting SDK chat\u{2026}")
                try await zoomChatClient.ensureReady(clientID: sdkClientID, clientSecret: sdkClientSecret)
                try await zoomChatClient.join(meetingNumber: meetingNumber, password: meetingPassword)
                // Only start hiding SDK windows AFTER the join completes -
                // policing during the connect once hid a dialog the SDK was
                // waiting on, deadlocking the whole start.
                startGhostWindowPolice()
                if let controller = zoomChatClient.chatController() {
                    zoomChatBridge.attach(to: controller)
                }
                ChatWindowController.show(chat: zoomChatBridge, layout: workspaceLayout)
                log("Chat window ready \u{2014} joined as a second, muted participant.")
                finalizeLayout()
            } catch {
                ghostWindowPolice?.cancel() // failed join - stop policing a window that's going away
                log("Meeting SDK chat failed: \(error.localizedDescription)")
            }
            isConnectingChat = false
        }
    }

    /// Shrinks Zoom's meeting window into the top of the side column,
    /// above the chat window - the final piece of the end-of-Start layout.
    /// Needs the one-time Accessibility grant; without it this logs how to
    /// enable it and the rest of the session is unaffected. Polls for up
    /// to 45s because the meeting window only exists once the meeting has
    /// actually started.
    private func parkZoomWindow() {
        guard workspaceLayout.sideShowsZoomTile else { return }
        guard ZoomWindowManager.hasAccessibilityPermission else {
            ZoomWindowManager.promptForAccessibilityPermission()
            log("To auto-tile the Zoom window into the side column, allow Greenroom under System Settings \u{2192} Privacy & Security \u{2192} Accessibility, then Start again.")
            return
        }
        guard let frame = ChatWindowController.zoomWindowAXFrame(for: workspaceLayout) else { return }
        Task {
            if let actual = await ZoomWindowManager.positionMeetingWindow(frame: frame, timeout: 45) {
                // Snap the chat to sit exactly below wherever Zoom REALLY
                // ended up (it clamps to its own minimum window size).
                ChatWindowController.adjustBelowZoom(actualZoomFrameAX: actual, layout: workspaceLayout)
                log("Zoom window parked top-right, above the chat.")
                startFollowingZoomWindow()
            } else {
                log("Couldn't find Zoom's meeting window to tile (did the meeting actually start?).")
            }
            finalizeLayout()
        }
    }

    private var layoutFollowTask: Task<Void, Never>?
    private var ghostWindowPolice: Task<Void, Never>?
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

    /// Sends the built-in client's dual-screen gallery window full-screen
    /// onto the chosen (or default secondary) display. Polls for it
    /// because the SDK creates it a beat after the primary meeting window.
    /// The primary is identified by `builtInMeetingWindow` (set when the
    /// tile parks); the gallery is any other SDK meeting window.
    private func placePeopleViewWindow() {
        guard peopleViewOnStart else { return }
        guard let target = peopleViewTargetScreen() else {
            log("People view skipped \u{2014} no second display to put it on. Connect your reference display, or pick it in Settings (\u{2318},) \u{2192} Layout.")
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

    /// The Meeting SDK renders a full meeting window of its own inside
    /// Greenroom's process for the chat participant - a second "Zoom
    /// window" that made sessions confusing next to the real (native) one.
    /// There's no official way to suppress it in default-UI mode (checked
    /// ZoomSDKMeetingUIController + ZoomSDKMeetingConfiguration headers),
    /// but it lives in OUR window list, so it can simply be ordered out -
    /// and re-ordered out every half second, since the SDK re-shows it on
    /// state changes (waiting room, share start, etc.).
    private func startGhostWindowPolice() {
        ghostWindowPolice?.cancel()
        ghostWindowPolice = Task {
            while !Task.isCancelled {
                hideSDKMeetingWindows()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// The SDK's in-process windows - identified by title ("Zoom Meeting",
    /// waiting-room text) or by their class living in Zoom's frameworks
    /// (ZM/ZP prefixes) when title-less. Everything known-ours is
    /// excluded first (the chat window's own title contains "Meeting").
    /// The hybrid flow HIDES these (ghost police); the all-in-one flow
    /// PARKS the first one top-right as the actual meeting window.
    private func sdkMeetingWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            guard window.isVisible, !window.isSheet else { return false }
            if ChatWindowController.owns(window) { return false } // "Meeting Chat" - ours
            if SpeakerWindowController.owns(window) { return false } // custom-UI speaker - also ours
            if ParticipantGridWindowController.owns(window) { return false } // custom-UI gallery - ours
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
        let title = window.title
        for panel in ["information", "participant", "invite", "security", "keypad", "poll", "breakout"]
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
    /// blanket the MAIN display: OBS's screen capture films that display,
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
        let placerHunting = peopleViewWanted && peopleViewWindow == nil
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

    /// Zoom reshapes its own window mid-meeting (screen share starting or
    /// stopping, the user dragging it) - a one-shot alignment left visible
    /// gaps between it and the chat below (seen in a real session). So for
    /// the life of the chat window, keep re-snapping the chat under
    /// wherever Zoom's window currently is.
    private func startFollowingZoomWindow() {
        layoutFollowTask?.cancel()
        layoutFollowTask = Task {
            var lastFrame = CGRect.null
            while !Task.isCancelled, ChatWindowController.isOpen {
                if let frame = ZoomWindowManager.currentMeetingWindowFrame(), frame != lastFrame {
                    lastFrame = frame
                    ChatWindowController.adjustBelowZoom(actualZoomFrameAX: frame, layout: workspaceLayout)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// The z-order finale: Zoom reduced to just the parked meeting tile,
    /// Greenroom's own window out of the way at the back, and the main
    /// pane's app active as the thing the user actually works in.
    /// Idempotent - runs after the chat window appears AND after the Zoom
    /// window parks, whichever finishes last wins.
    private func finalizeLayout() {
        if ZoomWindowManager.hasAccessibilityPermission {
            ZoomWindowManager.minimizeNonMeetingWindows()
        }
        for window in NSApp.windows where window.isVisible && window.title == "Greenroom" {
            window.orderBack(nil)
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: mainAppBundleID).first?.activate()
    }

    private func runPipeline() async throws {
        guard processManager.isInstalled else {
            throw NSError(domain: "Greenroom", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "OBS Studio isn't installed. Get it free from obsproject.com, then try again."
            ])
        }

        log("Launching OBS in the background\u{2026}")
        try await processManager.launch()

        log("Connecting to OBS\u{2026}")
        do {
            try await connectWithRetry()
        } catch {
            // Overwhelmingly this means OBS is sitting on a modal dialog
            // instead of running its websocket server - most often its
            // "did not shut down properly / Run in Safe Mode?" prompt
            // (Safe Mode disables websockets entirely).
            throw NSError(domain: "Greenroom", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't reach OBS. If OBS is showing a dialog, answer it \u{2014} choose \u{201C}Run in Normal Mode\u{201D} for the Safe Mode prompt (Safe Mode turns off the connection Greenroom needs), then press Start again."
            ])
        }

        // Self-heal an old install. Versions 0.3.5 through 0.3.7 parked OBS
        // on an idle scene carrying a `text_ft2_source` label whose font
        // spec was incomplete (face + size, no flags/style). That source
        // SEGV'd OBS in libfreetype on EVERY shutdown - 11 crash reports on
        // this machine, all libfreetype -> text-freetype2 -> libobs - and
        // the crash skipped OBS's sentinel cleanup, which is what arms its
        // "Run in Safe Mode?" prompt, and Safe Mode disables the websocket
        // this app depends on entirely.
        //
        // No longer creating it (see windDownForQuit) does not help a
        // profile that already HAS one: OBS instantiates every source in the
        // scene collection at startup, not just the active scene's. So it
        // has to be removed. Here is the safe moment - OBS is connected,
        // idle and fully started. The RemoveInput deadlock the teardown
        // comment warns about happened mid-quit, not during setup. Bounded
        // and best-effort: if it fails, Start proceeds exactly as before.
        _ = await boundedOBSRequest("RemoveInput",
                                    data: ["inputName": "Greenroom Idle Label"],
                                    seconds: 2)

        log("Configuring the Greenroom scene (screen + keyed webcam bubble)\u{2026}")
        let setup = try await GreenroomScene.ensureConfigured(
            client: client,
            bubble: .init(shape: webcamShape),
            preferredDisplayUUID: screenCaptureDisplayUUID)
        if !setup.webcamActive {
            log("No webcam connected \u{2014} running screen-only. Plug a camera in and press Start (or Snap Windows Back) to bring your video back.")
        }
        if setup.displayFellBack {
            log("The screen you picked to share isn't plugged in \u{2014} sharing \u{201C}\(setup.displayLabel ?? "the main display")\u{201D} instead. Change it in Settings (\u{2318},) \u{2192} Layout.")
        }
        // Never let a black picture ship silently: this is the one thing a
        // class cannot work without, and it used to fail with no message at
        // all while the webcam kept showing.
        if !setup.screenCaptureLive {
            // Recovery deliberately does NOT claim Snap Windows Back fixes
            // this: Snap Back only re-asserts layer order, it does not rebuild
            // a source. Rebuilding happens in ensureConfigured, which runs on
            // Start, so ending and restarting the session is the honest advice.
            log("The screen capture came up blank \u{2014} OBS couldn't open \u{201C}\(setup.displayLabel ?? "that display")\u{201D}. End the session and press Start to rebuild it, or pick a different screen in Settings (\u{2318},) \u{2192} Layout.")
            Notifier.post(title: "Screen sharing is blank",
                          body: "OBS couldn't capture that display. Check Settings \u{2192} Layout.")
        }

        log("Starting the virtual camera\u{2026}")
        try await GreenroomScene.startVirtualCam(client: client)
        virtualCamActive = true

        log("Ready \u{2014} \u{201C}OBS Virtual Camera\u{201D} is live.")
        log("First time only: in Zoom, go to Settings \u{2192} Video and pick \u{201C}OBS Virtual Camera\u{201D}. Zoom remembers that choice for every call after this.")
    }

    /// OBS takes a moment to come up after launch, so the first few connect
    /// attempts are expected to fail - this isn't a sign of a real problem.
    /// 200ms polls (same ~6s total budget as the old 12x500ms): each
    /// transition used to waste up to half a second just waiting out the
    /// interval, and with OBS prewarmed the first attempt usually lands.
    private func connectWithRetry(attempts: Int = 30) async throws {
        // The Settings live preview may already hold a working connection
        // - reuse it (verified, not trusted: a lingering dead socket gets
        // torn down and rebuilt).
        if client.isConnected {
            if (try? await client.request("GetVersion")) != nil { return }
            client.disconnect()
        }
        for attempt in 1...attempts {
            do {
                try await client.connect(port: OBSProcessManager.websocketPort, password: OBSProcessManager.websocketPassword)
                return
            } catch {
                if attempt == attempts { throw error }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    /// Launches OBS hidden ahead of need - at app launch and when the
    /// keep-warm toggle flips on - so Start begins at "connect" instead
    /// of OBS's multi-second cold launch. No-op mid-session, when OBS
    /// isn't installed, or when the setting is off.
    func prewarmOBSIfEnabled() {
        guard keepOBSWarm, processManager.isInstalled, !isRunning, !virtualCamActive else { return }
        Task { try? await processManager.launch() }
    }

    private func log(_ message: String) {
        statusLines.append(message)
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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .create: return "New Meeting"
        case .join: return "Join Existing"
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
    var mainAppBundleID: String?
    var mainAppURL: String?
    var mainAppOnStart: Bool?
    var peopleViewOnStart: Bool?
    var peopleViewDisplayUUID: String?
    var screenCaptureDisplayUUID: String?
    var hideSelfView: Bool?
    var speakerTileShortcutEnabled: Bool?
    var autoRecordOnStart: Bool?
    var keepOBSWarm: Bool?
    var meetingPresets: [MeetingPreset]?
    var workspaceLayout: WorkspaceLayout?
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
            mainAppBundleID: mainAppBundleID,
            mainAppURL: mainAppURL,
            mainAppOnStart: mainAppOnStart,
            peopleViewOnStart: peopleViewOnStart,
            peopleViewDisplayUUID: peopleViewDisplayUUID,
            screenCaptureDisplayUUID: screenCaptureDisplayUUID,
            hideSelfView: hideSelfView,
            speakerTileShortcutEnabled: speakerTileShortcutEnabled,
            autoRecordOnStart: autoRecordOnStart,
            keepOBSWarm: keepOBSWarm,
            meetingPresets: meetingPresets,
            workspaceLayout: workspaceLayout
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(transfer)
    }

    /// Assigning through the @Published properties (not UserDefaults
    /// directly) means every didSet persistence hook fires on its own - the
    /// import needs no separate save step.
    func importSettings(from data: Data) throws {
        let transfer = try JSONDecoder().decode(SettingsTransfer.self, from: data)
        loadSecretsIfNeeded() // so fields the file omits keep their current values
        if let value = transfer.sdkClientID { sdkClientID = value }
        if let value = transfer.sdkClientSecret { sdkClientSecret = value }
        if let value = transfer.s2sAccountID { s2sAccountID = value }
        if let value = transfer.s2sClientID { s2sClientID = value }
        if let value = transfer.s2sClientSecret { s2sClientSecret = value }
        if let value = transfer.webcamShape, let shape = WebcamShape(rawValue: value) { webcamShape = shape }
        if let value = transfer.mainAppBundleID { mainAppBundleID = value }
        // The chrome* fallbacks import Chrome-only-era files (whose main
        // app was implicitly Chrome, so the values carry straight over).
        if let value = transfer.mainAppURL ?? transfer.chromeURL { mainAppURL = value }
        if let value = transfer.mainAppOnStart ?? transfer.chromeOnStart { mainAppOnStart = value }
        if let value = transfer.peopleViewOnStart { peopleViewOnStart = value }
        if let value = transfer.peopleViewDisplayUUID { peopleViewDisplayUUID = value }
        if let value = transfer.screenCaptureDisplayUUID { screenCaptureDisplayUUID = value }
        if let value = transfer.hideSelfView { hideSelfView = value }
        if let value = transfer.speakerTileShortcutEnabled { speakerTileShortcutEnabled = value }
        if let value = transfer.autoRecordOnStart { autoRecordOnStart = value }
        if let value = transfer.keepOBSWarm { keepOBSWarm = value }
        if let value = transfer.meetingPresets { meetingPresets = value }
        if let value = transfer.workspaceLayout {
            workspaceLayout = value
        } else if let raw = transfer.chromeLayout, let migrated = WorkspaceLayout(legacyChromeLayout: raw) {
            workspaceLayout = migrated
        }
        log("Imported settings.")
    }
}
