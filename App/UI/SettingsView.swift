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

            MeetingSDKSettingsTab()
                .tabItem { Label("Meeting Chat", systemImage: "bubble.left.and.bubble.right.fill") }

            StartMeetingSettingsTab()
                .tabItem { Label("Start Meeting", systemImage: "video.badge.plus") }

            TransferSettingsTab()
                .tabItem { Label("Transfer", systemImage: "square.and.arrow.up.on.square") }
        }
        .frame(width: 540, height: 520)
        // Secrets are loaded lazily (see loadSecretsIfNeeded) - opening
        // Settings is the first moment the fields actually need them.
        .onAppear { coordinator.loadSecretsIfNeeded() }
    }
}

private struct WebcamSettingsTab: View {
    /// Bridges the coordinator's three separate published fractions to the one
    /// binding the preview wants.
    private var bubbleGeometry: Binding<WebcamShapePreview.BubbleGeometry> {
        Binding(
            get: {
                .init(widthFraction: coordinator.bubbleWidthFraction,
                      rightInset: coordinator.bubbleRightInset,
                      bottomInset: coordinator.bubbleBottomInset)
            },
            set: { updated in
                coordinator.bubbleWidthFraction = updated.widthFraction
                coordinator.bubbleRightInset = updated.rightInset
                coordinator.bubbleBottomInset = updated.bottomInset
            })
    }

    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Form {
            Picker("Bubble shape", selection: $coordinator.webcamShape) {
                ForEach(WebcamShape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            // Live preview of the real composite when OBS is warm;
            // schematic fallback otherwise. Shape changes while idle are
            // applied to the warm scene immediately, so the live picture
            // tracks the picker.
            Group {
                if let frame = coordinator.shapePreviewFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 4) {
                                Circle().fill(.green).frame(width: 6, height: 6)
                                Text("LIVE").font(.caption2.bold())
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.78), in: Capsule()) // opaque enough over any video frame
                            .foregroundStyle(.white)
                            .padding(6)
                        }
                } else {
                    WebcamShapePreview(shape: coordinator.webcamShape,
                                       geometry: bubbleGeometry,
                                       onCommit: {
                                           Task { await coordinator.applyShapeForPreview() }
                                       })
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .padding(.vertical, 6)
            .onAppear { coordinator.startShapePreview() }
            .onDisappear { coordinator.stopShapePreview() }
            .onChange(of: coordinator.webcamShape) { _ in
                Task { await coordinator.applyShapeForPreview() }
            }

            Text(shapeCaption)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Only the bubble shapes have a bubble to move. Cutout and Presenter
            // key the background out and place a full-height figure by another
            // rule, so there is nothing here to drag.
            if !coordinator.webcamShape.usesChromaKey {
                HStack {
                    Text("Drag the bubble to move it, or its corner to resize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset position") {
                        coordinator.resetBubbleLayout()
                        Task { await coordinator.applyShapeForPreview() }
                    }
                    .controlSize(.small)
                    .disabled(coordinator.bubbleIsAtDefault)
                }
            }

            Divider()

            Toggle("Start recording automatically with the meeting", isOn: $coordinator.autoRecordOnStart)

            Text("Off: record manually with the Record button or \u{2325}\u{2318}R. Either way, recordings save to Documents/Greenroom and stop safely when the session ends.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Keep OBS ready in the background", isOn: $coordinator.keepOBSWarm)

            Text("Launches OBS with Greenroom and leaves it running between sessions, so Start skips OBS's slow cold launch. OBS still quits when Greenroom quits.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var shapeCaption: String {
        switch coordinator.webcamShape {
        case .cutout:
            return "Cutout removes your background with a chroma key, so you appear as a cutout over the shared screen \u{2014} needs a real green screen behind you. Tune the key in OBS \u{2192} the webcam source \u{2192} Filters if the edges look rough."
        case .presenterLarge:
            return "The macOS Presenter Overlay (Large) look, built into the composite: the shared screen becomes a rounded panel and you stand in front of it at full height. Needs a real green screen behind you, like Cutout. Works on any Mac and needs no manual toggle each meeting."
        case .square, .circle, .roundedRectangle:
            return "Pick a shape, then start a session to apply it (Stop first if one is running)."
        }
    }
}

/// A miniature of what the virtual camera will actually send for the
/// chosen shape: the shared screen, with "you" composited the way OBS
/// will do it - bubble in the corner, keyed cutout, or the Presenter
/// panel arrangement. Mirrors the geometry in GreenroomScene. Internal
/// (not private): the onboarding's "Your setup" step reuses it.
/// The shape schematic, and for bubble shapes a draggable one.
///
/// Drag the bubble to move it, drag its corner handle to resize. The numbers
/// behind it - widthFraction, rightInset, bottomInset - are the same three
/// GreenroomScene has always sent to OBS, so what is dragged here is literally
/// the scene transform rather than a picture of one.
///
/// Only the bubble shapes are adjustable. Cutout and Presenter key the background
/// out and place a full-height figure by a different rule, so there is no bubble
/// to move; the schematic stays a preview for those.
struct WebcamShapePreview: View {
    let shape: WebcamShape
    /// Nil for a read-only schematic, as used by the onboarding screen.
    var geometry: Binding<BubbleGeometry>?
    /// Called when a drag finishes, so OBS is asked to re-place once rather
    /// than on every frame of the gesture.
    var onCommit: (() -> Void)?

    /// The three fractions, bundled so the view takes one binding.
    struct BubbleGeometry: Equatable {
        var widthFraction: Double
        var rightInset: Double
        var bottomInset: Double
    }

    @State private var dragStart: BubbleGeometry?

    private static let personGreen = Color(red: 0.373, green: 0.659, blue: 0.235)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // The canvas - only visible around the Presenter panel.
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.82))

                if shape.isPresenterStyle {
                    screenPanel(cornerRadius: 7)
                        .frame(width: w * 0.78, height: h * 0.78)
                        .position(x: w - w * 0.025 - (w * 0.78) / 2, y: h / 2)
                    person(height: h * 1.1)
                        .position(x: w * 0.24, y: h - (h * 1.1) / 2 + h * 0.04)
                } else {
                    screenPanel(cornerRadius: 8)
                        .frame(width: w, height: h)
                        .position(x: w / 2, y: h / 2)
                    if shape == .cutout {
                        // Flush with the bottom edge, like the real scene -
                        // the person rises from the screen edge, no float.
                        person(height: h * 0.62)
                            .position(x: w - w * 0.16, y: h - (h * 0.62) / 2)
                    } else {
                        // Sized off the WIDTH, matching positionBubble in
                        // GreenroomScene - the bubble is a square whose side is a
                        // fraction of canvas width, not height.
                        let live = geometry?.wrappedValue
                            ?? BubbleGeometry(widthFraction: 0.24, rightInset: 0.045, bottomInset: 0.06)
                        let side = w * live.widthFraction
                        let centreX = w - w * live.rightInset - side / 2
                        let centreY = h - h * live.bottomInset - side / 2
                        bubble(size: side)
                            .position(x: centreX, y: centreY)
                            .overlay {
                                if geometry != nil {
                                    resizeHandle(side: side)
                                        .position(x: centreX - side / 2 + 3,
                                                  y: centreY - side / 2 + 3)
                                }
                            }
                            .gesture(geometry == nil ? nil : moveGesture(canvas: geo.size, side: side))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .animation(.snappy(duration: 0.25), value: shape)
    }

    /// Drag anywhere on the bubble to move it.
    ///
    /// Insets are measured from the right and bottom edges, so a drag right
    /// DECREASES rightInset. Working in the scene's own coordinates rather than
    /// converting at the end keeps this and OBS in agreement.
    private func moveGesture(canvas: CGSize, side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let geometry else { return }
                let start = dragStart ?? geometry.wrappedValue
                if dragStart == nil { dragStart = start }
                geometry.wrappedValue = BubbleGeometry(
                    widthFraction: start.widthFraction,
                    rightInset: clamp(start.rightInset - value.translation.width / canvas.width,
                                      upper: 1 - start.widthFraction),
                    bottomInset: clamp(start.bottomInset - value.translation.height / canvas.height,
                                       upper: 1 - start.widthFraction))
            }
            .onEnded { _ in
                dragStart = nil
                onCommit?()
            }
    }

    /// A corner grip, at the top-left of the bubble: dragging it away from the
    /// bottom-right corner grows the bubble, which keeps that corner - the one
    /// pinned by the insets - still.
    private func resizeHandle(side: CGFloat) -> some View {
        Circle()
            .fill(Self.personGreen)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
            .frame(width: 14, height: 14)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard let geometry else { return }
                        let start = dragStart ?? geometry.wrappedValue
                        if dragStart == nil { dragStart = start }
                        // Up-and-left is bigger, so both deltas are negated.
                        let delta = (-value.translation.width - value.translation.height) / 2
                        let widthDelta = delta / 200
                        geometry.wrappedValue = BubbleGeometry(
                            widthFraction: clamp(start.widthFraction + widthDelta,
                                                 lower: 0.08, upper: 0.6),
                            rightInset: start.rightInset,
                            bottomInset: start.bottomInset)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onCommit?()
                    }
            )
            .help("Drag to resize")
    }

    private func clamp(_ value: Double, lower: Double = 0, upper: Double) -> Double {
        min(max(value, lower), max(lower, upper))
    }

    /// The shared screen, mocked as a document.
    private func screenPanel(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                VStack(alignment: .leading, spacing: 7) {
                    bar(width: 0.42, emphasis: true)
                    bar(width: 0.9)
                    bar(width: 0.84)
                    bar(width: 0.88)
                    bar(width: 0.58)
                    bar(width: 0.86)
                }
                .padding(14),
                alignment: .topLeading
            )
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator, lineWidth: 1))
    }

    private func bar(width fraction: CGFloat, emphasis: Bool = false) -> some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(emphasis ? Color.secondary.opacity(0.55) : Color.secondary.opacity(0.22))
                .frame(width: geo.size.width * fraction)
        }
        .frame(height: 7)
    }

    /// "You" - keyed, no background.
    private func person(height: CGFloat) -> some View {
        Image(systemName: "person.fill")
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(Self.personGreen.gradient)
    }

    /// "You" in a corner bubble - the webcam frame, background included.
    private func bubble(size: CGFloat) -> some View {
        let clip: AnyShape
        switch shape {
        case .circle: clip = AnyShape(Circle())
        case .roundedRectangle: clip = AnyShape(RoundedRectangle(cornerRadius: size * 0.18))
        default: clip = AnyShape(Rectangle())
        }
        return ZStack {
            clip.fill(Self.personGreen.opacity(0.22))
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .frame(height: size * 0.62)
                .foregroundStyle(Self.personGreen.gradient)
                .offset(y: size * 0.12)
        }
        .frame(width: size, height: size)
        .clipShape(clip)
        .overlay(clip.stroke(Self.personGreen.opacity(0.7), lineWidth: 1.5))
    }
}

/// The generalized main-pane + side-column arrangement: pick any app for
/// the main pane, choose how much of the screen it takes, and toggle what
/// fills the leftover column - with a live schematic of the result.
/// What can hold keyboard focus in this tab.
///
/// Exists so that NOTHING does by default. The website field was the tab's only
/// text field, so SwiftUI made it the initial first responder - and macOS Tab
/// moves between text fields, of which there was exactly one, so focus could not
/// be moved off it at all. Every keystroke went into it, which is how a control
/// character ended up in a saved URL.
private enum LayoutSettingsFocus: Hashable {
    case websiteURL
}

private struct LayoutSettingsTab: View {
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

            if needsAccessibility && !hasAccessibilityPermission {
                accessibilityWarning
            }

            Section {
                Picker("Main pane side", selection: $coordinator.workspaceLayout.mainOnLeft) {
                    Text("Left").tag(true)
                    Text("Right").tag(false)
                }
                .pickerStyle(.segmented)

                LayoutSchematicView(layout: $coordinator.workspaceLayout,
                                    appName: coordinator.mainAppDisplayName,
                                    appIcon: AppCatalog.icon(forBundleID: coordinator.mainAppBundleID))
                    .frame(height: 140)
                    .padding(.vertical, 4)

                Text("Drag the handle between the panes to set the main app's width; drag the one between Zoom and Chat to balance the side column. A live session re-tiles on Snap Windows Back (\u{2325}\u{2318}S).")
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
                Toggle("Hide my own video tile (Zoom's \u{201C}Hide Self View\u{201D})", isOn: $coordinator.hideSelfView)
                Text("On: the speaker tile and participant view show only the others. Off: your tile appears among them like anyone else's. The class receives your video either way \u{2014} this only changes what you see. Applies immediately, even mid-meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Quick-hide mode: speaker tile hidden by default (\u{2325}\u{2318}Z shows it)", isOn: $coordinator.speakerTileShortcutEnabled)
                Text("On: sessions start with the speaker hidden and the chat using the full column height \u{2014} press \u{2325}\u{2318}Z to show the speaker (the chat shrinks below it), and again to hide it. Off: the normal speaker-above-chat layout stays put and the shortcut does nothing. Applies immediately, works system-wide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shared screen") {
                Picker("Screen to share", selection: $coordinator.screenCaptureDisplayUUID) {
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

                Text("This is the screen your class sees. Automatic follows your main display, which is what you want unless you teach from a second monitor. If the display you pick isn't plugged in when a session starts, Greenroom shares your main one and says so in the status log.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Toggle("Send anonymous usage analytics", isOn: $coordinator.analyticsEnabled)
                Text("Counts and timings only \u{2014} which features get used, how long sessions run, whether something failed. Never student names, meeting IDs, file paths or chat. Turning this off stops all network calls to the analytics service, including registering this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Second display") {
                Toggle("Show the participant view on another display", isOn: $coordinator.peopleViewOnStart)

                if coordinator.peopleViewOnStart, coordinator.customUIMode {
                    Toggle("Allow it on this screen when no second display is connected",
                           isOn: $coordinator.participantPanelOnMainDisplay)
                    Text("Off by default. The panel is large and meant for a display only you can see, so on a single screen it covers the tiled workspace. Turn it on to try the panel without a reference monitor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if coordinator.peopleViewOnStart, coordinator.customUIMode {
                    Text("With the custom meeting UI on, this view also carries the host controls \u{2014} mute, spotlight, admit, rename, remove. It is meant for a display only you can see. With no second display it opens as an ordinary window you can move and resize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if coordinator.peopleViewOnStart {
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
                } else {
                    Text("On Start, a full-screen view of every participant opens on another display \u{2014} your reference monitor. Your tiled workspace, and any display mirroring it (e.g. a class projector), stay on your main screen. Works with the built-in meeting client.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                displays = DisplayResolver.connectedDisplays()
            }

            Toggle("Open the main app automatically on Start", isOn: $coordinator.mainAppOnStart)

            Text("The Zoom meeting tile and chat window tile themselves into whatever space the main pane leaves free.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

private struct MeetingSDKSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        // Form centers short content vertically in whatever height the
        // TabView gives it (fixed at 520 by SettingsView) rather than
        // pinning to the top - three fields read as floating in a mostly
        // empty pane (reproduced live, /qa pass). The trailing Spacer
        // claims the leftover space instead.
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Client ID", text: $coordinator.sdkClientID)
                SecureField("Client Secret", text: $coordinator.sdkClientSecret)

                Text("From your Zoom Marketplace app (General App \u{2192} Features \u{2192} Embed \u{2192} Meeting SDK). Only works for meetings hosted under this same Zoom account - joining a meeting hosted elsewhere fails with Zoom's cross-account restriction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Custom meeting UI (experimental)", isOn: $coordinator.customUIMode)

                if coordinator.customUIModeNeedsRelaunch {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Not active yet \u{2014} quit and reopen Greenroom. Zoom fixes the meeting UI when it first starts a session, and this launch has already started one.")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Text("Renders the speaker inside a Greenroom window instead of using Zoom's own meeting windows, so there is no Zoom toolbar or info button to manage, and the participant view becomes a full control surface with mute, spotlight and the rest. Zoom fixes the meeting UI when it first starts a session, so changing this only takes effect after you quit and reopen Greenroom.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

private struct StartMeetingSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        // See MeetingSDKSettingsTab - same top-align fix for Form's
        // vertical centering of shorter-than-520pt content.
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Account ID", text: $coordinator.s2sAccountID)
                TextField("Client ID", text: $coordinator.s2sClientID)
                SecureField("Client Secret", text: $coordinator.s2sClientSecret)

                Text("A different Zoom app than Meeting Chat's - create one at marketplace.zoom.us: Build App \u{2192} Server-to-Server OAuth, then copy its Account ID/Client ID/Secret here. Add all four scopes on its Scopes page: meeting:write:meeting:admin, meeting:read:list_meetings:admin, meeting:read:meeting:admin, user:read:token:admin. The setup guide (? on the main window) walks through it and can test the result. Same Zoom account as the Meeting Chat app = hosting and chat work in every meeting this creates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Use built-in meeting client", isOn: $coordinator.useBuiltInClient)
                TextField("Your display name", text: $coordinator.userDisplayName)

                Text("On (default): New Meeting runs entirely inside Greenroom's built-in Zoom client \u{2014} one participant (you), hosting directly, chat sent as you, no separate Zoom app. Off: the classic flow \u{2014} the native Zoom app plus a hidden \u{201C}Greenroom Chat\u{201D} participant carrying the chat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
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
        // See MeetingSDKSettingsTab - same top-align fix; this tab's two
        // buttons were the most visibly stranded of the three (reproduced
        // live: a near-empty pane with buttons floating mid-height).
        VStack(alignment: .leading, spacing: 0) {
            Form {
                HStack {
                    // Confirmation before writing secrets in plaintext - the
                    // risk shouldn't live only in small caption text below
                    // (Codex design audit #6).
                    Button("Export Settings\u{2026}") { confirmingExport = true }
                        .confirmationDialog("This file will contain your Zoom secrets in plain text.",
                                            isPresented: $confirmingExport, titleVisibility: .visible) {
                            Button("Export Plaintext File") { exportSettings() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Hand it over directly (e.g. AirDrop) and delete it after importing.")
                        }
                    Button("Import Settings\u{2026}") { importSettings() }
                }

                Text("One file with every setting on this screen, Zoom credentials included \u{2014} in plaintext. Hand it over directly (e.g. AirDrop) and delete it once imported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !statusMessage.isEmpty {
                    Text(statusMessage).font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
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
