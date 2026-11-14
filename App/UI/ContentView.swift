//
//  ContentView.swift
//  Greenroom
//
//  One decision, one button: pick "New Meeting", "Join Existing" or "Record"
//  in the toolbar, hit the button, and the whole session cascades - the picture, Zoom into
//  the meeting, Chrome tiled to its side of the screen, chat window tiled
//  to the other. Individual pieces remain available under the button's
//  chevron ("Manual controls"); configuration lives in Settings (⌘,).
//  Home itself is HomeView.swift.
//
import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @Environment(\.openSettings) private var openSettings
    /// Hidden by default: the log is diagnostic detail, opened when something
    /// needs explaining. Not persisted - each launch starts compact.
    @State private var statusShown = false
    /// Home's five setup tiles unfolded; per launch, collapsed by default.
    @State private var setupOpen = false
    /// Home shows its "Last session" line, which is 44pt of the window's
    /// height. Reported by HomeView, which is the one that knows.
    @State private var homeHasFooter = false
    /// The window's minimum height, which TRAILS a resize instead of leading
    /// it - see resizeWindow. Starts at 0 and is set on appear.
    @State private var heldMinHeight: CGFloat = 0
    /// The same, for width: Home is narrower than the pages, so the minimum
    /// follows the window out and back instead of forcing it open first.
    @State private var heldMinWidth: CGFloat = ContentView.collapsedWindowWidth
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

    /// Home's picture card: hidden until asked for, and collapsed on every launch
    /// (the camera must never start by itself; DESIGN.md, 2026-11-14). `previewMounted` lags a collapse by the
    /// window's shrink, so the card is drawn until the curtain has closed on it.
    @State private var previewShown = false
    @State private var previewMounted = false
    /// The frame the window had before the card opened, to give back exactly.
    @State private var previewRestoreFrame: NSRect?
    /// The frame the opening settled at, to tell whether the window was moved.
    @State private var previewExpandedFrame: NSRect?

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

    /// Sidebar for the Sessions pages, detail-only on Home and Record. Follows
    /// `chromeOnPage`, so the column appears and goes at the fade-out point of
    /// a page change, while Home is invisible, not at the click.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { SidebarRules.visibility(onSessionsPage: chromeOnPage, hidden: sidebarHidden) },
            set: { sidebarHidden = SidebarRules.hidden(afterVisibility: $0, onSessionsPage: chromeOnPage,
                                                       was: sidebarHidden) })
    }

    private var sidebarShown: Bool { chromeOnPage && !sidebarHidden }

    var body: some View {
        // The window's ROOT content is the split view: only then does macOS 26
        // draw the sidebar from the very top with the traffic lights in it, and
        // keep the toolbar over the detail column. (An earlier attempt let a
        // nested split view ignore the top safe area; it did not work.)
        NavigationSplitView(columnVisibility: columnVisibility) {
            SessionsSidebar(model: sidebarModel)
                // Home and Record have no sidebar to toggle. Documented home of
                // the removal: the sidebar column's content.
                .toolbar(removing: chromeOnPage ? nil : .sidebarToggle)
        } detail: {
            detailColumn
        }
        .environmentObject(sidebarModel)
        // Control-Command-S, the system's own sidebar key, which the single
        // View menu item (SidebarCommands) no longer carries. Present but
        // invisible: the menu shows one item.
        .background {
            Button("") { sidebarHidden.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!chromeOnPage)
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
            DispatchQueue.main.async { resizeWindow(animated: false) }
        }
        // The things that change the window's height. All grow it DOWNWARD
        // from an anchored top edge, so nothing above the divider moves - see
        // resizeWindow.
        .onChange(of: statusShown) { _, _ in resizeWindow(animated: true) }
        .onChange(of: setupOpen) { _, _ in resizeWindow(animated: true) }
        .onChange(of: previewShown) { _, shown in previewChanged(shown) }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugTourHomePreview)) { note in
            HomeView.debugSkipLive = (note.userInfo?["camera"] as? Bool) == false
            previewShown = (note.userInfo?["shown"] as? Bool) ?? false
        }
        #endif
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugTourHomeSetup)) { note in
            Collapse.animate { setupOpen = (note.userInfo?["expanded"] as? Bool) ?? false }
        }
        #endif
        .onChange(of: homeHasFooter) { _, _ in resizeWindow(animated: true) }
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
                homeFrameContentHeight = homeWindowHeight
                pageSettledFrame = nil
            }
            changePage(toHome: isHome)
        }
        // Esc goes back too. Left to a text field that is being edited.
        .onExitCommand {
            guard onPage, !(Self.window?.firstResponder is NSText) else { return }
            coordinator.goBack()
        }
        // The toast, the upload question and the start's progress card, while
        // this window is the one in view (WindowBanner.swift).
        .sheet(isPresented: $coordinator.showOnboarding) {
            OnboardingView()
                .environmentObject(coordinator)
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
        .pageToolbar(back: chromeOnPage ? PageBack(label: backLabel, action: { coordinator.goBack() }) : nil,
                     subtitle: coordinator.recordStudioShown && coordinator.mainPage.isHome ? RecordStudioView.subtitle(for: coordinator)
                                                : chromeOnPage ? pageSubtitle : "")
        .toolbar {
            // Record's own toolbar (Done) lives in RecordStudioContent.
            if !chromeOnPage && !coordinator.recordStudioShown {
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
                    .help("Sessions: every past class, its recordings and clips with a player, its YouTube links, and a name you can change.")
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
                // 24pt at the sides (Home is one column, 2026-11-13); 20pt top and
                // bottom, which the heights assume. Record's studio keeps 32.
                .padding(.horizontal, coordinator.recordStudioShown ? 32 : 24)
                .padding(.vertical, coordinator.recordStudioShown ? 20 : HomeView.verticalMargin)
                .frame(minWidth: coordinator.recordStudioShown ? Self.minimumWindowWidth : homeMinWidth, minHeight: homeWindowHeight)
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
        // The pages sit in the detail column, so they lose the sidebar's width
        // while it is up. Home's column is the whole window.
        let credit = sidebarHidden ? 0 : sidebarWidth
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
        HomeView(statusShown: $statusShown, hasFooter: $homeHasFooter, setupOpen: $setupOpen,
                 previewShown: $previewShown, previewMounted: previewMounted)
    }

    /// The window's height for the current state: the two columns, plus the
    /// "Last session" line when there is one, plus Join's passcode row, plus the
    /// log when it is shown. Measured from the accessibility tree rather than
    /// guessed, on the 4px scale (DESIGN.md: size from the content).
    private var preferredWindowHeight: CGFloat { onPage ? Self.pageHeight : homeWindowHeight }

    /// Home's own height, whichever page is up: Home is laid out at this while
    /// it fades, so it must not follow `onPage`.
    private var homeWindowHeight: CGFloat {
        if coordinator.recordStudioShown { return RecordStudioView.windowHeight }
        // 20pt of padding top and bottom around the column, whose height is
        // the sum of its fixed parts (HomeView.columnHeight).
        var height: CGFloat = HomeView.verticalMargin * 2 + HomeView.columnHeight
        if setupOpen { height += HomeView.tilesExtraHeight }
        if homeHasFooter { height += 44 }
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

    /// The least the window may be, for the page it is on. On Home that is
    /// its height for the state; on a page, the drag floor - not the page's
    /// opening size, which the user may shrink below.
    private var floorHeight: CGFloat { onPage ? Self.pageMinHeight : preferredWindowHeight }
    private var floorWidth: CGFloat {
        onPage ? Self.pageMinWidth : coordinator.recordStudioShown ? Self.minimumWindowWidth
            : previewShown ? Self.expandedWindowWidth : Self.collapsedWindowWidth
    }

    /// Home's collapsed width. 592, not column + margins (544): at 508 and 540 the
    /// toolbar folded Sessions, Help and Settings into an overflow chevron.
    private static let titleBarCredit: CGFloat = 52
    static var collapsedWindowWidth: CGFloat { 592 }
    /// With the picture card beside the column.
    static var expandedWindowWidth: CGFloat { collapsedWindowWidth + HomeView.previewExtraWidth }
    /// What the window opens at: collapsed unless the person left the picture
    /// open. The height is then the content's (homeWindowHeight).
    static var defaultWindowWidth: CGFloat { collapsedWindowWidth }
    /// The least Home may be, for whether the card is open.
    private var homeMinWidth: CGFloat { previewMounted ? Self.expandedWindowWidth : Self.collapsedWindowWidth }

    /// Where the window ends up for the current page and state, top edge
    /// anchored and inside the visible frame.
    private func settledFrame(for window: NSWindow, animated: Bool, returningHome: Bool,
                              previewChange: Bool = false) -> NSRect {
        let content = window.contentRect(forFrameRect: window.frame)
        // Home keeps the width the user gave it; a page widens it, within the
        // screen, and Back returns Home to the width it left.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        var width: CGFloat
        if onPage {
            width = animated ? max(content.width, Self.pageWidth) : Self.pageWidth
        } else if previewChange {
            // The card opening or closing moves only the right edge.
            width = content.width + (previewShown ? HomeView.previewExtraWidth : -HomeView.previewExtraWidth)
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
                return WindowFrameRules.expandedFrame(from: window.frame, size: size, in: visible)
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
        return WindowFrameRules.topLeftAnchored(on: window.frame, size: size, in: visible)
    }

    /// The Preview button (or the tour): grows the window to the right with the
    /// top-left anchored, or gives the exact collapsed frame back. Under Reduce
    /// Motion there is no slide: the frame jumps and the card crossfades.
    private func previewChanged(_ shown: Bool) {
        guard !onPage, !coordinator.recordStudioShown else {
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
            withAnimation(.easeInOut(duration: animated ? Self.growDuration : Self.crossfade)) {
                // Keep the card drawn while the window closes over it; the
                // crossfade under Reduce Motion fades it at once.
                if !animated { previewMounted = false }
            }
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
    private func resizeWindow(animated: Bool, returningHome: Bool = false, previewChange: Bool = false) {
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
                                previewChange: previewChange)
        pageSettledFrame = onPage ? frame : nil
        guard animated else {
            resizeGeneration += 1
            window.setFrame(frame, display: true)
            if onPage { pageSettledFrame = window.frame }
            if previewChange && previewShown { previewExpandedFrame = window.frame }
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
