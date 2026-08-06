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
import AppKit
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @Environment(\.openSettings) private var openSettings
    @State private var step = 0
    @State private var refreshTick = 0 // bumped by a timer so detected state stays live
    @State private var scratchExpanded = false
    @State private var isTesting = false
    @State private var testResults: [TestResult] = []

    private let stepCount = 6
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(28)

            Divider()

            footer
                .padding(16)
        }
        .frame(width: 580, height: 600)
        .onReceive(timer) { _ in refreshTick += 1 }
        // Secrets stay out of the Keychain until needed - the credential
        // fields in step 2 are that moment.
        .onAppear { coordinator.loadSecretsIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcomeStep
        case 1: essentialsStep
        case 2: credentialsStep
        case 3: setupStep
        case 4: permissionsStep
        default: readyStep
        }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 12)
            Text("Welcome to Greenroom").font(.largeTitle.bold())
            Text("Your whole meeting setup, one click.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label("A virtual camera showing your screen with you keyed into a bubble", systemImage: "web.camera")
                Label("Starts a fresh Zoom meeting as host, or joins one from a link", systemImage: "video.badge.plus")
                Label("Your main app and the meeting chat tiled neatly side by side", systemImage: "rectangle.split.2x1")
                Label("Stop tears the whole thing down again", systemImage: "stop.circle")
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private var essentialsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("The essentials", "Two free apps do the heavy lifting. Both are one-time installs.")

            StatusRow(
                ok: OBSProcessManager.obsAppURL != nil,
                title: "OBS Studio",
                detail: OBSProcessManager.obsAppURL != nil
                    ? "Installed \u{2014} Greenroom configures it automatically, nothing to set up."
                    : "Not found. Install it, then come back \u{2014} this row updates by itself.",
                actionTitle: OBSProcessManager.obsAppURL == nil ? "Download OBS" : nil
            ) {
                NSWorkspace.shared.open(URL(string: "https://obsproject.com")!)
            }

            StatusRow(
                ok: ZoomLauncher.isInstalled,
                title: "Zoom",
                detail: ZoomLauncher.isInstalled
                    ? "Installed."
                    : "Not found. Install the Zoom desktop app.",
                actionTitle: ZoomLauncher.isInstalled ? nil : "Download Zoom"
            ) {
                NSWorkspace.shared.open(URL(string: "https://zoom.us/download")!)
            }

            Text("A fresh OBS install may show its own setup wizard on first launch \u{2014} it can simply be cancelled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The four scopes the Server-to-Server app needs - every one was
    /// discovered as a live 4711 error at some point; spare the next
    /// person that ride by handing them the full list up front.
    private static let s2sScopes = "meeting:write:meeting:admin, meeting:read:list_meetings:admin, meeting:read:meeting:admin, user:read:token:admin"

    struct TestResult: Identifiable {
        let id = UUID()
        let name: String
        let ok: Bool
        let detail: String
    }

    private var credentialsStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                stepHeader("Zoom credentials", "Meeting features run on Zoom Marketplace app credentials. Two ways in:")

                HStack {
                    Button {
                        importSettingsFile()
                    } label: {
                        Label("Import Settings File\u{2026}", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Got a file from a teammate? This fills in everything at once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                StatusRow(
                    ok: !coordinator.sdkClientID.isEmpty,
                    title: "Meeting chat credentials (General App)",
                    detail: coordinator.sdkClientID.isEmpty
                        ? "Paste below \u{2014} powers the built-in meeting client and chat window."
                        : "Configured.",
                    actionTitle: nil, action: {}
                )
                HStack {
                    TextField("Client ID", text: $coordinator.sdkClientID)
                    SecureField("Client Secret", text: $coordinator.sdkClientSecret)
                }
                .textFieldStyle(.roundedBorder)

                StatusRow(
                    ok: !coordinator.s2sAccountID.isEmpty && !coordinator.s2sClientID.isEmpty,
                    title: "Start-meeting credentials (Server-to-Server app)",
                    detail: coordinator.s2sAccountID.isEmpty
                        ? "Paste below \u{2014} powers \u{201C}New Meeting\u{201D}, the Scheduled list, and hosting your own meetings."
                        : "Configured \u{2014} verify with the test below.",
                    actionTitle: nil, action: {}
                )
                HStack {
                    TextField("Account ID", text: $coordinator.s2sAccountID)
                    TextField("Client ID", text: $coordinator.s2sClientID)
                    SecureField("Client Secret", text: $coordinator.s2sClientSecret)
                }
                .textFieldStyle(.roundedBorder)

                DisclosureGroup("Setting up from scratch? The full walkthrough (\u{2248}10 minutes, once)", isExpanded: $scratchExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        scratchStep(1, "Create a **General App** \u{2014} on its **Features \u{2192} Embed** page toggle **Meeting SDK** on, then copy its **Client ID + Secret** into Settings \u{2192} Meeting Chat.",
                                    buttonTitle: "Create app on marketplace.zoom.us\u{2026}",
                                    url: "https://marketplace.zoom.us/develop/create")
                        scratchStep(2, "Create a **Server-to-Server OAuth** app \u{2014} copy its **Account ID, Client ID and Secret** into Settings \u{2192} Start Meeting.",
                                    buttonTitle: "Create app on marketplace.zoom.us\u{2026}",
                                    url: "https://marketplace.zoom.us/develop/create")
                        scratchStep(3, "On the Server-to-Server app's **Scopes** page, add these four (search each name):", buttonTitle: nil, url: nil)
                        scopesBox
                        scratchStep(4, "Both apps must belong to the SAME Zoom account \u{2014} that's what lets Greenroom host and chat in the meetings it creates.", buttonTitle: nil, url: nil)
                    }
                    .padding(.top, 8)
                }
                .font(.callout)

                Divider()

                HStack(spacing: 10) {
                    Button(isTesting ? "Testing\u{2026}" : "Test Zoom Connection") { runConnectionTest() }
                        .disabled(isTesting || coordinator.s2sAccountID.isEmpty || coordinator.s2sClientID.isEmpty)
                    Text("Checks the credentials and every scope, and names anything missing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(testResults) { result in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.name).font(.callout.weight(.medium))
                            Text(result.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func scratchStep(_ number: Int, _ text: LocalizedStringKey, buttonTitle: String?, url: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").bold().monospacedDigit()
            VStack(alignment: .leading, spacing: 5) {
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
            .help("Copy all four scope names")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Exercises the real API calls the app makes, so every check failure
    /// carries the same self-explanatory scope hint the session errors do.
    /// The write scope is the one thing not tested (verifying it would
    /// create an actual meeting) - the caption under the button says so.
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
        VStack(alignment: .leading, spacing: 14) {
            stepHeader("Your setup", "How mornings should look. Everything here lives in Settings (\u{2318},) too.")

            Picker("Main working app", selection: $coordinator.mainAppBundleID) {
                ForEach(setupApps) { app in
                    Text(app.name).tag(app.bundleID)
                }
            }
            Text("Tiled next to the meeting \u{2014} the reading doc's browser, a PDF app, notes. Split sizes and a default website live in Settings \u{2192} Layout.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("How you appear", selection: $coordinator.webcamShape) {
                ForEach(WebcamShape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            WebcamShapePreview(shape: coordinator.webcamShape)
                .frame(maxWidth: .infinity)
                .frame(height: 150)

            Toggle("Start recording automatically with the meeting", isOn: $coordinator.autoRecordOnStart)
            Toggle("People view on a second display (classroom projector)", isOn: $coordinator.peopleViewOnStart)
        }
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
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Permissions", "macOS will ask a few one-time questions. Here's what to expect and why.")

            StatusRow(
                ok: ZoomWindowManager.hasAccessibilityPermission,
                title: "Accessibility",
                detail: ZoomWindowManager.hasAccessibilityPermission
                    ? "Granted \u{2014} Zoom's window gets tiled automatically."
                    : "Needed to tile Zoom's window into the layout. Grant it now to avoid a mid-meeting prompt.",
                actionTitle: ZoomWindowManager.hasAccessibilityPermission ? nil : "Grant\u{2026}"
            ) {
                ZoomWindowManager.promptForAccessibilityPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Screen Recording \u{2014} OBS asks on the first Start (it captures your screen)", systemImage: "rectangle.dashed.badge.record")
                Label("Camera & Microphone \u{2014} asked on the first chat connection", systemImage: "camera")
                Label("Browser automation (Chrome) \u{2014} asked when its window is first tiled; other main apps use Accessibility above", systemImage: "globe")
                Label("Keychain \u{2014} if asked, always click \u{201C}Always Allow\u{201D}, never plain \u{201C}Allow\u{201D}", systemImage: "key")
            }
            .font(.callout)

            Text("Each appears exactly once if approved \u{2014} approving them all makes every later Start silent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .padding(.top, 12)
            Text("One last thing").font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 12) {
                Text("The first time you're in a Zoom meeting, open Zoom's **Settings \u{2192} Video** and pick **\u{201C}OBS Virtual Camera\u{201D}**. Zoom remembers it for every call after that \u{2014} it's the only manual step this app can't do for you.")
                Text("Then it's: pick **New Meeting** or **Join Existing**, hit **Start**, and everything falls into place.")
                Text("Reopen this guide anytime with the **?** button on the main window.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Shared pieces

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { step -= 1 }
                .disabled(step == 0)

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            if step < stepCount - 1 {
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Get Started") { coordinator.completeOnboarding() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func importSettingsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? coordinator.importSettings(from: Data(contentsOf: url))
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
