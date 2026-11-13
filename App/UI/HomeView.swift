//
//  HomeView.swift
//  Greenroom
//
//  Home, "Direction A: Picture first" (DESIGN.md decisions log, 2026-11-13).
//
//  Calmer (DESIGN.md, 2026-11-13): setup is ONE summary line with an Edit
//  button that unfolds the five tiles in place; readiness is one "Ready" chip
//  (or only the problems); the primary button and its menu are one shape.
//  Left, a 16:9 card showing the look the class will see. Right, the few
//  things that change a start: a name (or the meeting to join), the setup
//  line, the readiness chip, and ONE button that follows the mode. A last
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
    /// Whether the five setup tiles are unfolded. Owned by ContentView, which
    /// sizes the window for it; per launch only, collapsed by default.
    @Binding var setupOpen: Bool

    /// Height of the open log. Eight lines.
    static let statusLogHeight: CGFloat = 180
    /// The options column; its two equal tiles share it with an 8pt gap.
    static let optionsWidth: CGFloat = 380
    /// Fixed heights of the options column's parts, so the window's height is
    /// arithmetic: 42 + 32 + 32 + 44 + 24, five rows with four 16pt gaps.
    static let brandHeight: CGFloat = 42
    static let fieldHeight: CGFloat = 32
    static let summaryHeight: CGFloat = 32
    static let readyHeight: CGFloat = 24
    static let buttonHeight: CGFloat = 44
    /// A standard macOS 26 large control.
    static let largeControlHeight: CGFloat = 32
    static let columnGap: CGFloat = 16
    /// The five tiles: three rows of 44 with 8pt gaps, and the gap above them.
    static let tilesHeight: CGFloat = 148
    static var columnHeight: CGFloat {
        brandHeight + fieldHeight + summaryHeight + readyHeight + buttonHeight + 4 * columnGap
    }
    static var tilesExtraHeight: CGFloat { tilesHeight + columnGap }

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
                // The options column sets the row's height; the card fits the
                // room beside it, against the right edge, so the two columns
                // share a top and a bottom.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) { pictureCard }
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
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: liveFrameReady)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(showLive ? "Live preview of the picture" : "Drawing of the picture: \(lookText)")
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

    /// A glass capsule that says what it does: the icon and "Show live", or
    /// "Stop live" while the camera is on. The hover help keeps the fuller words.
    private var liveButton: some View {
        Button(action: toggleLive) {
            Label(showLive ? "Stop live" : "Show live", systemImage: "video")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .greenroomGlass(in: Capsule(), interactive: true)
        .disabled(isLive)
        .help(showLive
              ? "Hide the live picture. This turns the camera off again."
              : "Show the live picture. The camera stays off until you do.")
        .accessibilityLabel(showLive ? "Hide live picture" : "Show live picture")
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
        VStack(alignment: .leading, spacing: Self.columnGap) {
            brand
            nameSection
            setupSection
            readyRow
            actionRow
        }
    }

    /// The mark and the name, large, at the top of the column. The mark is the
    /// shipped asset, never recoloured or stretched (it has its own dark
    /// variant); the name is one colour (`Brand.name`). No subtitle: the
    /// toolbar's switcher says the mode.
    private var brand: some View {
        HStack(spacing: 10) {
            Image("LogoMark")
                .resizable()
                .scaledToFit()
                .frame(height: Self.brandHeight)
                .accessibilityHidden(true)
            Text("Greenroom")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(Brand.name)
        }
        .frame(height: Self.brandHeight)
        .accessibilityElement(children: .combine)
    }

    // MARK: Name / meeting

    @ViewBuilder private var nameSection: some View {
        if mode == .join {
            // One row, so Join is as tall as New and Record and the two
            // columns stay level. No label: the placeholder says what to type.
            HStack(spacing: 8) {
                TextField("Meeting link or ID", text: meetingBinding)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .disabled(isLive)
                    .onSubmit(submit)
                    .overlay(alignment: .trailing) {
                        if pastedHint {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Brand.text)
                                .padding(.trailing, 8)
                                .help("Pasted from clipboard")
                                .accessibilityLabel("Pasted from clipboard")
                                .transition(.opacity)
                        }
                    }
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
            .frame(height: Self.fieldHeight)
            .onAppear {
                // Pre-fetch so the menu is ready by the time it is opened;
                // skipped silently when credentials or a scope are missing.
                if coordinator.scheduledMeetings.isEmpty && !coordinator.s2sAccountID.isEmpty {
                    coordinator.refreshScheduledMeetings()
                }
            }
        } else {
            // The auto-name is the placeholder: it says what you will GET.
            // Left empty, the folder is named by date and time.
            TextField(folderPreview, text: $coordinator.className)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(height: Self.fieldHeight)
                .disabled(isLive)
                .onSubmit(submit)
                .accessibilityLabel("Name")
                .help("Names this session's folder in Documents/Greenroom. Leave it empty and the folder is named by date and time, as shown.")
        }
    }

    // MARK: Setup: one line, five tiles behind Edit

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: Self.columnGap) {
            // One row, two faces: the summary while folded, a "Setup" caption
            // with Done while the tiles show, so no value is drawn twice. Both
            // are the same height, so the column keeps its balance.
            ZStack(alignment: .topLeading) {
                if setupOpen { setupCaptionRow.transition(.opacity) } else { summaryRow.transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.2), value: setupOpen)
            Collapsible(hidden: !setupOpen) {
                // Equal tiles: Look | Share, Camera | Microphone, Layout across.
                VStack(spacing: 8) {
                    HStack(spacing: 8) { shapeChip; shareChip }
                    HStack(spacing: 8) { cameraChip; micChip }
                    layoutChip
                }
            }
        }
    }

    private var summaryItems: [SetupSummaryItem] {
        let share = coordinator.shareTarget
        let kind: SetupSummary.ShareKind
        switch share.kind {
        case .display: kind = .display
        case .app: kind = .app
        case .window: kind = .window
        case .whiteboard: kind = .whiteboard
        case .nothing: kind = .nothing
        }
        let gone = SetupSummary.shareIsGone(kind: kind, appBundleID: share.appBundleID,
                                            windowTitle: share.windowTitle,
                                            runningApps: apps.map(\.bundleID),
                                            openWindows: windows.map { ($0.bundleID, $0.title) })
        let camera = LookSummary.cameraText(coordinator, cameras: cameras)
        let mic = LookSummary.microphoneText(uid: coordinator.micDeviceUID, microphones: microphones,
                                             system: AVCaptureDevice.default(for: .audio)?.localizedName)
        return SetupSummary.items(
            cameraOff: coordinator.cameraIsOff,
            lookSymbol: "circle.lefthalf.filled", lookText: coordinator.webcamShape.label,
            shareSymbol: Self.symbol(for: share.kind), shareText: LookSummary.shareText(share), shareGone: gone,
            cameraText: Self.shortDeviceName(camera), cameraMissing: cameras.isEmpty,
            micText: Self.shortDeviceName(mic), layoutText: coordinator.layoutChoiceName)
    }

    private var summaryRow: some View {
        let items = summaryItems
        return HStack(alignment: .top, spacing: 8) {
            ChipFlow(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    summaryPart(item, last: index == items.count - 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            setupToggle
        }
        .frame(minHeight: Self.summaryHeight, alignment: .top)
    }

    private var setupCaptionRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Setup")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            setupToggle
        }
        .frame(minHeight: Self.summaryHeight, alignment: .top)
    }

    /// Edit while folded, Done while unfolded.
    private var setupToggle: some View {
        Button(setupOpen ? "Done" : "Edit") {
            Collapse.animate { setupOpen.toggle() }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(Brand.text)
        .help(setupOpen ? "Fold the setup back into one line." : "Change the look, what you share, the camera, the microphone or the layout.")
        .accessibilityLabel(setupOpen ? "Done editing setup" : "Edit setup")
    }

    /// One part of the line. Amber (text colour `net-text`, glyph `net`) when
    /// it needs the user's attention.
    private func summaryPart(_ item: SetupSummaryItem, last: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: item.symbol)
                .font(.system(size: 11))
                .foregroundStyle(item.attention ? Brand.net : Color.secondary)
            Text(item.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(item.attention ? Brand.netText : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !last {
                Text("\u{00B7}").foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.attention ? "\(item.text), needs attention" : item.text)
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

    private func fixFor(_ id: String) -> Fix {
        switch id {
        case "zoom": return .zoomSettings
        case "camera": return .cameraPrivacy
        case "mic": return .micPrivacy
        default: return .screenPrivacy
        }
    }

    /// What a start needs, from the same facts the start itself checks: the
    /// Zoom credentials `start()` refuses without, and the camera, microphone
    /// and Screen Recording permissions it would otherwise stall on.
    private var readiness: [ReadinessItem] {
        var items: [ReadinessItem] = []
        if mode != .record {
            let sdk = coordinator.sdkClientID.isEmpty || coordinator.sdkClientSecret.isEmpty
            let host = coordinator.s2sAccountID.isEmpty || coordinator.s2sClientID.isEmpty
                || coordinator.s2sClientSecret.isEmpty
            let missing = mode == .create ? (sdk || host) : sdk
            items.append(ReadinessItem(id: "zoom", title: "Zoom", problem: missing ? "Zoom: add credentials" : nil))
        }
        if !coordinator.cameraIsOff {
            let blocked = cameraAccess == .denied || cameraAccess == .restricted
            items.append(ReadinessItem(id: "camera", title: "Camera", problem: blocked ? "Camera: not allowed" : nil))
        }
        let micBlocked = micAccess == .denied || micAccess == .restricted
        items.append(ReadinessItem(id: "mic", title: "Mic", problem: micBlocked ? "Mic: not allowed" : nil))
        if coordinator.shareTarget.kind.capturesScreen {
            items.append(ReadinessItem(id: "screen", title: "Screen", problem: screenAllowed ? nil : "Screen: permission needed"))
        }
        return items
    }

    /// "Ready" as one chip when everything is fine; its click shows what each
    /// step did (the status log, which is the details). When something is
    /// wrong, only the problems, amber, each a click to its fix.
    private var readyRow: some View {
        Group {
            switch ReadinessSummary.reduce(readiness) {
            case .ready:
                readyChip
            case .problems(let bad):
                ChipFlow(spacing: 6) { ForEach(bad) { problemPill($0) } }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.readyHeight, alignment: .leading)
    }

    private var readyChip: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { statusShown.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("Ready").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Brand.text)
            .padding(.horizontal, 10)
            .frame(height: Self.readyHeight)
            .background(Capsule().fill(Brand.green.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Brand.green.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(statusShown ? "Ready. Click to hide the status details."
                          : "Ready: Zoom, camera, microphone and screen are fine. Click for the status details.")
        .accessibilityLabel("Ready")
        .accessibilityHint(statusShown ? "Hides the status details" : "Shows the status details")
    }

    private func problemPill(_ item: ReadinessItem) -> some View {
        Button { fix(fixFor(item.id)) } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(item.problem ?? item.title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(Brand.netText)
            .padding(.horizontal, 10)
            .frame(height: Self.readyHeight)
            .background(Capsule().fill(Brand.net.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Brand.net.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Click to fix it.")
        .accessibilityLabel(item.problem ?? item.title)
        .accessibilityHint("Opens where to fix it")
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

    /// One button that follows the mode: a single rounded shape, the label
    /// and a small chevron segment inside it. The chevron holds what the
    /// "Manual controls" pull-down held. Content-sized, Brand green in every
    /// mode (Record is marked by its red dot only).
    private var primaryButton: some View {
        HStack(spacing: 0) {
            Button {
                coordinator.start()
            } label: {
                HStack(spacing: 6) {
                    primaryGlyph
                    Text(primaryText)
                        .contentTransition(.opacity)
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(height: Self.largeControlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(startDisabled)
            .help(primaryHelp)

            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)

            // The glyph is drawn here; the menu is a clear layer over it, since
            // a borderless Menu label lost its glyph on the green.
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: Self.largeControlHeight)
                .overlay {
                    Menu {
                        Section("Manual controls") {
                            Button("Open Layout Apps") { coordinator.openMainAppWindow() }
                                .disabled(!coordinator.layoutHasApps)
                        }
                    } label: {
                        Color.clear.frame(width: 28, height: Self.largeControlHeight).contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Manual controls: each piece of the session on its own.")
                    .accessibilityLabel("Manual controls")
                }
        }
        .foregroundStyle(.white)
        .background(Capsule().fill(Brand.green.opacity(startDisabled ? 0.4 : 1)))
        .clipShape(Capsule())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: mode)
        // The column keeps its 44pt slot (the window's height is arithmetic
        // from it); the standard 32pt large control sits in it.
        .frame(maxWidth: .infinity, minHeight: Self.buttonHeight, alignment: .leading)
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
