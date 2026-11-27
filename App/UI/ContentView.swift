//
//  ContentView.swift
//  Greenroom
//
//  One decision, one button: pick "New Meeting", "My Meetings" or "Record"
//  in the toolbar, hit the button, and the whole session cascades - the picture, Zoom into
//  the meeting, Chrome tiled to its side of the screen, chat window tiled
//  to the other. The layout's apps can be opened on their own from the
//  Layout chip's menu; configuration lives in Settings (⌘,).
//  Home itself is HomeView.swift.
//
import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @EnvironmentObject private var editor: EditorViewModel
    @Environment(\.openSettings) private var openSettings
    /// Hidden by default: the log is diagnostic detail, opened when something
    /// needs explaining. Not persisted - each launch starts compact.
    @State private var statusShown = false
    /// Home's five setup tiles unfolded; per launch, collapsed by default.
    /// The window's minimum height, which TRAILS a resize instead of leading
    /// it - see resizeWindow. Starts at 0 and is set on appear.
    @State private var heldMinHeight: CGFloat = 0
    /// The same, for width: Home is narrower than the pages, so the minimum
    /// follows the window out and back instead of forcing it open first.
    @State private var heldMinWidth: CGFloat = ContentView.defaultWindowWidth
    /// The frame Home had before a page widened the window, so Back returns
    /// to it rather than to wherever the page left things.
    @State private var homeFrame: NSRect?
    /// The frame the page last settled at, to tell whether the user moved the
    /// window while on it.
    @State private var pageSettledFrame: NSRect?
    /// Home's content height when `homeFrame` was captured, so Back restores
    /// the identical size while Home's state is unchanged (the title bar is
    /// measured differently on a page, so recomputing it can drift).
    @State private var homeFrameContentHeight: CGFloat?
    private var homeWidth: CGFloat? { homeFrame?.width }

    /// Home's picture card: open on every launch, live (owner, 2026-11-16;
    /// supersedes 2026-11-14's "collapsed on launch"). Hide preview folds it
    /// for this run. `previewMounted` lags a collapse by the window's shrink,
    /// so the card is drawn until the curtain has closed on it.
    @State private var previewShown = true
    @State private var previewMounted = true
    /// The picture's aspect, which sizes the card and so the window. The main
    /// display's until the first frame, so the width does not jump then.
    @State private var pictureAspect: CGFloat = HomeView.defaultPictureAspect
    /// The frame the window had before the card opened, to give back exactly.
    @State private var previewRestoreFrame: NSRect?
    /// The frame the opening settled at, to tell whether the window was moved.
    @State private var previewExpandedFrame: NSRect?
    /// The frame the window had when Hide preview was pressed, and the one the
    /// hide settled at: Show gives the first back exactly while the second is
    /// untouched (WindowFrameRules.expandedFrame(restoring:)).
    @State private var previewFrameBeforeHide: NSRect?
    @State private var previewHiddenFrame: NSRect?
    /// The seeded aspect is not a change of shape: no resize for it.
    @State private var seedingAspect = false

    // The window's root is a NavigationSplitView (see body), so the system
    // draws the Sessions sidebar as the full-height floating panel with the
    // traffic lights inside it. Its column exists for the Sessions pages only.
    @StateObject private var sidebarModel = SessionsSidebarModel()
    /// The person's choice (Command-B, the system toggle). Saved, as in Finder.
    @AppStorage(SidebarRules.hiddenKey) private var sidebarHidden = false
    /// The sidebar column's real width, measured from the detail column once a
    /// page has settled: the pages' pinned sizes and the window's minimum
    /// subtract it. The ideal until measured.
    @State private var sidebarWidth = SidebarRules.idealWidth

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

    private var onPage: Bool { !coordinator.mainPage.isHome }

    /// The editor's Back goes through its own "Discard your edits?" question
    /// (a request the editor answers), and Esc is the editor's own key.
    private var isEditorPage: Bool {
        if case .editor = coordinator.mainPage { return true }
        return false
    }

    /// What Back goes to, named for its help and VoiceOver.
    private var backLabel: String {
        switch coordinator.mainPage {
        case .report, .editor: return "Session"
        case .detail, .home: return "Sessions"
        case .sessions: return "Home"
        }
    }

    /// Home has no page name. A Debug build shows the branch and commit it was
    /// built from (written into Info.plist by project.yml's "Stamp the Debug
    /// build" phase), so a running copy is never mistaken for another
    /// worktree's. Compiled out of Release.
    private var homeSubtitle: String {
        #if DEBUG
        return Bundle.main.object(forInfoDictionaryKey: "GreenroomDebugBuild") as? String ?? ""
        #else
        return ""
        #endif
    }

    private var pageSubtitle: String {
        switch coordinator.mainPage {
        case .home: return ""
        case .sessions: return "Sessions"
        case .detail: return ""   // the watch page names itself in its header
        case .report: return "Report"
        case .editor: return ""   // the page names itself, and the switch says Edit
        }
    }

    /// Sidebar for the Sessions pages, detail-only on Home and Record. Follows
    /// `chromeOnPage`, so the column appears and goes at the fade-out point of
    /// a page change, while Home is invisible, not at the click.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { SidebarRules.visibility(onSessionsPage: chromeOnPage, hidden: sidebarHidden,
                                           onSingleSession: onSingleSession) },
            set: { sidebarHidden = SidebarRules.hidden(afterVisibility: $0, onSessionsPage: chromeOnPage,
                                                       was: sidebarHidden,
                                                       onSingleSession: onSingleSession) })
    }

    /// A session's page or its report: no sidebar (the watch page).
    private var onSingleSession: Bool {
        switch coordinator.mainPage {
        case .detail, .report, .editor: return true
        case .home, .sessions: return false
        }
    }

    private var sidebarShown: Bool {
        SidebarRules.shown(onSessionsPage: chromeOnPage, hidden: sidebarHidden, onSingleSession: onSingleSession)
    }

    var body: some View {
        // The window's ROOT content is the split view: only then does macOS 26
        // draw the sidebar from the very top with the traffic lights in it, and
        // keep the toolbar over the detail column. (An earlier attempt let a
        // nested split view ignore the top safe area; it did not work.)
        NavigationSplitView(columnVisibility: columnVisibility) {
            SessionsSidebar(model: sidebarModel)
                // Home and Record have no sidebar to toggle. Documented home of
                // the removal: the sidebar column's content.
                .toolbar(removing: chromeOnPage && !onSingleSession ? nil : .sidebarToggle)
        } detail: {
            detailColumn
        }
        .environmentObject(sidebarModel)
        // After a class or a take: what to do with the recording.
        .overlay {
            if let finished = coordinator.finishedSession {
                SessionFinishedCard(coordinator: coordinator, session: finished)
            }
        }
        .animation(.easeOut(duration: 0.2), value: coordinator.finishedSession)
        // Upload to YouTube: the after-session card and the session page open it.
        .sheet(item: $coordinator.youtubeUploadDraft) { draft in
            YouTubeUploadSheet(draft: draft)
                .environmentObject(coordinator)
        }
        // Control-Command-S, the system's own sidebar key, which the single
        // View menu item (SidebarCommands) no longer carries. Present but
        // invisible: the menu shows one item.
        .background {
            Button("") { sidebarHidden.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!chromeOnPage || onSingleSession)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // The window OPENS at the preferred size every time, regardless
        // of the size it was closed at (explicit request) - SwiftUI
        // persists scene geometry across launches and defaultSize only
        // covers the first-ever open, so the size is asserted on appear.
        .onAppear {
            SessionNotes.shared.attach(coordinator)
            coordinator.warmUpForStart()
            // A recreated window knows the picture's shape already: place it
            // at that width from the start, not at the display's.
            if let known = coordinator.lastPictureAspect, abs(known - pictureAspect) > 0.001 {
                seedingAspect = true
                pictureAspect = known
            }
            DispatchQueue.main.async {
                resizeWindow(animated: false)
                Self.centreWindow()
                seedingAspect = false
            }
        }
        // The things that change the window's height. All grow it DOWNWARD
        // from an anchored top edge, so nothing above the divider moves - see
        // resizeWindow.
        .onChange(of: statusShown) { _, _ in resizeWindow(animated: true) }
        // Edit grows about the middle, not down from the top (owner, 2026-11-16).
        .onChange(of: previewShown) { _, shown in previewChanged(shown) }
        // The picture's shape changed (the share target did): the card, and
        // so the window, follows, the left edge staying put.
        .onChange(of: pictureAspect) { old, new in aspectChanged(from: old, to: new) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugTourHomePreview)) { note in
            HomeView.debugSkipLive = (note.userInfo?["camera"] as? Bool) == false
            previewShown = (note.userInfo?["shown"] as? Bool) ?? false
        }
        #endif
        .onChange(of: coordinator.meetingMode) { _, _ in resizeWindow(animated: true) }
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
                homeFrameContentHeight = homeWindowHeight
                pageSettledFrame = nil
            }
            changePage(toHome: isHome)
        }
        // Esc goes back too. Left to a text field that is being edited.
        .onExitCommand {
            guard onPage, !isEditorPage, !(Self.window?.firstResponder is NSText) else { return }
            coordinator.goBack()
        }
        // The toast, the upload question and the start's progress card, while
        // this window is the one in view (WindowBanner.swift).
        // The setup guide is a window of its own, centred on this one, not a
        // sheet: the sheet was taller than this window and shoved it up.
        .onChange(of: coordinator.showOnboarding, initial: true) { old, show in
            OnboardingWindowController.shared.sync(show: show, coordinator: coordinator, atLaunch: old == show)
        }
    }

    /// The detail column: the sizing carrier, the pages, and the toolbar. The
    /// toolbar is declared here, so its items sit over this column (Finder's
    /// arrangement) and never over the sidebar.
    private var detailColumn: some View {
        // The sizing carrier: it alone gives the window its minimum (the held
        // one, which trails a resize). The pages sit in an overlay so their
        // pinned, final sizes never push the window's minimum up mid-shrink.
        // GeometryReader rather than Color.clear: it keeps the title-bar
        // safe area the pages were always laid out inside. The minimum is the
        // window's minus the sidebar column, so the window as a whole keeps
        // the 900pt page minimum with the sidebar showing.
        GeometryReader { geo in
            Color.clear.onChange(of: geo.size.width) { _, width in noteDetailWidth(width) }
        }
            .frame(minWidth: SidebarRules.detailMinWidth(windowMin: heldMinWidth, sidebarShown: sidebarShown,
                                                         sidebarWidth: sidebarWidth),
                   maxWidth: .infinity,
                   // The split view counts the title bar twice in the window's
                   // minimum (held + 104, measured with `cmd=tree`), which left
                   // Home squeezed and its margins uneven; take one off.
                   minHeight: max(0, heldMinHeight - Self.titleBarCredit), maxHeight: .infinity)
            .overlay(alignment: .topLeading) { pageLayers }
            .clipped()
        // The toolbar: Back (and \u{2318}[) on a page, Sessions / Setup guide /
        // Settings on Home. One unified toolbar on every page, so the title bar
        // never changes height during a page change. Subtitle only, never a
        // navigation title: the window is still found by its title.
        .pageToolbar(back: chromeOnPage ? PageBack(label: backLabel, action: { if isEditorPage { editor.backRequests += 1 } else { coordinator.goBack() } }) : nil,
                     subtitle: chromeOnPage ? pageSubtitle : homeSubtitle)
        .toolbar {
            if !chromeOnPage {
                // The switcher is the toolbar's centre and the only main choice;
                // the leading side is empty. Sessions, Help and Settings are the
                // places and utilities, trailing.
                modeSwitcherItem
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        coordinator.mainPage = .sessions
                    } label: {
                        Label("Sessions", systemImage: "film.stack")
                            .labelStyle(.iconOnly)  // icon only, so the toolbar balances and the switcher sits centred (owner, 2026-11-14); the footer names Sessions
                    }
                    .help("Sessions: every past meeting, its recordings and clips with a player, its YouTube links, and a name you can change.")
                }
                if #available(macOS 26, *) {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }
                ToolbarItemGroup(placement: .primaryAction) {
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
    }

    /// Learns the sidebar's real width, from what the window has left over,
    /// once nothing is moving.
    private func noteDetailWidth(_ width: CGFloat) {
        guard sidebarShown, homePin == nil, pagePin == nil, let window = Self.window else { return }
        let measured = window.contentLayoutRect.width - width
        if SidebarRules.widthRange.contains(measured), abs(measured - sidebarWidth) > 0.5 {
            sidebarWidth = measured
        }
    }

    /// The switcher draws its own capsule (Segmented.swift), so the system's
    /// shared toolbar background is hidden on macOS 26: its padding differed
    /// top/bottom from the ends and could not be matched.
    @ToolbarContentBuilder
    private var modeSwitcherItem: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .principal) { modeSwitcher }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { modeSwitcher }
        }
    }

    private var modeSwitcher: some View {
        GreenroomSegmented("Mode", selection: $coordinator.meetingMode,
                           options: Array(MeetingMode.allCases), toolbar: true) { Text($0.shortLabel) }
            .segmentHelp { $0 == .join ? MeetingMode.scheduledHelp : nil }
    }

    /// Home and the pages, one over the other. Mounted by state (not by
    /// `onPage`) so the outgoing one stays up for the whole change, and so a
    /// new page is mounted already at opacity 0.
    private var pageLayers: some View {
        ZStack(alignment: .topLeading) {
            if homeMounted {
                homeContent
                // 24pt at the sides (Home is one column, 2026-11-13); 20pt top and
                // bottom, which the heights assume.
                .padding(.horizontal, HomeView.sideMargin)
                .padding(.vertical, HomeView.verticalMargin)
                .frame(minWidth: homeMinWidth, minHeight: homeWindowHeight)
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
    private static let growDuration = 0.25   // resizeWindow, ease-in-out
    private static let fadeInLead = 0.10     // the page fades in over the grow's last part
    private static let fadeInDuration = 0.2
    private static let pageRiseDistance: CGFloat = 6
    private static let crossfade = 0.15      // Reduce Motion, full screen
    private static let toolbarFadeIn = 0.15  // once the window is still

    /// Home <-> Sessions as one motion, in steps that never overlap the
    /// expensive ones:
    ///
    /// 1. The incoming page mounts, invisible, and the change waits a turn
    ///    of the run loop so its first layout is paid while nothing moves.
    /// 2. The outgoing page fades out.
    /// 3. With the content invisible and the window still, the sidebar
    ///    column and the toolbar swap. Both force a full layout of the
    ///    window; done mid-grow, that is what made the window stall and then
    ///    snap (filmed with the DEBUG `film` tour command, 2026-11-14).
    /// 4. The window grows (or shrinks) over both pages held at their final
    ///    sizes, and the incoming page fades in over the end of it, settling
    ///    6pt up.
    ///
    /// A click mid-way simply starts the next one: every step checks the
    /// token, the opacities retarget from where they are, and the window
    /// animator retargets from its current frame.
    private func changePage(toHome isHome: Bool) {
        transitionToken += 1
        let token = transitionToken
        let window = Self.window
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
        /// Once the work already queued (a mount, a layout) has been done.
        func next(_ step: @escaping () -> Void) {
            DispatchQueue.main.async {
                if token == transitionToken { step() }
            }
        }
        func finish() {
            homePin = nil
            pagePin = nil
            if let window { Self.setToolbarItemsAlpha(1, in: window, duration: Self.toolbarFadeIn) }
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
            if let window { Self.setToolbarItemsAlpha(1, in: window, duration: 0) }
            chromeOnPage = !isHome
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
        // The pages sit in the detail column, so they lose the sidebar's width
        // while it is up. Home's column is the whole window.
        let credit = sidebarHidden || onSingleSession ? 0 : sidebarWidth
        let target = CGSize(width: isHome ? settled.width : settled.width - credit,
                            height: settled.height - titleBar)
        let current = CGSize(width: isHome ? now.width - credit : now.width,
                             height: now.height - titleBar)
        if isHome {
            homePin = target
            if !inFlight { pagePin = current }
        } else {
            pagePin = target
            if !inFlight { homePin = CGSize(width: homeWidth ?? now.width, height: homeWindowHeight) }
        }

        // 1. Let the mount land before anything moves.
        next {
            // 2. The outgoing page fades out.
            withAnimation(.easeIn(duration: Self.fadeOutDuration)) {
                if isHome { pageOpacity = 0; pageRise = Self.pageRiseDistance } else { homeOpacity = 0 }
            }
            after(Self.fadeOutDuration) {
                // 3. Sidebar and toolbar, while nothing shows and nothing moves.
                // The toolbar's items go out of sight for the resize and fade
                // back in once the window stops (setToolbarItemsAlpha).
                Self.setToolbarItemsAlpha(0, in: window, duration: 0)
                chromeOnPage = !isHome
                next {
                    // The swap's layout, now, not on the grow's first frame:
                    // the animator is timed, so a frame lost there is a jump.
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    // The swap's new items, hidden too.
                    Self.setToolbarItemsAlpha(0, in: window, duration: 0)
                    CATransaction.flush()
                    // 4. The window, with the new page coming up over its end.
                    resizeWindow(animated: true, returningHome: isHome)
                    after(Self.growDuration - Self.fadeInLead) {
                        withAnimation(.easeOut(duration: Self.fadeInDuration)) {
                            if isHome { homeOpacity = 1 } else { pageOpacity = 1; pageRise = 0 }
                        }
                    }
                    after(Self.growDuration - Self.fadeInLead + Self.fadeInDuration) { finish() }
                }
            }
        }
    }

    private var homeContent: some View {
        HomeView(statusShown: $statusShown,
                 previewShown: $previewShown, previewMounted: previewMounted,
                 pictureAspect: $pictureAspect)
    }

    /// The window's height for the current state: the two columns, plus Join's passcode row, plus the
    /// log when it is shown. Measured from the accessibility tree rather than
    /// guessed, on the 4px scale (DESIGN.md: size from the content).
    private var preferredWindowHeight: CGFloat { onPage ? Self.pageHeight : homeWindowHeight }

    /// Home's own height, whichever page is up: Home is laid out at this while
    /// it fades, so it must not follow `onPage`.
    private var homeWindowHeight: CGFloat {
        // 20pt of padding top and bottom around the column, whose height is
        // the sum of its fixed parts (HomeView.columnHeight).
        var height: CGFloat = HomeView.verticalMargin * 2 + HomeView.columnHeight
        if statusShown { height += HomeView.statusLogHeight + 12 }
        return height
    }

    /// The least Home may be: 24pt of padding each side leaves 472pt, which
    /// still shows the 16:9 card at 265pt tall. The default (592) gives the
    /// 544pt column its full width.
    static var minimumWindowWidth: CGFloat { 520 }

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

    /// The window opens in the middle of the screen, every time (owner,
    /// 2026-11-16), not wherever it was last closed. The true middle of the
    /// visible area, not AppKit's `center()`, which sits it a third of the
    /// way down.
    private static func centreWindow() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let screen = NSScreen.main ?? window.screen else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                      y: (area.midY - size.height / 2).rounded()))
    }

    /// The least the window may be, for the page it is on. On Home that is
    /// its height for the state; on a page, the drag floor - not the page's
    /// opening size, which the user may shrink below.
    private var floorHeight: CGFloat { onPage ? Self.pageMinHeight : preferredWindowHeight }
    private var floorWidth: CGFloat {
        onPage ? Self.pageMinWidth
            : previewShown ? expandedWidth : Self.collapsedWindowWidth
    }

    /// Home's collapsed width. 592, not column + margins (544): at 508 and 540 the
    /// toolbar folded Sessions, Help and Settings into an overflow chevron, and the
    /// share eye in the title bar then took more: the least is now what the toolbar
    /// needs (HomeToolbarRules), never below 592.
    private static let titleBarCredit: CGFloat = 52
    /// The content with its margins, or what the toolbar needs if that is more;
    /// the column takes any width beyond its natural one, so the floor never
    /// becomes dead margins (HomeView.sideMargin).
    static var collapsedWindowWidth: CGFloat { max(HomeView.naturalCollapsedWidth, HomeToolbarRules.minWindowWidth) }
    /// With the picture card beside the column: the content and margins
    /// (the toolbar's need is then already met).
    static func expandedWindowWidth(aspect: CGFloat) -> CGFloat {
        max(HomeView.naturalCollapsedWidth + HomeView.previewExtraWidth(aspect: aspect), HomeToolbarRules.minWindowWidth)
    }
    private var expandedWidth: CGFloat { Self.expandedWindowWidth(aspect: pictureAspect) }
    /// What the window opens at: with the picture card open. The height is
    /// then the content's (homeWindowHeight).
    static var defaultWindowWidth: CGFloat { expandedWindowWidth(aspect: HomeView.defaultPictureAspect) }
    /// The least Home may be, for whether the card is open.
    private var homeMinWidth: CGFloat { previewMounted ? expandedWidth : Self.collapsedWindowWidth }

    /// Where the window ends up for the current page and state, top edge
    /// anchored and inside the visible frame.
    private func settledFrame(for window: NSWindow, animated: Bool, returningHome: Bool,
                              previewChange: Bool = false, middle: Bool = false) -> NSRect {
        let content = window.contentRect(forFrameRect: window.frame)
        // Home keeps the width the user gave it; a page widens it, within the
        // screen, and Back returns Home to the width it left.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        var width: CGFloat
        if onPage {
            width = animated ? max(content.width, Self.pageWidth) : Self.pageWidth
        } else if previewChange {
            // The card opening or closing moves only the right edge.
            width = previewShown ? max(content.width, expandedWidth)
                : max(Self.collapsedWindowWidth, content.width - HomeView.previewExtraWidth(aspect: pictureAspect))
        } else {
            width = returningHome ? PreviewFrameRules.returnWidth(remembered: homeWidth, current: content.width, floor: floorWidth)
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
        var size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)).size
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        // The top-left corner is anchored (DESIGN.md). Going to a page it
        // grows down and right from Home's saved frame, shifted only by what
        // would leave the screen; Back returns to that saved frame exactly.
        if onPage {
            let movedOnPage = WindowFrameRules.moved(from: pageSettledFrame, to: window.frame)
            let anchor = (movedOnPage ? nil : homeFrame) ?? window.frame
            return WindowFrameRules.pageFrame(from: anchor, size: size, visibleFrames: visibleFrames)
        }
        if previewChange {
            if previewShown {
                return WindowFrameRules.expandedFrame(
                    restoring: previewFrameBeforeHide, hiddenAt: previewHiddenFrame,
                    from: window.frame, size: size, in: visible)
            }
            return WindowFrameRules.collapsedFrame(
                restoring: previewRestoreFrame, current: window.frame, size: size,
                movedSinceExpand: WindowFrameRules.moved(from: previewExpandedFrame, to: window.frame),
                in: visible)
        }
        if returningHome, let remembered = homeFrame, homeFrameContentHeight == homeWindowHeight,
           abs(remembered.width - size.width) < 1 {
            size = remembered.size
        }
        if returningHome {
            return WindowFrameRules.returningHome(
                remembered: homeFrame, size: size, current: window.frame,
                movedOnPage: WindowFrameRules.moved(from: pageSettledFrame, to: window.frame),
                visibleFrames: visibleFrames, currentVisible: visible)
        }
        if middle { return WindowFrameRules.centred(on: window.frame, size: size, in: visible) }
        return WindowFrameRules.topLeftAnchored(on: window.frame, size: size, in: visible)
    }

    /// The Preview button (or the tour): grows the window about its centre, or
    /// gives the exact collapsed frame back. Under Reduce
    /// Motion there is no slide: the frame jumps and the card crossfades.
    private func previewChanged(_ shown: Bool) {
        guard !onPage else {
            previewMounted = shown
            return
        }
        let animated = !reduceMotion && Self.window.map { !$0.styleMask.contains(.fullScreen) && !$0.isZoomed } == true
        if shown {
            if let window = Self.window { previewRestoreFrame = window.frame }
            previewExpandedFrame = nil
            withAnimation(.easeInOut(duration: animated ? Self.growDuration : Self.crossfade)) { previewMounted = true }
        } else {
            let delay = animated ? Self.growDuration + 0.03 : Self.crossfade
            if let window = Self.window { previewFrameBeforeHide = window.frame }
            previewHiddenFrame = nil
            // Keep the card drawn while the window closes over it (a curtain,
            // so no content reflows at the wrong size); the crossfade under
            // Reduce Motion fades it at once.
            if !animated { withAnimation(.easeInOut(duration: Self.crossfade)) { previewMounted = false } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !previewShown { withAnimation(nil) { previewMounted = false } }
            }
        }
        resizeWindow(animated: animated, previewChange: true)
    }

    /// Resizes from an anchored TOP edge. AppKit's `setContentSize` keeps the
    /// bottom-left corner, so every expansion used to send the whole window
    /// climbing the screen while the rows above reflowed (reported live:
    /// "that animation where everything moves up"). Holding the top edge means
    /// the controls stay exactly where the cursor left them and only the
    /// bottom edge travels - down when the log opens, up when it closes.
    /// Width is the user's.
    /// The toolbar's items, out of sight while the window resizes for a page
    /// change. AppKit lays toolbar items out a frame behind a moving window, so
    /// every item (the switcher, Sessions, Help, Settings, Back) visibly shook
    /// across the grow and the shrink (owner, 2026-11-15). Hiding only the
    /// SwiftUI content left the system's glass capsules sliding, so this fades
    /// the toolbar's own view. The traffic lights stay: anything holding a
    /// window button is split until only item views are faded.
    private static func setToolbarItemsAlpha(_ alpha: CGFloat, in window: NSWindow, duration: Double) {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard let titlebar = buttons.first?.superview?.superview else { return }
        func holdsButton(_ view: NSView) -> Bool { buttons.contains { $0.isDescendant(of: view) } }
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).hasSuffix("NSToolbarView") { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        guard let toolbar = find(titlebar) else { return }
        var targets: [NSView] = []
        func collect(_ view: NSView) {
            if holdsButton(view) { view.subviews.forEach(collect) } else { targets.append(view) }
        }
        collect(toolbar)
        guard duration > 0 else {
            targets.forEach { $0.alphaValue = alpha }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            targets.forEach { $0.animator().alphaValue = alpha }
        }
    }

    /// Only the width moves, about the centre, over `growDuration`
    /// ease-in-out (instant under Reduce Motion).
    private func aspectChanged(from old: CGFloat, to new: CGFloat) {
        guard !seedingAspect, previewShown, previewMounted, !onPage, let window = Self.window,
              !window.styleMask.contains(.fullScreen), !window.isZoomed else { return }
        let delta = HomeView.previewExtraWidth(aspect: new) - HomeView.previewExtraWidth(aspect: old)
        guard abs(delta) >= 1 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        var width = max(content.width + delta, expandedWidth)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        if let visible { width = min(width, visible.width) }
        // About the centre, as the preview opening and closing are, so a hide
        // then a show never leaves the window somewhere else.
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: content.height)).size
        let frame = WindowFrameRules.aspectFrame(from: window.frame, size: CGSize(width: size.width, height: window.frame.height),
                                                 in: visible)
        guard abs(frame.width - window.frame.width) >= 1 else { heldMinWidth = floorWidth; return }
        if previewExpandedFrame != nil { previewExpandedFrame = nil }
        resizeGeneration += 1
        let generation = resizeGeneration
        let settledWidth = floorWidth
        if settledWidth < heldMinWidth { heldMinWidth = settledWidth }
        guard !reduceMotion else {
            window.setFrame(frame, display: true)
            heldMinWidth = settledWidth
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.growDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            guard generation == resizeGeneration else { return }
            heldMinWidth = settledWidth
        }
    }

    private func resizeWindow(animated: Bool, returningHome: Bool = false, previewChange: Bool = false,
                              middle: Bool = false) {
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
        let frame = settledFrame(for: window, animated: animated, returningHome: returningHome,
                                previewChange: previewChange, middle: middle && !onPage)
        pageSettledFrame = onPage ? frame : nil
        guard animated else {
            resizeGeneration += 1
            window.setFrame(frame, display: true)
            if onPage { pageSettledFrame = window.frame }
            if previewChange && previewShown { previewExpandedFrame = window.frame }
            if previewChange && !previewShown { previewHiddenFrame = window.frame }
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
            // What the window really settled at (AppKit may constrain it), so
            // "the user moved it" compares against the truth.
            if onPage { pageSettledFrame = window.frame }
            if previewChange && previewShown { previewExpandedFrame = window.frame }
            if previewChange && !previewShown { previewHiddenFrame = window.frame }
            heldMinHeight = settled
            heldMinWidth = settledWidth
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
