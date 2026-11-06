//
//  SettingsView.swift
//  Greenroom
//
//  Everything here is "set once, rarely touched" - opened via
//  Greenroom -> Settings... (⌘,), the standard macOS location, rather
//  than cluttering the main window's day-to-day flow. Shares the same
//  CoordinatorController instance as ContentView (injected via
//  .environmentObject in GreenroomApp.swift), so changes take effect
//  immediately.
//
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        TabView {
            WebcamSettingsTab()
                .tabItem { Label("Webcam", systemImage: "video.fill") }

            LayoutSettingsTab()
                .tabItem { Label("Layout", systemImage: "rectangle.split.2x1") }

            ZoomSettingsTab()
                .tabItem { Label("Zoom", systemImage: "video.fill") }

            YouTubeSettingsTab()
                .tabItem { Label("YouTube", systemImage: "play.rectangle.fill") }

            CuesSettingsTab()
                .tabItem { Label("Cues", systemImage: "waveform.and.magnifyingglass") }
            ScreenroomSettingsTab()
                .tabItem { Label("Screenroom", systemImage: "chart.bar.doc.horizontal") }

            TransferSettingsTab()
                .tabItem { Label("Transfer", systemImage: "square.and.arrow.up.on.square") }
        }
        .frame(width: 760, height: 730)
        // Secrets are loaded lazily (see loadSecretsIfNeeded) - opening
        // Settings is the first moment the fields actually need them.
        .onAppear { coordinator.loadSecretsIfNeeded() }
    }
}

private enum LayoutSettingsFocus: Hashable {
    case websiteURL
}

/// Re-draws its content whenever the director or the probe publishes.
///
/// Both are ObservableObjects owned by the coordinator, and SwiftUI does not
/// see through one observable to another: reading `coordinator.cameraDirector
/// .sight` subscribes to the coordinator, which never changes when the sight
/// does. So the angle and the switch countdown only moved when something else
/// happened to redraw the window. Observing the two directly fixes that
/// without making the whole coordinator republish three times a second.
private struct LiveReadings<Content: View>: View {
    @ObservedObject var director: CameraDirector
    @ObservedObject var probe: CameraProbe
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}

/// Setting up the two-camera cut.
///
/// The hard part of this feature is not the software, it is aiming a camera,
/// and that cannot be done blind. So the angle this camera currently reads is
/// on screen the whole time the tab is open - move the camera, watch the
/// number fall. Nothing cuts while you are in here; see
/// CameraDirector.startObserving.
struct CameraSwitchSection: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var cameras: [LocalDeviceResolver.Camera] = []
    /// Which camera the preview and the angle readout are currently on.
    @State private var aiming: String?

    private var settings: Binding<CameraDirectorSettings> { $coordinator.cameraDirectorSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Switch to the camera you\u{2019}re facing", isOn: settings.enabled)
                .help("For two monitors: put a camera on each, and the class sees whichever one you face instead of the side of your head.")

            // Shown whether or not switching is on, like the rest of Settings.
            // Choosing and aiming the cameras stays live - it is the setup a
            // teacher does BEFORE trusting the feature, and the angle readout
            // is how they check it - while the two settings that only shape a
            // cut grey out until there are cuts to shape.
            LiveReadings(director: coordinator.cameraDirector, probe: coordinator.cameraProbe) {
                chooser
            }
            Group {
                dwell
                transition
            }
            .disabled(!coordinator.cameraDirectorSettings.enabled)
            LiveReadings(director: coordinator.cameraDirector, probe: coordinator.cameraProbe) {
                readout
            }
        }
        .onAppear { cameras = LocalDeviceResolver.availableCameras() }
        .onDisappear {
            // A settings window left open would otherwise hold a camera - and
            // its light on - for as long as the app ran.
            coordinator.stopAiming()
            aiming = nil
        }
    }

    // MARK: Which cameras, and in what order

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CAMERAS, IN ORDER \u{00B7} A SESSION STARTS ON THE FIRST")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(.tertiary)

            if cameras.count < 2 {
                Text("Only one camera is plugged in, so there is nothing to cut to. Your iPhone counts \u{2014} put it on the other monitor and it appears here as a camera.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(cameras) { camera in
                let position = coordinator.cameraDirectorSettings.cameraUIDs.firstIndex(of: camera.id)
                Toggle(isOn: Binding(
                    get: { position != nil },
                    set: { wanted in toggle(camera, on: wanted) })) {
                    HStack(spacing: 8) {
                        // The order is the whole point, so it is a number
                        // rather than a checkmark: "which one do I start on"
                        // is the question a teacher actually has.
                        Text(position.map { "\($0 + 1)" } ?? "\u{2013}")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(position == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.text))
                            .frame(width: 14, alignment: .trailing)
                        Text(camera.name)
                        if coordinator.cameraDirector.liveCameraName == camera.name {
                            Text("LIVE")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Brand.fill, in: Capsule())
                        }
                        Spacer(minLength: 8)
                        // Aiming the second camera is the setup task, and the
                        // angle below reports whichever camera OBS is on. So
                        // there has to be a way to put it on this one.
                        if !coordinator.virtualCamActive {
                            Button(aiming == camera.id ? "Looking\u{2026}" : "Aim this one") {
                                aiming = camera.id
                                coordinator.aimCamera(uid: camera.id)
                            }
                            .controlSize(.small)
                            .disabled(aiming == camera.id)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            Button("Refresh the list") { cameras = LocalDeviceResolver.availableCameras() }
                .controlSize(.small)
        }
    }

    /// Ticking a camera appends it, so the order follows the order they were
    /// chosen in. That makes "the first one" something the teacher decided
    /// rather than something the device enumeration decided for them.
    private var aimingName: String? {
        aiming.flatMap { uid in cameras.first { $0.id == uid }?.name }
    }

    /// The live reading. During a class it is the director's, because the
    /// director owns the cameras then; otherwise it is the probe's.
    private var sight: CameraSight {
        coordinator.virtualCamActive ? coordinator.cameraDirector.sight : coordinator.cameraProbe.sight
    }

    private func toggle(_ camera: LocalDeviceResolver.Camera, on: Bool) {
        var uids = coordinator.cameraDirectorSettings.cameraUIDs
        if on {
            guard !uids.contains(camera.id) else { return }
            uids.append(camera.id)
        } else {
            uids.removeAll { $0 == camera.id }
        }
        coordinator.cameraDirectorSettings.cameraUIDs = uids
    }

    // MARK: How patient it is

    private var dwell: some View {
        HStack(spacing: 10) {
            Text("Cut after").font(.callout)
            Slider(value: settings.dwellSeconds, in: 0.5...6, step: 0.5)
                .frame(width: 180)
            Text(String(format: "%.1fs", coordinator.cameraDirectorSettings.dwellSeconds))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .frame(width: 42, alignment: .leading)
            Text("facing another camera")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: What the class sees

    /// Every camera is already open, so a cut has no hitch in it either way;
    /// this is only taste. Applies live, from the next switch.
    private var transition: some View {
        Picker(selection: settings.transition) {
            ForEach(CameraTransition.allCases) { style in
                Text(style.label).tag(style)
            }
        } label: {
            SettingLabel(title: "When it switches",
                         subtitle: "A cut is instant. A crossfade dissolves over half a second.")
        }
        .pickerStyle(.segmented)
    }

    // MARK: Proof that it is working

    /// The number that makes this setup-able.
    ///
    /// Aim the camera, read the angle, aim again. Below the threshold it is
    /// looking at you; above it, this camera has lost you, and another one
    /// that has you face-on would take over. Without this a
    /// teacher is guessing, and the first thing they would do is guess wrong
    /// and decide the feature is broken.
    private var readout: some View {
        let threshold = coordinator.cameraDirectorSettings.awayDegrees
        let degrees = sight.degrees
        let here = (degrees ?? .infinity) <= threshold
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(degrees.map { "\(Int($0.rounded()))\u{00B0}" } ?? "\u{2014}")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(here ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary))
                    .frame(width: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            // What the switch is decided on: every camera's angle, side by
            // side. The single number above is the live camera alone, which
            // cannot say why the shot moved - the comparison can. Lower wins,
            // once it is clearly lower for the whole delay.
            if coordinator.virtualCamActive, coordinator.cameraDirector.isRunning {
                comparison
            }
            // The same countdown the self view shows, for setting the dwell
            // by feel: drag the slider, turn, watch how long it takes.
            if coordinator.virtualCamActive, let pending = coordinator.cameraDirector.pendingSwitch {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: pending.progress)
                        .progressViewStyle(.linear)
                        .tint(Brand.green)
                        .animation(.linear(duration: CameraDirector.readingSeconds), value: pending.progress)
                    Text("Switching to \(pending.cameraName)\u{2026}")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if coordinator.virtualCamActive, coordinator.cameraDirector.cuts > 0 {
                Text("\(coordinator.cameraDirector.cuts) cut\(coordinator.cameraDirector.cuts == 1 ? "" : "s") this session.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var comparison: some View {
        let director = coordinator.cameraDirector
        let names = director.cameraNamesInOrder
        let angles = director.angles
        let best = angles.enumerated()
            .compactMap { index, angle in angle.map { (index, $0) } }
            .min { $0.1 < $1.1 }?.0
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                let angle = angles.indices.contains(index) ? angles[index] : nil
                HStack(spacing: 8) {
                    Text(angle.map { "\(Int($0.rounded()))\u{00B0}" } ?? "\u{2014}")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(index == best ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary))
                        .frame(width: 40, alignment: .leading)
                    Text(name).font(.caption).lineLimit(1)
                    if index == director.liveSlot {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Brand.fill, in: Capsule())
                    }
                    Spacer()
                }
            }
            Text("Lower is more head-on. The class gets whichever camera is clearly lower for the whole delay.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line per state, and never the wrong one.
    ///
    /// The first version printed "No face in this camera right now" whenever
    /// the angle was missing - including when nothing was looking at all,
    /// which is what a reader saw while sitting in front of their own camera.
    /// Every branch here is a different thing to DO about it.
    private var headline: String {
        switch sight {
        case .idle:
            return aiming == nil
                ? "Press \u{201C}Aim this one\u{201D} on a camera to see the angle it reads you at."
                : "Opening the camera\u{2026}"
        case .noPicture(let why):
            return why
        case .noFace:
            return "A picture, but nobody in it."
        case .noAngle:
            return "Found a face, but couldn\u{2019}t measure which way it is turned."
        case .seen(let degrees):
            return degrees <= coordinator.cameraDirectorSettings.awayDegrees
                ? "Looking at this camera."
                : "Turned away from this camera. In a class, a camera that sees you face-on would take over."
        }
    }

    private var detail: String {
        if coordinator.virtualCamActive {
            return "Measured through OBS while the class runs."
        }
        guard let aimingName else {
            return "Nothing is looking through a camera yet."
        }
        return "Looking through \(aimingName). Move it and watch this change."
    }
}

private struct LayoutSettingsTab: View {
    /// Half, two thirds, three quarters - what the fixed widths used to be.
    private static let widthPresets: [Double] = [0.5, 2.0 / 3.0, 0.75]
    @EnvironmentObject private var coordinator: CoordinatorController
    @FocusState private var focus: LayoutSettingsFocus?
    @State private var apps: [AppInfo] = []
    @State private var displays: [DisplayInfo] = DisplayResolver.connectedDisplays()
    @State private var hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission

    // AXIsProcessTrusted() has no change notification, so poll it while
    // the tab is visible - the warning below disappears on its own once
    // the user flips the switch in System Settings.
    private let permissionTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Picker("Main app", selection: $coordinator.mainAppBundleID) {
                ForEach(apps) { app in
                    HStack(spacing: 6) {
                        if let icon = AppCatalog.icon(forBundleID: app.bundleID) {
                            Image(nsImage: sized(icon))
                        }
                        Text(app.name)
                    }
                    .tag(app.bundleID)
                }
            }

            if AppCatalog.isBrowser(coordinator.mainAppBundleID) {
                // .roundedBorder, not the Form default borderless: the
                // borderless field rendered as an apparently-dead empty
                // row (macOS hides the prompt until focus), so nothing
                // signalled "type a URL here" (design-review F2).
                TextField("Open website", text: $coordinator.mainAppURL, prompt: Text("e.g. docs.google.com"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .websiteURL)
            }

            if AppCatalog.isBuiltInBrowser(coordinator.mainAppBundleID) {
                Text("Greenroom\u{2019}s own browser: tabs, find in page, local history, no permissions to grant. Pick Chrome above if you need extensions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: $coordinator.browserRestoresTabs) {
                    SettingLabel(title: "Reopen last session\u{2019}s tabs on Start",
                                 subtitle: "Yesterday\u{2019}s tabs come back beside the website above.")
                }
                Toggle(isOn: $coordinator.browserSearchSuggestions) {
                    SettingLabel(title: "Suggest searches as you type",
                                 subtitle: "Sends what you type to Google for completions. Off: history only, nothing leaves until Return.")
                }
                Toggle(isOn: $coordinator.browserClosesOnStop) {
                    SettingLabel(title: "Close the browser window when the session ends",
                                 subtitle: "Tabs are kept for the next Start.")
                }
            } else if AppCatalog.isBrowser(coordinator.mainAppBundleID) {
                // The same switch for an outside browser, which Greenroom
                // can close only because it made that window itself.
                Toggle(isOn: $coordinator.browserClosesOnStop) {
                    SettingLabel(title: "Close the window Start opened when the session ends",
                                 subtitle: "Only that window. Your other \(AppCatalog.displayName(forBundleID: coordinator.mainAppBundleID) ?? "browser") windows and tabs stay open. Works with Chrome and browsers built like it (Ulaa, Edge, Brave).")
                }
            }

            if needsAccessibility && !hasAccessibilityPermission {
                accessibilityWarning
            }

            Section {
                Picker("Main pane side", selection: $coordinator.workspaceLayout.mainOnLeft) {
                    Text("Left").tag(true)
                    Text("Right").tag(false)
                }
                .pickerStyle(.segmented)

                // Presets AND the drag, not one instead of the other. The fixed
                // widths were replaced by the drag handles in August, which made
                // any width possible and the three common ones fiddly: getting
                // exactly half by hand is a hunt for a pixel. A width the handles
                // left somewhere else simply has no segment lit.
                Picker("Main pane width", selection: Binding(
                    get: { Self.widthPresets.first { abs($0 - coordinator.workspaceLayout.clampedMainFraction) < 0.005 } ?? -1 },
                    set: { fraction in
                        withAnimation(.snappy(duration: 0.25)) {
                            coordinator.workspaceLayout.mainFraction = fraction
                        }
                    })) {
                    Text("\u{00BD}").tag(0.5)
                    Text("\u{2154}").tag(2.0 / 3.0)
                    Text("\u{00BE}").tag(0.75)
                }
                .pickerStyle(.segmented)

                LayoutSchematicView(layout: $coordinator.workspaceLayout,
                                    appName: coordinator.mainAppDisplayName,
                                    appIcon: AppCatalog.icon(forBundleID: coordinator.mainAppBundleID))
                    .frame(height: 140)
                    .padding(.vertical, 4)

                Text("Pick a width or drag the handles to size the panes. A live session re-tiles as you change it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Side column") {
                Toggle("Zoom meeting tile", isOn: $coordinator.workspaceLayout.sideShowsZoomTile)
                Toggle("Chat window", isOn: $coordinator.workspaceLayout.sideShowsChat)
                // Tile-vs-chat balance is set by dragging the handle in the
                // preview above - the old slider duplicated it.
            }

            Section("Meeting view") {
                Toggle(isOn: $coordinator.hideSelfView) {
                    SettingLabel(title: "Hide my own video tile",
                                 subtitle: "Only changes what you see; the class still gets your video.")
                }
                Toggle(isOn: $coordinator.speakerTileShortcutEnabled) {
                    SettingLabel(title: "Quick-hide mode",
                                 subtitle: "Sessions start with the speaker hidden and the chat full height; \u{2325}\u{2318}Z shows it.")
                }
            }

            Section("Privacy") {
                Toggle(isOn: $coordinator.analyticsEnabled) {
                    SettingLabel(title: "Send anonymous usage analytics",
                                 subtitle: "Counts and timings only. Never names, meeting IDs, addresses or chat.")
                }
            }

            Section("Second display") {
                Toggle(isOn: $coordinator.peopleViewOnStart) {
                    SettingLabel(title: "Show the participant view on another display",
                                 subtitle: coordinator.customUIMode
                                     ? "Every student and the host controls, full-screen on your reference monitor."
                                     : "Zoom\u{2019}s participant grid, full-screen on your reference monitor.")
                }

                // Greyed out rather than hidden while the view is off, like the
                // rest of Settings. The main-display option stays hidden with
                // Zoom's own grid, because there it does not exist at all.
                if coordinator.customUIMode {
                    Toggle(isOn: $coordinator.participantPanelOnMainDisplay) {
                        SettingLabel(title: "Allow it on this screen when no second display is connected",
                                     subtitle: "It is large and covers the workspace; for trying the panel without a second monitor.")
                    }
                    .disabled(!coordinator.peopleViewOnStart)
                }

                Group {
                    Picker("Participant-view display", selection: $coordinator.peopleViewDisplayUUID) {
                        Text("Automatic (a non-main display)").tag("")
                        ForEach(displays) { display in
                            Text(display.label).tag(display.id)
                        }
                        // Keep a saved-but-disconnected choice visible/valid.
                        if !coordinator.peopleViewDisplayUUID.isEmpty,
                           !displays.contains(where: { $0.id == coordinator.peopleViewDisplayUUID }) {
                            Text("Saved display (not connected)").tag(coordinator.peopleViewDisplayUUID)
                        }
                    }

                    Text(displayHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(!coordinator.peopleViewOnStart)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displays = DisplayResolver.connectedDisplays()
            }

            Toggle(isOn: $coordinator.mainAppOnStart) {
                SettingLabel(title: "Open the main app automatically on Start",
                             subtitle: "The Zoom tile and chat take whatever the main pane leaves free.")
            }
        }
        .formStyle(.grouped)
        // Nothing focused when the tab opens. Without this the website field
        // claimed focus immediately and could not be escaped, because macOS Tab
        // cycles text fields and this tab has only one.
        .defaultFocus($focus, nil)
        // Escape always releases it, which is the habit people already have and
        // the only way out when Tab has nowhere to go.
        .onExitCommand { focus = nil }
        .onAppear {
            apps = pickerApps()
            displays = DisplayResolver.connectedDisplays()
            focus = nil
        }
        .onReceive(permissionTick) { _ in
            hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission
        }
    }

    /// Caption under the participant-view display picker, adapting to how
    /// many displays are actually connected.
    private var displayHelp: String {
        if displays.count <= 1 {
            return "Only your main display is connected right now \u{2014} plug in your reference display and it will appear here. Mirrored displays show as their main and aren't listed separately, so pick your separate, extended monitor."
        }
        return "Pick your reference monitor. Mirrored displays (e.g. a class projector matching your main screen) show as their main and aren't listed separately \u{2014} choose the separate, extended display. \u{201C}Automatic\u{201D} uses the first non-main display."
    }

    /// Browsers are driven through the Chromium AppleScript dictionary
    /// (per-app Automation permission, prompted on first use) - only
    /// non-browser apps need the system-wide Accessibility grant to be
    /// moved. (A non-Chromium browser would fall back to Accessibility
    /// too, but that's rare enough to keep this warning simple.)
    private var needsAccessibility: Bool {
        !AppCatalog.isBrowser(coordinator.mainAppBundleID)
    }

    /// Without this, picking an ungranted app just silently fails to move
    /// its window at Start - say so up front, with a way to fix it.
    private var accessibilityWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text("Greenroom can't move \(coordinator.mainAppDisplayName)'s window yet.")
                    .font(.callout.weight(.medium))
                Text("Non-browser apps are positioned with the Accessibility API. Allow Greenroom under System Settings \u{2192} Privacy & Security \u{2192} Accessibility \u{2014} until then, \(coordinator.mainAppDisplayName) will open but stay wherever it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings\u{2026}") {
                AppWindowManager.promptForAccessibilityPermission()
                AppWindowManager.openAccessibilitySettings()
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Installed + running apps, with the saved choice force-included so
    /// the picker never shows blank if that app has since been removed.
    private func pickerApps() -> [AppInfo] {
        var list = AppCatalog.installedAndRunning()
        if !list.contains(where: { $0.bundleID == coordinator.mainAppBundleID }) {
            list.insert(AppInfo(bundleID: coordinator.mainAppBundleID,
                                name: AppCatalog.displayName(forBundleID: coordinator.mainAppBundleID) ?? coordinator.mainAppBundleID,
                                url: nil),
                        at: 0)
        }
        return list
    }

    /// NSWorkspace icons come at 32pt+; menu rows want 16.
    private func sized(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// A miniature live preview of the three panes: the main app's slice, and
/// the side column with the Zoom tile stacked over the chat - everything
/// proportioned exactly as the real layout will be, updating as the
/// controls above change.
/// What the class sees behind the webcam: a whole display, one app or one
/// window. Its own view because the window list has state of its own and
/// refreshes on its own schedule.
struct ShareTargetSettings: View {
    let displays: [DisplayInfo]
    /// Called after any change, so the live picture can rebuild for it.
    var onChange: () -> Void = {}
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var apps: [(bundleID: String, name: String)] = []
    @State private var windows: [ShareTarget.Window] = []
    @State private var canSeeTitles = CGPreflightScreenCaptureAccess()

    /// The kind (screen, app, window) is picked with the tiles on the
    /// Webcam page; this is the "which one" that follows.
    var body: some View {
        Group {
            switch coordinator.shareTarget.kind {
            case .display:
                displayPicker(title: "Screen")
                    .help("If this screen is unplugged at Start, the main display is shared instead.")
            case .app:
                appPicker
                    .help("Only this app\u{2019}s windows are shown. Everything else on that screen stays private.")
                displayPicker(title: "On screen")
            case .window:
                windowPicker
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: coordinator.shareTarget) { _ in onChange() }
        .onChange(of: coordinator.shareTarget.kind) { _ in refresh() }
        .onChange(of: coordinator.screenCaptureDisplayUUID) { _ in onChange() }
    }

    private func displayPicker(title: String) -> some View {
        Picker(title, selection: $coordinator.screenCaptureDisplayUUID) {
            Text("Automatic (your main display)").tag("")
            ForEach(displays) { display in
                Text(display.label).tag(display.id)
            }
            // Keep a saved-but-disconnected choice visible and valid,
            // so unplugging a monitor does not silently reset it.
            if !coordinator.screenCaptureDisplayUUID.isEmpty,
               !displays.contains(where: { $0.id == coordinator.screenCaptureDisplayUUID }) {
                Text("Saved display (not connected)").tag(coordinator.screenCaptureDisplayUUID)
            }
        }
    }

    private var appPicker: some View {
        Picker("App", selection: Binding(
            get: { coordinator.shareTarget.appBundleID },
            set: { id in
                coordinator.shareTarget.appBundleID = id
                coordinator.shareTarget.appName = apps.first { $0.bundleID == id }?.name ?? ""
                coordinator.shareTarget.windowTitle = ""
            })) {
            Text("Choose an app").tag("")
            ForEach(apps, id: \.bundleID) { app in
                Text(app.name).tag(app.bundleID)
            }
            // A saved app that is not open stays selectable, for the same
            // reason as a disconnected display.
            let saved = coordinator.shareTarget.appBundleID
            if !saved.isEmpty, !apps.contains(where: { $0.bundleID == saved }) {
                Text("\(coordinator.shareTarget.displayName) (not open)").tag(saved)
            }
        }
    }

    @ViewBuilder
    private var windowPicker: some View {
        let target = coordinator.shareTarget
        let selected = target.appBundleID.isEmpty ? "" : ShareTarget.windowKey(bundleID: target.appBundleID,
                                                                                 title: target.windowTitle)
        HStack {
            Picker("Window", selection: Binding(
                get: { selected },
                set: { key in
                    guard let window = windows.first(where: { $0.key == key }) else { return }
                    coordinator.shareTarget.appBundleID = window.bundleID
                    coordinator.shareTarget.appName = window.appName
                    coordinator.shareTarget.windowTitle = window.title
                })) {
                Text("Choose a window").tag("")
                ForEach(windows) { window in
                    Text(window.title.isEmpty ? window.appName : "\(window.appName) \u{2013} \(window.title)")
                        .tag(window.key)
                }
                if !selected.isEmpty, !windows.contains(where: { $0.key == selected }) {
                    // Not listed under that title, but the app may still be
                    // open - and then Start shares its front window.
                    let open = windows.contains { $0.bundleID == target.appBundleID }
                    let name = target.windowTitle.isEmpty
                        ? target.displayName
                        : "\(target.displayName) \u{2013} \(target.windowTitle)"
                    Text(open ? "\(name) (front window)" : "\(name) (not open)")
                        .tag(selected)
                }
            }
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh the window list")
                .accessibilityLabel("Refresh the window list")
        }
        if !canSeeTitles {
            HStack {
                Text("Windows are listed by app until Greenroom may read their titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Allow\u{2026}") {
                    ScreenroomScreenEngine.askForPermission()
                    canSeeTitles = CGPreflightScreenCaptureAccess()
                    refresh()
                }
            }
        }
    }

    /// Without titles every window of an app has the same key, so only the
    /// first (the front one) is listed; picking it shares the front window,
    /// which is what an untitled choice means at Start too.
    private func refresh() {
        apps = ShareTarget.runningApps()
        var seen = Set<String>()
        windows = ShareTarget.windows().filter { seen.insert($0.key).inserted }
        canSeeTitles = CGPreflightScreenCaptureAccess()
    }
}

private struct LayoutSchematicView: View {
    @Binding var layout: WorkspaceLayout
    let appName: String
    let appIcon: NSImage?

    private let spacing: CGFloat = 4
    @State private var draggingSplit = false
    @State private var draggingSlot = false

    var body: some View {
        GeometryReader { geo in
            let fraction = layout.clampedMainFraction
            let mainWidth = (geo.size.width - spacing) * fraction
            let sideWidth = geo.size.width - spacing - mainWidth
            let dividerX = layout.mainOnLeft ? mainWidth + spacing / 2 : sideWidth + spacing / 2
            let sideCenterX = layout.mainOnLeft ? mainWidth + spacing + sideWidth / 2 : sideWidth / 2

            ZStack(alignment: .topLeading) {
                HStack(spacing: spacing) {
                    if layout.mainOnLeft {
                        mainPane.frame(width: mainWidth)
                        sideColumn(height: geo.size.height).frame(width: sideWidth)
                    } else {
                        sideColumn(height: geo.size.height).frame(width: sideWidth)
                        mainPane.frame(width: mainWidth)
                    }
                }

                // Vertical divider: drag to resize main pane vs side column.
                grabber(width: 6, height: 44, active: draggingSplit)
                    .frame(width: 18, height: geo.size.height)
                    .contentShape(Rectangle())
                    .position(x: dividerX, y: geo.size.height / 2)
                    // NSCursor.set() rather than push/pop: the push/pop
                    // stack desynced across enter/exit events and left the
                    // wrong cursor orientation showing (reported live).
                    // Re-set every drag tick too - AppKit resets the cursor
                    // once the pointer leaves the hover area mid-drag.
                    .onHover { inside in
                        (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("schematic"))
                            .onChanged { value in
                                draggingSplit = true
                                NSCursor.resizeLeftRight.set()
                                let raw = Double(value.location.x / geo.size.width)
                                let fraction = layout.mainOnLeft ? raw : 1 - raw
                                layout.mainFraction = min(max(fraction, WorkspaceLayout.minMainFraction),
                                                          WorkspaceLayout.maxMainFraction)
                            }
                            .onEnded { _ in
                                draggingSplit = false
                                NSCursor.arrow.set()
                            }
                    )
                    // Keyboard/VoiceOver path for the mouse-only drag
                    // (Codex design audit #4).
                    .accessibilityElement()
                    .accessibilityLabel("Main pane width")
                    .accessibilityValue("\(Int((layout.clampedMainFraction * 100).rounded())) percent")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            layout.mainFraction = min(layout.clampedMainFraction + 0.05, WorkspaceLayout.maxMainFraction)
                        case .decrement:
                            layout.mainFraction = max(layout.clampedMainFraction - 0.05, WorkspaceLayout.minMainFraction)
                        @unknown default: break
                        }
                    }

                // Horizontal divider: drag to balance Zoom tile vs chat.
                if layout.sideShowsZoomTile && layout.sideShowsChat {
                    let slotY = (geo.size.height - spacing) * layout.effectiveZoomSlotRatio + spacing / 2
                    grabber(width: 44, height: 6, active: draggingSlot)
                        .frame(width: max(sideWidth - 16, 24), height: 18)
                        .contentShape(Rectangle())
                        .position(x: sideCenterX, y: slotY)
                        .onHover { inside in
                            (inside ? NSCursor.resizeUpDown : NSCursor.arrow).set()
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("schematic"))
                                .onChanged { value in
                                    draggingSlot = true
                                    NSCursor.resizeUpDown.set()
                                    let ratio = Double(value.location.y / geo.size.height)
                                    layout.zoomSlotRatio = min(max(ratio, 0.15), 0.85)
                                }
                                .onEnded { _ in
                                    draggingSlot = false
                                    NSCursor.arrow.set()
                                }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Zoom tile height")
                        .accessibilityValue("\(Int((layout.effectiveZoomSlotRatio * 100).rounded())) percent")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: layout.zoomSlotRatio = min(layout.zoomSlotRatio + 0.05, 0.85)
                            case .decrement: layout.zoomSlotRatio = max(layout.zoomSlotRatio - 0.05, 0.15)
                            @unknown default: break
                            }
                        }
                }
            }
            .coordinateSpace(name: "schematic")
        }
        // Snappy preset-style animation for external changes only - never
        // mid-drag, where it would lag the pointer.
        .animation(draggingSplit || draggingSlot ? nil : .snappy(duration: 0.25), value: layout)
    }

    /// Deliberately assertive, not decorative: the handles ARE the width
    /// controls now (the preset picker and slider are gone), so they must
    /// read as grabbable at a glance (design-review F5).
    private func grabber(width: CGFloat, height: CGFloat, active: Bool) -> some View {
        Capsule()
            .fill(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.85)))
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.35), radius: active ? 3 : 1.5)
    }

    private var mainPane: some View {
        pane(tint: .blue) {
            VStack(spacing: 4) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
                Text(appName)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                if draggingSplit {
                    Text("\(Int((layout.clampedMainFraction * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sideColumn(height: CGFloat) -> some View {
        VStack(spacing: spacing) {
            if layout.sideShowsZoomTile {
                pane(tint: .indigo) {
                    VStack(spacing: 2) {
                        Label("Zoom", systemImage: "video.fill")
                            .font(.caption2.weight(.medium))
                        if draggingSlot {
                            Text("\(Int((layout.effectiveZoomSlotRatio * 100).rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: layout.sideShowsChat
                       ? (height - spacing) * layout.effectiveZoomSlotRatio
                       : nil)
            }
            if layout.sideShowsChat {
                pane(tint: .teal) {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.caption2.weight(.medium))
                }
            }
            if !layout.sideShowsZoomTile && !layout.sideShowsChat {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .overlay(Text("Free").font(.caption2).foregroundStyle(.tertiary))
            }
        }
    }

    private func pane<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(tint.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 1)
            )
            .overlay(content().foregroundStyle(tint))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Both Zoom Marketplace apps on one page.
///
/// They were two tabs, Meeting Chat and Start Meeting, named after what each
/// credential unlocks rather than after what it is. Both are Zoom tokens, both
/// come from the same account, and the second tab's own footer had to say "on
/// the same Zoom account as Meeting Chat" - a sentence that exists only
/// because the two were apart. Setting Greenroom up means pasting six values
/// from one place, and it should be one page.
///
/// Two sections, kept separate, because they really are two different
/// Marketplace apps and pretending otherwise would be the opposite mistake:
/// Zoom's headless token grant is exclusive to the Server-to-Server type and
/// the Meeting SDK embed is exclusive to the General App type, so nobody can
/// consolidate them into one set of credentials. Vendor/README.md records the
/// attempt.
private struct ZoomSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $coordinator.sdkClientID)
                SecureField("Client Secret", text: $coordinator.sdkClientSecret)
            } header: { Text("Meeting SDK app") } footer: {
                Text("Powers the built-in meeting client and the chat window. Zoom Marketplace \u{2192} General App \u{2192} Features \u{2192} Embed \u{2192} Meeting SDK. Works only in meetings hosted under this Zoom account.")
            }

            Section {
                TextField("Account ID", text: $coordinator.s2sAccountID)
                TextField("Client ID", text: $coordinator.s2sClientID)
                SecureField("Client Secret", text: $coordinator.s2sClientSecret)
            } header: { Text("Server-to-Server OAuth app") } footer: {
                Text("Powers New Meeting and the scheduled list. A second Marketplace app on the same Zoom account. Scopes: meeting:write:meeting:admin, meeting:read:list_meetings:admin, meeting:read:meeting:admin, user:read:token:admin, meeting:update:status:admin. The setup guide (?) walks through it and tests the result.")
            }

            Section {
                Toggle(isOn: $coordinator.useBuiltInClient) {
                    SettingLabel(title: "Use built-in meeting client",
                                 subtitle: "The whole meeting runs inside Greenroom. Off: the Zoom app, with a hidden chat participant.")
                }
                TextField("Your display name", text: $coordinator.userDisplayName)

                Toggle(isOn: $coordinator.customUIMode) {
                    SettingLabel(title: "Custom meeting UI (experimental)",
                                 subtitle: "Greenroom draws the speaker and the participant panel itself. Takes effect after a relaunch.")
                }
                if coordinator.customUIModeNeedsRelaunch {
                    Label("Not active yet \u{2014} quit and reopen Greenroom.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: { Text("In the meeting") } footer: {
                Text("How the meeting appears once it starts. Nothing here needs a credential.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Uploading recordings to YouTube - the one feature that sends class
/// content off the Mac, so it opens on "Do nothing" and every line of copy
/// says where the file goes.
private struct YouTubeSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var connecting = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $coordinator.youtubeUploadMode) {
                    ForEach(YouTubeUploadMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    SettingLabel(title: "After a recording",
                                 subtitle: "\u{201C}Ask\u{201D} shows one Upload / Not now card. The file stays in Documents/Greenroom either way.")
                }
                Picker(selection: $coordinator.youtubePrivacy) {
                    Text("Unlisted").tag("unlisted")
                    Text("Private").tag("private")
                } label: {
                    SettingLabel(title: "Visibility",
                                 subtitle: coordinator.youtubePrivacy == "private" ? "Only the channel\u{2019}s account can watch." : "Anyone with the link can watch.")
                }
            } header: { Text("Upload") } footer: {
                Text("The one place class content leaves the Mac: the recording, over HTTPS, to the connected channel. Progress is in the menu bar; the link is copied when it finishes.")
            }

            Section {
                TextField("Client ID", text: $coordinator.youtubeClientID)
                SecureField("Client Secret", text: $coordinator.youtubeClientSecret)
                LabeledContent {
                    HStack(spacing: 12) {
                        if coordinator.youtubeConnected {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.green)
                            Button("Disconnect") { Task { await coordinator.disconnectYouTube() } }
                        } else {
                            Button(connecting ? "Waiting for Google\u{2026}" : "Connect\u{2026}") {
                                connecting = true
                                Task {
                                    await coordinator.connectYouTube()
                                    connecting = false
                                }
                            }
                            .disabled(connecting || coordinator.youtubeClientID.isEmpty || coordinator.youtubeClientSecret.isEmpty)
                        }
                        if coordinator.isUploadingToYouTube {
                            ProgressView().controlSize(.small)
                        }
                    }
                } label: {
                    SettingLabel(title: "Google account",
                                 subtitle: coordinator.youtubeStatus.isEmpty
                                     ? "Signs in once in your browser. Greenroom can upload and edit your own videos, nothing else."
                                     : coordinator.youtubeStatus)
                }
            } header: { Text("Account") } footer: {
                Text("From a Google Cloud OAuth client of type \u{201C}Desktop app\u{201D} with the YouTube Data API v3 enabled. The setup guide (? on the main window) has the clicks; while the Google project is in Testing, the sign-in lasts seven days.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Export/import all of the above as one JSON file - the whole point is
/// setting up a teammate's machine without them ever touching the Zoom
/// Marketplace: send them the app + this file, they import it, done.
private struct TransferSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var statusMessage = ""
    @State private var confirmingExport = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    // Confirmation before writing secrets in plaintext - the
                    // risk shouldn't live only in small caption text below
                    // (Codex design audit #6).
                    Button("Export\u{2026}") { confirmingExport = true }
                        .confirmationDialog("This file will contain your Zoom secrets in plain text.",
                                            isPresented: $confirmingExport, titleVisibility: .visible) {
                            Button("Export Plaintext File") { exportSettings() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Hand it over directly (e.g. AirDrop) and delete it after importing.")
                        }
                } label: {
                    SettingLabel(title: "Export settings", subtitle: "One file with every setting, credentials included, in plain text.")
                }
                LabeledContent {
                    Button("Import\u{2026}") { importSettings() }
                } label: {
                    SettingLabel(title: "Import settings", subtitle: "Sets up this Mac from a file a colleague exported.")
                }
            } header: { Text("Transfer") } footer: {
                Text(statusMessage.isEmpty ? "Hand the file over directly (AirDrop) and delete it once imported." : statusMessage)
            }
        }
        .formStyle(.grouped)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Greenroom Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.exportSettingsData().write(to: url, options: .atomic)
            statusMessage = "Exported to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.importSettings(from: Data(contentsOf: url))
            statusMessage = "Imported from \(url.lastPathComponent). You can delete that file now."
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
