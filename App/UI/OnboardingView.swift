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
    /// A deep link into the YouTube step, handed to `YouTubeGuideStep`, which clears it.
    @State private var youtubeJump: YouTubeGuideSpot?
    @State private var permissionDetailsExpanded = false
    /// A deep link into the Zoom step, handed to `ZoomGuideStep`, which clears it.
    @State private var zoomJump: ZoomGuideSpot?

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
            case .zoom: "Set up your meeting"
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
            setupChecker.credentialsChanged()
        }
        .onAppear { goToGuideSpot() }
        .onChange(of: coordinator.zoomGuideSpot) { _, _ in goToGuideSpot() }
        .onAppear { goToYouTubeSpot() }
        .onChange(of: coordinator.youtubeGuideSpot) { _, _ in goToYouTubeSpot() }
        .sheet(isPresented: showZoomChecks) { zoomCheckPanel }
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
            stepHeader("A calmer start to every meeting", "Set up your camera, meeting and workspace once. Greenroom brings them together when you press Start.")
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

    // "Check Zoom setup": the coordinator's one checker, shared with Settings -> Zoom.
    private var setupChecker: ZoomSetupChecker { coordinator.zoomSetupChecker }
    private var isTesting: Bool { setupChecker.isRunning }
    private var testResults: [ZoomCheckLine] { setupChecker.lines }
    private var showZoomChecks: Binding<Bool> {
        Binding(get: { ZoomCheckSurface.guide.isShown(setupChecker.showingIn) },
                set: { if !$0, setupChecker.showingIn == .guide { setupChecker.showingIn = nil } })
    }
    private func runConnectionTest() { coordinator.checkZoomSetup() }

    /// A deep link ("Show me where", Settings' Set up / Edit setup, Home's
    /// pill): the Zoom step, which opens the asked part and scrolls to it.
    private func goToGuideSpot() {
        guard let spot = coordinator.zoomGuideSpot else { return }
        coordinator.zoomGuideSpot = nil
        step = .zoom
        // The step may not exist yet; it reads the spot when it appears.
        DispatchQueue.main.async { zoomJump = spot }
    }

    /// Settings -> YouTube's "Set up… / Edit setup…": the YouTube step, own-app part open.
    private func goToYouTubeSpot() {
        guard let spot = coordinator.youtubeGuideSpot else { return }
        coordinator.youtubeGuideSpot = nil
        step = .youtube
        // The step may not exist yet; it reads the spot when it appears.
        DispatchQueue.main.async { youtubeJump = spot }
    }

    private var credentialsStep: some View {
        ZoomGuideStep(
            sdkClientID: $coordinator.sdkClientID,
            sdkClientSecret: $coordinator.sdkClientSecret,
            s2sAccountID: $coordinator.s2sAccountID,
            s2sClientID: $coordinator.s2sClientID,
            s2sClientSecret: $coordinator.s2sClientSecret,
            checkLines: testResults,
            isChecking: isTesting,
            checkDisabled: coordinator.phase.isInMeeting,
            signInComingSoon: ZoomSignInAvailability.isComingSoon,
            signIn: ZoomSignInAvailability.isComingSoon ? nil : AnyView(ZoomSignInSection.live(coordinator)),
            importStatus: importStatus,
            importFailed: importStatusIsError,
            jump: $zoomJump,
            onImport: { importSettingsFile() },
            onCheck: { setupChecker.showingIn = .guide; runConnectionTest() },
            onViewResults: { setupChecker.showingIn = .guide })
        .id(SetupPage.zoom)
    }

    /// The footer's plain note on the Zoom step while Zoom isn't connected yet.
    private var zoomFooterNote: String? {
        ZoomGuideFlowRules.flow(ZoomGuideFlowRules.facts(
            sdkFields: [coordinator.sdkClientID, coordinator.sdkClientSecret],
            s2sFields: [coordinator.s2sAccountID, coordinator.s2sClientID, coordinator.s2sClientSecret],
            lines: testResults, running: isTesting)).footerNote
    }

    private func credentialField(_ title: String, text: Binding<String>, secure: Bool = false) -> some View {
        LabeledContent(title) {
            Group {
                if secure { SecureField(title, text: text) }
                else { TextField(title, text: text) }
            }
            .labelsHidden()
            .textFieldStyle(.greenroom)
            .frame(maxWidth: 360)
        }
    }

    private var zoomCheckPanel: some View {
        ZoomCheckPanel(subject: "Zoom setup", lines: testResults, isRunning: isTesting,
                       footnote: ZoomSetupChecker.footnote,
                       againDisabled: coordinator.phase.isInMeeting, ids: coordinator.zoomCheckIDs,
                       onAgain: { runConnectionTest() }, onDone: { setupChecker.showingIn = nil },
                       onAction: { coordinator.performZoomCheckAction($0, kind: .ownApps) })
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
                stepHeader("How should a meeting start?", "Choose a layout, how you appear on camera and whether to record. You can change these later in Settings.")

                // The same cards and thumbnails as Settings \u{2192} Layout. Picking one
                // is choosing it for Start: it writes the library's active layout.
                let thumbHeight = layoutThumbHeight(for: setupMainSize)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: layoutCardWidth + 12), spacing: 8, alignment: .top)],
                          alignment: .leading, spacing: 8) {
                    ForEach(coordinator.layoutLibrary.templates) { template in
                        OnboardingLayoutCard(title: template.name, selected: coordinator.layoutLibrary.activeID == template.id,
                                             select: { chooseLayout(template.id) }) {
                            LayoutThumbnail(pieces: template.oneDisplay, aspect: layoutCardWidth / thumbHeight,
                                            camera: LayoutStripRules.thumbnailCamera(for: template), look: LayoutPieceLook.thumbnail)
                        }
                    }
                }

                if let template = chosenTemplate {
                    if let appID = template.firstAppBundleID {
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
                GreenroomSegmented("Camera shape", selection: $coordinator.webcamShape,
                                   options: Array(WebcamShape.allCases)) { shape in
                    Text(shape.label)
                }

                WebcamShapePreview(shape: coordinator.webcamShape)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)

                Divider()
                Text("When the meeting starts").font(.headline)
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
                        guideRow(VisibilitySymbol.screenRecordingPermission.name, "Screen recording", "Asked the first time your screen goes behind you, on Start or in Settings → Layouts. Quit and reopen Greenroom after allowing it.", symbol: true)
                        guideRow(VisibilitySymbol.cameraOn.name, "Camera and microphone", "Asked when you first connect to a meeting. You join muted, with the camera off.", symbol: true)
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
                summaryRow("Meeting layout", detail: "\(chosenTemplate?.name ?? "None") \u{00B7} \(coordinator.webcamShape.label)", page: .layout)
                summaryRow("Accessibility", detail: ZoomWindowManager.hasAccessibilityPermission ? "Window arrangement allowed" : "Allow window arrangement in System Settings", page: .permissions)
                Divider()
                Text("Your first meeting").font(.headline)
                Text("Choose New or Scheduled on the main screen, then press Start Meeting. To record without a meeting, choose Record.")
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

    // MARK: YouTube (optional) - the same choice as Settings → YouTube, as
    // a guided step (YouTubeGuideStep), because someone who records wants to
    // know uploads can land on the channel before the first meeting.

    private var youtubeStep: some View {
        let status = coordinator.youtubeStatus
        return YouTubeGuideStep(
            usesOwnApp: $coordinator.youtubeUsesOwnApp,
            clientID: $coordinator.youtubeClientID,
            clientSecret: $coordinator.youtubeClientSecret,
            uploadMode: $coordinator.youtubeUploadMode,
            madeForKids: $coordinator.youtubeMadeForKids,
            account: coordinator.youtubeAccountFacts,
            channel: coordinator.youtubeChannel,
            problem: !coordinator.youtubeConnected && !coordinator.youtubeSigningIn && status.hasPrefix("Not connected:")
                ? String(status.dropFirst("Not connected: ".count)) : nil,
            signIn: { Task { await coordinator.signInToYouTube() } },
            signOut: { Task { await coordinator.signOutOfYouTube() } },
            jump: $youtubeJump)
        .id(SetupPage.youtube)
    }

    // MARK: Cues (optional) - the same rows as Settings → Cues. In the
    // flow because the model download belongs to setup day, not to the first
    // minute of the first class.

    private var cuesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader(CuesAvailability.isReleased ? "Find links during meetings" : "Cues is coming soon",
                       CuesAvailability.isReleased
                           ? "Cues is a beta and very risky: it suggests links for what you mention in the meeting, and they can be wrong. Turn it on only if you want suggestions; you choose what to share."
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
                } else if step == .zoom, let note = zoomFooterNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
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

    /// Returns true when the file was imported.
    @discardableResult
    private func importSettingsFile() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        // Never silent: a failed import with no message read as "nothing
        // happened" (Codex design audit #5).
        do {
            let report = try coordinator.importSettings(from: Data(contentsOf: url))
            importStatus = (["Imported from \(url.lastPathComponent). You can delete that file now."] + report.notes)
                .joined(separator: " ")
            importStatusIsError = false
            return true
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
            importStatusIsError = true
            return false
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


/// The onboarding layout choice: the shared choice tile around the same
/// thumbnail Settings shows. Settings' `LayoutCard` (owned by the Settings
/// chunk) is left alone; onboarding has no rename, so this is just a Button.
private struct OnboardingLayoutCard<Thumbnail: View>: View {
    let title: String
    let selected: Bool
    let select: () -> Void
    @ViewBuilder let thumbnail: () -> Thumbnail

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                thumbnail().frame(width: layoutCardWidth)
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: layoutCardWidth, height: 34, alignment: .top)
            }
            .padding(6)
        }
        .greenroomTile(role: .choice(selected: selected))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Start layout" : "")
    }
}
