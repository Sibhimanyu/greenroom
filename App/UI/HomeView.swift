//
//  HomeView.swift
//  Greenroom
//
//  Home, "Direction A: Picture first" (DESIGN.md decisions log, 2026-11-13).
//
//  Left, a 16:9 card showing the look the class will see. Right, the few
//  things that change a start: a name (or the meeting to join), five setup
//  chips, the readiness pills, and ONE button that follows the mode. A last
//  session line sits under both. The New / Join / Record switcher lives in
//  the window toolbar (ContentView).
//
//  The card draws the look from the Webcam page's own numbers
//  (`WebcamShapePreview`), so the camera is NOT on just because Home is
//  visible. "Show live" asks for the same preview the Webcam page and the
//  Record view use (`startShapePreview`) and it is turned off again when
//  Home goes away or a start begins.
//
//  Nothing here owns logic. Each chip writes the setting the Webcam page
//  writes and calls the same `requestShapeApply`; the button calls `start()`.
//
import AVFoundation
import SwiftUI

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The status log's disclosure. Owned by ContentView, which sizes the
    /// window for it.
    @Binding var statusShown: Bool
    /// Tells ContentView whether the "Last session" line is drawn, since the
    /// window's height is measured with and without it.
    @Binding var hasFooter: Bool

    /// Height of the open log. Eight lines.
    static let statusLogHeight: CGFloat = 180
    /// The options column; its two equal tiles share it with an 8pt gap.
    static let optionsWidth: CGFloat = 380

    @State private var showLive = false
    @State private var cameras: [LocalDeviceResolver.Camera] = []
    @State private var microphones: [LocalDeviceResolver.Microphone] = []
    @State private var displays: [DisplayInfo] = []
    @State private var apps: [(bundleID: String, name: String)] = []
    @State private var windows: [ShareTarget.Window] = []
    @State private var screenAllowed = StageCompositor.screenRecordingGranted
    @State private var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var micAccess = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var lastSession: LastSession?
    @State private var pastedHint = false
    @State private var showSavePreset = false
    @State private var presetNameDraft = ""
    /// Only ever started while a session is live, when the microphone is
    /// already in use: see `micMeterLevel`.
    @StateObject private var meter = MicLevelMonitor()

    // MARK: Derived

    private var startDisabled: Bool { coordinator.startActionDisabled }
    private var isLive: Bool { coordinator.isRunning || coordinator.stageLive }
    private var mode: MeetingMode { coordinator.meetingMode }

    var body: some View {
        // The two columns share a top and a bottom: the picture card (16:9 of
        // its width) plus the ready row is as tall as the right column.
        // Extra window height is shared out above and below the block, so a
        // large window never leaves dead space under only one side.
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 32) {
                setupColumn
                    .frame(width: Self.optionsWidth)
                pictureColumn
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            if statusShown {
                statusLog.padding(.top, 12)
            }
            if let lastSession {
                footer(lastSession)
                    .padding(.top, 16)
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            coordinator.loadSecretsIfNeeded()
            refreshDevices()
            refreshPermissions()
            refreshShareLists()
            loadLastSession()
            if mode == .join { prefillFromClipboard() }
            if coordinator.stageLive { meter.start() }
        }
        .onDisappear {
            stopLive()
            meter.stop()
        }
        .onChange(of: lastSession) { _, session in hasFooter = session != nil }
        .onChange(of: coordinator.isRunning) { _, running in if running { stopLive() } }
        .onChange(of: coordinator.mainPage.isHome) { _, home in if !home { stopLive() } }
        .onChange(of: coordinator.sceneInUse) { _, inUse in if !inUse { loadLastSession() } }
        .onChange(of: coordinator.stageLive) { _, live in
            if live { meter.start() } else { meter.stop() }
        }
        .onChange(of: coordinator.meetingMode) { _, new in
            if new == .join { prefillFromClipboard() } else { pastedHint = false }
        }
        .onChange(of: coordinator.shareTarget.kind) { _, _ in refreshShareLists() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
            if coordinator.shareTarget.kind == .app || coordinator.shareTarget.kind == .window {
                refreshShareLists()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayResolver.connectedDisplays()
        }
    }

    // MARK: Left: the picture

    private var pictureColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            pictureCard
            Spacer(minLength: 12)
            readyRow
        }
    }

    /// Readiness is about the picture (camera, screen, mic, Zoom), so it sits
    /// under it.
    private var readyRow: some View {
        HStack(alignment: .center, spacing: 6) {
            ChipFlow(spacing: 6) {
                ForEach(readiness) { item in readinessPill(item) }
            }
            Spacer(minLength: 8)
            detailsLink
        }
    }

    private var liveFrameReady: Bool { showLive && coordinator.shapePreviewAspect != nil }

    private var pictureCard: some View {
        ZStack {
            // The drawing is always underneath, so Show live fades into
            // the same frame it replaces rather than a blank one.
            drawing
            if liveFrameReady {
                Color.black
                LiveCompositePicture(feed: coordinator.shapePreview)
            } else if showLive {
                ProgressView().controlSize(.small).colorScheme(.dark)
                    .padding(10)
                    .background(.black.opacity(0.55), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if liveFrameReady {
                PictureChip(text: "LIVE PREVIEW", dot: .red).padding(10)
            }
        }
        .overlay(alignment: .topTrailing) { liveButton.padding(10) }
        .overlay(alignment: .bottomLeading) { captionChip.padding(10) }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: liveFrameReady)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(showLive ? "Live preview of the picture" : "Drawing of the picture: \(lookText)")
    }

    private var captionChip: some View {
        Text(showLive ? "Live preview. Nothing is sent or saved." : "A drawing of your look. Camera off.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .greenroomGlass(in: Capsule())
    }

    /// What the card says in words, for VoiceOver and the tooltip.
    private var lookText: String {
        [coordinator.cameraIsOff ? nil : coordinator.webcamShape.label,
         LookSummary.shareText(coordinator.shareTarget)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder private var drawing: some View {
        if coordinator.shareTarget.kind == .nothing || coordinator.cameraIsOff {
            HalfSketch(showsCamera: !coordinator.cameraIsOff)
        } else {
            WebcamShapePreview(shape: coordinator.webcamShape,
                               geometry: .constant(geometry), mode: dragMode, aspect: 16.0 / 9.0)
        }
    }

    /// The Webcam page's mapping from the coordinator's fractions: a cutout
    /// keeps the camera's aspect and stands on the bottom edge.
    private var geometry: BubbleDragLayer.Geometry {
        coordinator.webcamShape == .cutout
            ? .init(size: coordinator.cutoutHeightFraction, rightInset: coordinator.cutoutRightInset, bottomInset: 0)
            : .init(size: coordinator.bubbleWidthFraction, rightInset: coordinator.bubbleRightInset,
                    bottomInset: coordinator.bubbleBottomInset)
    }

    private var dragMode: BubbleDragLayer.Mode {
        let camera = 16.0 / 9.0
        return coordinator.webcamShape == .cutout
            ? .cutout(aspect: camera)
            : .bubble(aspect: coordinator.webcamShape.cropsToSquare ? 1 : camera)
    }

    private var liveButton: some View {
        Button(action: toggleLive) {
            Label(showLive ? "Hide live" : "Show live", systemImage: showLive ? "eye.slash" : "video")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .greenroomGlass(in: Capsule(), interactive: true)
        .disabled(isLive)
        .help(showLive
              ? "Turns the camera off again."
              : "Turns the camera on to preview the real picture. Off until you ask, and off again when you start or leave Home.")
    }

    private func toggleLive() {
        if showLive { stopLive() } else {
            showLive = true
            coordinator.startShapePreview()
        }
    }

    /// Off when Home goes away or a start begins. Only if this view turned it
    /// on: the Webcam page shares the one preview and owns its own switch.
    private func stopLive() {
        guard showLive else { return }
        showLive = false
        coordinator.stopShapePreview()
    }

    // MARK: Right: setup

    private var setupColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            brand
                .padding(.bottom, 4)
            nameSection
            // Equal tiles: Look | Share, Camera | Microphone, Layout across.
            VStack(spacing: 8) {
                HStack(spacing: 8) { shapeChip; shareChip }
                HStack(spacing: 8) { cameraChip; micChip }
                layoutChip
            }
            actionRow
        }
    }

    /// The mark and the name, large, at the top of the column. The mark is the
    /// shipped asset, never recoloured or stretched (it has its own dark
    /// variant); the name is one colour (`Brand.name`).
    private var brand: some View {
        HStack(spacing: 10) {
            Image("LogoMark")
                .resizable()
                .scaledToFit()
                .frame(height: 42)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Greenroom")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(Brand.name)
                Text(tagline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: mode)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var tagline: String {
        switch mode {
        case .create: return "Start a class on Zoom"
        case .join: return "Join a class"
        case .record: return "Record without a meeting"
        }
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(.secondary)
    }

    // MARK: Name / meeting

    @ViewBuilder private var nameSection: some View {
        if mode == .join {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    eyebrow("Meeting")
                    if pastedHint {
                        Label("Pasted from clipboard", systemImage: "checkmark")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(Brand.text)
                            .transition(.opacity)
                    }
                    Spacer(minLength: 0)
                }
                // One row, so Join is as tall as New and Record and the two
                // columns stay level.
                HStack(spacing: 8) {
                    TextField("Meeting link or ID", text: meetingBinding)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .disabled(isLive)
                        .onSubmit(submit)
                        .help("A Zoom link, an invite, or the meeting ID. A link also fills the passcode.")
                    TextField("Passcode", text: $coordinator.meetingPassword)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .frame(width: 96)
                        .disabled(isLive)
                        .onSubmit(submit)
                        .help("The meeting's passcode, if it has one.")
                    presetsMenu
                    scheduledMeetingsMenu
                }
                .labelStyle(.iconOnly)
                .onAppear {
                    // Pre-fetch so the menu is ready by the time it is opened;
                    // skipped silently when credentials or a scope are missing.
                    if coordinator.scheduledMeetings.isEmpty && !coordinator.s2sAccountID.isEmpty {
                        coordinator.refreshScheduledMeetings()
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                eyebrow("Name")
                // The auto-name is the placeholder: it says what you will GET
                // while the field says what to DO. Left empty, the folder is
                // named by date and time.
                TextField(folderPreview, text: $coordinator.className)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .disabled(isLive)
                    .onSubmit(submit)
                    .help("Names this session's folder in Documents/Greenroom. Leave it empty and the folder is named by date and time, as shown.")
            }
        }
    }

    /// The folder the next Start will create, as the placeholder.
    private var folderPreview: String {
        if let live = coordinator.sessionFolder { return live.lastPathComponent }
        return SessionFolders.sessionFolderName(className: coordinator.className, started: Date(),
                                                fallback: mode == .record ? "Recording" : "Green")
    }

    /// Join reads the same two values it always did, the meeting number and the
    /// passcode. A link or invite typed or pasted here is parsed into both; a
    /// bare ID is kept as typed, spaces and all, since `meetingNumberDigits`
    /// strips them at every use.
    private var meetingBinding: Binding<String> {
        Binding(
            get: { coordinator.meetingNumber },
            set: { text in
                pastedHint = false
                let bareID = text.allSatisfy { $0.isNumber || $0.isWhitespace || $0 == "-" }
                if !bareID, let parsed = ZoomMeetingLinkParser.parse(text) {
                    coordinator.meetingNumber = parsed.number
                    coordinator.meetingPassword = parsed.password
                } else {
                    coordinator.meetingNumber = text
                }
            })
    }

    /// Choosing Join with a Zoom link already on the clipboard fills it in, with
    /// a hint so it is not a surprise. Only into an empty field.
    private func prefillFromClipboard() {
        guard coordinator.meetingNumberDigits.isEmpty,
              let text = NSPasteboard.general.string(forType: .string),
              let parsed = ZoomMeetingLinkParser.parse(text) else { return }
        coordinator.meetingNumber = parsed.number
        coordinator.meetingPassword = parsed.password
        withAnimation(.easeOut(duration: 0.15)) { pastedHint = true }
    }

    /// Return in a field starts, as the button does.
    private func submit() {
        guard !startDisabled else { return }
        coordinator.start()
    }

    // MARK: Chips

    /// An equal-size tile: icon, a small caption, and the current choice with a
    /// chevron. `trailingInset` keeps room for a button laid over the tile.
    private func tileLabel(symbol: String, caption: String, text: String, meter: Double? = nil,
                           trailingInset: CGFloat = 0) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(caption)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let meter { MiniMeter(level: meter) }
                }
            }
            Spacer(minLength: trailingInset)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// "MacBook Pro Camera" is "MacBook Pro" on the tile; the hover help and
    /// VoiceOver keep the full name.
    private static func shortDeviceName(_ name: String) -> String {
        for suffix in [" Camera", " Microphone", " Mic"] where name.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    private func choice(_ title: String, selected: Bool, disabled: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .disabled(disabled)
    }

    /// Shape: the Webcam page's look picker, one setting, one apply.
    private var shapeChip: some View {
        Menu {
            ForEach(WebcamShape.allCases) { shape in
                choice(shape.label, selected: coordinator.webcamShape == shape) {
                    coordinator.webcamShape = shape
                    coordinator.requestShapeApply()
                }
            }
            Divider()
            Button("More\u{2026}", action: openWebcamSettings)
        } label: {
            tileLabel(symbol: Self.symbol(for: coordinator.webcamShape), caption: "LOOK", text: coordinator.webcamShape.label)
        }
        .chipMenu()
        .disabled(coordinator.cameraIsOff)
        .help(coordinator.cameraIsOff ? "No camera is picked, so there is no look to choose."
                                      : "How you appear over what you share.")
        .accessibilityLabel("Look")
        .accessibilityValue(coordinator.webcamShape.label)
    }

    /// Share target: the Webcam page's "Behind you", kind then which one.
    private var shareChip: some View {
        Menu {
            ForEach(ShareTarget.Kind.allCases) { kind in
                choice(kind.label, selected: coordinator.shareTarget.kind == kind,
                       disabled: kind == .nothing && coordinator.cameraIsOff) {
                    coordinator.shareTarget.kind = kind
                    coordinator.requestShapeApply(rebuild: true)
                }
            }
            if coordinator.shareTarget.kind == .app {
                Divider()
                Menu("App") {
                    ForEach(apps, id: \.bundleID) { app in
                        choice(app.name, selected: coordinator.shareTarget.appBundleID == app.bundleID) {
                            coordinator.shareTarget.appBundleID = app.bundleID
                            coordinator.shareTarget.appName = app.name
                            coordinator.shareTarget.windowTitle = ""
                            coordinator.requestShapeApply(rebuild: true)
                        }
                    }
                }
            }
            if coordinator.shareTarget.kind == .window {
                Divider()
                Menu("Window") {
                    ForEach(windows) { window in
                        choice((window.title.isEmpty ? window.appName : "\(window.appName) \u{2013} \(window.title)")
                               + window.placement.menuSuffix,
                               selected: coordinator.shareTarget.appBundleID == window.bundleID
                                   && coordinator.shareTarget.windowTitle == window.title) {
                            coordinator.shareTarget.appBundleID = window.bundleID
                            coordinator.shareTarget.appName = window.appName
                            coordinator.shareTarget.windowTitle = window.title
                            coordinator.requestShapeApply(rebuild: true)
                        }
                    }
                }
            }
            if coordinator.shareTarget.kind == .display || coordinator.shareTarget.kind == .app {
                Divider()
                Menu("Display") {
                    choice("Automatic (your main display)", selected: coordinator.screenCaptureDisplayUUID.isEmpty) {
                        coordinator.screenCaptureDisplayUUID = ""
                        coordinator.requestShapeApply(rebuild: true)
                    }
                    ForEach(displays) { display in
                        choice(display.label, selected: coordinator.screenCaptureDisplayUUID == display.id) {
                            coordinator.screenCaptureDisplayUUID = display.id
                            coordinator.requestShapeApply(rebuild: true)
                        }
                    }
                }
            }
            Divider()
            Button("More\u{2026}", action: openWebcamSettings)
        } label: {
            tileLabel(symbol: Self.symbol(for: coordinator.shareTarget.kind), caption: "SHARE",
                      text: LookSummary.shareText(coordinator.shareTarget))
        }
        .chipMenu()
        .help("What the class sees behind you.")
        .accessibilityLabel("Behind you")
        .accessibilityValue(LookSummary.shareText(coordinator.shareTarget))
    }

    /// Camera: the same list and the same rule as the Webcam page's cards.
    private var cameraChip: some View {
        let chosen = coordinator.sceneCameraUIDs(limit: 1).first
        let name = LookSummary.cameraText(coordinator, cameras: cameras)
        return Menu {
            ForEach(cameras) { camera in
                choice(camera.name, selected: !coordinator.cameraIsOff && chosen == camera.id) {
                    var settings = coordinator.cameraDirectorSettings
                    settings.cameraUIDs = settings.cameraUIDs.filter { $0 != camera.id }
                    settings.cameraUIDs.insert(camera.id, at: 0)
                    settings.noCamera = false
                    coordinator.cameraDirectorSettings = settings
                    coordinator.previewCamerasChanged()
                }
            }
            Divider()
            choice("No camera", selected: coordinator.cameraIsOff,
                   disabled: coordinator.shareTarget.kind == .nothing) {
                coordinator.cameraDirectorSettings.noCamera = true
                coordinator.previewCamerasChanged()
            }
            Divider()
            Button("More\u{2026}", action: openWebcamSettings)
        } label: {
            tileLabel(symbol: coordinator.cameraIsOff ? "video.slash" : "camera", caption: "CAMERA",
                      text: Self.shortDeviceName(name))
        }
        .chipMenu()
        .help("Camera: \(name). Which camera you appear on.")
        .accessibilityLabel("Camera")
        .accessibilityValue(name)
    }

    /// Microphone: system default or one pinned device, as the Webcam page.
    /// The level meter appears only while the microphone is already in use
    /// (a live session); Home never opens it on its own.
    private var micChip: some View {
        let name = LookSummary.microphoneText(uid: coordinator.micDeviceUID, microphones: microphones,
                                              system: AVCaptureDevice.default(for: .audio)?.localizedName)
        return Menu {
            choice("System default", selected: coordinator.micDeviceUID.isEmpty) { pickMic("") }
            ForEach(microphones) { mic in
                choice(mic.name, selected: coordinator.micDeviceUID == mic.id) { pickMic(mic.id) }
            }
            if !coordinator.micDeviceUID.isEmpty, !microphones.contains(where: { $0.id == coordinator.micDeviceUID }) {
                choice("Saved microphone (not connected)", selected: true) {}
            }
            Divider()
            Button("More\u{2026}", action: openWebcamSettings)
        } label: {
            tileLabel(symbol: "mic", caption: "MICROPHONE", text: Self.shortDeviceName(name), meter: micMeterLevel)
        }
        .chipMenu()
        .help("Microphone: \(name). Which microphone the class hears and the recording takes.")
        .accessibilityLabel("Microphone")
        .accessibilityValue(name)
    }

    private func pickMic(_ uid: String) {
        coordinator.micDeviceUID = uid
        coordinator.previewCamerasChanged()
    }

    /// Only the system's input, which is what the monitor listens to, and only
    /// while a session has the microphone open already.
    private var micMeterLevel: Double? {
        guard coordinator.stageLive, coordinator.micDeviceUID.isEmpty, meter.isRunning else { return nil }
        return meter.level
    }

    /// Layout: the same picker as the menu bar and Settings, locked mid-class.
    /// "Show on screen" sits over the tile's trailing edge as its own button
    /// (`showLayoutButton`), so it is easy to move.
    private var layoutChip: some View {
        Menu {
            LayoutChoiceItems()
            Divider()
            Button("More\u{2026}") {
                openSettings()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .showSettingsTab, object: "layout")
                }
            }
        } label: {
            tileLabel(symbol: "rectangle.split.2x1", caption: "LAYOUT", text: coordinator.layoutChoiceName,
                      trailingInset: 34)
        }
        .chipMenu()
        .disabled(coordinator.layoutChoiceLocked)
        .overlay(alignment: .trailing) { showLayoutButton.padding(.trailing, 26) }
        .help(coordinator.layoutChoiceLocked
              ? "A class runs the layout it started with. Pick the next one after it ends."
              : "Where Start puts the meeting, the chat and your apps.")
        .accessibilityLabel("Layout")
        .accessibilityValue(coordinator.layoutChoiceName)
    }

    /// The Layout page's "Show on screen", through the same call.
    @ViewBuilder private var showLayoutButton: some View {
        if let template = coordinator.layoutLibrary.active, template.pieceCount > 0 {
            Button {
                LayoutPageContent.showOnScreen(template, customUIMode: coordinator.customUIMode,
                                               canMoveApps: AppWindowManager.hasAccessibilityPermission)
            } label: {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 14))
                    .foregroundStyle(Brand.text)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Preview this layout on your screen")
            .accessibilityLabel("Show layout on screen")
        }
    }

    private static func symbol(for shape: WebcamShape) -> String {
        switch shape {
        case .square: return "square"
        case .circle: return "circle"
        case .roundedRectangle: return "app"
        case .cutout, .presenterLarge: return "person.crop.rectangle"
        }
    }

    private static func symbol(for kind: ShareTarget.Kind) -> String {
        switch kind {
        case .display: return "display"
        case .app: return "macwindow"
        case .window: return "macwindow.on.rectangle"
        case .whiteboard: return "pencil.and.outline"
        case .nothing: return "eye.slash"
        }
    }

    // MARK: Readiness

    private enum Fix { case zoomSettings, cameraPrivacy, micPrivacy, screenPrivacy }

    private struct ReadyItem: Identifiable {
        let id: String
        let title: String
        /// nil: ready. Otherwise what is wrong, in the pill's own words.
        var problem: String?
        var fix: Fix
    }

    /// What a start needs, from the same facts the start itself checks: the
    /// Zoom credentials `start()` refuses without, and the camera, microphone
    /// and Screen Recording permissions it would otherwise stall on.
    private var readiness: [ReadyItem] {
        var items: [ReadyItem] = []
        if mode != .record {
            let sdk = coordinator.sdkClientID.isEmpty || coordinator.sdkClientSecret.isEmpty
            let host = coordinator.s2sAccountID.isEmpty || coordinator.s2sClientID.isEmpty
                || coordinator.s2sClientSecret.isEmpty
            let missing = mode == .create ? (sdk || host) : sdk
            items.append(ReadyItem(id: "zoom", title: "Zoom",
                                   problem: missing ? "Zoom: add credentials" : nil, fix: .zoomSettings))
        }
        if !coordinator.cameraIsOff {
            let blocked = cameraAccess == .denied || cameraAccess == .restricted
            items.append(ReadyItem(id: "camera", title: "Camera",
                                   problem: blocked ? "Camera: not allowed" : nil, fix: .cameraPrivacy))
        }
        let micBlocked = micAccess == .denied || micAccess == .restricted
        items.append(ReadyItem(id: "mic", title: "Mic",
                               problem: micBlocked ? "Mic: not allowed" : nil, fix: .micPrivacy))
        if coordinator.shareTarget.kind.capturesScreen {
            items.append(ReadyItem(id: "screen", title: "Screen",
                                   problem: screenAllowed ? nil : "Screen: permission needed", fix: .screenPrivacy))
        }
        return items
    }

    private func readinessPill(_ item: ReadyItem) -> some View {
        let warn = item.problem != nil
        return Button {
            if warn { fix(item.fix) } else { withAnimation(.snappy(duration: 0.25)) { statusShown.toggle() } }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: warn ? "exclamationmark.triangle.fill" : "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text(item.problem ?? item.title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(warn ? Brand.netText : Brand.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill((warn ? Brand.net : Brand.green).opacity(0.14)))
            .overlay(Capsule().strokeBorder((warn ? Brand.net : Brand.green).opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(warn ? "Click to fix it." : "Ready. Click for the status details.")
        .accessibilityLabel(item.problem ?? "\(item.title) ready")
        .accessibilityHint(warn ? "Opens where to fix it" : "Shows the status details")
    }

    private func fix(_ fix: Fix) {
        switch fix {
        case .zoomSettings:
            openSettings()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .showSettingsTab, object: "zoom")
            }
        case .cameraPrivacy: Self.openPrivacy("Privacy_Camera")
        case .micPrivacy: Self.openPrivacy("Privacy_Microphone")
        case .screenPrivacy: Self.openPrivacy("Privacy_ScreenCapture")
        }
    }

    private static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// What the Status row on Home was: the log of what each step did.
    private var detailsLink: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { statusShown.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(statusShown ? "Hide details" : "Details")
                if !coordinator.statusLines.isEmpty {
                    Text("\(coordinator.statusLines.count)")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .font(.caption)
            .foregroundStyle(Brand.text)
        }
        .buttonStyle(.plain)
        .help(statusShown ? "Hide the status log" : "Show what each step did and why")
        .accessibilityLabel(statusShown ? "Hide status" : "Show status")
    }

    // MARK: The button

    @ViewBuilder private var actionRow: some View {
        if isLive {
            liveRow
        } else {
            primaryButton
        }
    }

    private var primaryText: String {
        switch mode {
        case .create: return "Start Meeting"
        case .join: return "Join Meeting"
        case .record: return "Start Recording"
        }
    }

    private var primaryHelp: String {
        switch mode {
        case .create:
            return "Starts your screen and camera picture, creates a fresh meeting under your Zoom account with you as host, and tiles your windows \u{2014} the whole session in one click."
        case .join:
            return "Starts your screen and camera picture, joins the meeting above (starting it as host if it's yours), and tiles your windows."
        case .record:
            return "Starts the picture set in Settings \u{2192} Webcam and opens the Record view, where you can check it and press Record when you are ready. No meeting, no windows moved."
        }
    }

    /// One button that follows the mode. The split chevron holds what the
    /// "Manual controls" pull-down held.
    private var primaryButton: some View {
        HStack(spacing: 6) {
            Button {
                coordinator.start()
            } label: {
                HStack(spacing: 8) {
                    primaryGlyph
                    Text(primaryText)
                        .contentTransition(.opacity)
                }
                .font(.headline)
                .frame(minWidth: 148)
                .padding(.horizontal, 8)
            }
            .greenroomGlassButton(prominent: true)
            .disabled(startDisabled)
            .help(primaryHelp)

            Menu {
                Section("Manual controls") {
                    Button("Open Layout Apps") { coordinator.openMainAppWindow() }
                        .disabled(!coordinator.layoutHasApps)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .greenroomGlassButton(prominent: true)
            .help("Manual controls: each piece of the session on its own.")
            .accessibilityLabel("Manual controls")
        }
        .controlSize(.extraLarge)
        // One style in every mode: the mode changes the label and glyph only.
        .tint(Brand.green)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: mode)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Record's intent is a small red dot, not a red button.
    @ViewBuilder private var primaryGlyph: some View {
        switch mode {
        case .create: Image(systemName: "play.fill")
        case .join: Image(systemName: "arrow.right")
        case .record: Circle().fill(Color.red).frame(width: 9, height: 9)
        }
    }

    /// Only while a session is live: End Session and the recording control.
    /// Not drawn dimmed before, so Home asks one question at a time.
    private var liveRow: some View {
        HStack(spacing: 10) {
            Button {
                coordinator.confirmAndStop()
            } label: {
                Label(coordinator.isStopping ? "Ending\u{2026}" : coordinator.stageLive ? "End Session" : "Stop",
                      systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .greenroomGlassButton(prominent: true)
            .tint(.red)
            .disabled(coordinator.isStopping)
            .help("Ends the meeting for everyone when you're hosting (leaves it otherwise), closes the chat window, and stops the camera. Ending the meeting from the Zoom window does the same \u{2014} both roads end the whole session.")

            Button {
                coordinator.toggleRecording()
            } label: {
                Label(coordinator.isSavingRecording ? "Saving\u{2026}"
                        : coordinator.isRecording ? "Stop Recording" : "Record",
                      systemImage: coordinator.isSavingRecording ? "hourglass"
                        : coordinator.isRecording ? "stop.circle.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .greenroomGlassButton()
            .tint(coordinator.isRecording && !coordinator.isSavingRecording ? .red : Color(nsColor: .labelColor))
            .disabled(coordinator.isSavingRecording || !coordinator.stageLive && !coordinator.isRecording)
            .help("Records exactly what participants see \u{2014} your shared screen with you in it. Saved to Documents/Greenroom when stopped.")
        }
        .controlSize(.extraLarge)
    }

    // MARK: Footer

    private struct LastSession: Equatable {
        let path: String
        let title: String
        let length: String?
    }

    private func footer(_ session: LastSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 6) {
                Text("Last session:")
                    .foregroundStyle(.secondary)
                Text([session.title, session.length].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\u{00B7}").foregroundStyle(.secondary)
                Button {
                    coordinator.mainPage = .detail(session.path)
                } label: {
                    Text("Open \u{2192}").foregroundStyle(Brand.text)
                }
                .buttonStyle(.plain)
                .help("Opens that session's page.")
                Spacer(minLength: 0)
            }
            .font(.callout)
        }
    }

    /// Newest session on disk, its length read from the recording. Off the main
    /// thread: the library walks the folders and the length opens a file.
    private func loadLastSession() {
        Task.detached(priority: .utility) {
            guard let newest = ScreenroomLibrary.presentations().first else {
                await MainActor.run { lastSession = nil }
                return
            }
            var length: String?
            if let url = newest.recording,
               let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
               seconds.isFinite, seconds > 0 {
                length = SessionsFormat.length(seconds)
            }
            let found = LastSession(path: newest.folder.path, title: newest.presenter, length: length)
            await MainActor.run { lastSession = found }
        }
    }

    // MARK: Status log

    /// The log, when shown: a fixed 180pt box. Fixed, not flexible, so the
    /// window's growth is exactly the box, and the newest line is in view.
    private var statusLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if coordinator.statusLines.isEmpty {
                    Text("Nothing yet. Start a session and each step shows up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(coordinator.statusLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.callout)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.statusLogHeight)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)) // DESIGN.md radius-sm
            .onAppear { scrollToNewestStatus(proxy) }
            .onChange(of: coordinator.statusLines.count) { _, _ in scrollToNewestStatus(proxy) }
        }
    }

    private func scrollToNewestStatus(_ proxy: ScrollViewProxy) {
        guard let newest = coordinator.statusLines.indices.last else { return }
        // Next runloop pass: on expand the rows are created in the same layout
        // pass that runs this, and scrollTo cannot target a row not yet there.
        DispatchQueue.main.async { proxy.scrollTo(newest, anchor: .bottom) }
    }

    // MARK: Join's menus

    private var presetsMenu: some View {
        Menu {
            if coordinator.meetingPresets.isEmpty {
                Text("No saved presets")
            } else {
                ForEach(coordinator.meetingPresets) { preset in
                    Button(preset.menuLabel) { coordinator.applyPreset(preset) }
                }
            }
            Divider()
            Button("Save current as preset\u{2026}") { showSavePreset = true }
                .disabled(coordinator.meetingNumberDigits.isEmpty)
            if !coordinator.meetingPresets.isEmpty {
                Menu("Delete preset") {
                    ForEach(coordinator.meetingPresets) { preset in
                        Button(preset.menuLabel, role: .destructive) { coordinator.deletePreset(preset) }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "bookmark")
        }
        .help("Saved meetings")
        .menuStyle(.borderlessButton)
        .fixedSize()
        .alert("Save meeting preset", isPresented: $showSavePreset) {
            TextField("Name (e.g. Morning class)", text: $presetNameDraft)
            Button("Save") {
                coordinator.saveCurrentAsPreset(name: presetNameDraft)
                presetNameDraft = ""
            }
            Button("Cancel", role: .cancel) { presetNameDraft = "" }
        } message: {
            Text("Saves the meeting ID \(coordinator.meetingNumberDigits) and its passcode for one-click filling later.")
        }
    }

    private var scheduledMeetingsMenu: some View {
        Menu {
            if coordinator.scheduledMeetings.isEmpty {
                Text(coordinator.isLoadingScheduled ? "Loading\u{2026}" : "No scheduled meetings found")
            } else {
                ForEach(coordinator.scheduledMeetings) { meeting in
                    Button(scheduledMeetingLabel(meeting)) { coordinator.selectScheduledMeeting(meeting) }
                }
            }
            Divider()
            Button("Refresh") { coordinator.refreshScheduledMeetings() }
        } label: {
            Label("Scheduled", systemImage: "calendar")
        }
        .help("Scheduled meetings")
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Recurring meetings' times come from the per-meeting details call (their
    /// real next occurrence) - never from the list endpoint, whose recurring
    /// timestamps are the series' original anchor. No time means "no fixed
    /// time", no upcoming occurrence, or a missing details scope.
    private func scheduledMeetingLabel(_ meeting: ZoomServerToServerClient.ScheduledMeeting) -> String {
        let when = meeting.startTime?.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        switch (meeting.isRecurring, when) {
        case (true, let when?): return "\(meeting.topic) \u{2014} recurring, next \(when)"
        case (true, nil): return "\(meeting.topic) \u{2014} recurring"
        case (false, let when?): return "\(meeting.topic) \u{2014} \(when)"
        case (false, nil): return meeting.topic
        }
    }

    // MARK: Refresh

    private func refreshDevices() {
        cameras = LocalDeviceResolver.availableCameras()
        microphones = LocalDeviceResolver.availableMicrophones()
        displays = DisplayResolver.connectedDisplays()
    }

    private func refreshPermissions() {
        screenAllowed = StageCompositor.screenRecordingGranted
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        micAccess = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    private func refreshShareLists() {
        switch coordinator.shareTarget.kind {
        case .app:
            apps = ShareTarget.runningApps()
        case .window:
            var seen = Set<String>()
            windows = ShareTarget.windows().filter { seen.insert($0.key).inserted }
        default: break
        }
    }

    private func openWebcamSettings() {
        openSettings()
        // After the window exists: a Settings window opened just now starts on
        // Webcam anyway, and one already open needs telling.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showWebcamSettings, object: nil)
        }
    }
}

// MARK: - Pieces

private extension View {
    /// A tile's menu: the shared tile look, no arrow of its own.
    func chipMenu() -> some View {
        self.menuStyle(.button)
            .greenroomTile(role: .choice(selected: false), radius: 10)
            .menuIndicator(.hidden)
    }
}

/// The microphone's level as four thin bars, only drawn while there is a level
/// to read.
private struct MiniMeter: View {
    let level: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                let weight = [0.55, 1.0, 0.8, 0.45][index]
                Capsule()
                    .fill(Brand.green)
                    .frame(width: 2, height: 3 + 9 * min(1, level * weight * 1.4))
            }
        }
        .frame(height: 12, alignment: .bottom)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

/// Wraps its children onto as many rows as the width needs, left-aligned.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in rows.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], width: CGFloat, height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (frames, widest, y + rowHeight)
    }
}
