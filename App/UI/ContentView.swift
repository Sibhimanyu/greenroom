//
//  ContentView.swift
//  Greenroom
//
//  One decision, one button: pick "New Meeting" or "Join Existing", hit
//  Start, and the whole session cascades - the picture, Zoom into
//  the meeting, Chrome tiled to its side of the screen, chat window tiled
//  to the other. Individual pieces remain available under "Manual
//  controls" for debugging; configuration lives in Settings (⌘,).
//
import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @Environment(\.openSettings) private var openSettings
    @State private var showSavePreset = false
    @State private var presetNameDraft = ""
    /// Hidden by default: the log is diagnostic detail, opened when something
    /// needs explaining. Not persisted - each launch starts compact.
    @State private var statusShown = false
    /// The window's minimum height, which TRAILS a resize instead of leading
    /// it - see resizeWindow. Starts at 0 and is set on appear.
    @State private var heldMinHeight: CGFloat = 0
    /// The same, for width: Home is narrower than the pages, so the minimum
    /// follows the window out and back instead of forcing it open first.
    @State private var heldMinWidth: CGFloat = ContentView.minimumWindowWidth
    /// The frame Home had before a page widened the window, so Back returns
    /// to it rather than to wherever the page left things.
    @State private var homeFrame: NSRect?
    /// The frame the page last settled at, to tell whether the user moved the
    /// window while on it.
    @State private var pageSettledFrame: NSRect?
    private var homeWidth: CGFloat? { homeFrame?.width }

    // Page changes (Home <-> Sessions) are one motion - see changePage. Both
    // pages are mounted for its length, each laid out at its FINAL size and
    // pinned top-leading, so the window is a curtain over fixed content and
    // nothing reflows while it moves.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var homeMounted = true
    /// Which page's toolbar is up. Follows `onPage` at the fade-out point of a
    /// page change (not at the click), so the toolbar items swap with the
    /// content instead of ahead of it.
    @State private var chromeOnPage = false
    @State private var pageMounted = false
    @State private var homeOpacity = 1.0
    /// Rest values of the page layer are the HIDDEN ones, so it is invisible
    /// on the very frame it mounts.
    @State private var pageOpacity = 0.0
    @State private var pageRise: CGFloat = Self.pageRiseDistance
    /// Non-nil only while a page change runs: the size that layer is held to.
    @State private var homePin: CGSize?
    @State private var pagePin: CGSize?
    /// Bumped by every page change and every window resize, so the steps and
    /// completion handlers of a superseded one do nothing.
    @State private var transitionToken = 0
    @State private var resizeGeneration = 0

    /// Start is for starting: disabled while a start is in flight AND
    /// while the session is live (Stop first, then Start - pressing Start
    /// mid-session used to happily build a second meeting on top).
    /// Centralized on the coordinator so the menu bar shares the SAME
    /// rules (it used to skip the credential/ID checks).
    private var startDisabled: Bool { coordinator.startActionDisabled }

    /// Says what it does: which meeting action Start performs depends on
    /// the mode picker right above it.
    private var startLabel: String {
        if coordinator.isRunning { return "Starting\u{2026}" }
        if coordinator.stageLive { return "In Session" }
        if coordinator.recordOnlyActive { return coordinator.isRecording ? "Recording" : "Ready" }
        switch coordinator.meetingMode {
        case .create: return "Start Meeting"
        case .join: return "Join Meeting"
        case .record: return "Get Ready"
        }
    }

    private var startHelp: String {
        switch coordinator.meetingMode {
        case .create:
            return "Starts your screen and camera picture, creates a fresh meeting under your Zoom account with you as host, and tiles your windows \u{2014} the whole session in one click."
        case .join:
            return "Starts your screen and camera picture, joins the meeting above (starting it as host if it's yours), and tiles your windows."
        case .record:
            return "Starts the picture set in Settings \u{2192} Webcam and opens the Record view, where you can check it and press Record when you are ready. No meeting, no windows moved."
        }
    }

    /// What is running wins over what the picker says, so flipping the picker
    /// mid-session does not relabel the buttons of the session in progress.
    private var isRecordMode: Bool {
        coordinator.recordOnlyActive
            || (coordinator.meetingMode == .record && !coordinator.stageLive)
    }

    /// Stop needs something to stop: a live session, or a start in
    /// flight (which it cancels at the next checkpoint).
    private var stopDisabled: Bool {
        coordinator.isStopping || (!coordinator.isRunning && !coordinator.sceneInUse)
    }

    /// Recording needs a live session - except when already
    /// recording, where the button must stay pressable to stop it.
    private var recordDisabled: Bool {
        coordinator.isSavingRecording || (!coordinator.stageLive && !coordinator.isRecording)
    }

    /// Names the session's folder, so a term of classes is not a wall of
    /// identical timestamps.
    ///
    /// Pre-filled from last time rather than asked for on every Start: the same
    /// class runs five mornings a week, and a dialog would spend a click a day
    /// on yesterday's answer. Shown BEFORE Start rather than after, so a wrong
    /// name is something you notice rather than something you discover in the
    /// folder afterwards.
    /// Two things, neither of which repeats the other.
    ///
    /// It was three: an eyebrow reading CLASS NAME, a placeholder reading
    /// "Class", and a preview reading "Class - 2026-09-19 08-53". The word
    /// "class" three times in one row, and a reader has to check all three to
    /// find the one that carries information.
    ///
    /// Now the placeholder says what to DO and the preview says what you will
    /// GET. The eyebrow went: a field that says "Name this class" does not
    /// also need a label saying CLASS NAME.
    @ViewBuilder private var classNameField: some View {
        HStack(spacing: 10) {
            TextField(isRecordMode ? "Name this recording" : "Name this class", text: $coordinator.className)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .disabled(coordinator.isRunning || coordinator.sceneInUse)
                .help("Names this session's folder in Documents/Greenroom. Leave it empty and the folder is named by date and time instead.")
            Text(folderPreview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("The folder this session will be saved in.")
        }
    }

    /// The folder the next Start will create, shown as you type. Cheaper than
    /// explaining the naming rule in prose, and it makes the timestamp fallback
    /// obvious the moment the field is empty.
    private var folderPreview: String {
        if let live = coordinator.sessionFolder { return live.lastPathComponent }
        return SessionFolders.sessionFolderName(className: coordinator.className, started: Date(),
                                                fallback: isRecordMode ? "Recording" : "Green")
    }

    private var onPage: Bool { !coordinator.mainPage.isHome }

    /// What Back goes to, named for its help and VoiceOver.
    private var backLabel: String {
        switch coordinator.mainPage {
        case .report: return "Session"
        case .detail, .home: return "Sessions"
        case .sessions: return "Home"
        }
    }

    private var pageSubtitle: String {
        switch coordinator.mainPage {
        case .home: return ""
        case .sessions: return "Sessions"
        case .detail: return "Session"
        case .report: return "Report"
        }
    }

    var body: some View {
        // The sizing carrier: it alone gives the window its minimum (the held
        // one, which trails a resize). The pages sit in an overlay so their
        // pinned, final sizes never push the window's minimum up mid-shrink.
        // GeometryReader rather than Color.clear: it keeps the title-bar
        // safe area the pages were always laid out inside.
        GeometryReader { _ in Color.clear }
            .frame(minWidth: heldMinWidth, maxWidth: .infinity,
                   minHeight: heldMinHeight, maxHeight: .infinity)
            .overlay(alignment: .topLeading) { pageLayers }
            .clipped()
        // The window OPENS at the preferred size every time, regardless
        // of the size it was closed at (explicit request) - SwiftUI
        // persists scene geometry across launches and defaultSize only
        // covers the first-ever open, so the size is asserted on appear.
        .onAppear {
            SessionNotes.shared.attach(coordinator)
            DispatchQueue.main.async { resizeWindow(animated: false) }
        }
        // The things that change the window's height. All grow it DOWNWARD
        // from an anchored top edge, so nothing above the divider moves - see
        // resizeWindow.
        .onChange(of: statusShown) { _, _ in resizeWindow(animated: true) }
        .onChange(of: coordinator.meetingMode) { _, _ in resizeWindow(animated: true) }
        .onChange(of: coordinator.recordStudioShown) { _, shown in
            // A recording started from the menu bar or a hotkey opens in this
            // window, on Home, wherever the window was.
            if shown { coordinator.mainPage = .home }
            resizeWindow(animated: true)
        }
        // Leaving full screen puts the window back at the frame it had going
        // in, which may be Home's size under a page: size it for the page.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === Self.window else { return }
            resizeWindow(animated: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === Self.window else { return }
            heldMinHeight = floorHeight
            heldMinWidth = floorWidth
        }
        .onChange(of: coordinator.mainPage.isHome) { _, isHome in
            // Not mid-change: the window is then part-way, not Home's width.
            let settled = homePin == nil && pagePin == nil
            if !isHome, settled, let window = Self.window, !window.styleMask.contains(.fullScreen), !window.isZoomed {
                homeFrame = window.frame
                pageSettledFrame = nil
            }
            changePage(toHome: isHome)
        }
        // The toolbar: Back (and \u{2318}[) on a page, Sessions / Setup guide /
        // Settings on Home. One unified toolbar on every page, so the title bar
        // never changes height during a page change. Subtitle only, never a
        // navigation title: the window is still found by its title.
        .pageToolbar(back: chromeOnPage ? PageBack(label: backLabel, action: { coordinator.goBack() }) : nil,
                     subtitle: coordinator.recordStudioShown && coordinator.mainPage.isHome ? RecordStudioView.subtitle(for: coordinator)
                                                : chromeOnPage ? pageSubtitle : "")
        .toolbar {
            // Record's own toolbar (Done) lives in RecordStudioContent.
            if !chromeOnPage && !coordinator.recordStudioShown {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        coordinator.mainPage = .sessions
                    } label: {
                        Label("Sessions", systemImage: "film.stack")
                    }
                    .help("Sessions: every past class, its recordings and clips with a player, its YouTube links, and a name you can change.")

                    Button {
                        coordinator.presentOnboarding()
                    } label: {
                        Label("Setup guide", systemImage: "questionmark.circle")
                    }
                    .help("Setup guide")

                    Button {
                        openSettings()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Settings")
                }
            }
        }
        .homeTitleHidden(!chromeOnPage)
        // Esc goes back too. Left to a text field that is being edited.
        .onExitCommand {
            guard onPage, !(Self.window?.firstResponder is NSText) else { return }
            coordinator.goBack()
        }
        // The toast, the upload question and the start's progress card, while
        // this window is the one in view (WindowBanner.swift).
        .overlay { WindowBannerOverlay() }
        .sheet(isPresented: $coordinator.showOnboarding) {
            OnboardingView()
                .environmentObject(coordinator)
        }
    }

    /// Home and the pages, one over the other. Mounted by state (not by
    /// `onPage`) so the outgoing one stays up for the whole change, and so a
    /// new page is mounted already at opacity 0.
    private var pageLayers: some View {
        ZStack(alignment: .topLeading) {
            if homeMounted {
                Group {
                    if coordinator.recordStudioShown {
                        RecordStudioView()
                    } else {
                        homeContent
                    }
                }
                // 32pt at the sides so nothing sits at the window's edge (20pt read as
                // about to be cut off); 20pt top and bottom, which the heights assume.
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
                .frame(minWidth: Self.minimumWindowWidth, minHeight: homeWindowHeight)
                .frame(width: homePin?.width, height: homePin?.height)
                // Pinned to the top while the window catches up to a new
                // height; otherwise the content is centred and everything
                // jumps up, then back (see resizeWindow).
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(homeOpacity)
                .allowsHitTesting(!onPage)
                .accessibilityHidden(onPage)
            }
            if pageMounted {
                // Sessions, a session, its report: pages of this window, not
                // windows of their own. Full-bleed - they draw their own
                // margins - and sized by the window, never the other way.
                RecordingsView()
                    .frame(width: pagePin?.width, height: pagePin?.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(pageOpacity)
                    .offset(y: pageRise)
                    .allowsHitTesting(onPage)
                    .accessibilityHidden(!onPage)
            }
        }
    }

    // Page change timings (seconds). DESIGN.md: 150-250ms for state changes,
    // 250ms for layout moves, ease-out in, ease-in out, ease-in-out moving.
    private static let fadeOutDuration = 0.12
    private static let growDelay = 0.08      // the window starts as Home thins out
    private static let growDuration = 0.25   // resizeWindow, ease-in-out
    private static let fadeInDelay = 0.20    // the last part of the grow
    private static let fadeInDuration = 0.2
    private static let pageRiseDistance: CGFloat = 6
    private static let changeLength = 0.40   // fadeInDelay + fadeInDuration
    private static let crossfade = 0.15      // Reduce Motion, full screen

    /// Home <-> Sessions as one motion: the outgoing page fades out, the
    /// window grows (or shrinks) over both pages held at their final sizes,
    /// then the incoming page fades in and settles 6pt up.
    ///
    /// A click mid-way simply starts the next one: every step checks the
    /// token, the opacities retarget from where they are, and the window
    /// animator retargets from its current frame.
    private func changePage(toHome isHome: Bool) {
        transitionToken += 1
        let token = transitionToken
        let window = Self.window
        defer {
            // The toolbar follows the content: at the fade-out point when it
            // moves, at once when it does not.
            if reduceMotion || !(window.map { !$0.styleMask.contains(.fullScreen) && !$0.isZoomed } ?? false) {
                chromeOnPage = !isHome
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOutDuration) {
                    if token == transitionToken { chromeOnPage = !isHome }
                }
            }
        }
        let resizes = window.map { !$0.styleMask.contains(.fullScreen) && !$0.isZoomed } ?? false
        let moving = resizes && !reduceMotion
        let inFlight = homePin != nil || pagePin != nil || homeMounted == pageMounted

        homeMounted = true
        pageMounted = true
        if !inFlight {
            homeOpacity = isHome ? 0 : 1
            pageOpacity = isHome ? 1 : 0
            pageRise = (isHome || !moving) ? 0 : Self.pageRiseDistance
        }

        func after(_ delay: Double, _ step: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if token == transitionToken { step() }
            }
        }
        func finish() {
            homePin = nil
            pagePin = nil
            if isHome {
                pageMounted = false
                pageOpacity = 0
                pageRise = Self.pageRiseDistance
            } else {
                homeMounted = false
                homeOpacity = 1
            }
        }

        // Instant resize, plain crossfade: Reduce Motion, and full screen or
        // zoomed (where the size is the user's and nothing resizes).
        guard moving, let window else {
            homePin = nil
            pagePin = nil
            resizeWindow(animated: false, returningHome: isHome)
            pageRise = 0
            withAnimation(.easeInOut(duration: Self.crossfade)) {
                homeOpacity = isHome ? 1 : 0
                pageOpacity = isHome ? 0 : 1
            }
            after(Self.crossfade) { finish() }
            return
        }

        // Pin both layers. The incoming one to the size the window will
        // settle at; the outgoing one to the size it has now (kept as is when
        // interrupted, since the window is then part-way).
        let titleBar = window.frame.height - window.contentLayoutRect.height
        let now = window.contentRect(forFrameRect: window.frame).size
        let settled = window.contentRect(forFrameRect: settledFrame(for: window, animated: true, returningHome: isHome)).size
        let target = CGSize(width: settled.width, height: settled.height - titleBar)
        let current = CGSize(width: now.width, height: now.height - titleBar)
        if isHome {
            homePin = target
            if !inFlight { pagePin = current }
        } else {
            pagePin = target
            if !inFlight { homePin = CGSize(width: homeWidth ?? now.width, height: homeWindowHeight) }
        }

        withAnimation(.easeIn(duration: Self.fadeOutDuration)) {
            if isHome { pageOpacity = 0; pageRise = Self.pageRiseDistance } else { homeOpacity = 0 }
        }
        after(Self.growDelay) { resizeWindow(animated: true, returningHome: isHome) }
        after(Self.fadeInDelay) {
            withAnimation(.easeOut(duration: Self.fadeInDuration)) {
                if isHome { homeOpacity = 1 } else { pageOpacity = 1; pageRise = 0 }
            }
        }
        after(Self.changeLength) { finish() }
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            meetingSection

            classNameField

            LookSummaryLine(change: openWebcamSettings)

            HStack(spacing: 10) {
                Button {
                    coordinator.start()
                } label: {
                    Label(startLabel, systemImage: "play.fill")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(startDisabled)
                .help(startHelp)

                // Record mode ends from its own view (Done), so a Stop here
                // would only ever be dimmed.
                if !isRecordMode {
                    Button(stopLabel) {
                        coordinator.confirmAndStop()
                    }
                    .controlSize(.large)
                    .tint(Self.secondaryTint)
                    .disabled(stopDisabled)
                    .help("Ends the meeting for everyone when you're hosting (leaves it otherwise), closes the chat window, and stops the camera. Ending the meeting from the Zoom window does the same \u{2014} both roads end the whole session.")
                }

                Spacer()

                // Record mode has its own Record button, in its own view.
                if !isRecordMode {
                    recordButton
                }
            }

            // Quiet, under Start: which layout the next class uses.
            LayoutChoiceLine()
                .padding(.top, -8)

            Divider()

            bottomBar

            if statusShown {
                statusLog
            }

            Spacer(minLength: 0)
        }
    }

    /// One compact row: logo + wordmark with the tagline
    /// UNDER the wordmark (not under the logo), so everything shares one
    /// leading edge; window controls vertically centered on the row.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            // The mark is sized to the name, as in the lockup (the name's
            // capitals are 0.55 of the mark's height); the row keeps the
            // 88pt it always had. LogoMark has a dark-appearance variant.
            Image("LogoMark")
                .resizable()
                .scaledToFit()
                .frame(height: 36)
                .frame(height: 88)
            VStack(alignment: .leading, spacing: 2) {
                // The name in one colour, as in the lockup: deep green on
                // light, white on dark (Brand.name).
                Text("Greenroom")
                    .font(.system(size: 27, weight: .bold))
                    .foregroundStyle(Brand.name)
                Text("One click: camera on, Zoom in the meeting, your windows tiled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The window's height for the current state: the controls, plus Join's
    /// two extra rows, plus the log when it is shown. Measured from the
    /// accessibility tree rather than guessed, on the 4px scale.
    private var preferredWindowHeight: CGFloat { onPage ? Self.pageHeight : homeWindowHeight }

    /// Home's own height, whichever page is up: Home is laid out at this while
    /// it fades, so it must not follow `onPage`.
    private var homeWindowHeight: CGFloat {
        // 356, not 372: the class-name row lost its eyebrow and the 4pt above
        // it, which is ~19pt of content. A height measured for a layout that
        // changed is 19pt of dead space at the bottom of the window.
        // +36 for the look summary: an 18pt row and the stack's 16pt gap,
        // rounded up to the 4px scale.
        if coordinator.recordStudioShown { return RecordStudioView.windowHeight }
        var height: CGFloat = 356 + 36
        if coordinator.meetingMode == .join { height += 64 }
        if statusShown { height += Self.statusLogHeight + 12 }
        return height
    }

    /// The width the button row needs, and therefore the window's.
    ///
    /// Worked out from the row rather than chosen: the buttons at their
    /// LONGEST labels - "Stop Recording", not "Record", and Start's 130pt
    /// floor - plus the gaps, 32pt padding each side, and enough left for
    /// the Spacer to still read as a gap.
    ///
    /// Longest labels on purpose: a window sized for the idle state reflows
    /// the moment a recording starts, which is the one moment nothing on
    /// screen should move.
    static var minimumWindowWidth: CGFloat { 744 }

    /// The pages' size: room for a grid of cards, or a 16:9 picture with its
    /// title and actions above the fold. Home's size is theirs to give back.
    private static let pageWidth: CGFloat = 1_180
    private static let pageHeight: CGFloat = 760
    /// The smallest a page is allowed to be dragged to.
    private static let pageMinWidth: CGFloat = 900
    private static let pageMinHeight: CGFloat = 600

    private static var window: NSWindow? {
        MainWindow.current
    }

    /// The least the window may be, for the page it is on. On Home that is
    /// its height for the state; on a page, the drag floor - not the page's
    /// opening size, which the user may shrink below.
    private var floorHeight: CGFloat { onPage ? Self.pageMinHeight : preferredWindowHeight }
    private var floorWidth: CGFloat { onPage ? Self.pageMinWidth : Self.minimumWindowWidth }

    /// What the window opens at: the minimum plus the 40pt of breathing room
    /// the original pair (580/620) already used.
    static var defaultWindowWidth: CGFloat { 784 }

    /// The button row's secondary buttons are neutral, so Start is the one
    /// green button. Under the app-wide green tint a bordered button draws a
    /// green label on a green wash - mint in light mode - which made the row
    /// two styles at once (enabled mint, disabled grey) and competed with
    /// Start. The label colour gives the standard grey bordered button with
    /// a label that follows the appearance.
    private static let secondaryTint = Color(nsColor: .labelColor)

    /// "Manual controls" is green TEXT, so on light it is --brand-green
    /// #2F6118 (7.38:1); the accent #5FA83C measured about 2.9:1 on white,
    /// under the bar for text (DESIGN.md). Dark keeps the accent it had -
    /// not Brand.text's lime, which read as a highlighter in the UI.
    private static let manualControlsTint = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? (NSColor(named: "AccentColor") ?? .systemGreen)
            : NSColor(srgbRed: 0x2F / 255, green: 0x61 / 255, blue: 0x18 / 255, alpha: 1)
    })

    /// Height of the open log. Eight lines.
    private static let statusLogHeight: CGFloat = 180

    /// Where the window ends up for the current page and state, top edge
    /// anchored and inside the visible frame.
    private func settledFrame(for window: NSWindow, animated: Bool, returningHome: Bool) -> NSRect {
        let content = window.contentRect(forFrameRect: window.frame)
        // Home keeps the width the user gave it; a page widens it, within the
        // screen, and Back returns Home to the width it left.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        var width: CGFloat
        if onPage {
            width = animated ? max(content.width, Self.pageWidth) : Self.pageWidth
        } else {
            width = returningHome ? (homeWidth ?? content.width)
                : animated ? content.width : Self.defaultWindowWidth
        }
        if let visible { width = min(width, visible.width) }
        // The content view is full-size: it runs under the title bar, so
        // contentRect is the whole window. preferredWindowHeight is the
        // content BELOW the title bar, so the bar's height goes on top.
        // Without it every resize aimed 32pt short of what SwiftUI would
        // allow, then snapped the rest of the way (or squeezed the content)
        // once the animation ended - the jitter on Status and on the
        // New/Join switch.
        let titleBar = window.frame.height - window.contentLayoutRect.height
        var height = preferredWindowHeight + titleBar
        if let visible { height = min(height, visible.height) }
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)).size
        // The top edge is anchored (DESIGN.md) and width changes grow around
        // the window's middle, so a page opens centred where Home was. Back
        // returns to Home's own frame unless the window was moved on the page.
        // The top edge only gives way where the bottom would leave the screen.
        if returningHome && !onPage {
            return WindowFrameRules.returningHome(
                remembered: homeFrame, size: size, current: window.frame,
                movedOnPage: WindowFrameRules.moved(from: pageSettledFrame, to: window.frame),
                visibleFrames: NSScreen.screens.map(\.visibleFrame), currentVisible: visible)
        }
        return WindowFrameRules.centred(on: window.frame, size: size, in: visible)
    }

    /// Resizes from an anchored TOP edge. AppKit's `setContentSize` keeps the
    /// bottom-left corner, so every expansion used to send the whole window
    /// climbing the screen while the rows above reflowed (reported live:
    /// "that animation where everything moves up"). Holding the top edge means
    /// the controls stay exactly where the cursor left them and only the
    /// bottom edge travels - down when the log opens, up when it closes.
    /// Width is the user's.
    private func resizeWindow(animated: Bool, returningHome: Bool = false) {
        guard let window = Self.window else { return }
        // Full screen (or zoomed to fill the screen) is the user's size, not
        // ours. Resizing here shrank the window to a page's 1180x760 and left
        // the rest of the display black. The content fills what it is given;
        // only the drag floors follow the page.
        if window.styleMask.contains(.fullScreen) || window.isZoomed {
            heldMinHeight = floorHeight
            heldMinWidth = floorWidth
            return
        }
        let frame = settledFrame(for: window, animated: animated, returningHome: returningHome)
        pageSettledFrame = onPage ? frame : nil
        guard animated else {
            resizeGeneration += 1
            window.setFrame(frame, display: true)
            heldMinHeight = floorHeight
            heldMinWidth = floorWidth
            return
        }
        // The window's minimum never outruns the window: lowered before a
        // shrink so the window can get smaller, raised only once a grow has
        // finished. Raised early, the content outgrows its frame mid-resize
        // and gets centred (see body).
        let settled = floorHeight
        let settledWidth = floorWidth
        if settled < heldMinHeight { heldMinHeight = settled }
        if settledWidth < heldMinWidth { heldMinWidth = settledWidth }
        // The animator proxy, not setFrame(_:display:animate:). That one runs
        // its own blocking loop, so the click that asked for the resize sat
        // unanswered until the window finished moving.
        resizeGeneration += 1
        let generation = resizeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.growDuration // DESIGN.md: layout moves, ease-in-out
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            // A resize that was superseded must not raise the minimum the
            // newer one lowered.
            guard generation == resizeGeneration else { return }
            heldMinHeight = settled
            heldMinWidth = settledWidth
        }
    }

    private var recordButton: some View {
        Button {
            coordinator.toggleRecording()
        } label: {
            Label(coordinator.isSavingRecording ? "Saving\u{2026}"
                    : coordinator.isRecording ? "Stop Recording" : "Record",
                  systemImage: coordinator.isSavingRecording ? "hourglass"
                    : coordinator.isRecording ? "stop.circle.fill" : "record.circle")
        }
        .controlSize(.large)
        .tint(coordinator.isRecording && !coordinator.isSavingRecording ? .red : Self.secondaryTint)
        .disabled(recordDisabled)
        .help("Records exactly what participants see \u{2014} your shared screen with you in it. Saved to Documents/Greenroom when stopped.")
    }

    private var stopLabel: String {
        if coordinator.isStopping { return isRecordMode ? "Stopping\u{2026}" : "Ending\u{2026}" }
        return isRecordMode ? "Stop" : "End Session"
    }

    /// Settings, on the Webcam tab whichever tab it was left on.
    private func openWebcamSettings() {
        openSettings()
        // After the window exists: a Settings window opened just now starts
        // on Webcam anyway, and one already open needs telling.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showWebcamSettings, object: nil)
        }
    }

    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GreenroomSegmented("Mode", selection: $coordinator.meetingMode,
                               options: Array(MeetingMode.allCases)) { Text($0.label) }

            switch coordinator.meetingMode {
            case .create:
                if coordinator.s2sAccountID.isEmpty || coordinator.s2sClientID.isEmpty {
                    Text("Needs the Server-to-Server credentials \u{2014} add them in Settings (\u{2318},) \u{2192} Zoom.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Start creates a fresh meeting under your Zoom account and opens it as host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .record:
                Text("Gets the picture set in Settings \u{2192} Webcam ready, then you press Record. No meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .join:
                // Two aligned rows instead of one crammed line: the
                // fields get room to breathe, the fill-from sources sit
                // together beneath them.
                VStack(alignment: .leading, spacing: 8) {
                    // Visible labels, not placeholder-as-label: once
                    // filled, two bare fields were indistinguishable
                    // (Codex design audit #2).
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Meeting ID").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: $coordinator.meetingNumber, prompt: Text("e.g. 465 230 8563"))
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 170)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Passcode").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: $coordinator.meetingPassword, prompt: Text("optional"))
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 130)
                        }
                    }
                    HStack(spacing: 8) {
                        presetsMenu
                        scheduledMeetingsMenu
                        Button {
                            coordinator.fillMeetingFromClipboard()
                        } label: {
                            Label("Paste Link", systemImage: "doc.on.clipboard")
                        }
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                }
                .onAppear {
                    // Pre-fetch so the menu is ready by the time it's
                    // opened - skipped silently when credentials or a
                    // read scope are missing (refresh logs the reason).
                    if coordinator.scheduledMeetings.isEmpty && !coordinator.s2sAccountID.isEmpty {
                        coordinator.refreshScheduledMeetings()
                    }
                }
            }
        }
    }

    /// The account's scheduled/recurring meetings, one click to fill the
    /// Join fields - the daily-class flow: schedule a recurring meeting
    /// once at zoom.us, then it's always right here.
    /// Saved meeting shortcuts: click one to fill the ID + passcode, or
    /// save the current fields as a new preset. Delete via each preset's
    /// context menu (right-click). Mirrors the Scheduled menu's pattern.
    private var presetsMenu: some View {
        Menu {
            if coordinator.meetingPresets.isEmpty {
                Text("No saved presets")
            } else {
                ForEach(coordinator.meetingPresets) { preset in
                    Button(preset.menuLabel) {
                        coordinator.applyPreset(preset)
                    }
                }
            }
            Divider()
            Button("Save current as preset\u{2026}") { showSavePreset = true }
                .disabled(coordinator.meetingNumberDigits.isEmpty)
            if !coordinator.meetingPresets.isEmpty {
                Menu("Delete preset") {
                    ForEach(coordinator.meetingPresets) { preset in
                        Button(preset.menuLabel, role: .destructive) {
                            coordinator.deletePreset(preset)
                        }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "bookmark")
        }
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
                    Button(scheduledMeetingLabel(meeting)) {
                        coordinator.selectScheduledMeeting(meeting)
                    }
                }
            }
            Divider()
            Button("Refresh") { coordinator.refreshScheduledMeetings() }
        } label: {
            Label("Scheduled", systemImage: "calendar")
        }
        .fixedSize()
    }

    /// Recurring meetings' times come from the per-meeting details call
    /// (their real next occurrence) - never from the list endpoint, whose
    /// recurring timestamps are the series' original anchor (confirmed
    /// live: a daily 4 PM class listed a months-old date). No time means
    /// "no fixed time", no upcoming occurrence, or a missing details
    /// scope (the status log explains that one).
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

    /// The pieces of the session as individual actions - out of the way,
    /// but there when one piece needs re-running without the rest. A
    /// pull-down, not a disclosure: three buttons that are used a few times a
    /// term do not deserve a row of the window, and a menu opens over the
    /// content instead of pushing it around.
    private var manualControlsMenu: some View {
        Menu {
            Button("Open Layout Apps") { coordinator.openMainAppWindow() }
                .disabled(!coordinator.layoutHasApps)
        } label: {
            Text("Manual controls")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .tint(Self.manualControlsTint)
        .fixedSize()
        .help("Each piece of the session on its own: the chat, the main app window, or Zoom.")
    }

    /// The row under the divider: the log's toggle on the left, the manual
    /// pull-down on the right. One fixed-height row in both states, so the
    /// only thing that changes when the log opens is what is below it.
    private var bottomBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                statusShown.toggle()
            } label: {
                HStack(spacing: 6) {
                    // One glyph, turned - not chevron.right swapped for
                    // chevron.down. The two are different widths, so the
                    // swap nudged "Status" sideways on every click.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(statusShown ? 90 : 0))
                        .frame(width: 10)
                    Text("Status")
                    // The count is a machine fact, so mono - and it is what says
                    // "something happened" while the log is closed.
                    if !coordinator.statusLines.isEmpty {
                        Text("\(coordinator.statusLines.count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                // A plain button only takes clicks on its drawn pixels, so
                // the gap between chevron and word, and the space around
                // them, used to fall through. The whole row is the target,
                // plus 4pt above and below that the layout never sees - the
                // window height is measured, and the row must not grow.
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .padding(.vertical, -4)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .help(statusShown ? "Hide the status log" : "Show what each step did and why")
            .accessibilityLabel(statusShown ? "Hide status" : "Show status")

            Spacer()
            manualControlsMenu
        }
    }

    /// The log, when shown: a fixed 180pt box under the bar. Fixed, not
    /// flexible, so the window's growth is exactly the box - and the newest
    /// line is always the one in view.
    private var statusLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if coordinator.statusLines.isEmpty {
                    // An empty state, not dead space.
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
            // Opening lands on the NEWEST line; while open, follow the tail.
            .onAppear { scrollToNewestStatus(proxy) }
            .onChange(of: coordinator.statusLines.count) { _, _ in
                scrollToNewestStatus(proxy)
            }
        }
    }

    private func scrollToNewestStatus(_ proxy: ScrollViewProxy) {
        guard let newest = coordinator.statusLines.indices.last else { return }
        // Next runloop pass, not this one: on expand the rows are created in
        // the same layout pass that runs this, and scrollTo cannot target a
        // row that does not exist yet.
        DispatchQueue.main.async {
            proxy.scrollTo(newest, anchor: .bottom)
        }
    }
}



private extension View {
    /// Hides the duplicate "Greenroom" title on Home (macOS 15+). The window's
    /// title string is untouched, so lookups by title keep working. On a page
    /// the title stays, because the subtitle sits under it.
    @ViewBuilder func homeTitleHidden(_ hidden: Bool) -> some View {
        if #available(macOS 15.0, *) {
            self.toolbar(removing: hidden ? .title : nil)
        } else {
            self
        }
    }
}
