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
        zoomChatClient.leave() // ends the meeting if we're hosting it
    }

    /// Graceful infrastructure teardown for app quit, awaited via
    /// applicationShouldTerminate's terminateLater. OBS must be wound
    /// down IN ORDER - virtual camera stopped, then asked to quit, then
    /// actually waited for - because terminating it with capture and the
    /// virtual camera still live crashed it during its own shutdown:
    /// the "OBS quit unexpectedly" dialog after every Greenroom quit.
    func windDownForQuit() async {
        if client.isConnected {
            // Bounded: a dead socket must not stall the quit (the request
            // watchdog is 15s - too long here). 3s covers the real call.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [client] in _ = try? await client.request("StopVirtualCam") }
                group.addTask { try? await Task.sleep(nanoseconds: 3_000_000_000) }
                _ = await group.next()
                group.cancelAll()
            }
            client.disconnect()
        }
        await processManager.quitAndWait() // graceful quit, waits for real exit
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
    @Published var meetingMode: MeetingMode {
        didSet { defaults.set(meetingMode.rawValue, forKey: "meetingMode") }
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
    // Vendor/ZoomSDK/README.md). Client ID is harmless in UserDefaults;
    // the Secret is a real credential, so it lives in the Keychain instead.

    @Published var sdkClientID: String {
        didSet { defaults.set(sdkClientID, forKey: "zoomSDKClientID") }
    }
    @Published var sdkClientSecret: String {
        didSet {
            guard !isRestoringSecret else { return }
            KeychainStore.set(sdkClientSecret, forKey: "zoomSDKClientSecret")
        }
    }
    private var secretsLoaded = false
    private var isRestoringSecret = false

    /// Reads both Zoom secrets from the Keychain on first use instead of at
    /// launch. Confirmed by testing: reading them in init() meant a Keychain
    /// access prompt on every single app launch, even when the Zoom features
    /// were never touched. Combined with the stable signing identity (see
    /// project.yml), any remaining prompt appears once, offers "Always
    /// Allow", and never comes back.
    func loadSecretsIfNeeded() {
        guard !secretsLoaded else { return }
        secretsLoaded = true
        isRestoringSecret = true
        sdkClientSecret = KeychainStore.get("zoomSDKClientSecret") ?? ""
        s2sClientSecret = KeychainStore.get("zoomS2SClientSecret") ?? ""
        isRestoringSecret = false
    }

    let zoomChatClient = ZoomMeetingSDKClient()
    let zoomChatBridge = ZoomChatBridge()
    @Published private(set) var isConnectingChat = false

    // MARK: Start-a-meeting (Server-to-Server OAuth app - a SECOND
    // Marketplace app, separate from the Meeting SDK one above; see
    // Vendor/README.md, including why a one-app OAuth consolidation was
    // built and then abandoned). Account ID + Client ID are harmless in
    // UserDefaults; the Secret goes to the Keychain, loaded lazily like
    // the SDK secret.

    @Published var s2sAccountID: String {
        didSet { defaults.set(s2sAccountID, forKey: "zoomS2SAccountID") }
    }
    @Published var s2sClientID: String {
        didSet { defaults.set(s2sClientID, forKey: "zoomS2SClientID") }
    }
    @Published var s2sClientSecret: String {
        didSet {
            guard !isRestoringSecret else { return }
            KeychainStore.set(s2sClientSecret, forKey: "zoomS2SClientSecret")
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

    // MARK: Defaults - persisted so Start reproduces the whole setup every time

    @Published var webcamShape: WebcamShape {
        didSet { defaults.set(webcamShape.rawValue, forKey: "webcamShape") }
    }
    /// The main pane + side column arrangement - see WorkspaceLayout.
    /// Stored as one JSON blob (it's several coupled fields, not a flat
    /// value like the keys around it).
    @Published var workspaceLayout: WorkspaceLayout {
        didSet { workspaceLayout.save(to: defaults) }
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
    /// window (every participant) goes full-screen onto a second display
    /// - the classroom projector. No-op with a single display.
    @Published var peopleViewOnStart: Bool {
        didSet { defaults.set(peopleViewOnStart, forKey: "peopleViewOnStart") }
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
        mainAppURL = defaults.string(forKey: "mainAppURL") ?? defaults.string(forKey: "chromeURL") ?? ""
        // Defaults to ON for fresh installs (bool(forKey:) alone can't
        // distinguish "never set" from "explicitly off") - the one-button
        // session flow treats the main app window as part of the setup,
        // and the Settings toggle is the opt-out.
        mainAppOnStart = (defaults.object(forKey: "mainAppOnStart") as? Bool)
            ?? (defaults.object(forKey: "chromeOnStart") as? Bool)
            ?? true
        peopleViewOnStart = defaults.bool(forKey: "peopleViewOnStart")
        autoRecordOnStart = defaults.bool(forKey: "autoRecordOnStart")
        keepOBSWarm = (defaults.object(forKey: "keepOBSWarm") as? Bool) ?? true
        meetingMode = MeetingMode(rawValue: defaults.string(forKey: "meetingMode") ?? "") ?? .create
        showOnboarding = !defaults.bool(forKey: "hasCompletedOnboarding")
        sdkClientID = defaults.string(forKey: "zoomSDKClientID") ?? ""
        sdkClientSecret = "" // loaded lazily via loadSecretsIfNeeded() - never at launch
        s2sAccountID = defaults.string(forKey: "zoomS2SAccountID") ?? ""
        s2sClientID = defaults.string(forKey: "zoomS2SClientID") ?? ""
        s2sClientSecret = "" // loaded lazily via loadSecretsIfNeeded() - never at launch
        useBuiltInClient = defaults.object(forKey: "useBuiltInClient") == nil ? true : defaults.bool(forKey: "useBuiltInClient")
        userDisplayName = defaults.string(forKey: "userDisplayName") ?? NSFullUserName()

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
            guard !meetingNumber.isEmpty else {
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
        try? await GreenroomScene.ensureConfigured(client: client, bubble: .init(shape: webcamShape))
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
        guard !meetingNumber.isEmpty else { return }
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

        parkBuiltInMeetingWindow()
        placePeopleViewWindow()
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
                if let prefetched = prefetchedZAK, prefetched.meetingNumber == meetingNumber,
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

        parkBuiltInMeetingWindow()
        placePeopleViewWindow()
        finalizeLayout()
    }

    /// Whether the Join Existing target is one of the account's own
    /// meetings - i.e. it appears in the Scheduled list fetched with the
    /// S2S credentials. Own meetings get host-started; everything else
    /// gets a plain join.
    private var isOwnScheduledMeeting: Bool {
        !s2sAccountID.isEmpty && !s2sClientID.isEmpty && !s2sClientSecret.isEmpty
            && scheduledMeetings.contains { String($0.id) == meetingNumber }
    }

    /// Parks the built-in client's meeting window into the side column's
    /// top slot and keeps the chat aligned below it - all plain NSWindow
    /// work, since the window belongs to this process. Skipped entirely
    /// when the Zoom tile is toggled out of the side column: the meeting
    /// window then stays wherever it is.
    private func parkBuiltInMeetingWindow() {
        guard workspaceLayout.sideShowsZoomTile else { return }
        layoutFollowTask?.cancel()
        layoutFollowTask = Task {
            var parked = false
            var lastFrame = CGRect.null
            while !Task.isCancelled, ChatWindowController.isOpen {
                if let window = sdkMeetingWindows().first {
                    if !parked, let slot = ChatWindowController.zoomSlotNSFrame(for: workspaceLayout) {
                        window.setFrame(slot, display: true)
                        // The parked tile should be a plain current-speaker
                        // view - done here (not at connect) because the
                        // view switch needs the meeting window to exist.
                        zoomChatClient.simplifyMeetingView()
                        // Remembered so the people-view placer knows which
                        // window is the tile and which is the gallery.
                        builtInMeetingWindow = window
                        parked = true
                    }
                    let frame = window.frame
                    if frame != lastFrame, let screen = NSScreen.main {
                        lastFrame = frame
                        let axFrame = CGRect(x: frame.origin.x,
                                             y: screen.frame.height - frame.maxY,
                                             width: frame.width,
                                             height: frame.height)
                        ChatWindowController.adjustBelowZoom(actualZoomFrameAX: axFrame, layout: workspaceLayout)
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// The menu bar's "Snap Windows Back": re-tiles everything to the
    /// session layout after the user has dragged windows around. Handles
    /// whichever meeting window exists - the built-in client's (ours,
    /// plain NSWindow) or the native Zoom app's (Accessibility API) - and
    /// the follow loops those restart re-align the chat automatically.
    func snapWindowsBack() {
        Task {
            if let error = await MainPaneManager.repositionFrontWindow(bundleID: mainAppBundleID, layout: workspaceLayout) {
                log(error)
            }
        }
        if ChatWindowController.isOpen {
            ChatWindowController.show(chat: zoomChatBridge, layout: workspaceLayout)
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
        prefetchZAK(for: meetingNumber)
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
            log("Clipboard doesn't look like a Zoom meeting link/invite.")
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
        guard !isConnectingChat, !meetingNumber.isEmpty else { return }
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

    /// Whether this session should put the gallery on a second display:
    /// the toggle is on AND a second display actually exists right now.
    private var peopleViewWanted: Bool {
        peopleViewOnStart && NSScreen.screens.count > 1
    }

    /// Sends the built-in client's dual-screen gallery window full-screen
    /// onto the external display. Polls for it because the SDK creates it
    /// a beat after the primary meeting window. The primary is identified
    /// by `builtInMeetingWindow` (set when the tile parks); the gallery is
    /// any other SDK meeting window.
    private func placePeopleViewWindow() {
        guard peopleViewOnStart else { return }
        guard let external = NSScreen.screens.first(where: { $0 != NSScreen.screens.first }) else {
            log("People view skipped \u{2014} no second display connected.")
            return
        }
        peopleViewTask?.cancel()
        peopleViewTask = Task {
            for _ in 0..<30 {
                if Task.isCancelled { return }
                let candidates = sdkMeetingWindows().filter { $0 !== builtInMeetingWindow }
                // When the tile is parked, anything else is the gallery;
                // un-parked (Zoom tile toggled off), the gallery is the
                // SDK's second window - take the last, the primary was
                // created first.
                let gallery = builtInMeetingWindow != nil
                    ? candidates.first
                    : (candidates.count > 1 ? candidates.last : nil)
                if let gallery {
                    gallery.setFrame(external.frame, display: true)
                    gallery.orderFront(nil)
                    log("People view is on the second display.")
                    return
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

        log("Configuring the Greenroom scene (screen + keyed webcam bubble)\u{2026}")
        try await GreenroomScene.ensureConfigured(client: client, bubble: .init(shape: webcamShape))

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
    var autoRecordOnStart: Bool?
    var keepOBSWarm: Bool?
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
            autoRecordOnStart: autoRecordOnStart,
            keepOBSWarm: keepOBSWarm,
            workspaceLayout: workspaceLayout
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(transfer)
    }

    /// Assigning through the @Published properties (not UserDefaults/Keychain
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
        if let value = transfer.autoRecordOnStart { autoRecordOnStart = value }
        if let value = transfer.keepOBSWarm { keepOBSWarm = value }
        if let value = transfer.workspaceLayout {
            workspaceLayout = value
        } else if let raw = transfer.chromeLayout, let migrated = WorkspaceLayout(legacyChromeLayout: raw) {
            workspaceLayout = migrated
        }
        log("Imported settings.")
    }
}
