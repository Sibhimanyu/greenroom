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
//  The card draws the look from the working copy's own numbers
//  (`WebcamShapePreview`), so the camera is NOT on just because Home is
//  visible. "Show live" asks for the same preview Settings -> Layouts and the
//  Record view use (`startShapePreview`) and it is turned off again when
//  Home goes away or a start begins.
//
//  Nothing here owns logic. Each chip writes the working-copy setting Layouts
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
    /// The picture is hidden until asked for (DESIGN.md, 2026-11-14): the
    /// owner's choice, kept per Mac by ContentView, which also grows the window.
    @Binding var previewShown: Bool
    /// Whether the card is drawn. It outlives `previewShown` by the window's
    /// shrink, so a collapse reveals nothing but a closing curtain.
    let previewMounted: Bool
    /// The picture's real aspect, reported up so the window can size the card.
    @Binding var pictureAspect: CGFloat

    /// Height of the open log. Eight lines.
    static let statusLogHeight: CGFloat = 180
    /// Home is a compact options column (DESIGN.md, 2026-11-14): this wide (the window is 592 so the
    /// toolbar fits),
    /// with the 16:9 picture card beside it only when Preview is pressed.
    static let contentWidth: CGFloat = 496
    /// Space between the window's edge and the content, each side (owner,
    /// 2026-11-17: no wide dead margins). The column takes whatever width the
    /// window has beyond its natural one.
    static let sideMargin: CGFloat = 24
    /// The window's width with nothing but the content in it.
    static var naturalCollapsedWidth: CGFloat { contentWidth + sideMargin * 2 }
    /// Space between the column and the card, and the card's width: 16:9 of
    /// the column's height, so the card's top meets the logo and its bottom
    /// meets the Start button.
    static let cardGutter: CGFloat = 24
    /// The card is sized from its picture: the column's height less the
    /// eyebrow, times the picture's real aspect, so no width is left over.
    static func cardWidth(aspect: CGFloat) -> CGFloat {
        PreviewFrameRules.cardWidth(columnHeight: columnHeight, eyebrow: eyebrowSpace, aspect: aspect)
    }
    /// What the window gains when the card shows.
    static func previewExtraWidth(aspect: CGFloat) -> CGFloat { cardGutter + cardWidth(aspect: aspect) }
    /// The aspect assumed until the first frame arrives: the main display's.
    static var defaultPictureAspect: CGFloat {
        PreviewFrameRules.defaultAspect(screen: NSScreen.main?.frame.size)
    }
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

    @State private var scheduledSheet: NewScheduledMeetingSheet.Mode?
    @State private var showLive = false
    /// The live preview was asked for but no picture came, even after one
    /// automatic restart: the card says so and offers Try again.
    @State private var previewStalled = false
    /// This Home's claim on the shared preview (CoordinatorController.PreviewViewer).
    @State private var previewID = UUID()
    /// What the preview card shows: the picture the class sees, or how your
    /// screen is laid out (owner, 2026-11-16: "preview the layout and all").
    @State private var cameras: [LocalDeviceResolver.Camera] = []
    @State private var microphones: [LocalDeviceResolver.Microphone] = []
    @State private var displays: [DisplayInfo] = []
    @State private var apps: [(bundleID: String, name: String)] = []
    @State private var windows: [ShareTarget.Window] = []
    @State private var walkingWindows = false
    @State private var screenAllowed = StageCompositor.screenRecordingGranted
    @State private var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var micAccess = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var lookOpen = false
    @State private var cameraOpen = false
    @State private var shareOpen = false
    @State private var layoutOpen = false
    @State private var recordOpen = false
    @State private var micOpen = false
    @State private var moreOpen = false
    /// Only ever started while a session is live, when the microphone is
    /// already in use: see `micMeter`. Held, not observed: the level changes
    /// about 47 times a second, and only `LiveMiniMeter` watches it, so Home
    /// does not redraw (and re-resolve its layout) on every one. Made on first
    /// use, since it owns an audio engine.
    @State private var meter: MicLevelMonitor?

    // MARK: Derived

    private var startDisabled: Bool { coordinator.startActionDisabled }
    private var isLive: Bool { coordinator.phase.isInMeeting }
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
                        .frame(minWidth: Self.contentWidth, maxWidth: .infinity)
                    if previewMounted {
                        // Level with the logo at the top and the Start button
                        // at the bottom (the column's height is the card's).
                        pictureCard
                            .frame(width: Self.cardWidth(aspect: pictureAspect))
                            .transition(.opacity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                if statusShown {
                    statusLog.frame(maxWidth: .infinity).padding(.top, 12)
                }
            }
            // Side margins come from ContentView (one value, sideMargin).
            Spacer(minLength: 0)
        }
        // The window sizes the card from the picture's real shape.
        .onChange(of: frameAspect) { _, a in
            // Only a real picture moves it (PreviewFrameRules.heldAspect): leaving for a
            // page stops the camera, and the default aspect then reset the card wider than
            // the window Home returns to.
            let held = PreviewFrameRules.heldAspect(current: pictureAspect, live: aspectKnown ? a : nil)
            if held != pictureAspect { pictureAspect = held }
            if aspectKnown { coordinator.lastPictureAspect = held }
        }
        .onAppear {
            coordinator.loadSecretsIfNeeded()
            refreshDevices()
            refreshPermissions()
            refreshShareLists()
            if coordinator.stageLive { startMeter() }
            // The card opens with Home (owner, 2026-11-16), so its picture is live too.
            if previewShown { startLive() }
        }
        .onDisappear {
            stopLive()
            meter?.stop()
        }
        // The camera runs while the card is open on Home, and stops when it
        // folds (or Home goes away, or a start begins).
        .onChange(of: previewShown) { _, shown in if shown { startLive() } else { stopLive() } }
        .onChange(of: coordinator.isRunning) { _, running in
            if running { stopLive() } else if previewShown, coordinator.mainPage.isHome { startLive() }
        }
        .onChange(of: coordinator.mainPage.isHome) { _, home in
            if !home { stopLive() } else if previewShown, !coordinator.isRunning { startLive() }
        }
        .onChange(of: coordinator.stageLive) { _, live in
            if live { startMeter() } else { meter?.stop() }
        }
        .onChange(of: coordinator.shareTarget.kind) { _, _ in refreshShareLists() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            refreshPermissions()
            refreshShareLists()
            keepPreviewHonest()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshDevices() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayResolver.connectedDisplays()
        }
        #if DEBUG
        // DebugTour `popup name=`: opens one dock popup, as its button does.
        .onReceive(NotificationCenter.default.publisher(for: .debugTourPopup)) { note in
            let name = note.userInfo?["name"] as? String ?? ""
            lookOpen = name == "look"; cameraOpen = name == "camera"; shareOpen = name == "share"
            layoutOpen = name == "layout"; recordOpen = name == "record"; micOpen = name == "mic"
            moreOpen = name == "more"
        }
        #endif
    }

    // MARK: Left: the picture

    private var liveFrameReady: Bool { showLive && coordinator.shapePreviewAspect != nil }

    /// One card: the live picture, with the layout outlined on the screen in
    /// it (owner, 2026-11-16: no Picture / Screen switch).
    private var pictureCard: some View {
        // The label sits above the picture, left-aligned with it; the picture
        // takes the screen's own shape (no bars) and the pair is centred in
        // the slot, which is as tall as the column.
        GeometryReader { geo in
            let fit = PreviewOutlineRules.fit(
                frameAspect, in: CGRect(x: 0, y: 0, width: geo.size.width,
                                        height: max(geo.size.height - Self.eyebrowSpace, 1)))
            VStack(alignment: .leading, spacing: Self.eyebrowGap) {
                eyebrow.frame(height: Self.eyebrowHeight)
                pictureFace(size: fit.size)
                previewFooter
            }
            .frame(width: fit.width, height: fit.height + Self.eyebrowSpace)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(height: Self.columnHeight)
    }

    static let eyebrowHeight: CGFloat = 14
    static let eyebrowGap: CGFloat = 6
    static let footerHeight: CGFloat = 20
    /// Always reserved, so the picture does not change size when the row comes or goes.
    static var eyebrowSpace: CGFloat { eyebrowHeight + eyebrowGap * 2 + footerHeight }

    /// DESIGN.md eyebrow: mono, uppercase, .08em, 10pt, in the text green;
    /// the red dot says it is live. Only while there is a live picture (the
    /// space is kept either way, so the picture does not jump).
    @ViewBuilder private var eyebrow: some View {
        if liveFrameReady {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 6, height: 6)
                Text("LIVE PREVIEW")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Brand.text)
            }
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        } else {
            Color.clear
        }
    }

    /// What of the canvas the picture shows: the shared content when there
    /// is some, else all of it. Nothing to crop until the picture is up.
    private var previewCrop: CGRect {
        guard liveFrameReady else { return PreviewFrameRules.crop(content: nil, presenter: false) }
        return PreviewFrameRules.crop(content: coordinator.shapePreviewContent,
                                      presenter: coordinator.stageLayout.cameraShape == .presenterLarge)
    }

    private var frameAspect: CGFloat {
        let canvasAspect = coordinator.shapePreviewAspect.map { $0.width / max($0.height, 1) } ?? 16.0 / 9.0
        return aspectKnown ? PreviewFrameRules.aspect(canvasAspect: canvasAspect, crop: previewCrop)
            : Self.defaultPictureAspect
    }

    /// A picture whose shape is real: up, and (for a screen share) with its
    /// content rect known. Until then the card keeps its last shape.
    private var aspectKnown: Bool {
        liveFrameReady && !PreviewFrameRules.awaitingContent(
            capturesScreen: coordinator.shareTarget.kind.capturesScreen,
            presenter: coordinator.stageLayout.cameraShape == .presenterLarge,
            content: coordinator.shapePreviewContent)
    }

    /// The shared screen, when the picture shows one (Whole screen or One app):
    /// the layout's places only line up with a picture of the display.
    private var sharedScreen: NSScreen? {
        guard [.display, .app].contains(coordinator.shareTarget.kind)  else { return nil }
        return DisplayResolver.screen(forUUID: coordinator.effectiveCaptureDisplayUUID)
            ?? DisplayResolver.mainDisplayScreen()
    }

    /// The active layout's places on the shared screen, as fractions of it
    /// (top-left origin), named as Show on screen names them.
    private var layoutOutlines: [(id: Int, rect: CGRect, title: String)] {
        guard let screen = sharedScreen, let template = coordinator.layoutLibrary.active else { return [] }
        let s = screen.frame
        let items = LayoutScreenPreview.items(for: template) {
            LayoutPageContent.look($0, canMoveApps: AppWindowManager.hasAccessibilityPermission)
        }
        return items.enumerated().compactMap { index, item in
            PreviewOutlineRules.fraction(of: item.frame, on: s).map { (index, $0, item.title) }
        }
    }

    /// The row under the picture, from the layout in effect (the same resolver
    /// Start uses, against the displays connected now); nil when it places no windows.
    private var previewRow: PreviewSecondDisplayRules.Row? {
        guard let template = coordinator.layoutLibrary.active else { return nil }
        // ADR 0002: only what is placed now counts, so pieces on a second display that is not
        // connected do not make a row.
        let result = LayoutResolver.resolve(
            template, screens: LayoutEngine.connectedScreens(),
            primaryHeight: DisplayResolver.mainDisplayScreen()?.frame.height ?? 0)
        let second = result.placed.filter { $0.slot == .second }.map { $0.piece.kind.isMeeting }
        return PreviewSecondDisplayRules.row(for: template, secondPieceIsMeeting: second, placedPieceCount: result.placed.count)
    }

    /// Under the picture, never over it: the second-display note, and the
    /// same Show on screen the Layouts page and the Layout tile use.
    @ViewBuilder private var previewFooter: some View {
        let template = coordinator.layoutLibrary.active
        let room = template.flatMap {
            RoomDisplayNote.note(for: $0, connectedDisplays: displays.count, isMirrored: DisplayResolver.hasMirroredDisplay())
        }
        // R36.2: one note at a time: the room display, then the share hint, then the second display. The room
        // note stands on its own, so a layout that places no window still says its Room screen has no display.
        if let template, let footer = ShareHintRules.footer(
            hasRow: previewRow != nil, room: room?.text,
            hint: ShareHintRules.hint(kind: coordinator.shareTarget.kind, appName: shareAppName),
            secondDisplay: previewRow?.note) {
            HStack(spacing: 8) {
                switch footer.note {
                case .room:
                    // R15.2: calm, amber small text; Start is never blocked.
                    if let room {
                        Label(room.text, systemImage: "display")
                            .font(.system(size: 11)).foregroundStyle(Brand.netText).lineLimit(1)
                            .help(RoomDisplayNote.hint)
                        Button("Open Displays settings") {
                            if let url = URL(string: RoomDisplayNote.openDisplaysSettingsURL) { NSWorkspace.shared.open(url) }
                        }
                        .buttonStyle(.link).font(.system(size: 11))
                    }
                case let .hint(text):
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.tail).help(text)
                case let .secondDisplay(note):
                    Label(note, systemImage: "display")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                case nil:
                    EmptyView()
                }
                Spacer(minLength: 0)
                if footer.showsOutline {
                    Button {
                        LayoutPageContent.showOnScreen(template,
                                                       canMoveApps: AppWindowManager.hasAccessibilityPermission)
                    } label: {
                        Label(VisibilitySymbol.showOnScreen.words, systemImage: VisibilitySymbol.showOnScreen.name)
                            .font(.system(size: 11, weight: .medium))
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Show on screen: outline where each window of this layout will go")
                    .accessibilityLabel(VisibilitySymbol.showOnScreen.words)
                }
            }
            .frame(height: Self.footerHeight)
        } else {
            Color.clear.frame(height: Self.footerHeight)
        }
    }

    /// Green outlines over the screen in the picture, where each window goes.
    @ViewBuilder private var layoutOverlay: some View {
        if liveFrameReady, let screen = sharedScreen {
            let outlines = layoutOutlines
            GeometryReader { geo in
                // The picture (a 16:9 canvas) sits fitted in the card, and the
                // screen sits fitted in the picture, with bars at its sides;
                // Presenter puts the screen in a box at the right.
                let crop = previewCrop
                let cropped = crop.width < 0.999 || crop.height < 0.999
                let frames = PreviewOutlineRules.frames(
                    card: geo.size, canvasAspect: coordinator.shapePreviewAspect.map { $0.width / max($0.height, 1) },
                    screen: screen.frame.size, presenter: coordinator.stageLayout.cameraShape == .presenterLarge)
                // Cropped to the screen: the whole frame IS the screen.
                let canvas = cropped ? PreviewFrameRules.canvasRect(frame: CGRect(origin: .zero, size: geo.size), crop: crop)
                                     : frames.canvas
                let shown = cropped ? CGRect(origin: .zero, size: geo.size) : frames.screen
                ZStack {
                ForEach(outlines, id: \.id) { outline in
                    let box = PreviewOutlineRules.place(outline.rect, in: shown).insetBy(dx: 1.5, dy: 1.5)
                    // Names at the top right: clear of LIVE PREVIEW and of you.
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Brand.green.opacity(0.12))
                        RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Brand.green, lineWidth: 1.5)
                        if box.width > 50, box.height > 22 {
                            Text(outline.title)
                                .font(.system(size: 10.5, weight: .semibold))
                                .lineLimit(1)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.black.opacity(0.72)))
                                .padding(4)
                        }
                    }
                    .frame(width: max(box.width, 0), height: max(box.height, 0))
                    .position(x: box.midX, y: box.midY)
                }
                }
                // The outlines are on the screen, so they pass under you: the
                // compositor's own camera alpha (your cutout, the bubble) is
                // cut out of them, frame by frame.
                .mask { CameraOpenMask(feed: coordinator.shapePreview, canvas: canvas) }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    /// Drag your camera in the picture: it moves for everyone, live.
    @ViewBuilder private var cameraDragLayer: some View {
        let layout = coordinator.stageLayout
        if liveFrameReady, layout.isPresencePlaceable {
            let crop = previewCrop
            let cropped = crop.width < 0.999 || crop.height < 0.999
            PreviewCameraDragLayer(
                box: layout.presenceBox, shape: layout.cameraShape,
                aspect: layout.cameraShape.cropsToSquare ? 1 : 16.0 / 9.0,
                content: cropped ? coordinator.shapePreview.contentRect : nil,
                onStep: { coordinator.previewPlacementStep($0) },
                onCommit: { coordinator.commitPreviewPlacement($0, source: .home) },
                everyoneSees: !coordinator.cameraIsOff, onMyScreen: coordinator.cameraState.iSee)
        }
    }

    private func pictureFace(size: CGSize) -> some View {
        ZStack {
            // Plain black fills the whole card in every state, so the picture
            // fades in from it on show and out to it on hide or quit, and
            // nothing else ever flashes between (owner, 2026-11-24).
            Color.black
            if liveFrameReady {
                CroppedLivePicture(feed: coordinator.shapePreview, crop: previewCrop)
                layoutOverlay
                cameraDragLayer
            } else if showLive, previewStalled {
                HStack(spacing: 8) {
                    Text("The preview didn\u{2019}t start")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("Try again") { retryPreview() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Brand.text)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.55), in: Capsule())
                .colorScheme(.dark)
            } else if showLive {
                ProgressView().controlSize(.small).colorScheme(.dark)
                    .padding(10)
                    .background(.black.opacity(0.55), in: Capsule())
            }
        }
        // A safety net: waiting 3s with no picture restarts the preview once;
        // 3s more and the card says so instead of spinning for ever.
        .task(id: showLive) {
            previewStalled = false
            guard showLive else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, showLive, !liveFrameReady else { return }
            coordinator.revivePreviewIfStalled(evenIfRunning: true)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, showLive, !liveFrameReady else { return }
            previewStalled = true
        }
        .onChange(of: liveFrameReady) { _, ready in if ready { previewStalled = false } }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1))
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

    /// The open card starts the same live preview Settings -> Layouts and the
    /// Record view use (`startShapePreview`): on Home appearing with the card
    /// open, or on pressing Preview. A camera that cannot start shows its
    /// reason in the card instead.
    private func startLive() {
        #if DEBUG
        if Self.debugSkipLive { return }
        #endif
        guard !showLive, !isLive, cameraProblem == nil else { return }
        showLive = true
        coordinator.startShapePreview(for: .home(previewID))
    }

    /// The card says live only when it is: every 2 seconds, an open card on
    /// Home with nothing live starts its picture if it is off, and claims it
    /// again if something else let go of it (owner, 2026-11-16: after a
    /// meeting ended the card stayed on the drawing).
    private func keepPreviewHonest() {
        guard previewShown, coordinator.mainPage.isHome, !isLive, !coordinator.isStopping else { return }
        if !showLive {
            startLive()
        } else if !coordinator.isShowingPreview(for: .home(previewID)) {
            coordinator.startShapePreview(for: .home(previewID))
        }
    }

    /// Try again on a stalled card: restart the picture and wait once more.
    private func retryPreview() {
        previewStalled = false
        coordinator.revivePreviewIfStalled(evenIfRunning: true)
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if showLive, !liveFrameReady { previewStalled = true }
        }
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
    /// on: Settings -> Layouts shares the one preview and holds its own claim on it.
    private func stopLive() {
        guard showLive else { return }
        showLive = false
        coordinator.stopShapePreview(for: .home(previewID))
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
            // One row, so Scheduled is as tall as New and Record and the two
            // columns stay level: one picker styled like the other fields.
            scheduledRow
            .labelStyle(.iconOnly)
            .frame(height: Self.fieldHeight)
            .onAppear {
                // Pre-fetch so the menu is ready by the time it is opened;
                // skipped silently when credentials or a scope are missing.
                if coordinator.scheduledMeetings.isEmpty && coordinator.zoomHostingReady {
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
                .help("Names this session's folder in Documents/Greenroom. Leave it empty and the folder is named Green or Recording, with the date and time.")
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
            moreControl
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
        shareGone ? "Not open" : ShareHintRules.tileLabel(kind: coordinator.shareTarget.kind, appName: shareAppName)
    }

    private var shareAppName: String {
        coordinator.shareTarget.appBundleID.isEmpty ? "" : coordinator.shareTarget.displayName
    }

    /// The readiness problem that belongs to one dock button, if any.
    private func problem(_ id: String) -> Bool {
        readiness.contains { $0.id == id && $0.problem != nil }
    }

    /// The folder the next Start will create, as the placeholder.
    private var folderPreview: String {
        if let live = coordinator.sessionFolder { return live.lastPathComponent }
        // Not started yet: ask for a name in words. Left empty, the folder is
        // still named by date and time (the help says so).
        if coordinator.className.isEmpty { return "Meeting name (optional)" }
        return SessionFolders.sessionFolderName(className: coordinator.className, started: Date(),
                                                fallback: mode == .record ? "Recording" : "Green")
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
    private func dockLabel(symbol: String, symbolBadge: String? = nil, value: String, lit: Bool = false,
                           warn: Bool = false, meter: MicLevelMonitor? = nil) -> some View {
        DockFace(symbol: symbol, symbolBadge: symbolBadge, value: value, lit: lit, warn: warn, meter: meter)
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
        let state = CameraTileRules.state(cameraIsOff: coordinator.cameraIsOff, deviceCount: cameras.count)
        return Button {
            if CameraTileRules.tapTurnsCameraOn(state) { turnCameraOn() }
            lookOpen.toggle()
        } label: {
            dockLabel(symbol: CameraTileRules.symbol(state, onSymbol: Self.symbol(for: coordinator.webcamShape)),
                      symbolBadge: CameraTileRules.badge(state),
                      value: CameraTileRules.value(state, onValue: coordinator.webcamShape.label))
        }
        .buttonStyle(DockButtonStyle())
        .disabled(!CameraTileRules.isEnabled(state))
        .greenroomPopover(isPresented: $lookOpen) { lookPicker }
        // The panel explains itself (header line, value), so no hover card.
        // To bring a tile's hover card back, add `.dockHint(DockHintContent(...))` here.
        .help(state == .noDevice ? CameraTileRules.noDeviceHelp
              : state == .offBySetting ? CameraTileRules.offHelp
              : "Look: how you appear over what you share.")
        .accessibilityLabel("Look")
        .accessibilityValue(coordinator.webcamShape.label)
    }

    private var lookPicker: some View {
        HomeTilePanel(
            title: "Look", summary: "How you appear over what you share.", value: coordinator.webcamShape.label,
            moreTitle: "More look settings\u{2026}", onMore: { lookOpen = false; openCameraSettings() },
            width: nil
        ) {
            CameraShapeTiles(selected: coordinator.webcamShape, autofocus: true) { shape in
                coordinator.webcamShape = shape
                coordinator.requestShapeApply()
                lookOpen = false
            }
        }
    }

    /// Share target: what is shared ("Everyone sees this" in Layouts), as a panel (HomeScreenPanel):
    /// four choice tiles, displays, windows by app, slide-show follow.
    private var shareChip: some View {
        Button { shareOpen.toggle() } label: {
            dockLabel(symbol: Self.symbol(for: coordinator.shareTarget.kind), value: shareValue,
                      warn: shareGone || problem("screen"))
        }
        .buttonStyle(DockButtonStyle())
        .greenroomPopover(isPresented: $shareOpen) {
            HomeScreenPanel(coordinator: coordinator, displays: displays, windows: windows,
                            gone: shareGone, permissionMissing: problem("screen"), value: shareValue,
                            cameraCount: cameras.count,
                            more: { shareOpen = false; openCameraSettings() },
                            close: { shareOpen = false })
        }
        // The panel explains itself, so no hover card (see lookControl).
        .help(shareGone ? SetupSummary.shareGoneHelp
              : problem("screen") ? "Screen: Greenroom needs Screen Recording permission to share. The line under the dock opens it."
              : "Screen: what everyone sees behind you.")
        .accessibilityLabel("Behind you")
        .accessibilityValue(LookSummary.shareText(coordinator.shareTarget))
    }

    /// This meeting only (the camera state's live change); the saved default is untouched.
    private func turnCameraOn() { coordinator.turnCameraOnFromHome() }

    /// Camera: the same list and the same rule as Settings -> Devices' cards.
    /// The tile's icon: no camera connected, else the camera state's own (R17.3).
    private var chipMeaning: VisibilitySymbol {
        CameraTileRules.chipMeaning(state: coordinator.cameraState, noDevice: cameras.isEmpty && !coordinator.cameraIsOff,
                                    videoStopped: coordinator.videoStopped)
    }

    private var cameraChip: some View {
        let name = LookSummary.cameraText(coordinator, cameras: cameras)
        let warn = problem("camera") || (cameras.isEmpty && !coordinator.cameraIsOff)
        return Button { cameraOpen.toggle() } label: {
            dockLabel(symbol: chipMeaning.name, symbolBadge: chipMeaning.badge,
                      value: CameraTileRules.chipValue(state: coordinator.cameraState, cameraInPicture: !coordinator.cameraIsOff,
                                                       deviceName: Self.shortDeviceName(name),
                                                       videoStopped: coordinator.videoStopped),
                      warn: warn)
        }
        .buttonStyle(DockButtonStyle())
        .greenroomPopover(isPresented: $cameraOpen) {
            HomeCameraPanel(coordinator: coordinator, cameras: cameras) {
                cameraOpen = false
                openSettingsTab("devices")
            }
        }
        // The panel explains itself, so no hover card (see lookControl).
        .help(coordinator.videoStopped ? "\(StopVideoRules.stoppedWords). \(StopVideoRules.stopNote)"
              : cameras.isEmpty && !coordinator.cameraIsOff ? SetupSummary.cameraMissingHelp
              : coordinator.cameraIsOff ? "Camera: \(coordinator.cameraState.name). \(coordinator.cameraState.detail)"
              : "Camera: \(name). Which camera you appear on.")
        .accessibilityLabel("Camera")
        .accessibilityValue(CameraTileRules.chipValue(state: coordinator.cameraState, cameraInPicture: !coordinator.cameraIsOff,
                                                      deviceName: name, videoStopped: coordinator.videoStopped))
    }

    /// Microphone: system default or one pinned device, as Settings -> Devices.
    /// The level meter appears only while the microphone is already in use
    /// (a live session); Home never opens it on its own.
    private var micChip: some View {
        let name = LookSummary.microphoneText(uid: coordinator.micDeviceUID, microphones: microphones,
                                              system: AVCaptureDevice.default(for: .audio)?.localizedName)
        return Button { micOpen.toggle() } label: {
            dockLabel(symbol: "mic", value: micCaption(name), warn: problem("mic"), meter: micMeter)
        }
        .buttonStyle(DockButtonStyle())
        .greenroomPopover(isPresented: $micOpen) {
            HomeMicPanel(coordinator: coordinator, microphones: microphones,
                         systemName: AVCaptureDevice.default(for: .audio)?.localizedName) {
                micOpen = false
                openSettingsTab("devices")
            }
        }
        // The panel explains itself, so no hover card (see lookControl).
        .help("Microphone: \(name). Which microphone everyone hears, and the recording takes.")
        .accessibilityLabel("Microphone")
        .accessibilityValue(name)
    }

    /// The tile's caption. The same laptop is often the camera and the
    /// microphone, and two tiles saying "MacBook Pro" tell nobody which is
    /// which, so the mic says "Mic" when the names would match.
    private func micCaption(_ name: String) -> String {
        let short = Self.shortDeviceName(name)
        let camera = Self.shortDeviceName(LookSummary.cameraText(coordinator, cameras: cameras))
        return short == camera ? "Mic" : short
    }

    private func pickMic(_ uid: String) {
        coordinator.micDeviceUID = uid
        coordinator.previewCamerasChanged()
    }

    /// Only the system's input, which is what the monitor listens to, and only
    /// while a session has the microphone open already.
    private var micMeter: MicLevelMonitor? {
        coordinator.stageLive && coordinator.micDeviceUID.isEmpty ? meter : nil
    }

    private func startMeter() {
        if meter == nil { meter = MicLevelMonitor() }
        meter?.start()
    }

    /// Layout: tiles with diagrams in a panel (HomeLayoutPanel). The tile
    /// stays clickable mid-meeting so the panel can say why the choices are off.
    private var layoutChip: some View {
        Button { layoutOpen.toggle() } label: {
            dockLabel(symbol: "rectangle.split.2x1",
                      value: coordinator.layoutChoiceName == "None" ? "No layout" : coordinator.layoutChoiceName)
        }
        .buttonStyle(DockButtonStyle())
        .greenroomPopover(isPresented: $layoutOpen) {
            HomeLayoutPanel(coordinator: coordinator, more: {
                layoutOpen = false
                openSettings()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .showSettingsTab, object: "layout")
                }
            }, close: { layoutOpen = false })
        }
        // The panel explains itself, so no hover card (see lookControl).
        .help(coordinator.layoutChoiceLocked ? "Layout: \(LayoutPanelRules.lockedNote)"
              : "Layout: where Start puts the meeting, the chat and your apps.")
        .accessibilityLabel("Layout")
        .accessibilityValue(coordinator.layoutChoiceName)
    }

    /// Record: whether recording starts with the meeting (Settings → Devices'
    /// "Record automatically with the meeting"). Lit green while it does, so a
    /// recording that starts by itself is never a surprise.
    private var recordControl: some View {
        let on = coordinator.autoRecordOnStart
        return Button { recordOpen.toggle() } label: {
            dockLabel(symbol: "record.circle", value: on ? "Auto-rec" : "Manual rec", lit: on)
        }
        .buttonStyle(DockButtonStyle())
        .disabled(isLive)
        .greenroomPopover(isPresented: $recordOpen) {
            HomeRecordPanel(coordinator: coordinator, isLive: isLive) {
                recordOpen = false
                openSettingsTab("devices")
            }
        }
        // The panel explains itself, so no hover card (see lookControl).
        .help(on ? SetupSummary.autoRecordHelp : "Recording starts when you press Record.")
        .accessibilityLabel("Record")
        .accessibilityValue(on ? "With the meeting" : "When I press it")
    }

    /// More: every other setting, in Settings (owner, 2026-11-16).
    private var moreControl: some View {
        Button { moreOpen.toggle() } label: {
            dockLabel(symbol: "ellipsis", value: "More")
        }
        .buttonStyle(DockButtonStyle())
        .greenroomPopover(isPresented: $moreOpen) {
            HomeMorePanel(
                openTab: { tab in
                    moreOpen = false
                    openSettings()
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .showSettingsTab, object: tab)
                    }
                },
                setupGuide: {
                    moreOpen = false
                    coordinator.presentOnboarding()
                },
                allSettings: {
                    moreOpen = false
                    openSettings()
                })
        }
        // The panel explains itself, so no hover card (see lookControl).
        .help("More: every other setting, camera, layouts, shortcuts, Zoom, YouTube and more.")
        .accessibilityLabel("More settings")
    }

    private static func symbol(for shape: WebcamShape) -> String { CameraShapeTiles.symbol(for: shape) }

    private static func symbol(for kind: ShareTarget.Kind) -> String {
        switch kind {
        case .display: return VisibilitySymbol.share.name
        case .app: return "macwindow"
        case .window: return "macwindow.on.rectangle"
        case .whiteboard: return "pencil.and.outline"
        case .nothing: return VisibilitySymbol.shareNothing.name
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
            let sdk = !coordinator.zoomSDKReady
            let host = !coordinator.zoomHostingReady
            let missing = mode == .create ? (sdk || host) : sdk
            items.append(ReadinessItem(id: "zoom", title: "Zoom", problem: missing ? (ZoomRouteWords.homeProblem(coordinator.zoomRoute) ?? "Zoom: sign in") : coordinator.zoomRouteAttention))
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
        case .join: return "Start Meeting"
        case .record: return "Start Recording"
        }
    }

    private var primaryHelp: String {
        switch mode {
        case .create:
            return "Starts your screen and camera picture, creates a fresh meeting under your Zoom account with you as host, and tiles your windows \u{2014} the whole session in one click."
        case .join:
            return "Starts your screen and camera picture, starts the chosen meeting with you as host, and tiles your windows."
        case .record:
            return "Brings up the picture set in Settings \u{2192} Layouts, counts down on the notch, then records. The recording bar controls it. No meeting, no windows moved."
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
        .background(Capsule().fill(Brand.buttonFill.opacity(startDisabled ? 0.4 : 1)))
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
        case .join: Image(systemName: "play.fill")
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
                // Asks in place: pressed once it names what the second press does.
                Label(coordinator.isStopping ? "Ending\u{2026}"
                        : coordinator.exitAsk != nil ? "Confirm: \(coordinator.exitConfirmHelp)"
                        : coordinator.stageLive ? "End Session" : "Stop",
                      systemImage: coordinator.exitAsk != nil ? "exclamationmark.circle.fill" : "stop.fill")
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
            .disabled(coordinator.isSavingRecording || coordinator.phase.hasNoLiveMeetingOrTake)
            .help("Records exactly what participants see \u{2014} your shared screen with you in it. Saved to Documents/Greenroom when stopped.")
        }
        .controlSize(.extraLarge)
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

    // MARK: Scheduled picker

    private var selectedScheduledMeeting: ZoomServerToServerClient.ScheduledMeeting? {
        let digits = coordinator.meetingNumberDigits
        guard !digits.isEmpty else { return nil }
        return coordinator.scheduledMeetings.first { String($0.id) == digits }
    }

    private var hasS2SCredentials: Bool {
        coordinator.zoomHostingReady
    }

    /// One full-width picker in the field's own look: calendar symbol, the
    /// chosen meeting (or the placeholder), a chevron.
    private var scheduledPicker: some View {
        let chosen = selectedScheduledMeeting
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Menu {
            if coordinator.scheduledMeetings.isEmpty {
                if coordinator.isLoadingScheduled {
                    Text("Loading\u{2026}")
                } else if !hasS2SCredentials {
                    Button("Add your Zoom account in Settings \u{2192} Zoom") { fix(.zoomSettings) }
                } else {
                    Text("No scheduled meetings on this Zoom account. Schedule one in Zoom, then Refresh.")
                }
            } else {
                ForEach(coordinator.scheduledMeetings) { meeting in
                    Button {
                        coordinator.selectScheduledMeeting(meeting)
                    } label: {
                        if chosen?.id == meeting.id {
                            Label(scheduledMeetingLabel(meeting), systemImage: "checkmark")
                        } else {
                            Text(scheduledMeetingLabel(meeting))
                        }
                    }
                }
            }
            Divider()
            Button("Refresh") { coordinator.refreshScheduledMeetings() }
            Text(MeetingMode.scheduledHelp)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(chosen.map(scheduledMeetingLabel) ?? scheduledPlaceholder)
                    .font(.system(size: 14))
                    .foregroundStyle(chosen == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity)
            .frame(height: Self.fieldHeight)
            .background { shape.fill(.quinary) }
            .overlay { shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5) }
            .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(isLive)
        .opacity(isLive ? 0.6 : 1)
        .help("Choose one of the meetings scheduled on your Zoom account")
        .accessibilityLabel("Scheduled meeting")
    }

    /// Nothing scheduled yet (loaded, credentials present): say so, and the +
    /// button turns green.
    private var noScheduledYet: Bool {
        hasS2SCredentials && coordinator.scheduledMeetings.isEmpty && !coordinator.isLoadingScheduled
    }

    private var scheduledPlaceholder: String {
        noScheduledYet ? "No scheduled meetings yet" : "Choose a scheduled meeting"
    }

    /// The row: the picker, then Edit and New as square buttons in the same
    /// field look. Both vanish without Zoom credentials.
    private var scheduledRow: some View {
        HStack(spacing: 8) {
            scheduledPicker
            if hasS2SCredentials {
                scheduledSquare("pencil", help: "Edit this meeting", highlight: false,
                                disabled: isLive || selectedScheduledMeeting == nil) {
                    if let m = selectedScheduledMeeting { scheduledSheet = .edit(m.id) }
                }
                scheduledSquare("plus", help: "New scheduled meeting", highlight: noScheduledYet,
                                disabled: isLive) { scheduledSheet = .new }
            }
        }
        .sheet(item: $scheduledSheet) { mode in
            NewScheduledMeetingSheet(mode: mode).environmentObject(coordinator)
        }
    }

    private func scheduledSquare(_ symbol: String, help: String, highlight: Bool, disabled: Bool,
                                 action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(highlight ? Color.white : Color.primary)
                .frame(width: Self.fieldHeight, height: Self.fieldHeight)
                .background { shape.fill(highlight ? AnyShapeStyle(Brand.buttonFill) : AnyShapeStyle(.quinary)) }
                .overlay { shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5) }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .help(help)
        .accessibilityLabel(help)
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
    /// not redraw Home for nothing. Windows arrive a moment later.
    private func refreshShareLists() {
        let freshApps = ShareTarget.runningApps()
        if freshApps.map(\.bundleID) != apps.map(\.bundleID) || freshApps.map(\.name) != apps.map(\.name) {
            apps = freshApps
        }
        // The window list is the slow one (it walks every window on the
        // system), so it is read off the main thread; one walk at a time.
        guard !walkingWindows else { return }
        walkingWindows = true
        let sizes = NSScreen.screens.map(\.frame.size)
        Task.detached(priority: .utility) {
            var seen = Set<String>()
            let fresh = ShareTarget.windows(displaySizes: sizes).filter { seen.insert($0.key).inserted }
            await MainActor.run {
                walkingWindows = false
                if fresh != windows { windows = fresh }
            }
        }
    }

    /// The camera look lives in Layouts now: the camera piece, selected.
    private func openCameraSettings() { openSettingsTab(SettingsTabs.cameraLookID) }

    /// Settings on the named tab (`SettingsTabs`), e.g. "devices".
    private func openSettingsTab(_ tab: String) {
        openSettings()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showSettingsTab, object: tab)
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

/// Watches the microphone monitor on its own, so a level change redraws these
/// bars and nothing else. Drawn only once a tap is genuinely running.
private struct LiveMiniMeter: View {
    @ObservedObject var monitor: MicLevelMonitor

    var body: some View {
        if monitor.isRunning { MiniMeter(level: monitor.level) }
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
    var symbolBadge: String?
    let value: String
    var lit = false
    var warn = false
    var meter: MicLevelMonitor?
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
                            .symbolBadge(symbolBadge, size: 9)
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
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
                if let meter { LiveMiniMeter(monitor: meter) }
            }
            .padding(.horizontal, 3)
        }
        .padding(.top, 4)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// White wherever the picture's cameras did not draw, fitted to the canvas:
/// masks Home's layout outlines so they pass behind you. Its own view so it
/// follows the preview feed frame by frame.
private struct CameraOpenMask: View {
    @ObservedObject var feed: ShapePreviewFeed
    let canvas: CGRect

    var body: some View {
        if let open = feed.openMask {
            Image(nsImage: open).resizable()
                .frame(width: canvas.width, height: canvas.height)
                .position(x: canvas.midX, y: canvas.midY)
        } else {
            Color.white
        }
    }
}
