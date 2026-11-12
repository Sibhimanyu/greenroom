//
//  OnboardingView.swift
//  Greenroom
//
//  First-launch setup wizard - walks a fresh user through everything the
//  READMEs know the hard way: credentials (via the settings-file import
//  fast path) and the permission prompts macOS will throw at them. Nothing
//  needs installing: Greenroom makes the picture and runs the meeting
//  itself. Detects live state wherever possible (credentials present,
//  Accessibility granted) instead of just
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
    @State private var isTesting = false
    @State private var testResults: [TestResult] = []
    @State private var showZoomChecks = false
    @State private var copiedScope: String?
    @State private var connectingYouTube = false
    @State private var editCredentials = false
    @State private var youtubeHelpExpanded = false
    @State private var permissionDetailsExpanded = false

    private enum SetupPage: Int, CaseIterable, Identifiable {
        case welcome, zoom, layout, permissions, youtube, cues, ready
        var id: Self { self }
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .zoom: "Zoom"
            case .layout: "Layout"
            case .permissions: "Access"
            case .youtube: "YouTube"
            case .cues: "Cues"
            case .ready: "Finish"
            }
        }
        var section: String {
            switch self {
            case .welcome: "Getting started"
            case .zoom, .layout, .permissions: "The basics"
            case .youtube, .cues: "Optional features"
            case .ready: "Your setup"
            }
        }
        var nextTitle: String {
            switch self {
            case .welcome: "Connect Zoom"
            case .zoom: "Set up your class"
            case .layout: "Check permissions"
            case .permissions: "Explore optional features"
            case .youtube, .cues: "Continue"
            case .ready: "Open Greenroom"
            }
        }
        var isOptional: Bool { self == .youtube || self == .cues }
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
        .onChange(of: zoomCredentials) { _, _ in
            if !isTesting { testResults = [] }
        }
        .sheet(isPresented: $showZoomChecks) { zoomCheckPanel }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .zoom: credentialsStep
        case .layout: setupStep
        case .permissions: permissionsStep
        case .youtube: youtubeStep
        case .cues: cuesStep
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
                guideRow("3", "Add what you need", "YouTube uploads and live suggestions are optional.")
            }
            Divider()
            Label("Your changes save as you go.", systemImage: "checkmark.circle")
                .font(.callout.weight(.medium))
            Text("Close whenever you like. Reopen with the ? button, or click any step below to jump straight there.")
                .foregroundStyle(.secondary)
        }
    }

    private enum ZoomCheck: String, CaseIterable {
        case sdk, account, create, list, details, host, end, meetings, hostToken
        var title: String {
            switch self {
            case .sdk: "Meeting and chat credentials"
            case .account: "Hosting credentials and app activation"
            case .create: "Permission to create meetings"
            case .list: "Permission to list meetings"
            case .details: "Permission to read meeting details"
            case .host: "Permission to get the hosting token"
            case .end: "Permission to end meetings"
            case .meetings: "Scheduled meetings API"
            case .hostToken: "Hosting token API"
            }
        }
    }

    private enum CheckStatus { case waiting, running, passed, failed, skipped }

    private struct TestResult: Identifiable {
        let check: ZoomCheck
        var status: CheckStatus = .waiting
        var detail = "Waiting to check"
        var id: ZoomCheck { check }
        var ok: Bool { status == .passed }
    }

    private struct ZoomScope: Identifiable {
        let check: ZoomCheck
        let name: String
        let purpose: String
        let legacy: String
        var id: String { name }
    }

    private static let zoomBuilder = URL(string: "https://marketplace.zoom.us/user/build")!
    private static let requiredScopes = [
        ZoomScope(check: .create, name: "meeting:write:meeting:admin", purpose: "Create meetings", legacy: "meeting:write:admin"),
        ZoomScope(check: .list, name: "meeting:read:list_meetings:admin", purpose: "List scheduled meetings", legacy: "meeting:read:admin"),
        ZoomScope(check: .details, name: "meeting:read:meeting:admin", purpose: "Read meeting details", legacy: "meeting:read:admin"),
        ZoomScope(check: .host, name: "user:read:token:admin", purpose: "Get your hosting token", legacy: "user:read:admin"),
        ZoomScope(check: .end, name: "meeting:update:status:admin", purpose: "End meetings for everyone", legacy: "meeting:write:admin")
    ]

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
                HStack(spacing: 12) {
                    zoomCheckButton
                    if isTesting { ProgressView().controlSize(.small) }
                    if !testResults.isEmpty && !isTesting {
                        Text("\(testResults.filter(\.ok).count) of \(testResults.count) checks passed")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("View results") { showZoomChecks = true }
                    }
                }
                Text(coordinator.isRunning || coordinator.stageLive
                     ? "End the current session before checking Zoom."
                     : "Checks both Zoom apps, all five hosting permissions, meeting lookup and the hosting token. No meeting is created or ended.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                DisclosureGroup(chatConfigured && hostingConfigured ? "Review or edit your Zoom apps" : "Set up Zoom without a settings file", isExpanded: $editCredentials) {
                    manualZoomSetup
                        .padding(.top, 16)
                        .disabled(isTesting)
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

    private var zoomCheckButton: some View {
        Button(isTesting ? "View checks in progress…" : "Check Zoom setup") {
            showZoomChecks = true
            if !isTesting { runConnectionTest() }
        }
        .disabled(coordinator.isRunning || coordinator.stageLive)
    }

    private var manualZoomSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("One-time setup · about 10 minutes")
                .font(.headline)
            Text("Use the same Zoom account for both apps. You need permission to build apps and add admin scopes; ask your Zoom account admin if those options are missing.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("In Zoom, choose Build App → General App. Under Features → Embed, turn on Meeting SDK. Find the Client ID and Secret under Basic Information and paste them here.")
                        .font(.callout)
                    zoomBuilderLink
                    credentialField("Client ID", text: $coordinator.sdkClientID)
                    credentialField("Client Secret", text: $coordinator.sdkClientSecret, secure: true)
                }
                .padding(12)
            } label: { Text("1 · Meeting and chat").font(.headline) }
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    Text("In Zoom, choose Build App → Server-to-Server OAuth. Copy the three values from App Credentials.")
                        .font(.callout)
                    zoomBuilderLink
                    credentialField("Account ID", text: $coordinator.s2sAccountID)
                    credentialField("Client ID", text: $coordinator.s2sClientID)
                    credentialField("Client Secret", text: $coordinator.s2sClientSecret, secure: true)
                    Divider()
                    Text("Add permissions, one at a time").font(.headline)
                    Text("In Zoom’s Scopes → Add Scopes, copy one name below, paste it into the search field and select the matching permission. Repeat for all five, then save.")
                        .font(.callout).foregroundStyle(.secondary)
                    scopesList
                    Divider()
                    Label("Finish Information, then open Activation and activate the app in Zoom. Return here to check your setup.", systemImage: "checkmark.circle")
                        .font(.callout)
                    zoomCheckButton
                }
                .padding(12)
            } label: { Text("2 · Create and host meetings").font(.headline) }
        }
    }

    private var zoomBuilderLink: some View {
        Link(destination: Self.zoomBuilder) {
            Label("Open Zoom app builder", systemImage: "arrow.up.right")
        }
        .help(Self.zoomBuilder.absoluteString)
    }

    private var scopesList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Self.requiredScopes) { scope in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scope.purpose).font(.callout.weight(.medium))
                        Text(scope.name).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                    Button(copiedScope == scope.name ? "Copied" : "Copy", systemImage: copiedScope == scope.name ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(scope.name, forType: .string)
                        copiedScope = scope.name
                    }
                    .accessibilityLabel("Copy \(scope.name)")
                    .accessibilityValue(copiedScope == scope.name ? "Copied" : "")
                }
            }
        }
    }

    private var zoomCheckPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isTesting ? "Checking your Zoom setup" : (testResults.allSatisfy(\.ok) ? "Zoom setup checks passed" : "Zoom setup needs attention"))
                        .font(.title2.bold())
                    Text("\(testResults.filter(\.ok).count) of \(testResults.count) checks passed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isTesting { ProgressView().controlSize(.small) }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(testResults) { result in
                        HStack(alignment: .top, spacing: 12) {
                            checkIcon(result.status).frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.check.title).font(.callout.weight(.semibold))
                                if result.status == .failed || result.status == .skipped || result.status == .running {
                                    Text(result.detail).font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer(minLength: 0)
                            if result.ok { Text("Passed").font(.caption).foregroundStyle(.secondary) }
                        }
                        .help(result.detail)
                    }
                }
                .padding(4)
            }
            Divider()
            Text("Scope checks read Zoom’s granted permissions. Creating, joining and ending a real meeting are still tested when you start a class.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if !isTesting {
                    Button("Check again") { runConnectionTest() }
                        .disabled(coordinator.isRunning || coordinator.stageLive)
                }
                Spacer()
                Button(isTesting ? "Close checks" : "Done") { showZoomChecks = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 580, height: 640)
    }

    @ViewBuilder
    private func checkIcon(_ status: CheckStatus) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.text)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }

    private func updateCheck(_ check: ZoomCheck, _ status: CheckStatus, _ detail: String) {
        guard let index = testResults.firstIndex(where: { $0.check == check }) else { return }
        testResults[index].status = status
        testResults[index].detail = detail
    }

    private func runConnectionTest() {
        guard !isTesting && !coordinator.isRunning && !coordinator.stageLive else { return }
        coordinator.loadSecretsIfNeeded()
        isTesting = true
        testResults = ZoomCheck.allCases.map { TestResult(check: $0) }
        let credentials = zoomCredentials
        let (sdkID, sdkSecret, account, client, secret) = (credentials[0], credentials[1], credentials[2], credentials[3], credentials[4])
        Task { @MainActor in
            defer {
                isTesting = false
                // Edits through Settings while a check was running invalidate it, too.
                if zoomCredentials != credentials {
                    for check in ZoomCheck.allCases {
                        updateCheck(check, .skipped, "Zoom details changed during the check. Check again to verify the new values.")
                    }
                }
            }
            if sdkID.isEmpty || sdkSecret.isEmpty {
                updateCheck(.sdk, .failed, "Add both General App values under Meeting and chat.")
            } else {
                updateCheck(.sdk, .running, "Authenticating with the Zoom Meeting SDK…")
                do {
                    try await coordinator.zoomChatClient.ensureReady(clientID: sdkID, clientSecret: sdkSecret, forceAuthentication: true)
                    updateCheck(.sdk, .passed, "Zoom accepted the General App credentials.")
                } catch {
                    updateCheck(.sdk, .failed, "\(error.localizedDescription) Check the General App credentials and that Meeting SDK is enabled.")
                }
            }
            guard !account.isEmpty && !client.isEmpty && !secret.isEmpty else {
                updateCheck(.account, .failed, "Add all three Server-to-Server app values under Create and host meetings.")
                skipHostingChecks("Add hosting credentials, then check again.")
                return
            }
            updateCheck(.account, .running, "Checking the Server-to-Server app with Zoom…")
            do {
                let scopes = try await ZoomServerToServerClient.grantedScopes(accountID: account, clientID: client, clientSecret: secret)
                updateCheck(.account, .passed, "Zoom issued an access token. The hosting app is active.")
                for scope in Self.requiredScopes {
                    let granted = scopes.contains(scope.name) || scopes.contains(scope.legacy)
                    updateCheck(scope.check, granted ? .passed : .failed,
                                granted ? "Granted by Zoom." : "Missing \(scope.name). Add it in the Server-to-Server app’s Scopes page, save, and check again.")
                }
            } catch {
                updateCheck(.account, .failed, "\(error.localizedDescription) Check the three hosting values and activate the app in Zoom.")
                skipHostingChecks("Hosting authentication failed. Fix it, then check again.")
                return
            }
            updateCheck(.meetings, .running, "Loading scheduled meetings…")
            do {
                let list = try await ZoomServerToServerClient.listScheduledMeetings(accountID: account, clientID: client, clientSecret: secret)
                if let warning = list.warning {
                    updateCheck(.meetings, .failed, warning)
                } else {
                    updateCheck(.meetings, .passed, "Zoom returned \(list.meetings.count) scheduled meeting(s).")
                }
            } catch { updateCheck(.meetings, .failed, error.localizedDescription) }
            updateCheck(.hostToken, .running, "Requesting the hosting token…")
            do {
                let token = try await ZoomServerToServerClient.fetchZAK(accountID: account, clientID: client, clientSecret: secret)
                updateCheck(.hostToken, token.isEmpty ? .failed : .passed,
                            token.isEmpty ? "Zoom returned an empty hosting token." : "Zoom returned a hosting token. No meeting was started.")
            } catch { updateCheck(.hostToken, .failed, error.localizedDescription) }
        }
    }

    private func skipHostingChecks(_ reason: String) {
        for check in ZoomCheck.allCases where check != .sdk && check != .account {
            updateCheck(check, .skipped, reason)
        }
    }

    // MARK: "Your setup" - the choices that actually differ per person,
    // inline instead of discovered by wandering into Settings later. All
    // bound straight to the coordinator, so they persist immediately and
    // Settings shows the same values.

    @State private var setupApps: [AppInfo] = []

    private var setupMainSize: CGSize {
        DisplayResolver.mainDisplayScreen()?.visibleFrame.size ?? CGSize(width: 1440, height: 875)
    }

    private var chosenTemplate: LayoutTemplate? { coordinator.layoutLibrary.active }

    private var setupStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stepHeader("How should a class start?", "Choose a layout, how you appear on camera and whether to record. You can change these later in Settings.")

                // The same cards and thumbnails as Settings \u{2192} Layout. Picking one
                // is choosing it for Start: it writes the library's active layout.
                let thumbHeight = layoutThumbHeight(for: setupMainSize)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: layoutCardWidth + 12), spacing: 8, alignment: .top)],
                          alignment: .leading, spacing: 8) {
                    LayoutCard(title: "None", selected: coordinator.layoutLibrary.activeID == nil, isRenaming: false,
                               draft: .constant(""), select: { chooseLayout(nil) }, beginRename: nil,
                               commitRename: {}, cancelRename: {}) {
                        LayoutNoneThumbnail(height: thumbHeight)
                    }
                    ForEach(coordinator.layoutLibrary.templates) { template in
                        LayoutCard(title: template.name, selected: coordinator.layoutLibrary.activeID == template.id,
                                   isRenaming: false, draft: .constant(""), select: { chooseLayout(template.id) },
                                   beginRename: nil, commitRename: {}, cancelRename: {}) {
                            LayoutThumbnail(pieces: template.oneDisplay, aspect: layoutCardWidth / thumbHeight,
                                            look: LayoutPieceLook.thumbnail)
                        }
                    }
                }

                if let template = chosenTemplate {
                    // A built-in layout is not edited here, so it gets no picker.
                    if !template.isLocked, let appID = template.firstAppBundleID {
                        Picker("Working app", selection: Binding(
                            get: { appID },
                            set: { newID in
                                var edited = template
                                edited.replaceApp(appID, with: newID)
                                coordinator.layoutLibrary.update(edited)
                            })) {
                            ForEach(setupAppChoices(including: appID)) { app in
                                Text(app.name).tag(app.bundleID)
                            }
                        }
                        Text("Your reading, slides or notes open beside the meeting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Fine-tune it in Settings \u{2192} Layout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Greenroom opens and moves nothing. The meeting opens in its own window, and a small control bar floats at the bottom of the screen when that window is out of view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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
            }
            .padding(.horizontal, 8)
        }
        .id(SetupPage.layout)
        .onAppear {
            LayoutIcons.reset()
            setupApps = AppCatalog.installedAndRunning()
        }
    }

    /// The installed apps, plus the layout's own app when it is not among them
    /// (an import from another Mac), so the picker never shows a blank.
    private func setupAppChoices(including bundleID: String) -> [AppInfo] {
        guard !setupApps.contains(where: { $0.bundleID == bundleID }) else { return setupApps }
        let missing = AppInfo(bundleID: bundleID,
                              name: AppCatalog.displayName(forBundleID: bundleID) ?? bundleID, url: nil)
        return [missing] + setupApps
    }

    private func chooseLayout(_ id: UUID?) {
        guard coordinator.layoutLibrary.activeID != id else { return }
        coordinator.layoutLibrary.select(id)
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
                        guideRow("rectangle.dashed.badge.record", "Screen recording", "Asked the first time your screen goes behind you, on Start or in Settings → Webcam. Quit and reopen Greenroom after allowing it.", symbol: true)
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
                Text("Next are two optional features. Skip them to review your setup, or explore them now.")
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
                summaryRow("Zoom", detail: chatConfigured && hostingConfigured ? "Connection details saved" : "Connection details still needed", page: .zoom)
                if let failure = testResults.first(where: { $0.status == .failed }) {
                    Label(failure.detail, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                }
                summaryRow("Class layout", detail: "\(chosenTemplate?.name ?? "None") \u{00B7} \(coordinator.webcamShape.label)", page: .layout)
                summaryRow("Accessibility", detail: ZoomWindowManager.hasAccessibilityPermission ? "Window arrangement allowed" : "Allow window arrangement in System Settings", page: .permissions)
                Divider()
                Text("Your first class").font(.headline)
                Text("Choose New Meeting or Join Existing on the main screen, then press Start. To record without a meeting, choose Record.")
                Label("Greenroom sends its own picture into the meeting, so there is no camera to pick in Zoom.", systemImage: "web.camera")
                    .font(.callout).foregroundStyle(.secondary)
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
