//
//  ParticipantGridWindow.swift
//  Greenroom
//
//  The reference display: every student, and every control the SDK exposes.
//
//  This surface goes on a display only the teacher can see, which is what makes
//  the controls appropriate here at all. Nobody is being shown chrome; this is
//  the podium, not the projector. So it is dense on purpose, where the speaker
//  window and the OBS composite stay clean.
//
//  In default Zoom-UI mode the gallery is one of the SDK's own windows, which
//  Greenroom had to identify among several, send to the right display, and keep
//  re-sending because the SDK moved it back on every meeting state change. That
//  produced a visible flicker between displays and a two-minute give-up
//  backstop. None of that applies here: the window is ours, so it goes where we
//  put it and stays, and clicking it cannot make the SDK rebuild anything
//  because in custom-UI mode the SDK owns no windows at all.
//
import AppKit

@MainActor
enum ParticipantGridWindowController {

    // MARK: - What the caller supplies

    /// Session facts the roster cannot answer for itself. Passed in rather than
    /// read from the SDK because Greenroom, not Zoom, owns the meeting number
    /// the teacher typed and the OBS recording state.
    struct SessionInfo: Equatable {
        var meetingNumber: String = ""
        var startedAt: Date?
        var obsRecording: Bool = false
        var presetName: String = ""
        /// Whether the live-speaker tile is currently quick-hidden, so the rail
        /// can offer the opposite action rather than a stale one.
        var speakerHidden: Bool = false
    }

    /// Started with the panel and stopped with it, so nothing taps the
    /// microphone outside a session.
    private static let micMonitor = MicLevelMonitor()
    private static var micTimer: Timer?

    private static weak var client: ZoomMeetingSDKClient?
    private static var log: (@MainActor (String) -> Void)?
    private static var endSession: (@MainActor () -> Void)?
    private static var showChat: (@MainActor () -> Void)?
    private static var toggleRecording: (@MainActor () -> Void)?
    private static var snapBack: (@MainActor () -> Void)?
    private static var toggleSpeaker: (@MainActor () -> Void)?
    private static var showMainWindow: (@MainActor () -> Void)?

    /// Wired once at session start. The window talks to the SDK directly rather
    /// than routing every button through the coordinator: the coordinator owns
    /// placement and session lifecycle, not what a host does to a roster.
    static func configure(client: ZoomMeetingSDKClient,
                          log: @escaping @MainActor (String) -> Void,
                          endSession: @escaping @MainActor () -> Void,
                          showChat: @escaping @MainActor () -> Void,
                          toggleRecording: @escaping @MainActor () -> Void,
                          snapBack: @escaping @MainActor () -> Void,
                          toggleSpeaker: @escaping @MainActor () -> Void,
                          showMainWindow: @escaping @MainActor () -> Void) {
        self.client = client
        self.log = log
        self.endSession = endSession
        self.showChat = showChat
        self.toggleRecording = toggleRecording
        self.snapBack = snapBack
        self.toggleSpeaker = toggleSpeaker
        self.showMainWindow = showMainWindow

        // Driven on its own timer, not the one-second roster poll: a meter that
        // updated once a second would not be a meter.
        micMonitor.start()
        micTimer?.invalidate()
        micTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { _ in
            Task { @MainActor in
                root?.applyMicLevel(micMonitor.level, running: micMonitor.isRunning)
            }
        }
    }

    // MARK: - Window

    /// A non-activating panel, not a plain window. Clicking a control must not
    /// pull Greenroom in front of whatever the teacher has on their main screen
    /// - the reference display is glanced at and poked, never "switched to".
    private final class ControlPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private static var panel: ControlPanel?
    private static var root: RootView?

    /// Full-screen and borderless when it has a display to itself. On a single
    /// display it becomes an ordinary movable, resizable window instead - a
    /// teacher on a laptop still needs the roster and the controls, and a
    /// borderless panel covering their only screen would be unusable.
    private static func makePanel(on screen: NSScreen, windowed: Bool) -> ControlPanel {
        let frame = windowed
            ? NSRect(x: screen.visibleFrame.minX + 60,
                     y: screen.visibleFrame.minY + 60,
                     width: min(1100, screen.visibleFrame.width - 120),
                     height: min(760, screen.visibleFrame.height - 120))
            : screen.frame
        let created = ControlPanel(contentRect: frame,
                                   styleMask: windowed
                                       ? [.titled, .resizable, .miniaturizable, .nonactivatingPanel]
                                       : [.borderless, .nonactivatingPanel],
                                   backing: .buffered,
                                   defer: false,
                                   screen: screen)
        created.title = "Participants"
        created.isReleasedWhenClosed = false
        created.hidesOnDeactivate = false
        created.backgroundColor = .black
        created.level = .normal
        created.collectionBehavior = [.managed, .fullScreenAuxiliary]
        created.isMovable = windowed
        return created
    }

    // MARK: - Refresh

    /// Pulls the roster itself and redraws. Called on a poll rather than driven
    /// by join/leave callbacks because a brand-new participant's video element
    /// is not renderable the instant the callback fires, and a poll converges
    /// whether or not any single event was missed.
    static func refresh(on screen: NSScreen, session: SessionInfo, windowed: Bool) {
        guard let client else { return }

        // Self is never in the grid. The rail carries a dedicated self view, and
        // an NSView has one superview - having both would mean two hosts
        // fighting over one SDK render element. It also matches how the surface
        // reads: left is you, right is the class.
        var roster = client.meetingRoster()
        roster.removeAll { $0.isMyself }

        let hosting: ControlPanel
        let isNewWindow: Bool
        if let existing = panel, isWindowed == windowed,
           windowed || existing.screen === screen {
            hosting = existing
            isNewWindow = false
        } else {
            isNewWindow = true
            // Closed, not merely ordered out. orderOut leaves the window in
            // NSApp.windows for the life of the process, so swapping between the
            // windowed and full-screen forms would strand one there on every
            // switch - invisible, but still walked by the 500ms SDK-window
            // sweep and never freed.
            root?.detachAllVideo()
            panel?.close()
            hosting = makePanel(on: screen, windowed: windowed)
            let view = RootView(frame: hosting.contentLayoutRect)
            view.autoresizingMask = [.width, .height]
            hosting.contentView = view
            panel = hosting
            root = view
            isWindowed = windowed
        }
        // Only the full-screen form is re-framed, and only when it has actually
        // drifted. Once the teacher has moved or resized the windowed form,
        // pinning it back every second would make it impossible to place.
        if !windowed, hosting.frame != screen.frame {
            hosting.setFrame(screen.frame, display: true)
        }

        root?.update(roster: roster,
                     flags: client.roomFlags(),
                     waiting: client.waitingRoomNames(),
                     session: session,
                     videoProvider: { id, frame in client.participantView(userID: id, frame: frame) },
                     selfProvider: { frame in client.makeRailSelfView(frame: frame) })
        // Pruned to the VISIBLE page, not the whole roster, so students on other
        // pages release their streams. The rail's self view is a separate element
        // and is unaffected.
        client.pruneParticipantViews(keeping: root?.visibleIDs ?? [])

        // Raise it only when it is new, or when it has gone away and was not
        // deliberately minimised. Placement here is CONVERGENT, not assertive.
        //
        // The first version ordered the panel front on every tick of a
        // one-second poll, which meant clicking any other window sent it behind
        // and then had it jump back on top a second later - a tug-of-war with
        // the person using the Mac, and indistinguishable from the SDK-window
        // fighting that custom UI exists to end. A window that is merely BEHIND
        // another is still `isVisible`, so this leaves it where the user put it.
        if isNewWindow || (!hosting.isVisible && !hosting.isMiniaturized) {
            hosting.orderFrontRegardless()
        }
    }

    private static var isWindowed = false

    static var isOpen: Bool { panel?.isVisible ?? false }

    /// So SDK window hunting recognises this as ours, the same as the chat and
    /// speaker windows.
    static func owns(_ candidate: NSWindow) -> Bool { candidate == panel }

    static func hide() { panel?.orderOut(nil) }

    static func close() {
        root?.detachAllVideo()
        panel?.contentView = NSView()
        panel?.close()
        panel = nil
        root = nil
        client = nil
        log = nil
        endSession = nil
        showChat = nil
        toggleRecording = nil
        snapBack = nil
        toggleSpeaker = nil
        showMainWindow = nil
        micTimer?.invalidate()
        micTimer = nil
        micMonitor.stop()
    }

    fileprivate static func report(_ message: String) { log?(message) }
    fileprivate static func requestEndSession() { endSession?() }
    fileprivate static func requestShowChat() { showChat?() }
    fileprivate static func requestToggleRecording() { toggleRecording?() }
    fileprivate static func requestSnapBack() { snapBack?() }
    fileprivate static func requestToggleSpeaker() { toggleSpeaker?() }
    fileprivate static func requestShowMainWindow() { showMainWindow?() }
    fileprivate static var sdk: ZoomMeetingSDKClient? { client }
    fileprivate static var hostWindow: NSWindow? { panel }
}

// MARK: - Root layout

/// Top bar, video grid, contextual strip, bottom bar.
///
/// Hand-laid rather than Auto Layout: the video views come from the SDK with
/// frames of their own and are re-framed every refresh anyway, so one layout
/// pass over explicit rects is both simpler and cheaper than maintaining
/// constraints for a grid whose shape changes as students join.
@MainActor
private final class RootView: NSView {

    private let topBar = BarView()
    private let bottomBar = BarView()
    private let contextBar = BarView()
    private let gridHost = NSView()
    private let emptyState = NSTextField(labelWithString: "")

    private let titleLabel = NSTextField(labelWithString: "")
    private let factsLabel = NSTextField(labelWithString: "")
    private let recordingLabel = NSTextField(labelWithString: "")
    private let recordingDot = DotView()

    private var tiles: [UInt32: TileView] = [:]
    private var selected: UInt32?
    private var lastGridShape: (cols: Int, rows: Int, count: Int) = (0, 0, -1)
    /// What the bars were last built from. Deliberately excludes who is TALKING:
    /// that changes constantly and only affects tile rings, never a button.
    private var lastBarSignature = ""
    /// Held so a page change can re-attach video without waiting for the poll.
    private var lastVideoProvider: ((UInt32, NSRect) -> NSView?)?
    private var lastSelfProvider: ((NSRect) -> NSView?)?

    private var roster: [ZoomMeetingSDKClient.RosterEntry] = []
    private var page = 0
    private let rail = BarView()
    private let selfViewHost = NSView()
    private let selfViewLabel = NSTextField(labelWithString: "You, as the class sees you")
    private var selfVideo: NSView?
    private var railControls: [NSView] = []
    private let micMeter = LevelMeterView()
    private let micLabel = NSTextField(labelWithString: "Your microphone")
    private let micHint = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private let pageLabel = NSTextField(labelWithString: "")
    private var pagePrev: NSButton?
    private var pageNext: NSButton?
    private var flags = ZoomMeetingSDKClient.RoomFlags()
    private var waiting: [(id: UInt32, name: String)] = []
    private var session = ParticipantGridWindowController.SessionInfo()

    /// Left rail: you and your tools. Right: the class. The split the teacher
    /// asked for, and it also settles a technical problem - with a dedicated
    /// self view on the left there is no reason for the grid to include you, so
    /// nothing fights over a single SDK render element.
    private static let railWidth: CGFloat = 380
    /// How many students fit on one page before the carousel appears. Fixed
    /// rather than computed from the area: a page size that changed as people
    /// joined would reshuffle faces mid-lesson, which is exactly when a teacher
    /// is relying on their position.
    private static let perPage = 9
    private static let barHeight: CGFloat = 44
    /// Zero: the rail carries every control now, so there is no bottom toolbar
    /// to reserve space for. Kept as a constant because the body layout reads it.
    private static let bottomHeight: CGFloat = 0
    private static let contextHeight: CGFloat = 48
    private static let gutter: CGFloat = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // NOT pure black. Reported live as "the external display goes dark when
        // I start the meeting", and that was exactly right: a borderless
        // full-screen window painted #000 with an empty grid is
        // indistinguishable from a monitor that has lost signal. It got worse
        // when self left the grid, because alone in a room there was then
        // nothing on the right at all. A real surface colour reads as a panel
        // that is ready, which is what it is.
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        for bar in [topBar, rail, contextBar, bottomBar] { addSubview(bar) }
        gridHost.wantsLayer = true
        gridHost.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        addSubview(gridHost)

        selfViewHost.wantsLayer = true
        selfViewHost.layer?.backgroundColor = NSColor.black.cgColor
        selfViewHost.layer?.cornerRadius = 10        // DESIGN.md radius-md
        selfViewHost.layer?.masksToBounds = true
        rail.addSubview(selfViewHost)

        selfViewLabel.font = .systemFont(ofSize: 11)
        selfViewLabel.textColor = .secondaryLabelColor
        rail.addSubview(selfViewLabel)

        micLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        micLabel.textColor = .tertiaryLabelColor
        micLabel.stringValue = "YOUR MICROPHONE"
        rail.addSubview(micLabel)
        rail.addSubview(micMeter)

        micHint.font = .systemFont(ofSize: 10)
        micHint.textColor = .secondaryLabelColor
        micHint.maximumNumberOfLines = 2
        micHint.usesSingleLineMode = false
        micHint.lineBreakMode = .byWordWrapping
        rail.addSubview(micHint)

        statsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statsLabel.textColor = .tertiaryLabelColor
        statsLabel.maximumNumberOfLines = 3
        statsLabel.usesSingleLineMode = false
        statsLabel.lineBreakMode = .byWordWrapping
        rail.addSubview(statsLabel)

        pageLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.alignment = .center
        addSubview(pageLabel)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        // Machine facts in mono, prose in the system face - the split DESIGN.md
        // asks for, so a meeting number never reads as a sentence.
        factsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        factsLabel.textColor = .secondaryLabelColor
        recordingLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        for label in [titleLabel, factsLabel, recordingLabel] { topBar.addSubview(label) }
        topBar.addSubview(recordingDot)

        emptyState.font = .systemFont(ofSize: 15)
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.maximumNumberOfLines = 3
        emptyState.usesSingleLineMode = false
        emptyState.lineBreakMode = .byWordWrapping
        addSubview(emptyState)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }

    // MARK: Update

    func update(roster: [ZoomMeetingSDKClient.RosterEntry],
                flags: ZoomMeetingSDKClient.RoomFlags,
                waiting: [(id: UInt32, name: String)],
                session: ParticipantGridWindowController.SessionInfo,
                videoProvider: @escaping (UInt32, NSRect) -> NSView?,
                selfProvider: @escaping (NSRect) -> NSView?) {
        self.roster = roster
        self.flags = flags
        self.waiting = waiting
        self.session = session

        // A selection whose owner left must not linger: its actions would apply
        // to a user ID the SDK has already recycled.
        if let selected, !roster.contains(where: { $0.id == selected }) { self.selected = nil }

        // Clamp rather than reset. If someone leaves while the teacher is on the
        // last page, dropping them to page one would lose their place; this only
        // moves them when the page they are on no longer exists.
        let pages = max(1, Int(ceil(Double(roster.count) / Double(Self.perPage))))
        page = min(page, pages - 1)

        syncTiles()
        updateChromeText()
        // Rebuilt ONLY when something a bar actually shows has changed.
        //
        // The first version tore every button down and recreated it on each tick
        // of a one-second poll. That is wasteful, it makes the toolbar unreadable
        // to accessibility (enumerating it raced the teardown and returned a
        // different answer each time), and worst of all a click landing during a
        // rebuild hits a button that no longer exists - so controls would
        // occasionally just do nothing.
        let signature = barSignature()
        if signature != lastBarSignature {
            lastBarSignature = signature
            rebuildBars()
        }
        layoutEverything()
        // Video is attached only once the tiles have real frames. The SDK
        // resizes its render element to whatever rect it is handed, and handing
        // it the zero rect a freshly created tile still has produces an element
        // that never draws.
        attachVideo(videoProvider)
        attachSelfVideo(selfProvider)
    }

    private func syncTiles() {
        // Only the current page. An off-page student keeps no tile and therefore
        // no video subscription - a class of forty should not mean forty live
        // streams for twelve visible faces.
        let visible = pageRoster
        let live = Set(visible.map(\.id))
        for (id, tile) in tiles where !live.contains(id) {
            tile.detachVideo()
            tile.removeFromSuperview()
            tiles.removeValue(forKey: id)
        }
        for entry in visible {
            let tile = tiles[entry.id] ?? {
                let made = TileView(userID: entry.id)
                made.onSelect = { [weak self] id in
                    guard let self else { return }
                    // Clicking the selected tile clears it, so there is always a
                    // way back to the room-wide controls without a Done button.
                    self.selected = (self.selected == id) ? nil : id
                    self.selectionChanged()
                }
                tiles[entry.id] = made
                gridHost.addSubview(made)
                return made
            }()
            tile.apply(entry: entry, isSelected: selected == entry.id)
        }
    }

    /// The SDK renders into a view it owns; the tile only parents it, and only
    /// when it changes. Re-parenting a live video view every refresh would
    /// flicker the whole wall.
    private func attachVideo(_ videoProvider: @escaping (UInt32, NSRect) -> NSView?) {
        lastVideoProvider = videoProvider
        for entry in pageRoster {
            guard let tile = tiles[entry.id], !tile.bounds.isEmpty else { continue }
            tile.attach(video: videoProvider(entry.id, tile.videoBounds))
        }
    }

    /// Selection changes the tile rings, the contextual strip, and therefore
    /// the height available to the grid - so all three are redone, without
    /// waiting for the next poll. A click has to feel immediate.
    private func selectionChanged() {
        for entry in pageRoster {
            tiles[entry.id]?.apply(entry: entry, isSelected: selected == entry.id)
        }
        lastBarSignature = barSignature()
        rebuildBars()
        layoutEverything()
    }

    /// Fed at 20Hz from the mic monitor, independent of the roster poll.
    func applyMicLevel(_ level: Double, running: Bool) {
        micMeter.isHidden = !running
        micLabel.isHidden = !running
        micHint.isHidden = !running
        guard running else { return }
        micMeter.level = level
        let muted = ParticipantGridWindowController.sdk?.iAmMuted ?? false
        micMeter.muted = muted
        // The one sentence worth saying about a live meter: whether the room can
        // actually hear it. "Muted but talking" is the commonest confusion in a
        // video call, and a meter alone does not resolve it.
        let speaking = level > 0.12
        micHint.stringValue = muted
            ? (speaking ? "You are muted \u{2014} the class cannot hear this." : "Muted.")
            : (speaking ? "The class can hear you." : "Live, but quiet.")
        micHint.textColor = muted && speaking ? .systemOrange : .secondaryLabelColor
    }

    /// Who is on screen right now, for the caller's stream pruning.
    var visibleIDs: Set<UInt32> { Set(pageRoster.map(\.id)) }

    /// The self view, in its own render element so it never contends with the
    /// speaker window for one NSView.
    private func attachSelfVideo(_ provider: @escaping (NSRect) -> NSView?) {
        lastSelfProvider = provider
        guard !selfViewHost.bounds.isEmpty else { return }
        guard let view = provider(selfViewHost.bounds) else { return }
        if selfVideo !== view {
            selfVideo?.removeFromSuperview()
            view.autoresizingMask = [.width, .height]
            selfViewHost.addSubview(view)
            selfVideo = view
        }
        view.frame = selfViewHost.bounds
    }

    func detachAllVideo() {
        tiles.values.forEach { $0.detachVideo() }
        selfVideo?.removeFromSuperview()
        selfVideo = nil
    }

    // MARK: Layout

    private func layoutEverything() {
        let width = bounds.width
        let showContext = selected != nil

        topBar.frame = NSRect(x: 0, y: bounds.height - Self.barHeight,
                              width: width, height: Self.barHeight)
        bottomBar.frame = .zero
        bottomBar.isHidden = true
        // Spans only the grid, not the rail: it describes a selected student, and
        // the students are on the right.
        contextBar.frame = NSRect(x: Self.railWidth, y: 0,
                                  width: max(0, width - Self.railWidth),
                                  height: showContext ? Self.contextHeight : 0)
        contextBar.isHidden = !showContext

        let gridBottom = Self.bottomHeight + (showContext ? Self.contextHeight : 0)
        let bodyHeight = max(0, bounds.height - Self.barHeight - gridBottom)
        rail.frame = NSRect(x: 0, y: gridBottom, width: Self.railWidth, height: bodyHeight)

        // The carousel row sits between the grid and whatever is below it, and
        // only takes space when there is more than one page.
        let pages = max(1, Int(ceil(Double(roster.count) / Double(Self.perPage))))
        let pagerHeight: CGFloat = pages > 1 ? 24 : 0
        gridHost.frame = NSRect(x: Self.railWidth,
                                y: gridBottom + pagerHeight,
                                width: max(0, width - Self.railWidth),
                                height: max(0, bodyHeight - pagerHeight))
        layoutPager(pages: pages, y: gridBottom, width: width - Self.railWidth)
        layoutRail()

        emptyState.frame = NSRect(x: Self.railWidth + 40, y: gridHost.frame.midY - 40,
                                  width: max(80, width - Self.railWidth - 80), height: 80)
        emptyState.isHidden = !roster.isEmpty
        layoutHeaderLabels()
        layoutTiles()
    }

    private func layoutHeaderLabels() {
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(x: 16, y: (Self.barHeight - titleLabel.frame.height) / 2,
                                  width: titleLabel.frame.width, height: titleLabel.frame.height)
        factsLabel.sizeToFit()
        factsLabel.frame = NSRect(x: titleLabel.frame.maxX + 16,
                                  y: (Self.barHeight - factsLabel.frame.height) / 2,
                                  width: factsLabel.frame.width, height: factsLabel.frame.height)
        recordingLabel.sizeToFit()
        recordingLabel.frame = NSRect(x: bounds.width - recordingLabel.frame.width - 16,
                                      y: (Self.barHeight - recordingLabel.frame.height) / 2,
                                      width: recordingLabel.frame.width,
                                      height: recordingLabel.frame.height)
        let dotSize: CGFloat = 8
        recordingDot.frame = NSRect(x: recordingLabel.frame.minX - dotSize - 6,
                                    y: (Self.barHeight - dotSize) / 2,
                                    width: dotSize, height: dotSize)
    }

    /// The students on the current page. Everything downstream - layout, video
    /// subscription, ring state - works from this rather than the whole roster,
    /// so a class of forty does not mean forty live video streams.
    private var pageRoster: [ZoomMeetingSDKClient.RosterEntry] {
        let start = page * Self.perPage
        guard start < roster.count else { return [] }
        return Array(roster[start..<min(start + Self.perPage, roster.count)])
    }

    private func layoutTiles() {
        let visible = pageRoster
        guard !visible.isEmpty else { return }
        let area = gridHost.bounds
        let (cols, rows) = Self.bestGrid(count: visible.count, in: area.size)
        let cellW = (area.width - Self.gutter * CGFloat(cols + 1)) / CGFloat(cols)
        let cellH = (area.height - Self.gutter * CGFloat(rows + 1)) / CGFloat(rows)

        // Layout moves get DESIGN.md's 250ms, but only when the grid actually
        // changes shape. Animating every two-second refresh would mean a wall
        // that is permanently in motion.
        let shape = (cols, rows, visible.count)
        let animate = lastGridShape.count >= 0 && shape != lastGridShape
        lastGridShape = shape

        for (index, entry) in visible.enumerated() {
            guard let tile = tiles[entry.id] else { continue }
            let row = index / cols
            let column = index % cols
            // The last row is centred rather than left-packed: three students
            // in a 2x2 read as a group, not as a missing fourth.
            let inRow = min(cols, visible.count - row * cols)
            let rowWidth = CGFloat(inRow) * cellW + CGFloat(inRow - 1) * Self.gutter
            let originX = (area.width - rowWidth) / 2 + CGFloat(column) * (cellW + Self.gutter)
            let target = NSRect(x: originX,
                                y: area.height - Self.gutter - CGFloat(row + 1) * cellH
                                    - CGFloat(row) * Self.gutter,
                                width: cellW, height: cellH)
            guard tile.frame != target else { continue }
            if animate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    tile.animator().frame = target
                }
            } else {
                tile.frame = target
            }
        }
    }

    /// Picks the grid that fills the space best, rather than assuming a square.
    ///
    /// `ceil(sqrt(n))` is the obvious choice and the wrong one: on a 16:9 screen
    /// it gives five students a 3x2 with slivers, and it ignores that a wide
    /// display wants wide rows. This scores every column count by how much of
    /// the screen the resulting 16:9 cells actually cover.
    static func bestGrid(count: Int, in size: NSSize) -> (cols: Int, rows: Int) {
        guard count > 0, size.width > 0, size.height > 0 else { return (1, 1) }
        var best = (cols: 1, rows: count)
        var bestCoverage: CGFloat = -1
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cellW = size.width / CGFloat(cols)
            let cellH = size.height / CGFloat(rows)
            // How much of each cell a 16:9 video actually fills.
            let videoW = min(cellW, cellH * 16 / 9)
            let videoH = videoW * 9 / 16
            let coverage = videoW * videoH * CGFloat(count) / (size.width * size.height)
            if coverage > bestCoverage {
                bestCoverage = coverage
                best = (cols, rows)
            }
        }
        return best
    }

    // MARK: Chrome

    override func layout() {
        super.layout()
        layoutEverything()
    }

    private func updateChromeText() {
        let heads = roster.count
        let people = heads == 1 ? "1 person" : "\(heads) people"
        titleLabel.stringValue = session.presetName.isEmpty ? "Class" : session.presetName

        var facts = [people]
        if !session.meetingNumber.isEmpty { facts.append(session.meetingNumber) }
        if let started = session.startedAt {
            let seconds = Int(Date().timeIntervalSince(started))
            facts.append(String(format: "%02d:%02d", seconds / 60, seconds % 60))
        }
        let hands = roster.filter(\.isRaisingHand).count
        if hands > 0 { facts.append(hands == 1 ? "1 hand up" : "\(hands) hands up") }
        if !waiting.isEmpty { facts.append("\(waiting.count) waiting") }
        factsLabel.stringValue = facts.joined(separator: "   ")

        // Recording is Greenroom's own capture, and Greenroom's whole claim is
        // that it never leaves this Mac. So it reads in the brand green that
        // means local throughout the app, not the red that means "broadcasting"
        // - and it says which recorder it is, since Zoom has one too.
        // The dot carries the colour, the words do not. DESIGN.md bars the
        // accent from text outright. The measured reason is that it fails AA on
        // white, and although this chrome is dark enough that it would pass here
        // (~7:1 against the HUD material), the substitute the rule points at,
        // --brand-green #2F6118, would be far LESS legible on a dark surface.
        // Painting the indicator and leaving the label in the system label
        // colour satisfies the rule as written and reads better either way.
        recordingLabel.isHidden = !session.obsRecording
        recordingDot.isHidden = !session.obsRecording
        recordingDot.fill = Self.accent
        recordingLabel.stringValue = "Recording locally"
        recordingLabel.textColor = .labelColor

        emptyState.stringValue = waiting.isEmpty
            ? "Waiting for students.\nThey will appear here as they join."
            : "\(waiting.count) waiting to be let in.\nUse Participants \u{2192} Admit all waiting."

        var stats: [String] = []
        let raisedCount = roster.filter(\.isRaisingHand).count
        let mutedCount = roster.filter(\.isMuted).count
        let cameraOff = roster.filter { !$0.videoOn }.count
        stats.append("students   \(roster.count)")
        if raisedCount > 0 { stats.append("hands up   \(raisedCount)") }
        if mutedCount > 0 { stats.append("muted      \(mutedCount)") }
        if cameraOff > 0 { stats.append("no camera  \(cameraOff)") }
        statsLabel.stringValue = stats.joined(separator: "\n")
    }

    /// Everything the toolbar and context strip render from, flattened.
    private func barSignature() -> String {
        let sdk = ParticipantGridWindowController.sdk
        var parts: [String] = [
            selected.map(String.init) ?? "-",
            String(page),
            String(roster.count),
            String(waiting.count),
            session.obsRecording ? "rec" : "-",
            (sdk?.iAmMuted ?? false) ? "me-muted" : "-",
            (sdk?.myVideoIsOn ?? false) ? "me-video" : "-",
            (sdk?.myHandIsRaised ?? false) ? "me-hand" : "-",
            flags.chatAllowed ? "c" : "-",
            flags.shareAllowed ? "s" : "-",
            flags.renameAllowed ? "r" : "-",
            flags.startVideoAllowed ? "v" : "-",
            flags.unmuteSelfAllowed ? "u" : "-",
            flags.focusModeOn ? "f" : "-",
            flags.incomingAudioStopped ? "q" : "-",
            flags.canSuspend ? "z" : "-",
            roster.contains(where: \.isRaisingHand) ? "hands" : "-",
            roster.contains(where: \.isSpotlighted) ? "spots" : "-"
        ]
        // The context strip mirrors one student, so its state belongs here too.
        if let id = selected, let entry = roster.first(where: { $0.id == id }) {
            parts.append("\(entry.name)|\(entry.isMuted)|\(entry.videoOn)|\(entry.isSpotlighted)|\(entry.isPinned)|\(entry.isRaisingHand)|\(entry.isCoHost)|\(entry.isMyself)")
        }
        return parts.joined(separator: ";")
    }

    private func rebuildBars() {
        rebuildRail()
        rebuildContextBar()
    }

    static var accent: NSColor { NSColor(named: "AccentColor") ?? .systemGreen }

    // MARK: The rail - you, and everything you can do

    /// The left rail: self view on top, then every control, grouped by which
    /// product owns it.
    ///
    /// This replaced a Zoom-shaped bottom toolbar. The toolbar was the right
    /// first move - it matched muscle memory - but on a display the teacher alone
    /// can see, a horizontal strip wastes the space that makes this surface worth
    /// having. A rail fits the whole control set without hiding two thirds of it
    /// behind menus, and leaves the rest of the display to the class.
    ///
    /// Grouped rather than mixed on purpose. "Record" here is Greenroom's own
    /// capture of the OBS composite, and "Mute" is Zoom's; a teacher who cannot
    /// tell which product a button belongs to cannot predict what it will do.
    private func rebuildRail() {
        railControls.forEach { $0.removeFromSuperview() }
        railControls = []
        guard let sdk = ParticipantGridWindowController.sdk else { return }

        railControls.append(Self.railHeader("Greenroom"))

        let recording = session.obsRecording
        railControls.append(Self.railRow(recording ? "Stop recording" : "Record this class",
                                         symbol: recording ? "stop.circle.fill" : "record.circle",
                                         alert: recording) {
            ParticipantGridWindowController.requestToggleRecording()
        })
        railControls.append(Self.railRow("Snap windows back", symbol: "rectangle.3.group") {
            ParticipantGridWindowController.requestSnapBack()
        })
        railControls.append(Self.railRow(session.speakerHidden ? "Show live speaker" : "Hide live speaker",
                                         symbol: session.speakerHidden ? "eye" : "eye.slash") {
            ParticipantGridWindowController.requestToggleSpeaker()
        })
        railControls.append(Self.railRow("Chat", symbol: "bubble.left.and.bubble.right") {
            ParticipantGridWindowController.requestShowChat()
        })
        railControls.append(Self.railRow("Greenroom window", symbol: "macwindow") {
            ParticipantGridWindowController.requestShowMainWindow()
        })

        railControls.append(Self.railHeader("Zoom"))

        let muted = sdk.iAmMuted
        railControls.append(Self.railRow(muted ? "Unmute me" : "Mute me",
                                         symbol: muted ? "mic.slash.fill" : "mic.fill",
                                         alert: muted) {
            Self.perform(muted ? "Unmuted yourself" : "Muted yourself") { $0.setMyMute(!muted) }
        })
        let videoOn = sdk.myVideoIsOn
        railControls.append(Self.railRow(videoOn ? "Stop my video" : "Start my video",
                                         symbol: videoOn ? "video.fill" : "video.slash.fill",
                                         alert: !videoOn) {
            Self.perform(videoOn ? "Stopped your video" : "Started your video") { $0.setMyVideo(on: !videoOn) }
        })
        railControls.append(Self.railMenuRow("Participants (\(roster.count))",
                                             symbol: "person.2.fill",
                                             items: participantItems()))
        railControls.append(Self.railMenuRow("Reactions", symbol: "hand.thumbsup", items: reactionItems()))
        railControls.append(Self.railMenuRow("Security", symbol: "shield.lefthalf.filled", items: securityItems()))
        railControls.append(Self.railRow("Meeting info", symbol: "info.circle") {
            Self.showMeetingInfo()
        })

        if !waiting.isEmpty {
            railControls.append(Self.railRow("Admit \(waiting.count) waiting",
                                             symbol: "person.badge.plus", alert: true) {
                Self.perform("Admitted everyone waiting") { $0.admitEveryoneWaiting() }
            })
        }

        railControls.append(Self.railRow("End session", symbol: "xmark.circle.fill", destructive: true) {
            Self.confirm(title: "End the session?",
                         message: "Leaves the meeting, finishes any recording, and shuts OBS down.",
                         confirm: "End session") {
                ParticipantGridWindowController.requestEndSession()
            }
        })

        railControls.forEach { rail.addSubview($0) }
    }

    /// Self view on top, then the controls down the rail.
    private func layoutRail() {
        let pad: CGFloat = 12
        let width = Self.railWidth - pad * 2
        // 16:9, because that is the shape of the OBS composite being sent.
        let videoHeight = (width * 9 / 16).rounded()
        var y = rail.bounds.height - pad - videoHeight
        selfViewHost.frame = NSRect(x: pad, y: y, width: width, height: videoHeight)
        selfVideo?.frame = selfViewHost.bounds

        y -= 18
        selfViewLabel.sizeToFit()
        selfViewLabel.frame = NSRect(x: pad, y: y, width: width, height: 16)

        // Microphone block, directly under your own picture: the two things you
        // check about yourself in one place.
        y -= 22
        micLabel.frame = NSRect(x: pad, y: y, width: width, height: 14)
        y -= 16
        micMeter.frame = NSRect(x: pad, y: y, width: width, height: 12)
        y -= 26
        micHint.frame = NSRect(x: pad, y: y, width: width, height: 24)

        y -= 10
        for control in railControls {
            let height: CGFloat = control is NSTextField ? 20 : 28
            y -= height
            control.frame = NSRect(x: pad, y: y, width: width, height: height)
            y -= 2
        }

        // Session facts at the foot of the rail, in mono because they are
        // machine facts - the split DESIGN.md asks for.
        y -= 10
        statsLabel.frame = NSRect(x: pad, y: max(6, y - 30), width: width, height: 36)
    }

    /// The students-overflow carousel. Only drawn when there is a second page.
    private func layoutPager(pages: Int, y: CGFloat, width: CGFloat) {
        let show = pages > 1
        pageLabel.isHidden = !show
        pagePrev?.isHidden = !show
        pageNext?.isHidden = !show
        guard show else { return }

        if pagePrev == nil {
            let previous = Self.pagerButton("chevron.left") { [weak self] in
                guard let self else { return }
                self.page = max(0, self.page - 1)
                self.pageChanged()
            }
            let next = Self.pagerButton("chevron.right") { [weak self] in
                guard let self, let pageCount = self.pageCount else { return }
                self.page = min(pageCount - 1, self.page + 1)
                self.pageChanged()
            }
            pagePrev = previous
            pageNext = next
            addSubview(previous)
            addSubview(next)
        }
        pageLabel.stringValue = "Page \(page + 1) of \(pages)"
        pageLabel.sizeToFit()
        let centreX = Self.railWidth + width / 2
        pageLabel.frame = NSRect(x: centreX - pageLabel.frame.width / 2, y: y + 4,
                                 width: pageLabel.frame.width, height: 16)
        pagePrev?.frame = NSRect(x: pageLabel.frame.minX - 30, y: y + 1, width: 24, height: 22)
        pageNext?.frame = NSRect(x: pageLabel.frame.maxX + 6, y: y + 1, width: 24, height: 22)
    }

    private var pageCount: Int? {
        roster.isEmpty ? nil : max(1, Int(ceil(Double(roster.count) / Double(Self.perPage))))
    }

    /// A page change swaps which students are on screen, so tiles, video
    /// subscriptions and layout all have to follow immediately rather than
    /// waiting for the next poll.
    private func pageChanged() {
        selected = nil
        lastBarSignature = barSignature()
        rebuildRail()
        rebuildContextBar()
        layoutEverything()
        if let provider = lastVideoProvider { attachVideo(provider) }
        if let provider = lastSelfProvider { attachSelfVideo(provider) }
    }

    // MARK: Menu contents

    private func participantItems() -> [(String, () -> Void)] {
        var out: [(String, () -> Void)] = [
            ("Mute all", { Self.perform("Muted everyone") { $0.muteEveryone() } }),
            ("Ask all to unmute", { Self.perform("Asked everyone to unmute") { $0.askEveryoneToUnmute() } })
        ]
        if roster.contains(where: \.isRaisingHand) {
            out.append(("Lower all hands", { Self.perform("Lowered all hands") { $0.lowerEveryHand() } }))
        }
        if roster.contains(where: \.isSpotlighted) {
            out.append(("Clear spotlight", { Self.perform("Cleared spotlight") { $0.clearAllSpotlights() } }))
        }
        if !waiting.isEmpty {
            out.append(("Admit all waiting", { Self.perform("Admitted everyone waiting") { $0.admitEveryoneWaiting() } }))
        }
        return out
    }

    private func reactionItems() -> [(String, () -> Void)] {
        guard let sdk = ParticipantGridWindowController.sdk else { return [] }
        let raised = sdk.myHandIsRaised
        var out: [(String, () -> Void)] = [
            (raised ? "Lower my hand" : "Raise my hand",
             { Self.perform(raised ? "Lowered your hand" : "Raised your hand") { $0.setMyHand(raised: !raised) } })
        ]
        for reaction in ZoomMeetingSDKClient.Reaction.allCases {
            out.append((reaction.rawValue, {
                Self.perform("Sent \(reaction.rawValue.lowercased())") { $0.send(reaction) }
            }))
        }
        return out
    }

    /// Named Security, as Zoom names it. Set once at the start of a term rather
    /// than reached for mid-lesson, which is why these sit behind a menu.
    private func securityItems() -> [(String, () -> Void)] {
        var out: [(String, () -> Void)] = []
        func toggle(_ title: String, _ on: Bool, _ apply: @escaping (Bool) -> Void) {
            out.append(((on ? "\u{2713} " : "   ") + title, { apply(!on) }))
        }
        toggle("Participants can unmute themselves", flags.unmuteSelfAllowed) { on in
            Self.perform(on ? "Participants may unmute themselves" : "Participants may not unmute themselves") {
                $0.setAllowUnmuteSelf(on)
            }
        }
        toggle("Participants can start video", flags.startVideoAllowed) { on in
            Self.perform(on ? "Participants may start video" : "Participants may not start video") {
                $0.setAllowStartVideo(on)
            }
        }
        toggle("Participants can chat", flags.chatAllowed) { on in
            Self.perform(on ? "Chat allowed" : "Chat turned off") { $0.setAllowChat(on) }
        }
        toggle("Participants can rename themselves", flags.renameAllowed) { on in
            Self.perform(on ? "Renaming allowed" : "Renaming turned off") { $0.setAllowRename(on) }
        }
        toggle("Focus mode", flags.focusModeOn) { on in
            Self.perform(on ? "Focus mode on \u{2014} students see only you" : "Focus mode off") {
                $0.setFocusMode(on)
            }
        }
        let stopped = flags.incomingAudioStopped
        out.append((stopped ? "Restore incoming audio" : "Silence the room on this Mac only", {
            Self.perform(stopped ? "Restored incoming audio" : "Silenced the room on this Mac only") {
                $0.setIncomingAudioStopped(!stopped)
            }
        }))
        if flags.canSuspend {
            out.append(("Suspend all activities\u{2026}", {
                Self.confirm(title: "Suspend all participant activities?",
                             message: "This stops every camera, microphone, share and chat in the meeting at once. Use it only if something has gone wrong.",
                             confirm: "Suspend") {
                    Self.perform("Suspended all participant activities") { $0.suspendAllActivities() }
                }
            }))
        }
        return out
    }

    /// Zoom's (i) button: how somebody else gets into this room.
    private static func showMeetingInfo() {
        guard let invite = ParticipantGridWindowController.sdk?.meetingInvite() else {
            ParticipantGridWindowController.report("Meeting details are not available yet.")
            return
        }
        let alert = NSAlert()
        alert.messageText = invite.topic.isEmpty ? "Meeting info" : invite.topic
        alert.informativeText = "Anyone with this link can join."
        alert.addButton(withTitle: "Copy invitation")
        alert.addButton(withTitle: "Done")

        // Selectable, so the link can be picked out by hand as well as copied
        // wholesale.
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 84))
        field.string = invite.shareText
        field.isEditable = false
        field.isSelectable = true
        field.drawsBackground = false
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        alert.accessoryView = field

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(invite.shareText, forType: .string)
            ParticipantGridWindowController.report("Invitation copied \u{2014} paste it wherever you invite people.")
        }
    }


    // MARK: Context bar - the selected student

    private func rebuildContextBar() {
        contextBar.subviews.forEach { $0.removeFromSuperview() }
        guard let id = selected, let entry = roster.first(where: { $0.id == id }) else { return }

        let name = NSTextField(labelWithString: entry.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = .labelColor
        var controls: [NSView] = [name]

        if !entry.isMyself {
            controls.append(Self.button(entry.isMuted ? "Unmute" : "Mute",
                                        symbol: entry.isMuted ? "mic" : "mic.slash") {
                let mute = !entry.isMuted
                // Unmuting someone else is a request in Zoom's model, never a
                // command - the wording has to match or the teacher waits for
                // something that was never going to happen on its own.
                Self.perform(mute ? "Muted \(entry.name)" : "Asked \(entry.name) to unmute") {
                    $0.setMuted(mute, userID: id)
                }
            })
            controls.append(Self.button(entry.videoOn ? "Stop video" : "Ask to start video",
                                        symbol: entry.videoOn ? "video.slash" : "video") {
                let stop = entry.videoOn
                Self.perform(stop ? "Stopped \(entry.name)'s video" : "Asked \(entry.name) to start video") {
                    $0.setVideoMuted(stop, userID: id)
                }
            })
        }
        controls.append(Self.button(entry.isSpotlighted ? "Unspotlight" : "Spotlight",
                                    symbol: entry.isSpotlighted ? "star.slash" : "star",
                                    prominent: !entry.isSpotlighted) {
            let on = !entry.isSpotlighted
            Self.perform(on ? "Spotlighted \(entry.name) for everyone" : "Removed \(entry.name) from spotlight") {
                $0.spotlight(on, userID: id)
            }
        })
        controls.append(Self.button(entry.isPinned ? "Unpin" : "Pin for me",
                                    symbol: entry.isPinned ? "pin.slash" : "pin") {
            let on = !entry.isPinned
            Self.perform(on ? "Pinned \(entry.name) on this Mac only" : "Unpinned \(entry.name)") {
                $0.pin(on, userID: id)
            }
        })
        if entry.isRaisingHand {
            controls.append(Self.button("Lower hand", symbol: "hand.raised.slash") {
                Self.perform("Lowered \(entry.name)'s hand") { $0.lowerHand(userID: id) }
            })
        }
        controls.append(Self.button("Rename", symbol: "pencil") {
            Self.prompt(title: "Rename \(entry.name)", current: entry.name) { newName in
                Self.perform("Renamed \(entry.name) to \(newName)") { $0.rename(userID: id, to: newName) }
            }
        })
        if !entry.isMyself {
            controls.append(Self.button(entry.isCoHost ? "Remove co-host" : "Make co-host",
                                        symbol: "person.2") {
                let on = !entry.isCoHost
                Self.perform(on ? "\(entry.name) is now a co-host" : "\(entry.name) is no longer a co-host") {
                    $0.setCoHost(on, userID: id)
                }
            })
            controls.append(Self.button("Make host", symbol: "person.badge.key") {
                Self.confirm(title: "Make \(entry.name) the host?",
                             message: "You become a co-host. You cannot take the host role back without the host key.",
                             confirm: "Make host") {
                    Self.perform("\(entry.name) is now the host") { $0.makeHost(userID: id) }
                }
            })
            controls.append(Self.button("Remove", symbol: "person.fill.xmark", destructive: true) {
                Self.confirm(title: "Remove \(entry.name) from the meeting?",
                             message: "They cannot rejoin this meeting.",
                             confirm: "Remove") {
                    Self.perform("Removed \(entry.name)") { $0.expel(userID: id) }
                }
            })
        }
        Self.pack(controls, into: contextBar, height: Self.contextHeight)
    }

    // MARK: Control helpers

    private static func pack(_ controls: [NSView], into bar: NSView, height: CGFloat) {
        var x: CGFloat = 16
        for control in controls {
            if control is NSTextField { control.frame.size = control.fittingSize }
            else if control.frame.width == 0 { control.frame.size = control.fittingSize }
            control.frame.origin = NSPoint(x: x, y: (height - control.frame.height) / 2)
            bar.addSubview(control)
            x = control.frame.maxX + 8
        }
    }

    /// A section eyebrow: mono, uppercase, letter-spaced, per DESIGN.md.
    private static func railHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// A full-width rail row: icon, then label, left aligned. Reads as a control
    /// panel rather than a toolbar, which is the point of the rail.
    private static func railRow(_ title: String,
                                symbol: String,
                                alert: Bool = false,
                                destructive: Bool = false,
                                action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action)
        button.title = " " + title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        // systemRed, not the brand accent: DESIGN.md bars the accent from text,
        // and red-for-muted is the convention being matched anyway.
        button.contentTintColor = destructive || alert ? .systemRed : .labelColor
        return button
    }

    private static func railMenuRow(_ title: String,
                                    symbol: String,
                                    items: [(String, () -> Void)]) -> NSView {
        let menu = NSMenu()
        for (label, action) in items {
            let carrier = BlockMenuItem(title: label, action)
            let item = NSMenuItem(title: label, action: #selector(BlockMenuItem.fire), keyEquivalent: "")
            item.target = carrier
            item.representedObject = carrier   // NSMenuItem.target is weak
            menu.addItem(item)
        }
        let button = ToolMenuButton(menu: menu)
        button.title = " " + title + "\u{2026}"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .labelColor
        return button
    }

    private static func pagerButton(_ symbol: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        return button
    }

    /// One toolbar button, icon above a small label, the way Zoom draws them.
    ///
    /// `alert` uses systemRed rather than the brand accent: red-when-muted is
    /// Zoom's own convention and the muscle memory being matched, and it keeps
    /// the accent out of text, which DESIGN.md forbids. systemRed is a platform
    /// colour, which the same document allows for chrome.
    private static func toolButton(_ title: String,
                                   symbol: String,
                                   alert: Bool = false,
                                   destructive: Bool = false,
                                   action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action)
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageAbove
        button.isBordered = false
        button.font = .systemFont(ofSize: 10)
        button.contentTintColor = destructive || alert ? .systemRed : .labelColor
        button.sizeToFit()
        button.frame.size.width = max(button.frame.width + 20, 72)
        button.frame.size.height = 48
        return button
    }

    /// A toolbar button that drops a menu.
    ///
    /// Built from an NSMenu popped by hand rather than an NSPopUpButton: a
    /// pull-down cannot draw icon-above-label, and a popped menu behaves
    /// predictably inside a non-activating panel, where the stock control's
    /// tracking could not be confirmed working.
    private static func toolMenu(_ title: String,
                                 symbol: String,
                                 items: [(String, () -> Void)]) -> NSView {
        let menu = NSMenu()
        for (label, action) in items {
            let carrier = BlockMenuItem(title: label, action)
            let item = NSMenuItem(title: label, action: #selector(BlockMenuItem.fire), keyEquivalent: "")
            item.target = carrier
            // NSMenuItem.target is weak, so the carrier needs an owner that is
            // not - representedObject retains.
            item.representedObject = carrier
            menu.addItem(item)
        }
        let button = ToolMenuButton(menu: menu)
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageAbove
        button.isBordered = false
        button.font = .systemFont(ofSize: 10)
        button.contentTintColor = .labelColor
        button.sizeToFit()
        button.frame.size.width = max(button.frame.width + 20, 72)
        button.frame.size.height = 48
        return button
    }

    private static func button(_ title: String,
                               symbol: String,
                               prominent: Bool = false,
                               destructive: Bool = false,
                               action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(action)
        button.title = " " + title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12)
        if prominent { button.hasDestructiveAction = false; button.bezelColor = accent }
        if destructive { button.hasDestructiveAction = true }
        button.sizeToFit()
        return button
    }

    fileprivate static func perform(_ success: String,
                                    _ body: (ZoomMeetingSDKClient) -> Bool) {
        guard let sdk = ParticipantGridWindowController.sdk else { return }
        let ok = body(sdk)
        // The success string is a sentence for the status log and can name a
        // student, so it is NEVER the event. Only the outcome travels.
        Analytics.track(.controlAction, [.refused: ok ? "no" : "yes"])
        if ok {
            ParticipantGridWindowController.report(success)
        } else {
            // Named as a refusal rather than a failure: the usual cause is
            // that the SDK will not allow it in this role, not that anything
            // broke. The attempted outcome is quoted so the log says which
            // button was pressed.
            ParticipantGridWindowController.report("Zoom refused that \u{2014} nothing changed. (\(success))")
        }
    }

    private static func confirm(title: String, message: String, confirm: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // Run modal rather than as a sheet: the host is a non-activating panel,
        // and a sheet on a window whose app is not frontmost can appear behind
        // everything with no way to answer it. A destructive confirmation is
        // also the one moment where pulling focus is the correct behaviour.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }

    private static func prompt(title: String, current: String, action: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if response == .alertFirstButtonReturn, !trimmed.isEmpty { action(trimmed) }
    }
}

// MARK: - Chrome background

/// System material, not a hardcoded grey: DESIGN.md reserves the brand palette
/// for content and asks chrome to follow the platform.
@MainActor
private final class BarView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
    }
    required init?(coder: NSCoder) { nil }
}

// MARK: - One student

/// A video view plus the state that video cannot show.
///
/// Zoom draws its own name label into the video it renders, but nothing else:
/// whether a microphone is off, whether a hand is up, whether this is the
/// student currently being spotlighted. Those are the facts a teacher scans for,
/// so they are drawn here rather than inferred.
@MainActor
private final class TileView: NSView {

    let userID: UInt32
    var onSelect: ((UInt32) -> Void)?

    private var video: NSView?
    private let scrim = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let handDot = DotView()
    private let speaking = SpeakingIndicatorView()
    private var isSelected = false
    private var isTalking = false

    init(userID: UInt32) {
        self.userID = userID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10          // DESIGN.md radius-md
        layer?.masksToBounds = true
        layer?.borderWidth = 0

        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        addSubview(scrim)

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .white
        addSubview(nameLabel)

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .right
        addSubview(statusLabel)

        handDot.isHidden = true
        addSubview(handDot)

        speaking.isHidden = true
        addSubview(speaking)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }

    var videoBounds: NSRect { NSRect(origin: .zero, size: bounds.size) }

    func attach(video newVideo: NSView?) {
        guard video !== newVideo else { return }
        video?.removeFromSuperview()
        video = newVideo
        guard let newVideo else { return }
        newVideo.autoresizingMask = [.width, .height]
        newVideo.frame = videoBounds
        addSubview(newVideo, positioned: .below, relativeTo: scrim)
    }

    func detachVideo() {
        video?.removeFromSuperview()
        video = nil
    }

    func apply(entry: ZoomMeetingSDKClient.RosterEntry, isSelected: Bool) {
        self.isSelected = isSelected
        isTalking = entry.isTalking

        var name = entry.name
        if entry.isMyself { name += " (you)" }
        if entry.isHost { name += " · host" }
        else if entry.isCoHost { name += " · co-host" }
        nameLabel.stringValue = name

        // Glyphs only for what is wrong or notable. A student who is unmuted
        // with their camera on gets no badge at all, so the eye lands on the
        // ones that need attention.
        var badges: [String] = []
        if entry.isRaisingHand { badges.append("hand up") }
        if entry.isSpotlighted { badges.append("spotlit") }
        if !entry.hasJoinedAudio { badges.append("no audio") }
        else if entry.isMuted { badges.append("muted") }
        if !entry.videoOn { badges.append("camera off") }
        statusLabel.stringValue = badges.joined(separator: " · ")
        // Always white. The accent marks a raised hand as a filled dot instead
        // of tinting the words - see the note on the recording indicator.
        statusLabel.textColor = .white
        handDot.isHidden = !entry.isRaisingHand
        handDot.fill = RootView.accent
        // Bars, not a level: the SDK reports only that this person is talking,
        // so animating a height against a number we do not have would be
        // fiction. See SpeakingIndicatorView.
        speaking.talking = entry.isTalking

        needsLayout = true
        needsDisplay = true
        layoutStates()
    }

    override func layout() {
        super.layout()
        video?.frame = videoBounds
        layoutStates()
    }

    private func layoutStates() {
        let inset: CGFloat = 8
        let barHeight: CGFloat = 26
        scrim.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        nameLabel.sizeToFit()
        nameLabel.frame = NSRect(x: inset, y: (barHeight - nameLabel.frame.height) / 2,
                                 width: min(nameLabel.frame.width, bounds.width * 0.6),
                                 height: nameLabel.frame.height)
        statusLabel.sizeToFit()
        statusLabel.frame = NSRect(x: bounds.width - statusLabel.frame.width - inset,
                                   y: (barHeight - statusLabel.frame.height) / 2,
                                   width: statusLabel.frame.width, height: statusLabel.frame.height)
        let dotSize: CGFloat = 8
        handDot.frame = NSRect(x: statusLabel.frame.minX - dotSize - 6,
                               y: (barHeight - dotSize) / 2, width: dotSize, height: dotSize)
        // Top-left, away from the name bar, so a talking student is obvious
        // without reading anything.
        speaking.frame = NSRect(x: inset, y: bounds.height - inset - 14, width: 18, height: 14)

        // Speaking is the one thing worth a colour on the tile itself, and
        // accent-lime is a fill token, so a stroke is a legitimate use of it.
        // Selection outranks it: the teacher needs to see what their next click
        // will act on more than who is talking.
        // Two ring states, not three. Selection is white rather than
        // controlAccentColor: that follows whatever hue the user picked in System
        // Settings, which can land on a blue or pink that fights the brand on a
        // surface this saturated. Speaking gets the accent, which is a stroke and
        // therefore a legitimate fill use of a token barred from text.
        // Spotlighting needs no ring - the badge already reads "spotlit", and a
        // third ring style would make all three harder to tell apart.
        if isSelected {
            layer?.borderWidth = 3
            layer?.borderColor = NSColor.white.cgColor
        } else if isTalking {
            layer?.borderWidth = 3
            layer?.borderColor = RootView.accent.cgColor
        } else {
            layer?.borderWidth = 0
        }
    }

    /// The whole tile is one click target. Without this the SDK's own video
    /// view sits on top and may consume the click, so selecting a student would
    /// work on some tiles and not others depending on what Zoom is rendering.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Accept the very first click.
    ///
    /// AppKit swallows the click that brings a non-key window forward unless the
    /// view under the cursor opts in, and this panel is deliberately
    /// non-activating so it never steals focus from the main screen - so it is
    /// almost never key. Without this, EVERY control needed two clicks: one
    /// discarded to make the panel key, one to act. Found live on a three-display
    /// setup; the second click worked, which is what identified it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onSelect?(userID) }
}

// MARK: - Meters

/// A segmented level bar, the shape of a hardware meter rather than a progress
/// view - discrete segments read as "loud enough" at a glance, where a smooth
/// fill has to be measured against its own track.
///
/// Green through most of the travel, amber near the top. Both are system
/// colours: DESIGN.md keeps the brand accent out of anything text-like and
/// reserves its amber for "leaves your Mac", which a microphone level is not.
@MainActor
private final class LevelMeterView: NSView {

    var level: Double = 0 { didSet { if abs(level - oldValue) > 0.01 { needsDisplay = true } } }
    /// Drawn hollow when the mic is muted in Zoom, so a moving meter never
    /// implies the class can hear you.
    var muted = false { didSet { needsDisplay = true } }

    private let segments = 20

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let unit = (bounds.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
        let lit = Int((Double(segments) * level).rounded())

        for index in 0..<segments {
            let rect = NSRect(x: CGFloat(index) * (unit + gap), y: 0, width: unit, height: bounds.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            let hot = index >= segments - 3
            if index < lit && !muted {
                (hot ? NSColor.systemOrange : NSColor.systemGreen).setFill()
                path.fill()
            } else if index < lit && muted {
                // Muted: outline only. The level is still real, but it is going
                // nowhere, and the drawing should say so.
                (hot ? NSColor.systemOrange : NSColor.systemGreen).withAlphaComponent(0.5).setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
                path.fill()
            }
        }
    }
}

/// Three bars that animate while someone is talking.
///
/// Deliberately NOT presented as a level. The SDK gives `isTalking` and nothing
/// else for other participants - no amplitude at all - so a bar whose height
/// tracked a number would be inventing one. These bounce on a fixed loop to say
/// "this person is speaking", which is the whole of what is actually known.
@MainActor
private final class SpeakingIndicatorView: NSView {

    var talking = false {
        didSet {
            guard talking != oldValue else { return }
            isHidden = !talking
            talking ? start() : stop()
        }
    }

    private var phase = 0.0
    private var timer: Timer?

    private func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.phase += 0.28
                self.needsDisplay = true
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGreen.setFill()
        let count = 3
        let gap: CGFloat = 2
        let unit = (bounds.width - CGFloat(count - 1) * gap) / CGFloat(count)
        for index in 0..<count {
            let wave = (sin(phase + Double(index) * 1.1) + 1) / 2
            let height = bounds.height * CGFloat(0.35 + 0.65 * wave)
            let rect = NSRect(x: CGFloat(index) * (unit + gap),
                              y: (bounds.height - height) / 2,
                              width: unit, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}

// MARK: - A filled indicator

/// A small filled circle. Exists so the brand accent can mark state without ever
/// becoming text, which DESIGN.md forbids.
@MainActor
private final class DotView: NSView {
    var fill: NSColor = .white { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// MARK: - Target carriers

/// A button that owns its own action.
///
/// AppKit targets are unowned and these controls are rebuilt on every refresh,
/// so a separate target object would have to be kept alive by something. Having
/// the button be its own target removes the question.
/// A toolbar button that owns and pops its own menu.
@MainActor
private final class ToolMenuButton: NSButton {
    private let owned: NSMenu
    init(menu: NSMenu) {
        self.owned = menu
        super.init(frame: .zero)
        target = self
        action = #selector(pop)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func pop() {
        // Above the button, since the toolbar sits at the bottom of the screen.
        owned.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
    /// See TileView.acceptsFirstMouse - the panel is rarely key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class ClosureButton: NSButton {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) {
        self.body = body
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func fire() { body() }

    /// See TileView.acceptsFirstMouse - the panel is rarely key, so without this
    /// every button press was discarded the first time.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A pop-up that also answers the first click. NSPopUpButton has the same
/// first-mouse problem as every other control in a non-activating panel, and
/// no way to opt in without subclassing.
@MainActor
private final class FirstClickPopUpButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class BlockMenuItem: NSObject {
    private let body: () -> Void
    let title: String
    init(title: String, _ body: @escaping () -> Void) {
        self.title = title
        self.body = body
    }
    @objc func fire() { body() }
}
