//
//  OnboardingView.swift
//  Greenroom
//
//  First-launch setup wizard - walks a fresh user through everything the
//  READMEs know the hard way: the two external installs, credentials (via
//  the settings-file import fast path), and the permission prompts macOS
//  will throw at them. Detects live state wherever possible (OBS/Zoom
//  installed, credentials present, Accessibility granted) instead of just
//  instructing. Reopenable anytime from the main window's ? button.
//
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var step: SetupPage = .welcome
    @State private var refreshTick = 0 // bumped by a timer so detected state stays live
    @State private var importStatus = ""
    @State private var importStatusIsError = false
    @State private var scratchExpanded = false
    @State private var isTesting = false
    @State private var testResults: [TestResult] = []
    @State private var connectingYouTube = false
    @State private var editCredentials = false
    @State private var youtubeHelpExpanded = false
    @State private var permissionDetailsExpanded = false

    private enum SetupPage: Int, CaseIterable, Identifiable {
        case welcome, essentials, zoom, layout, permissions, youtube, cues, screenroom, ready
        var id: Self { self }
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .essentials: "Apps"
            case .zoom: "Zoom"
            case .layout: "Layout"
            case .permissions: "Access"
            case .youtube: "YouTube"
            case .cues: "Cues"
            case .screenroom: "Screenroom"
            case .ready: "Finish"
            }
        }
        var section: String {
            switch self {
            case .welcome: "Getting started"
            case .essentials, .zoom, .layout, .permissions: "The basics"
            case .youtube, .cues, .screenroom: "Optional features"
            case .ready: "Your setup"
            }
        }
        var nextTitle: String {
            switch self {
            case .welcome: "Set up Greenroom"
            case .essentials: "Connect Zoom"
            case .zoom: "Choose your layout"
            case .layout: "Check permissions"
            case .permissions: "Explore optional features"
            case .youtube, .cues, .screenroom: "Continue"
            case .ready: "Open Greenroom"
            }
        }
        var isOptional: Bool { self == .youtube || self == .cues || self == .screenroom }
    }

    private var chatConfigured: Bool {
        !coordinator.sdkClientID.isEmpty && !coordinator.sdkClientSecret.isEmpty
    }
    private var hostingConfigured: Bool {
        !coordinator.s2sAccountID.isEmpty && !coordinator.s2sClientID.isEmpty && !coordinator.s2sClientSecret.isEmpty
    }
    private var zoomCredentials: [String] {
        [coordinator.sdkClientID, coordinator.sdkClientSecret,
         coordinator.s2sAccountID, coordinator.s2sClientID, coordinator.s2sClientSecret]
    }
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image("LogoMark")
                    .resizable().scaledToFit().frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up Greenroom").font(.headline)
                    Text("\(step.section) · \(step.rawValue + 1) of \(SetupPage.allCases.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close setup", systemImage: "xmark") { coordinator.completeOnboarding() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close now. Your changes are saved; reopen with the ? button.")
            }
            .padding(20)
            Divider()

            // Read the polling tick so external install/permission changes redraw this page.
            let _ = refreshTick
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)

            Divider()
            footer.padding(16)
        }
        .frame(width: 680, height: 700)
        .onReceive(timer) { _ in refreshTick += 1 }
        .onAppear { coordinator.loadSecretsIfNeeded() }
        .onChange(of: zoomCredentials) { _, _ in testResults = [] }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .essentials: essentialsStep
        case .zoom: credentialsStep
        case .layout: setupStep
        case .permissions: permissionsStep
        case .youtube: youtubeStep
        case .cues: cuesStep
        case .screenroom: screenroomStep
        case .ready: readyStep
        }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeader("A calmer start to class", "Set up your camera, meeting and workspace once. Greenroom brings them together when you press Start.")
            VStack(alignment: .leading, spacing: 20) {
                guideRow("1", "Check the basics", "Install the apps and connect your Zoom account.")
                guideRow("2", "Make it yours", "Choose your working app, camera shape and permissions.")
                guideRow("3", "Add what you need", "YouTube uploads, live suggestions and presentation reviews are optional.")
            }
            Divider()
            Label("Your changes save as you go.", systemImage: "checkmark.circle")
                .font(.callout.weight(.medium))
            Text("Close whenever you like. Reopen with the ? button, or click any step below to jump straight there.")
                .foregroundStyle(.secondary)
        }
    }

    private var essentialsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Two apps, one setup", "Greenroom uses OBS for your camera and Zoom for your meetings. We check for both automatically.")

            StatusRow(
                ok: OBSProcessManager.obsAppURL != nil,
                title: "OBS Studio",
                detail: OBSProcessManager.obsAppURL != nil
                    ? "Ready. Greenroom sets up your virtual camera for you."
                    : "Install OBS, then return here. This check updates automatically.",
                actionTitle: OBSProcessManager.obsAppURL == nil ? "Download OBS" : nil
            ) {
                NSWorkspace.shared.open(URL(string: "https://obsproject.com")!)
            }

            StatusRow(
                ok: ZoomLauncher.isInstalled,
                title: "Zoom",
                detail: ZoomLauncher.isInstalled
                    ? "Ready for meetings."
                    : "Install the Zoom desktop app, then return here.",
                actionTitle: ZoomLauncher.isInstalled ? nil : "Download Zoom"
            ) {
                NSWorkspace.shared.open(URL(string: "https://zoom.us/download")!)
            }

            Text("If OBS opens its own setup wizard, cancel it. Greenroom handles that setup.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The five scopes the Server-to-Server app needs - every one was
    /// discovered as a live 4711 error at some point; spare the next
    /// person that ride by handing them the full list up front. The fifth,
    /// meeting:update:status:admin, is End session's backstop: it lets the
    /// meeting be ended for everyone from the web when the in-meeting end
    /// does not take, and lets the pre-flight clear a meeting left running.
    private static let s2sScopes = "meeting:write:meeting:admin, meeting:read:list_meetings:admin, meeting:read:meeting:admin, user:read:token:admin, meeting:update:status:admin"

    struct TestResult: Identifiable {
        let id = UUID()
        let name: String
        let ok: Bool
        let detail: String
    }

    private var credentialsStep: some View {
        // Keep native disclosure chevrons and focus rings inside the scroll clip.
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                stepHeader("Connect your Zoom account", "Have a settings file from a teammate? Import it to fill in the connection details.")
                HStack(spacing: 12) {
                    Button("Import settings file…", systemImage: "square.and.arrow.down") { importSettingsFile() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isTesting)
                    Text("The quickest way to get connected.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !importStatus.isEmpty {
                    Label(importStatus, systemImage: importStatusIsError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(importStatusIsError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                VStack(spacing: 12) {
                    StatusRow(ok: chatConfigured, title: "Meeting and chat",
                              detail: chatConfigured ? "Details saved. Used by the built-in meeting client." : "Needs the Client ID and Secret from a Zoom General App.",
                              actionTitle: nil, action: {})
                    StatusRow(ok: hostingConfigured, title: "Create and host meetings",
                              detail: hostingConfigured ? "Details saved. Run the check below to verify the connection." : "Needs the Account ID, Client ID and Secret from a Server-to-Server app.",
                              actionTitle: nil, action: {})
                }
                DisclosureGroup("Enter or edit connection details", isExpanded: $editCredentials) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("General App · meeting and chat").font(.headline)
                        credentialField("Client ID", text: $coordinator.sdkClientID)
                        credentialField("Client Secret", text: $coordinator.sdkClientSecret, secure: true)
                        Divider()
                        Text("Server-to-Server app · hosting").font(.headline)
                        credentialField("Account ID", text: $coordinator.s2sAccountID)
                        credentialField("Client ID", text: $coordinator.s2sClientID)
                        credentialField("Client Secret", text: $coordinator.s2sClientSecret, secure: true)
                    }
                    .padding(.top, 12)
                    .disabled(isTesting)
                }
                DisclosureGroup("No settings file? Create your Zoom apps", isExpanded: $scratchExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Allow about 10 minutes. Both apps must belong to the same Zoom account.")
                            .font(.callout).foregroundStyle(.secondary)
                        scratchStep(1, "Create a **General App**. Under **Features → Embed**, turn on **Meeting SDK**. Copy its Client ID and Secret into the meeting and chat fields above.",
                                    buttonTitle: "Create a Zoom app…", url: "https://marketplace.zoom.us/develop/create")
                        scratchStep(2, "Create a **Server-to-Server OAuth** app. Copy its Account ID, Client ID and Secret into the hosting fields above.",
                                    buttonTitle: "Create a Zoom app…", url: "https://marketplace.zoom.us/develop/create")
                        scratchStep(3, "Add these five permissions on the Server-to-Server app’s **Scopes** page:", buttonTitle: nil, url: nil)
                        scopesBox
                    }
                    .padding(.top, 12)
                }
                Divider()
                HStack(spacing: 12) {
                    Button(isTesting ? "Checking Zoom…" : "Check Zoom connection") { runConnectionTest() }
                        .disabled(isTesting || !hostingConfigured)
                    if isTesting { ProgressView().controlSize(.small) }
                }
                Text("Checks saved hosting credentials, meeting lookup and the host token. Creating and ending a meeting are checked when you use those features.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(testResults) { result in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.name).font(.callout.weight(.medium))
                            Text(result.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.ok ? Brand.text : .red)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .id(SetupPage.zoom)
    }

    private func credentialField(_ title: String, text: Binding<String>, secure: Bool = false) -> some View {
        LabeledContent(title) {
            Group {
                if secure { SecureField(title, text: text) }
                else { TextField(title, text: text) }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 360)
        }
    }

    private func scratchStep(_ number: Int, _ text: LocalizedStringKey, buttonTitle: String?, url: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").bold().monospacedDigit()
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.callout)
                if let buttonTitle, let url {
                    Button(buttonTitle) { NSWorkspace.shared.open(URL(string: url)!) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var scopesBox: some View {
        HStack(alignment: .top) {
            Text(Self.s2sScopes)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.s2sScopes, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy all five scope names")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Exercises the real API calls the app makes, so every check failure
    /// carries the same self-explanatory scope hint the session errors do.
    /// Read/token checks only; creating or ending a meeting belongs to the
    /// session flow, not to a setup connection check.
    private func runConnectionTest() {
        coordinator.loadSecretsIfNeeded()
        isTesting = true
        testResults = []
        let (account, client, secret) = (coordinator.s2sAccountID, coordinator.s2sClientID, coordinator.s2sClientSecret)
        Task {
            var results: [TestResult] = []
            do {
                let list = try await ZoomServerToServerClient.listScheduledMeetings(
                    accountID: account, clientID: client, clientSecret: secret)
                results.append(TestResult(name: "Credentials + scheduled meetings list", ok: true,
                                          detail: "\(list.meetings.count) scheduled meeting(s) found."))
                if let warning = list.warning {
                    results.append(TestResult(name: "Recurring meetings' next times", ok: false, detail: warning))
                } else {
                    results.append(TestResult(name: "Recurring meetings' next times", ok: true, detail: "View-a-meeting scope in place."))
                }
            } catch {
                results.append(TestResult(name: "Credentials + scheduled meetings list", ok: false,
                                          detail: error.localizedDescription))
            }
            do {
                _ = try await ZoomServerToServerClient.fetchZAK(accountID: account, clientID: client, clientSecret: secret)
                results.append(TestResult(name: "Hosting your own meetings (host key)", ok: true, detail: "User token scope in place."))
            } catch {
                results.append(TestResult(name: "Hosting your own meetings (host key)", ok: false,
                                          detail: error.localizedDescription))
            }
            testResults = results
            isTesting = false
        }
    }

    // MARK: "Your setup" - the choices that actually differ per person,
    // inline instead of discovered by wandering into Settings later. All
    // bound straight to the coordinator, so they persist immediately and
    // Settings shows the same values.

    @State private var setupApps: [AppInfo] = []

    private var setupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stepHeader("Make room for your class", "Choose what sits beside the meeting and how you appear on camera. You can change these later in Settings.")

                Text("Your workspace").font(.headline)
                Picker("Working app", selection: $coordinator.mainAppBundleID) {
                    ForEach(setupApps) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                Text("Your reading, slides or notes open beside the meeting. Adjust the split in Settings → Layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                Text("Your camera").font(.headline)
                Picker("Camera shape", selection: $coordinator.webcamShape) {
                    ForEach(WebcamShape.allCases) { shape in
                        Text(shape.label).tag(shape)
                    }
                }
                .pickerStyle(.segmented)

                WebcamShapePreview(shape: coordinator.webcamShape)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)

                Divider()
                Text("When class starts").font(.headline)
                Toggle("Record automatically", isOn: $coordinator.autoRecordOnStart)
                Toggle("Show participants on a second display", isOn: $coordinator.peopleViewOnStart)
            }
            .padding(.horizontal, 8)
        }
        .id(SetupPage.layout)
        .onAppear {
            var apps = AppCatalog.installedAndRunning()
            if !apps.contains(where: { $0.bundleID == coordinator.mainAppBundleID }) {
                apps.insert(AppInfo(bundleID: coordinator.mainAppBundleID,
                                    name: AppCatalog.displayName(forBundleID: coordinator.mainAppBundleID) ?? coordinator.mainAppBundleID,
                                    url: nil), at: 0)
            }
            setupApps = apps
        }
    }

    private var permissionsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                stepHeader("Let Greenroom arrange your workspace", "Accessibility lets Greenroom position your meeting windows. You can grant it now.")
                StatusRow(ok: ZoomWindowManager.hasAccessibilityPermission,
                          title: "Arrange windows",
                          detail: ZoomWindowManager.hasAccessibilityPermission
                            ? "Accessibility is granted. Your windows can be tiled automatically."
                            : "Allow Greenroom in System Settings → Privacy & Security → Accessibility.",
                          actionTitle: ZoomWindowManager.hasAccessibilityPermission ? nil : "Open System Settings…") {
                    ZoomWindowManager.promptForAccessibilityPermission()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                DisclosureGroup("What will macOS ask me later?", isExpanded: $permissionDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 16) {
                        guideRow("rectangle.dashed.badge.record", "Screen recording", "OBS asks when you first start sharing your screen.", symbol: true)
                        guideRow("camera", "Camera and microphone", "Asked when you first connect to a meeting. You join muted, with the camera off.", symbol: true)
                        guideRow("globe", "Browser automation", "Asked when Greenroom first arranges your browser window.", symbol: true)
                    }
                    .padding(.top, 16)
                }
                Text("You control these permissions in System Settings and can revoke them anytime.")
                    .font(.callout).foregroundStyle(.secondary)
                Link(destination: AppLinks.safety) {
                    Label("See what Greenroom can access", systemImage: "lock.shield")
                }
                .font(.callout)
                Spacer(minLength: 0)
                Divider()
                Text("Next are three optional features. Skip them to review your setup, or explore them now.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }
        .id(SetupPage.permissions)
    }

    private var readyStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                stepHeader("Your setup, at a glance", "You can return to any step below. Everything you changed is already saved.")
                summaryRow("Apps", detail: OBSProcessManager.obsAppURL != nil && ZoomLauncher.isInstalled ? "OBS and Zoom installed" : "Install OBS and Zoom to get started", page: .essentials)
                summaryRow("Zoom", detail: chatConfigured && hostingConfigured ? "Connection details saved" : "Connection details still needed", page: .zoom)
                if let failure = testResults.first(where: { !$0.ok }) {
                    Label(failure.detail, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                }
                summaryRow("Workspace", detail: "\(AppCatalog.displayName(forBundleID: coordinator.mainAppBundleID) ?? coordinator.mainAppBundleID) · \(coordinator.webcamShape.label)", page: .layout)
                summaryRow("Accessibility", detail: ZoomWindowManager.hasAccessibilityPermission ? "Window arrangement allowed" : "Allow window arrangement in System Settings", page: .permissions)
                Divider()
                Text("Your first class").font(.headline)
                Text("Choose New Meeting or Join Existing on the main screen, then press Start.")
                if coordinator.useBuiltInClient {
                    Label("The built-in meeting client selects OBS Virtual Camera for you.", systemImage: "web.camera")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Label("In Zoom → Settings → Video, choose OBS Virtual Camera once. Zoom remembers it.", systemImage: "web.camera")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Text("Need a change later? Use Settings, or reopen this guide with the ? button.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
        }
        .id(SetupPage.ready)
    }

    private func summaryRow(_ title: String, detail: String, page: SetupPage) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") { step = page }
                .accessibilityLabel("Review \(title)")
        }
    }

    // MARK: YouTube (optional) - the same controls as Settings → YouTube, in
    // the flow, because a teacher who records wants to know the class can
    // land on the channel before the first morning, not discover it later.

    private var youtubeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                stepHeader("Share recordings after class", "Upload recordings to your YouTube channel as unlisted videos. You can leave this for later.")
                Picker("After a recording", selection: $coordinator.youtubeUploadMode) {
                    ForEach(YouTubeUploadMode.allCases) { mode in Text(mode.label).tag(mode) }
                }
                Text("Recordings stay in Documents/Greenroom. “Ask” lets you decide after each recording.")
                    .font(.callout).foregroundStyle(.secondary)
                if coordinator.youtubeUploadMode != .off {
                    StatusRow(ok: coordinator.youtubeConnected, title: "YouTube account",
                              detail: coordinator.youtubeConnected ? "Connected. Uploads go to this account’s channel." : "Connect the Google account that owns your channel.",
                              actionTitle: nil, action: {})
                    if coordinator.youtubeConnected {
                        Button("Disconnect account") { Task { await coordinator.disconnectYouTube() } }
                    } else {
                        credentialField("Client ID", text: $coordinator.youtubeClientID)
                        credentialField("Client Secret", text: $coordinator.youtubeClientSecret, secure: true)
                        HStack(spacing: 12) {
                            Button(connectingYouTube ? "Waiting for Google…" : "Connect Google account…") {
                                connectingYouTube = true
                                Task {
                                    await coordinator.connectYouTube()
                                    connectingYouTube = false
                                }
                            }
                            .disabled(connectingYouTube || coordinator.youtubeClientID.isEmpty || coordinator.youtubeClientSecret.isEmpty)
                            if connectingYouTube { ProgressView().controlSize(.small) }
                        }
                    }
                    if !coordinator.youtubeStatus.isEmpty {
                        Text(coordinator.youtubeStatus).font(.callout).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Where do I get the Client ID and Secret?", isExpanded: $youtubeHelpExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("In Google Cloud Console, create a project and enable YouTube Data API v3. Under Credentials, create an OAuth client ID with type Desktop app. Paste its ID and Secret above, then connect your account.")
                            Link("Open Google Cloud Console…", destination: URL(string: "https://console.cloud.google.com/")!)
                            Text("If your imported settings file includes these details, you can connect right away.")
                        }
                        .font(.callout).padding(.top, 12)
                    }
                }
                Label("Uploading sends the recording to YouTube. With “Do nothing”, no recordings are uploaded.", systemImage: "arrow.up.right")
                    .font(.callout).foregroundStyle(Brand.netText)
            }
            .padding(.horizontal, 8)
        }
        .id(SetupPage.youtube)
    }

    // MARK: Cues (optional) - the same rows as Settings → Cues. In the
    // flow because the model download belongs to setup day, not to the first
    // minute of the first class.

    private var cuesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(CuesAvailability.isReleased ? "Find links while you teach" : "Cues is coming soon",
                       CuesAvailability.isReleased
                           ? "Cues suggests links for what you mention in class. Turn it on only if you want suggestions; you choose what to share."
                           : "Link suggestions will arrive in a later release. There is nothing to set up here yet.")
            if !CuesAvailability.isReleased {
                Form {
                    CuesComingSoonRows(compact: true)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            } else if #available(macOS 26.0, *) {
                Form {
                    CuesSetupRows(compact: true)
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                Label("Speech is transcribed on this Mac. Search phrases go to book and reference services, and optionally YouTube. More controls live in Settings → Cues.", systemImage: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(Brand.netText)
            } else {
                CuesUnavailableText()
            }
        }
    }

    // MARK: Screenroom (optional) - the Settings tab itself, so the two can
    // never disagree. A teacher who evaluates presentations sets up whisper
    // and the agent here on setup day, not in the first minute of a student's
    // talk.

    private var screenroomStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Review student presentations",
                       "Screenroom pairs a recording with your timed notes and a speaking report. Skip this if you only teach classes.")
            ScreenroomSettingsTab(compact: true)
                .scrollContentBackground(.hidden)
        }
    }

    // MARK: Shared pieces

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private func guideRow(_ icon: String, _ title: String, _ detail: String, symbol: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if symbol { Image(systemName: icon) }
                else { Text(icon).monospacedDigit() }
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(Brand.text)
            .frame(width: 24)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 4) {
                ForEach(SetupPage.allCases) { page in
                    Button { step = page } label: {
                        VStack(spacing: 8) {
                            Circle()
                                .fill(page == step ? Brand.green : Color.secondary.opacity(0.3))
                                .frame(width: page == step ? 12 : 8, height: 12)
                            Text(page.title)
                                .font(.caption)
                                .fontWeight(page == step ? .semibold : .regular)
                                .foregroundStyle(page == step ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(page.title), step \(page.rawValue + 1) of \(SetupPage.allCases.count)")
                    .accessibilityValue(page == step ? "Current step" : "Jump to step")
                    .help("Go to \(page.title)")
                }
            }
            HStack(spacing: 12) {
                Button("Back") {
                    if let previous = SetupPage(rawValue: step.rawValue - 1) { step = previous }
                }
                .disabled(step == .welcome)
                if step.isOptional || step == .permissions {
                    Button("Skip optional features") { step = .ready }
                } else {
                    Text("Changes save automatically").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(step.nextTitle) {
                    if let next = SetupPage(rawValue: step.rawValue + 1) { step = next }
                    else { coordinator.completeOnboarding() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func importSettingsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Never silent: a failed import with no message read as "nothing
        // happened" (Codex design audit #5).
        do {
            try coordinator.importSettings(from: Data(contentsOf: url))
            importStatus = "Imported from \(url.lastPathComponent). You can delete that file now."
            importStatusIsError = false
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
            importStatusIsError = true
        }
    }
}

/// One detected-state row: a live check/warning icon, what it means, and
/// (when something's missing) the button that fixes it.
private struct StatusRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Brand.text : Brand.netText)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}
