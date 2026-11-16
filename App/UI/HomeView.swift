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
    /// The picture is hidden until asked for (DESIGN.md, 2026-11-14): the
    /// owner's choice, kept per Mac by ContentView, which also grows the window.
    @Binding var previewShown: Bool
    /// Whether the card is drawn. It outlives `previewShown` by the window's
    /// shrink, so a collapse reveals nothing but a closing curtain.
    let previewMounted: Bool

    /// Height of the open log. Eight lines.
    static let statusLogHeight: CGFloat = 180
    /// Home is a compact options column (DESIGN.md, 2026-11-14): this wide (the window is 592 so the
    /// toolbar fits),
    /// with the 16:9 picture card beside it only when Preview is pressed.
    static let contentWidth: CGFloat = 496
    /// Space between the column and the card, and the card's width: 16:9 of
    /// the column's height, so the card's top meets the logo and its bottom
    /// meets the Start button.
    static let cardGutter: CGFloat = 24
    static var cardWidth: CGFloat { (columnHeight * 16 / 9).rounded() }
    /// What the window gains when the card shows.
    static var previewExtraWidth: CGFloat { cardGutter + cardWidth }
    /// Fixed heights of the column's parts: brand 42, name 32, summary 32,
    /// the Ready / Preview row 26, button 32, with 16pt between them.
    static let brandHeight: CGFloat = 42
    static let fieldHeight: CGFloat = 32
    /// The setup dock: one row of icon buttons with the value under each
    /// (owner, 2026-11-16, "B · Dock"), 6pt inside its plate.
    static let dockHeight: CGFloat = 70
    static let readyHeight: CGFloat = 24
    static let readyRowHeight: CGFloat = 26
    /// A standard macOS 26 large control.
    static let largeControlHeight: CGFloat = 32
    static let buttonHeight: CGFloat = 32
    static let columnGap: CGFloat = 16
    /// The column's rhythm (owner, 2026-11-14): logo to name 16, name to setup
    /// 12, setup to the Ready row 12, Ready row to the button 16.
    static let brandGap: CGFloat = 16
    static let fieldGap: CGFloat = 12
    static let summaryGap: CGFloat = 12
    static let readyGap: CGFloat = 16
    /// Top margin under the toolbar and bottom margin under the last element.
    static let verticalMargin: CGFloat = 24
    static var columnHeight: CGFloat {
        brandHeight + fieldHeight + dockHeight + readyRowHeight + buttonHeight
            + brandGap + fieldGap + summaryGap + readyGap
    }
    /// The button fills the column (false: sized to its label, at the left).
    static let primaryFullWidth = true

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
    @State private var lookOpen = false
    @State private var recordOpen = false
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
        // One column, top to bottom. Extra window height is shared out above
        // and below the block, so a tall window never leaves dead space under
        // only one end.
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Self.cardGutter) {
                    setupColumn
                        .frame(width: Self.contentWidth)
                    if previewMounted {
                        // Level with the logo at the top and the Start button
                        // at the bottom (the column's height is the card's).
                        pictureCard
                            .frame(width: Self.cardWidth)
                            .transition(.opacity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if statusShown {
                    statusLog.frame(width: blockWidth).padding(.top, 12)
                }
                if let lastSession {
                    // The column's own width, so the block stays one width
                    // and centres: a wider footer made the stack take its
                    // width and pushed the column to the left (owner, 2026-11-14).
                    footer(lastSession)
                        .frame(width: blockWidth)
                        .padding(.top, 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
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
        // The camera starts only from the person pressing Preview, and stops
        // when it folds (or Home goes away, or a start begins).
        .onChange(of: previewShown) { _, shown in if shown { startLive() } else { stopLive() } }
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
            refreshShareLists()
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
        .overlay(alignment: .bottomLeading) {
            if previewShown, !showLive, let problem = cameraProblem {
                HStack(spacing: 6) {
                    Text(problem.text).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    if let fixer = problem.fix {
                        Button("Open Settings") { fix(fixer) }
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Brand.text)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .colorScheme(.dark)
                .padding(10)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: liveFrameReady)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(showLive ? "Live preview of the picture" : "Picture people will see: \(lookText)")
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

    /// A quiet glass capsule in the Ready row that grows the window to the
    /// right for the picture, and folds it away again.
    private var previewButton: some View {
        Button { previewShown.toggle() } label: {
            Label(previewShown ? "Hide preview" : "Preview",
                  systemImage: previewShown ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: Self.readyRowHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .greenroomGlass(in: Capsule(), interactive: true)
        .fixedSize()
        .help(previewShown ? "Hide the picture and turn the camera off"
                           : "Show the picture people will see. This turns the camera on.")
        .accessibilityLabel(previewShown ? "Hide preview" : "Preview")
        .accessibilityHint(previewShown ? "Narrows the window, hides the picture and turns the camera off"
                                        : "Widens the window and turns the camera on to show the picture people will see")
    }

    /// Pressing Preview is the explicit ask: it starts the same live preview the
    /// Webcam page and the Record view use (`startShapePreview`). Never on a
    /// launch, never on a mere appearance of Home. A camera that cannot start
    /// shows its reason in the card instead.
    private func startLive() {
        #if DEBUG
        if Self.debugSkipLive { return }
        #endif
        guard !showLive, !isLive, cameraProblem == nil else { return }
        showLive = true
        coordinator.startShapePreview()
    }

    #if DEBUG
    /// The tour expands the card without turning the owner's camera on.
    static var debugSkipLive = false
    #endif

    /// Why the picture cannot be live, in words; nil when it can.
    private var cameraProblem: (text: String, fix: Fix?)? {
        if cameraAccess == .denied || cameraAccess == .restricted {
            return ("Camera unavailable: access is turned off", .cameraPrivacy)
        }
        if cameras.isEmpty { return ("Camera unavailable: no camera found", nil) }
        return nil
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
        VStack(alignment: .leading, spacing: 0) {
            brand
            nameSection.padding(.top, Self.brandGap)
            setupSection.padding(.top, Self.fieldGap)
            HStack(spacing: 8) {
                readyRow
                previewButton
            }
            .frame(height: Self.readyRowHeight)
            .padding(.top, Self.summaryGap)
            actionRow.padding(.top, Self.readyGap)
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
                    .textFieldStyle(.greenroom)
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
                    .textFieldStyle(.greenroom)
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
                .textFieldStyle(.greenroom)
                .controlSize(.large)
                .frame(height: Self.fieldHeight)
                .disabled(isLive)
                .onSubmit(submit)
                .accessibilityLabel("Name")
                .help("Names this session's folder in Documents/Greenroom. Leave it empty and the folder is named by date and time, as shown.")
        }
    }

    // MARK: Setup: the dock

    /// Every setting in one row, each one click from its picker: no Edit step
    /// (owner, 2026-11-16, "B · Dock"). A setting that needs attention wears an
    /// amber dot; recording with the meeting lights its button green.
    private var setupSection: some View {
        HStack(spacing: 2) {
            lookControl
            shareChip
            cameraChip
            micChip
            layoutChip
            if mode != .record { recordControl }
        }
        .padding(6)
        .frame(height: Self.dockHeight)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quinary.opacity(0.7))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        }
    }

    /// A share target that has gone away (the app quit, its window closed).
    private var shareGone: Bool {
        let share = coordinator.shareTarget
        let kind: SetupSummary.ShareKind
        switch share.kind {
        case .display: kind = .display
        case .app: kind = .app
        case .window: kind = .window
        case .whiteboard: kind = .whiteboard
        case .nothing: kind = .nothing
        }
        return SetupSummary.shareIsGone(kind: kind, appBundleID: share.appBundleID,
                                        windowTitle: share.windowTitle,
                                        runningApps: apps.map(\.bundleID),
                                        openWindows: windows.map { ($0.bundleID, $0.title) })
    }

    /// Short enough for the dock; the help says what the class would see.
    private var shareValue: String {
        shareGone ? "Not open" : LookSummary.shareText(coordinator.shareTarget)
    }

    /// The readiness problem that belongs to one dock button, if any.
    private func problem(_ id: String) -> Bool {
        readiness.contains { $0.id == id && $0.problem != nil }
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

    /// One dock button's face: a rounded orb with the glyph, the current value
    /// under it. `lit` fills the orb green (a setting that acts on its own);
    /// `warn` adds an amber dot and turns the value amber.
    private func dockLabel(symbol: String, value: String, lit: Bool = false, warn: Bool = false,
                           meter: Double? = nil) -> some View {
        DockFace(symbol: symbol, value: value, lit: lit, warn: warn, meter: meter)
    }

    /// "MacBook Pro Camera" is "MacBook Pro" on the tile; the hover help and
    /// VoiceOver keep the full name.
    private static func shortDeviceName(_ name: String) -> String {
        for suffix in [" Camera", " Microphone", " Mic"] where name.hasSuffix(suffix) && name.count > suffix.count {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// A submenu's title with the tick when the current pick is inside it.
    @ViewBuilder private func checkedLabel(_ title: String, _ checked: Bool) -> some View {
        if checked { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func pickDisplay(_ id: String) {
        coordinator.screenCaptureDisplayUUID = id
        coordinator.shareTarget.kind = .display
        coordinator.requestShapeApply(rebuild: true)
    }

    private func choice(_ title: String, selected: Bool, disabled: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .disabled(disabled)
    }

    /// Look: the shapes as swatches in a popover, one click each.
    private var lookControl: some View {
        Button { lookOpen.toggle() } label: {
            dockLabel(symbol: Self.symbol(for: coordinator.webcamShape),
                      value: coordinator.cameraIsOff ? "No camera" : coordinator.webcamShape.label)
        }
        .buttonStyle(DockButtonStyle())
        .disabled(coordinator.cameraIsOff)
        .popover(isPresented: $lookOpen, arrowEdge: .bottom) { lookPicker }
        .help(coordinator.cameraIsOff ? "No camera is picked, so there is no look to choose."
                                      : "Look: \(coordinator.webcamShape.label). How you appear over what you share.")
        .accessibilityLabel("Look")
        .accessibilityValue(coordinator.webcamShape.label)
    }

    private var lookPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOOK")
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(WebcamShape.allCases) { shape in
                    let chosen = coordinator.webcamShape == shape
                    Button {
                        coordinator.webcamShape = shape
                        coordinator.requestShapeApply()
                        lookOpen = false
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: Self.symbol(for: shape))
                                .font(.system(size: 22, weight: .regular))
                                .frame(width: 58, height: 40)
                            Text(shape.label)
                                .font(.system(size: 11, weight: chosen ? .semibold : .regular))
                                .foregroundStyle(chosen ? .primary : .secondary)
                        }
                        .padding(.vertical, 6)
                        .frame(width: 70)
                    }
                    .greenroomTile(role: .choice(selected: chosen), radius: 10)
                    .help(shape.label)
                }
            }
            Button("More look settings\u{2026}") { lookOpen = false; openWebcamSettings() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.text)
        }
        .padding(14)
    }

    /// Share target: the Webcam page's "Behind you". One pick says both what
    /// kind and which one: "One window" opens the window list itself, so
    /// choosing a window is the whole job, as in the control bar's Present menu.
    private var shareChip: some View {
        let share = coordinator.shareTarget
        return Menu {
            // Whole screen: a list of displays only when there is a choice.
            if displays.count > 1 {
                Menu {
                    choice("Automatic (your main display)",
                           selected: share.kind == .display && coordinator.screenCaptureDisplayUUID.isEmpty) {
                        pickDisplay("")
                    }
                    ForEach(displays) { display in
                        choice(display.label,
                               selected: share.kind == .display && coordinator.screenCaptureDisplayUUID == display.id) {
                            pickDisplay(display.id)
                        }
                    }
                } label: { checkedLabel(ShareTarget.Kind.display.label, share.kind == .display) }
            } else {
                choice(ShareTarget.Kind.display.label, selected: share.kind == .display) { pickDisplay("") }
            }
            Menu {
                if apps.isEmpty { Text("No other app is open") }
                ForEach(apps, id: \.bundleID) { app in
                    choice(app.name, selected: share.kind == .app && share.appBundleID == app.bundleID) {
                        coordinator.shareTarget.kind = .app
                        coordinator.shareTarget.appBundleID = app.bundleID
                        coordinator.shareTarget.appName = app.name
                        coordinator.shareTarget.windowTitle = ""
                        coordinator.requestShapeApply(rebuild: true)
                    }
                }
            } label: { checkedLabel(ShareTarget.Kind.app.label, share.kind == .app) }
            Menu {
                if windows.isEmpty { Text("No window to share") }
                ForEach(windows) { window in
                    choice((window.title.isEmpty ? window.appName : "\(window.appName) \u{2013} \(window.title)")
                           + window.placement.menuSuffix,
                           selected: share.kind == .window && share.appBundleID == window.bundleID
                               && share.windowTitle == window.title) {
                        coordinator.shareTarget.kind = .window
                        coordinator.shareTarget.appBundleID = window.bundleID
                        coordinator.shareTarget.appName = window.appName
                        coordinator.shareTarget.windowTitle = window.title
                        coordinator.requestShapeApply(rebuild: true)
                    }
                }
            } label: { checkedLabel(ShareTarget.Kind.window.label, share.kind == .window) }
            ForEach([ShareTarget.Kind.whiteboard, .nothing], id: \.self) { kind in
                choice(kind.label, selected: share.kind == kind,
                       disabled: kind == .nothing && coordinator.cameraIsOff) {
                    coordinator.shareTarget.kind = kind
                    coordinator.requestShapeApply(rebuild: true)
                }
            }
            // One app is drawn on one display; which, when there is a choice.
            if share.kind == .app && displays.count > 1 {
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
            dockLabel(symbol: Self.symbol(for: coordinator.shareTarget.kind), value: shareValue,
                      warn: shareGone || problem("screen"))
        }
        .dockMenu()
        .help(shareGone ? SetupSummary.shareGoneHelp
              : problem("screen") ? "Greenroom needs Screen Recording permission to share. The line under the dock opens it."
              : "Share: \(shareValue). What the class sees behind you.")
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
            dockLabel(symbol: coordinator.cameraIsOff ? "video.slash" : "camera",
                      value: coordinator.cameraIsOff ? "Off" : Self.shortDeviceName(name),
                      warn: problem("camera") || (cameras.isEmpty && !coordinator.cameraIsOff))
        }
        .dockMenu()
        .help(cameras.isEmpty && !coordinator.cameraIsOff ? SetupSummary.cameraMissingHelp
              : "Camera: \(name). Which camera you appear on.")
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
            dockLabel(symbol: "mic", value: Self.shortDeviceName(name), warn: problem("mic"), meter: micMeterLevel)
        }
        .dockMenu()
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
            // What the Start button's chevron used to hold, under a heading
            // ("Manual controls") nobody could read. It belongs to the layout,
            // so it lives with it, and only when there is something to open.
            if let template = coordinator.layoutLibrary.active, template.pieceCount > 0 {
                Button("Show on Screen") {
                    LayoutPageContent.showOnScreen(template, customUIMode: coordinator.customUIMode,
                                                   canMoveApps: AppWindowManager.hasAccessibilityPermission)
                }
                .help("Preview this layout on your screen")
            }
            if coordinator.layoutHasApps {
                Button("Open This Layout\u{2019}s Apps") { coordinator.openMainAppWindow() }
                    .help("Opens the layout\u{2019}s apps in their places now, without starting a class.")
            }
            Button("More\u{2026}") {
                openSettings()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .showSettingsTab, object: "layout")
                }
            }
        } label: {
            dockLabel(symbol: "rectangle.split.2x1", value: coordinator.layoutChoiceName)
        }
        .dockMenu()
        .disabled(coordinator.layoutChoiceLocked)
        .help(coordinator.layoutChoiceLocked
              ? "A class runs the layout it started with. Pick the next one after it ends."
              : "Where Start puts the meeting, the chat and your apps.")
        .accessibilityLabel("Layout")
        .accessibilityValue(coordinator.layoutChoiceName)
    }

    /// Record: whether recording starts with the meeting (Settings → Webcam's
    /// "Record automatically with the meeting"). Lit green while it does, so a
    /// recording that starts by itself is never a surprise.
    private var recordControl: some View {
        let on = coordinator.autoRecordOnStart
        return Button { recordOpen.toggle() } label: {
            dockLabel(symbol: on ? "record.circle.fill" : "record.circle",
                      value: on ? "With meeting" : "By hand", lit: on)
        }
        .buttonStyle(DockButtonStyle())
        .disabled(isLive)
        .popover(isPresented: $recordOpen, arrowEdge: .bottom) { recordPicker }
        .help(on ? SetupSummary.autoRecordHelp : "Recording starts when you press Record.")
        .accessibilityLabel("Record")
        .accessibilityValue(on ? "With the meeting" : "When I press it")
    }

    private var recordPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECORD")
                .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                recordChoice(true, symbol: "record.circle.fill", title: "With the meeting",
                             detail: "Starts by itself")
                recordChoice(false, symbol: "hand.tap", title: "When I press it",
                             detail: "You start it")
            }
        }
        .padding(14)
    }

    private func recordChoice(_ value: Bool, symbol: String, title: String, detail: String) -> some View {
        let chosen = coordinator.autoRecordOnStart == value
        return Button {
            coordinator.autoRecordOnStart = value
            recordOpen = false
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(value ? Color.red.opacity(0.85) : Color.secondary)
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(width: 140, alignment: .leading)
        }
        .greenroomTile(role: .choice(selected: chosen), radius: 10)
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

    /// The status line's ready state: a green dot and words. Its click shows
    /// what each step did (the status log).
    private var readyChip: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { statusShown.toggle() }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(Brand.green).frame(width: 7, height: 7)
                    .background(Circle().fill(Brand.green.opacity(0.2)).frame(width: 13, height: 13))
                Text("Ready to start").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(height: Self.readyHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(statusShown ? "Ready. Click to hide the status details."
                          : "Ready: Zoom, camera, microphone and screen are fine. Click for the status details.")
        .accessibilityLabel("Ready to start")
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
            return "Brings up the picture set in Settings \u{2192} Webcam, counts down on the notch, then records. The recording bar controls it. No meeting, no windows moved."
        }
    }

    /// One button that follows the mode, a single rounded shape. No chevron:
    /// its menu held one item under a "Manual controls" heading that read as
    /// a second, mystery way to start; opening the layout's apps is in the
    /// Layout chip's menu now. Content-sized, Brand green in every mode
    /// (Record is marked by its red dot only).
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
                .padding(.horizontal, 16)
                .frame(maxWidth: Self.primaryFullWidth ? .infinity : nil)
                .frame(height: Self.largeControlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(startDisabled)
            .help(primaryHelp)
        }
        .foregroundStyle(.white)
        .background(Capsule().fill(Brand.green.opacity(startDisabled ? 0.4 : 1)))
        .clipShape(Capsule())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: mode)
        // The column keeps its 44pt slot (the window's height is arithmetic
        // from it); the standard 32pt large control sits in it.
        .frame(maxWidth: Self.primaryFullWidth ? nil : .infinity, minHeight: Self.buttonHeight, alignment: .leading)
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

    /// The width of the whole block: the column, plus the picture when shown.
    private var blockWidth: CGFloat {
        Self.contentWidth + (previewMounted ? Self.cardGutter + Self.cardWidth : 0)
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
                // No "All sessions" link: the toolbar's Sessions button is
                // that, and three ways to the same place was one too many
                // (owner, 2026-11-16).
                Spacer(minLength: 0)
            }
            .font(.callout)
        }
    }

    /// Newest session on disk, its length read from the recording. Off the main
    /// thread: the library walks the folders and the length opens a file.
    private func loadLastSession() {
        Task.detached(priority: .utility) {
            let all = ScreenroomLibrary.presentations()
            guard let newest = all.first else {
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

    /// Both lists, whatever is picked now: the Share menu offers every app and
    /// every window at once. Set only when they changed, so the 2s tick does
    /// not redraw Home for nothing.
    private func refreshShareLists() {
        let freshApps = ShareTarget.runningApps()
        if freshApps.map(\.bundleID) != apps.map(\.bundleID) || freshApps.map(\.name) != apps.map(\.name) {
            apps = freshApps
        }
        var seen = Set<String>()
        let freshWindows = ShareTarget.windows().filter { seen.insert($0.key).inserted }
        if freshWindows != windows { windows = freshWindows }
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
    /// A dock button that opens a menu.
    func dockMenu() -> some View {
        self.menuStyle(.button)
            .buttonStyle(DockButtonStyle())
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

/// A dock button: no box at rest, a soft wash under the pointer, the orb
/// lifts 1pt. Under Reduce Motion only the wash changes.
private struct DockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DockBody(configuration: configuration)
    }

    private struct DockBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .environment(\.dockLift, hovering && enabled && !reduceMotion)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.quaternary.opacity(hovering && enabled ? 1 : 0))
                }
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

private struct DockLiftKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var dockLift: Bool {
        get { self[DockLiftKey.self] }
        set { self[DockLiftKey.self] = newValue }
    }
}

/// The face of a dock button: orb and value, the whole cell clickable.
private struct DockFace: View {
    let symbol: String
    let value: String
    var lit = false
    var warn = false
    var meter: Double?
    @Environment(\.dockLift) private var lift

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(lit ? AnyShapeStyle(Brand.green) : AnyShapeStyle(.quaternary))
                    .frame(width: 36, height: 34)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(lit ? Color.white : Color.primary)
                    }
                if warn {
                    Circle().fill(Brand.net)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 3, y: -3)
                }
            }
            .offset(y: lift ? -1 : 0)
            HStack(spacing: 3) {
                Text(value)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(warn ? Brand.netText : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let meter { MiniMeter(level: meter) }
            }
            .padding(.horizontal, 3)
        }
        .padding(.top, 4)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}
