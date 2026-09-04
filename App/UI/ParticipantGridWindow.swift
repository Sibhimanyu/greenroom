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
        /// How far the start has got. See `Readiness`.
        var readiness = Readiness()
    }

    /// How much of the session is up yet.
    ///
    /// The panel used to open only once the meeting was connected, which left
    /// the reference display blank for the whole start - several seconds of
    /// OBS, virtual camera, meeting creation and SDK auth during which the
    /// teacher could see the workspace appear and then nothing at all. The work
    /// was never invisible to the app; every step already wrote a line into the
    /// status log. It was invisible to the person waiting, because that log is
    /// collapsed by default and lives in another window on another display.
    ///
    /// So the panel opens on the first frame of the start and shows this
    /// instead, filling in as each piece comes live. That is not decoration: a
    /// start that hangs now hangs visibly, on a named step.
    struct Readiness: Equatable {
        enum State: Equatable { case pending, active, done, skipped, failed }
        struct Step: Equatable {
            var label: String
            var state: State
        }

        var steps: [Step] = []
        /// Set when a start fails, so the panel stops promising it is coming.
        var failure: String?
        /// The newest status line, shown under the steps. Without it the card
        /// says only which step is running, and a slow step reads as a hang.
        var detail: String?

        /// True once there is nothing left to wait for. An empty list counts as
        /// live so that anything not driving readiness - the default Zoom-UI
        /// path, a panel reopened mid-session - behaves exactly as before.
        var isLive: Bool {
            failure == nil && steps.allSatisfy { $0.state == .done || $0.state == .skipped }
        }
        var settled: Int { steps.filter { $0.state == .done || $0.state == .skipped }.count }
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
    /// Whether the featured speaker gets the large tile above the gallery,
    /// or everyone shares the grid equally. What \u{2325}\u{2318}Z toggles now.
    ///
    /// A pop-out window was tried and is not possible: Zoom's own capability
    /// matrix for custom UI says "Multiple windows: No (regions in 1
    /// container)" - SDK-rendered video cannot leave the container's window,
    /// and a pop-out needs the raw-data pipeline instead. The experiment
    /// agreed: the re-parented view landed in a visible window at the right
    /// size and still drew black.
    static var featuredViewEnabled = true
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
    /// Where the panel currently lives, for alerts that must appear on the
    /// same display the teacher is looking at.
    fileprivate static var panelScreen: NSScreen? { panel?.screen }
    /// The panel window itself, for the alert runner to step around.
    fileprivate static var panelWindowForAlerts: NSWindow? { panel }
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
        ZoomMeetingSDKClient.videoLog("panel form=\(windowed ? "windowed" : "fullscreen")"
            + " screen=\(screen.localizedName) size=\(Int(frame.width))x\(Int(frame.height))")
        created.isReleasedWhenClosed = false
        created.hidesOnDeactivate = false
        created.backgroundColor = .black
        // Ordinary window level, deliberately - both forms.
        //
        // The full-screen form sat at .statusBar for a while so it would cover
        // the menu bar and Dock, and that was the wrong trade: at that level
        // every OTHER window on the display layers underneath it too, which
        // made the reference monitor unusable for anything else - reported
        // live as "when it is full screen I am not able to do anything else on
        // that monitor". A panel that fills the display at .normal keeps the
        // display usable: other windows can come in front, and the menu bar
        // drawing over the top sliver is a fair price. Never a fullscreen
        // Space either - a window in a Space cannot be re-framed, which is why
        // the Zoom-UI placer has to eject its gallery from fullscreen.
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
        lastScreen = screen
        lastSession = session
        // Who draws the checklist. Full-screen on its own display, the panel
        // owns it. Windowed, it is just another window on a single screen about
        // to be buried by the tiling, so the floating HUD carries it and the
        // panel behaves as if the session were already up. The readiness itself
        // still reaches the panel either way - it is what dims the controls.
        root?.showsReadiness = !windowed

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
                     featured: client.speakerToShow(),
                     videoProvider: { id, frame, hero in
                         client.participantView(userID: id, frame: frame, hero: hero)
                     },
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
    /// The last inputs to `refresh`, so a control can redraw the panel the
    /// instant it acts instead of waiting for the next poll tick.
    private static var lastScreen: NSScreen?
    private static var lastSession = SessionInfo()

    /// Re-reads SDK state and redraws now.
    ///
    /// Without this every control had up to a full second of dead time: the
    /// roster poll runs at 1Hz, so pressing "Mute me" left the button still
    /// saying "Mute me" until the next tick. Nothing was broken, but nothing
    /// acknowledged the press either, which is the whole of what "unresponsive"
    /// meant here.
    static func refreshNow() {
        guard let screen = lastScreen else { return }
        refresh(on: screen, session: lastSession, windowed: isWindowed)
    }

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
    private let readiness = ReadinessView()
    /// False when the floating HUD is carrying the start instead - see `refresh`.
    fileprivate var showsReadiness = true

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
    private var lastVideoProvider: ((UInt32, NSRect, Bool) -> NSView?)?
    private var lastSelfProvider: ((NSRect) -> NSView?)?

    private var roster: [ZoomMeetingSDKClient.RosterEntry] = []
    /// Who gets the large tile above the gallery. See speakerToShow().
    private var featuredID: UInt32?
    /// How much of the grid area the featured speaker takes. Zoom's own
    /// custom-UI example splits 70/30; a class needs a little more room for
    /// faces than a one-to-one call, so the gallery keeps slightly more.
    private static let featuredShare: CGFloat = 0.58
    private var page = 0
    private let rail = BarView()
    /// The rail scrolls.
    ///
    /// Without this the controls were laid downward from a fixed origin, so a
    /// short window pushed End session and the session facts to negative
    /// coordinates - off the rail entirely, unreachable, and invisible even to
    /// the accessibility tree. Reproduced by resizing the window to 620x520.
    private let railScroll = NSScrollView()
    private let railContent = NSView()
    private let railDivider = NSView()
    private let selfViewHost = NSView()
    private let selfViewLabel = NSTextField(labelWithString: "You, as the class sees you")
    private var selfVideo: NSView?
    private var railControls: [NSView] = []
    private let micMeter = LevelMeterView()
    private let micLabel = NSTextField(labelWithString: "Your microphone")
    private let micHint = NSTextField(labelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    /// The block under the controls. Persistent views whose text is rewritten
    /// each tick, never rebuilt - see `updateNeedsBlock`.
    private let needsEyebrow = NSTextField(labelWithString: "")
    private let needsRows: [NSTextField] = (0..<6).map { _ in NSTextField(labelWithString: "") }
    /// When each currently-raised hand went up.
    ///
    /// The SDK reports `isRaisingHand` as a bare bool with no timestamp, so
    /// raise order is remembered here or not at all. It has to be remembered:
    /// a set of raised hands tells a teacher how many, and the one thing they
    /// actually need from it is who to call on first.
    private var handRaisedAt: [UInt32: Date] = [:]
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
    /// The rail/grid split is not fixed: as students arrive the grid earns space
    /// back and the rail shrinks toward a floor that still fits its controls.
    ///
    /// Started life at a flat 300pt, which read as 20/80 on a 1920 display: a
    /// postage-stamp self view next to an enormous empty rectangle.
    ///
    /// These fractions now only ever SHRINK the rail - `railWidth` caps it at
    /// what the content actually needs - so on any display wider than about
    /// 870pt the first two cases are inert and the rail simply sits at its
    /// ceiling until a class starts filling up. They still bind on a small
    /// window, which is the only place a fraction of the display is the right
    /// way to describe a panel.
    private static func railFraction(students: Int) -> CGFloat {
        switch students {
        case 0: return 0.62
        case 1...2: return 0.48
        case 3...4: return 0.40
        case 5...9: return 0.32
        default: return 0.26
        }
    }

    /// As wide as the content needs, and no wider.
    ///
    /// This used to be a fraction of the display and nothing else, which made
    /// sense while the rail's contents stretched to fill whatever they were
    /// given. They do not any more - `railColumn` caps them - so a rail sized by
    /// fraction just bought margin. Empty room on a 1496pt display: a 926pt rail
    /// wrapping a 396pt column in 265pt of nothing on each side.
    ///
    /// So the content sets the ceiling and the floor, and `railFraction` only
    /// decides how much of that range a filling class claws back.
    private var railWidth: CGFloat {
        let share = bounds.width * Self.railFraction(students: roster.count)
        // Both bounds yield on a narrow window. A hard minimum used to swallow
        // the whole width and leave the grid at zero, so it gives way once the
        // window is small enough that something has to.
        let ceiling = min(Self.railWidthHolding(cells: railCellsPerRow),
                          bounds.width * 0.66)
        let floor = min(Self.railWidthHolding(cells: Self.railMinCellsPerRow),
                        bounds.width * 0.45)
        return max(floor, min(share, ceiling)).rounded()
    }

    /// The widest column whose WHOLE stack - picture, controls, needs block -
    /// still fits the rail's height.
    ///
    /// Sizing the column on width alone made the picture as big as the rail was
    /// wide, and on a 845pt-tall window that pushed the block under the controls
    /// off the bottom the moment one student joined. That block exists to answer
    /// "who is at the door, whose hand is up"; a version of it you have to
    /// scroll to find is no use in the middle of a lesson. So the column answers
    /// to both dimensions and the picture gives up width to keep the panel whole.
    ///
    /// When nothing fits - a full class on a short window, where the rail is
    /// genuinely cramped - it takes the size that overflows least rather than
    /// the narrowest, because narrower means more wrapped rows and a TALLER
    /// control column. Reaching for the minimum there would make it worse.
    private var railCellsPerRow: Int {
        let ceiling = Self.railMaxCellsPerRow
        // Before the first rebuild there is nothing to measure.
        guard !railControls.isEmpty, railBodyHeight > 0 else { return ceiling }

        var best = (cells: ceiling, stack: CGFloat.greatestFiniteMagnitude)
        for cells in stride(from: ceiling, through: Self.railMinCellsPerRow, by: -1) {
            let column = CGFloat(cells) * (Self.railCell.width + Self.railCellGap)
                - Self.railCellGap
            let stack = selfBlockHeight(width: column)
                + controlColumnHeight(width: column)
                + needsBlockHeight(width: column) + 10 + Self.railPad * 2
            if stack <= railBodyHeight { return cells }
            if stack < best.stack { best = (cells, stack) }
        }
        return best.cells
    }

    /// The rail's usable height, which is what `railCellsPerRow` fits against.
    /// Mirrors what `layoutEverything` hands the rail.
    private var railBodyHeight: CGFloat {
        max(0, bounds.height - Self.barHeight
               - Self.bottomHeight - (selected != nil ? Self.contextHeight : 0))
    }

    /// The rail width that wraps a column of `cells` in margin. Derived rather
    /// than tuned, so changing the cell size or the five-across cap moves the
    /// rail with it instead of stranding a magic number.
    private static func railWidthHolding(cells: Int) -> CGFloat {
        let column = CGFloat(cells) * (railCell.width + railCellGap) - railCellGap
        return column + railColumnMargin * 2 + railPad * 2
    }
    /// Breathing room each side of the content column, and the rail's own inset.
    ///
    /// 24, down from 60. Sixty was chosen to make surplus width read as margin
    /// rather than as a column that failed to fill its box - which it did, but
    /// once the column stopped being oversized the margin had nothing left to
    /// justify. It was 120pt of the rail spent on nothing.
    private static let railColumnMargin: CGFloat = 24
    private static let railPad: CGFloat = 12
    /// Three across is the narrowest the control grid still reads as a grid.
    private static let railMinCellsPerRow = 3
    /// The mic meter's cap. See the note where it is placed.
    private static let railMeterWidth: CGFloat = 200
    /// One line in the block under the controls.
    private static let railRowHeight: CGFloat = 18
    /// Marks a control that insists on starting its own row.
    private static let railBreakTag = 7001
    /// The fixed stack between the picture and the controls: caption, mic
    /// eyebrow, meter row, trailing space. Named because `selfBlockHeight` and
    /// `layoutSelfBlock` both step through it and have to agree.
    ///
    /// The hint used to be a fifth step worth 26pt. It now sits beside the
    /// meter, because a one-line gloss on what the meter is already showing did
    /// not earn its own row.
    private static let selfChrome = (caption: CGFloat(18), micLabel: CGFloat(22),
                                     meter: CGFloat(16), trail: CGFloat(24))
    private static var selfChromeHeight: CGFloat {
        selfChrome.caption + selfChrome.micLabel + selfChrome.meter + selfChrome.trail
    }

    /// One control cell. Read by the measuring pass and the placing pass both,
    /// which have to agree or the rail scrolls to the wrong offset.
    private static let railCell = CGSize(width: 76, height: 54)
    private static let railCellGap: CGFloat = 4
    /// The widest the rail's content column may get, counted in control cells
    /// rather than points.
    ///
    /// Seven, not five. Five was picked for the control grid alone and it was a
    /// reasonable number for a control grid, but the column carries the self
    /// view too, and the picture is the primary thing here - sizing the column
    /// to the buttons made the media pay for the buttons' comfort. Seven also
    /// happens to clear Zoom's six-button group in a single row, where five
    /// forced it to wrap and cost 58pt of column to do it.
    private static let railMaxCellsPerRow = 7
    /// Break above a section eyebrow, and the breath below it before its first
    /// row. Both on the DESIGN.md 4px scale. They are the only vertical gaps in
    /// the control column that are a decision; every other gap is the cell grid.
    private static let railGroupGap: CGFloat = 20
    private static let railEyebrowGap: CGFloat = 8
    /// How many students fit on one page before the carousel appears. Fixed
    /// rather than computed from the area: a page size that changed as people
    /// joined would reshuffle faces mid-lesson, which is exactly when a teacher
    /// is relying on their position.
    /// How many students fit before the carousel appears, derived from the grid's
    /// real size rather than fixed.
    ///
    /// It was a flat 9, which on a small window meant nine unreadable slivers and
    /// on a large one wasted room. Quantised into a few steps rather than computed
    /// exactly, because a page size that changed by one on every few pixels of
    /// resize would reshuffle faces while a teacher was looking at them.
    private var perPage: Int {
        let area = gridHost.bounds
        guard area.width > 0, area.height > 0 else { return 9 }
        // ~260x150 is the smallest tile a face and a name label stay legible in.
        let fits = Int(area.width / 260) * Int(area.height / 150)
        switch fits {
        case ..<2: return 1
        case ..<4: return 2
        case ..<6: return 4
        case ..<9: return 6
        case ..<12: return 9
        default: return 12
        }
    }
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

        // The rail and the class share two dark greys that differ by almost
        // nothing, so in dark mode the split read as an accident rather than a
        // division. A hairline is the lightest thing that says it is deliberate.
        railDivider.wantsLayer = true
        railDivider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(railDivider)

        railScroll.drawsBackground = false
        railScroll.hasVerticalScroller = true
        // Overlay style so the scroller does not permanently steal width from a
        // rail that usually does not need one.
        railScroll.scrollerStyle = .overlay
        railScroll.autohidesScrollers = true
        railScroll.documentView = railContent
        rail.addSubview(railScroll)

        selfViewHost.wantsLayer = true
        selfViewHost.layer?.backgroundColor = NSColor.black.cgColor
        selfViewHost.layer?.cornerRadius = 10        // DESIGN.md radius-md
        selfViewHost.layer?.masksToBounds = true
        railContent.addSubview(selfViewHost)

        selfViewLabel.font = .systemFont(ofSize: 11)
        selfViewLabel.textColor = .secondaryLabelColor
        railContent.addSubview(selfViewLabel)

        micLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        micLabel.textColor = .tertiaryLabelColor
        micLabel.stringValue = "YOUR MICROPHONE"
        railContent.addSubview(micLabel)
        railContent.addSubview(micMeter)

        // One line now that it sits beside the meter rather than under it.
        micHint.font = .systemFont(ofSize: 10)
        micHint.textColor = .secondaryLabelColor
        micHint.maximumNumberOfLines = 1
        micHint.lineBreakMode = .byTruncatingTail
        railContent.addSubview(micHint)

        needsEyebrow.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        needsEyebrow.textColor = .tertiaryLabelColor
        railContent.addSubview(needsEyebrow)
        for row in needsRows {
            row.textColor = .secondaryLabelColor
            row.lineBreakMode = .byTruncatingTail
            railContent.addSubview(row)
        }

        statsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statsLabel.textColor = .tertiaryLabelColor
        statsLabel.maximumNumberOfLines = 3
        statsLabel.usesSingleLineMode = false
        statsLabel.lineBreakMode = .byWordWrapping
        railContent.addSubview(statsLabel)

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

        addSubview(readiness)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }

    // MARK: Update

    func update(roster: [ZoomMeetingSDKClient.RosterEntry],
                flags: ZoomMeetingSDKClient.RoomFlags,
                waiting: [(id: UInt32, name: String)],
                session: ParticipantGridWindowController.SessionInfo,
                featured: UInt32?,
                videoProvider: @escaping (UInt32, NSRect, Bool) -> NSView?,
                selfProvider: @escaping (NSRect) -> NSView?) {
        self.roster = roster
        self.featuredID = ParticipantGridWindowController.featuredViewEnabled ? featured : nil
        self.flags = flags
        self.waiting = waiting
        self.session = session
        self.readiness.apply(session.readiness)

        // A selection whose owner left must not linger: its actions would apply
        // to a user ID the SDK has already recycled.
        if let selected, !roster.contains(where: { $0.id == selected }) { self.selected = nil }

        // Stamp new hands, forget lowered ones. Dropping the entry on lower is
        // what makes a hand that goes up again go to the BACK of the queue,
        // which is the fair reading and the one a class will expect.
        var raised: Set<UInt32> = []
        for entry in roster where entry.isRaisingHand {
            raised.insert(entry.id)
            if handRaisedAt[entry.id] == nil { handRaisedAt[entry.id] = Date() }
        }
        handRaisedAt = handRaisedAt.filter { raised.contains($0.key) }

        // Clamp rather than reset. If someone leaves while the teacher is on the
        // last page, dropping them to page one would lose their place; this only
        // moves them when the page they are on no longer exists.
        let pages = max(1, Int(ceil(Double(roster.count) / Double(perPage))))
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
    private func attachVideo(_ videoProvider: @escaping (UInt32, NSRect, Bool) -> NSView?) {
        lastVideoProvider = videoProvider
        for entry in pageRoster {
            guard let tile = tiles[entry.id], !tile.bounds.isEmpty else { continue }
            let hero = entry.id == featuredID
            // The featured tile is the one stream worth spending quality on.
            tile.attach(video: videoProvider(entry.id, tile.videoBounds, hero))
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

    private var lastRailWidth: CGFloat = 0

    private func layoutEverything() {
        let width = bounds.width
        let showContext = selected != nil
        // A join or a leave moves the divider, and DESIGN.md budgets 250ms for a
        // layout move. Animated only when the width actually changes, so the
        // one-second poll does not keep the whole panel in motion.
        let railChanged = abs(railWidth - lastRailWidth) > 1 && lastRailWidth > 0
        lastRailWidth = railWidth

        topBar.frame = NSRect(x: 0, y: bounds.height - Self.barHeight,
                              width: width, height: Self.barHeight)
        bottomBar.frame = .zero
        bottomBar.isHidden = true
        // Spans only the grid, not the rail: it describes a selected student, and
        // the students are on the right.
        contextBar.frame = NSRect(x: railWidth, y: 0,
                                  width: max(0, width - railWidth),
                                  height: showContext ? Self.contextHeight : 0)
        contextBar.isHidden = !showContext

        let gridBottom = Self.bottomHeight + (showContext ? Self.contextHeight : 0)
        let bodyHeight = max(0, bounds.height - Self.barHeight - gridBottom)

        // perPage is derived from gridHost's size, and gridHost's height depends
        // on whether the carousel is shown, which depends on perPage. The cycle
        // is broken by measuring against the full body height first: the carousel
        // is 24pt, far less than one quantisation step, so including it or not
        // cannot change the answer.
        gridHost.frame = NSRect(x: railWidth, y: gridBottom + 24,
                                width: max(0, width - railWidth),
                                height: max(0, bodyHeight - 24))
        let pages = max(1, Int(ceil(Double(roster.count) / Double(perPage))))
        let pagerHeight: CGFloat = pages > 1 ? 24 : 0

        let railTarget = NSRect(x: 0, y: gridBottom, width: railWidth, height: bodyHeight)
        let gridTarget = NSRect(x: railWidth,
                                y: gridBottom + pagerHeight,
                                width: max(0, width - railWidth),
                                height: max(0, bodyHeight - pagerHeight))
        // Rides the divider, so it slides with the split rather than jumping to
        // the new edge while the two panels are still moving.
        let dividerTarget = NSRect(x: railWidth, y: gridBottom, width: 1, height: bodyHeight)

        // A join or a leave moves the divider, and DESIGN.md budgets 250ms for a
        // layout move. Animated only when the width actually changed, so the
        // one-second poll does not keep the panel permanently in motion.
        if railChanged {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                rail.animator().frame = railTarget
                gridHost.animator().frame = gridTarget
                railDivider.animator().frame = dividerTarget
            }
            // Contents are placed at the destination immediately. Animating the
            // rail's own subviews as well would have them arrive at different
            // times and read as a stutter rather than a slide.
            rail.frame = railTarget
            gridHost.frame = gridTarget
        } else {
            rail.frame = railTarget
            gridHost.frame = gridTarget
            railDivider.frame = dividerTarget
        }
        layoutPager(pages: pages, y: gridBottom, width: width - railWidth)
        layoutRail()

        // While the start is running the class side carries the progress, not
        // "Waiting for students" - which would be a lie, since we are not in the
        // meeting yet and nobody could be waiting.
        let starting = !session.readiness.isLive && showsReadiness
        readiness.isHidden = !starting
        emptyState.isHidden = starting || !roster.isEmpty
        if starting {
            let panelWidth = min(360, max(200, width - railWidth - 80))
            let height = readiness.fittingHeight
            readiness.frame = NSRect(x: railWidth + ((width - railWidth) - panelWidth) / 2,
                                     y: gridHost.frame.midY - height / 2,
                                     width: panelWidth, height: height)
        } else {
            emptyState.frame = NSRect(x: railWidth + 40, y: gridHost.frame.midY - 40,
                                      width: max(80, width - railWidth - 80), height: 80)
        }
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
        let start = page * perPage
        guard start < roster.count else { return [] }
        return Array(roster[start..<min(start + perPage, roster.count)])
    }

    private func layoutTiles() {
        let visible = pageRoster
        guard !visible.isEmpty else { return }
        let full = gridHost.bounds

        // Featured speaker on top, gallery beneath - the split Zoom's own
        // custom-UI reference example uses, and the only layout the SDK
        // actually supports: every video element lives in one container owned
        // by one window, so the person being featured has to be drawn here
        // rather than in a window of their own.
        //
        // Not applied to a single participant: one person alone is the gallery,
        // and splitting the space would draw them twice the size for no reason.
        var gallery = visible
        var featuredTile: TileView?
        if let id = featuredID, visible.count > 1,
           let index = gallery.firstIndex(where: { $0.id == id }) {
            featuredTile = tiles[gallery.remove(at: index).id]
        }

        let featuredHeight = featuredTile == nil
            ? 0 : (full.height * Self.featuredShare).rounded()
        if let tile = featuredTile {
            let target = NSRect(x: Self.gutter,
                                y: full.height - featuredHeight + Self.gutter,
                                width: max(0, full.width - Self.gutter * 2),
                                height: max(0, featuredHeight - Self.gutter * 2))
            if tile.frame != target { tile.frame = target }
        }

        let area = NSRect(x: 0, y: 0, width: full.width,
                          height: max(0, full.height - featuredHeight))
        guard !gallery.isEmpty else { return }
        let (cols, rows) = Self.bestGrid(count: gallery.count, in: area.size)
        let cellW = (area.width - Self.gutter * CGFloat(cols + 1)) / CGFloat(cols)
        let cellH = (area.height - Self.gutter * CGFloat(rows + 1)) / CGFloat(rows)

        // Layout moves get DESIGN.md's 250ms, but only when the grid actually
        // changes shape. Animating every two-second refresh would mean a wall
        // that is permanently in motion.
        let shape = (cols, rows, gallery.count)
        let animate = lastGridShape.count >= 0 && shape != lastGridShape
        lastGridShape = shape

        for (index, entry) in gallery.enumerated() {
            guard let tile = tiles[entry.id] else { continue }
            let row = index / cols
            let column = index % cols
            // The last row is centred rather than left-packed: three students
            // in a 2x2 read as a group, not as a missing fourth.
            let inRow = min(cols, gallery.count - row * cols)
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

        // Only exceptions earn a line. A head count here duplicated the top
        // bar's "N people" word for word, so in an empty room the block was one
        // redundant line taking 56pt of column.
        var stats: [String] = []
        let raisedCount = roster.filter(\.isRaisingHand).count
        let mutedCount = roster.filter(\.isMuted).count
        let cameraOff = roster.filter { !$0.videoOn }.count
        if raisedCount > 0 { stats.append("hands up   \(raisedCount)") }
        if mutedCount > 0 { stats.append("muted      \(mutedCount)") }
        if cameraOff > 0 { stats.append("no camera  \(cameraOff)") }
        statsLabel.stringValue = stats.joined(separator: "\n")
        updateNeedsBlock()
    }

    /// Raised hands in the order they went up.
    private var handQueue: [ZoomMeetingSDKClient.RosterEntry] {
        roster.filter(\.isRaisingHand).sorted {
            (handRaisedAt[$0.id] ?? .distantPast) < (handRaisedAt[$1.id] ?? .distantPast)
        }
    }

    /// The block under the controls: whatever most needs the teacher right now.
    ///
    /// Strictly prioritised, because only one thing can be the most urgent:
    /// people at the door, then hands in the air, then - before class, or during
    /// a quiet stretch - the facts you would otherwise go hunting for. It is
    /// never blank, which is the entire point. A block that empties out is not
    /// filling the space at the bottom of the rail, it is moving the hole.
    ///
    /// Text is rewritten in place, never rebuilt. `rebuildRail` learned that
    /// lesson the hard way: tearing views down on a one-second poll races the
    /// accessibility tree and drops clicks that land mid-teardown.
    private func updateNeedsBlock() {
        let mono = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let prose = NSFont.systemFont(ofSize: 12)
        var eyebrow = ""
        var rows: [(text: String, font: NSFont)] = []

        if !session.readiness.isLive {
            // The class side is already carrying the progress. Two accounts of
            // the same wait, side by side, is one too many.
            eyebrow = ""
        } else if !waiting.isEmpty {
            eyebrow = "WAITING TO JOIN   \(waiting.count)"
            rows = waiting.prefix(5).map { ($0.name, prose) }
            if waiting.count > 5 { rows.append(("+\(waiting.count - 5) more", prose)) }
        } else if !handQueue.isEmpty {
            let queue = handQueue
            eyebrow = "HANDS UP   \(queue.count)"
            rows = queue.prefix(5).enumerated().map { index, entry in
                ("\(index + 1).  \(entry.name)", prose)
            }
            if queue.count > 5 { rows.append(("+\(queue.count - 5) more", prose)) }
        } else {
            // Machine facts, so mono - the split DESIGN.md asks for. The meeting
            // number is here rather than only in the top bar because the moment
            // you need it is the moment a student cannot find the link, and it
            // should be readable aloud without hunting.
            eyebrow = "SESSION"
            if !session.meetingNumber.isEmpty {
                rows.append(("MEETING     \(session.meetingNumber)", mono))
            }
            rows.append((session.obsRecording ? "RECORDING   local" : "RECORDING   off", mono))
            rows.append(("\u{2325}\u{2318}G start    \u{2325}\u{2318}R record    \u{2325}\u{2318}S snap back", mono))
            rows.append(("\u{2325}\u{2318}X end      \u{2325}\u{2318}Z speaker", mono))
        }

        needsEyebrow.stringValue = eyebrow
        for (index, row) in needsRows.enumerated() {
            let content = index < rows.count ? rows[index] : nil
            row.stringValue = content?.text ?? ""
            if let content { row.font = content.font }
            row.isHidden = content == nil
        }
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
            roster.contains(where: \.isSpotlighted) ? "spots" : "-",
            // Readiness changes what the controls look like - dimmed or live -
            // so a step completing has to rebuild the rail like any other
            // state a button renders from.
            String(describing: session.readiness)
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

        // Its own row. It is the one irreversible control in the rail, and
        // sitting inline next to Meeting info left red as the only thing telling
        // them apart - which is no separation at all for anyone who does not
        // parse colour quickly, or at all.
        let endSession = Self.railRow("End session", symbol: "xmark.circle.fill", destructive: true) {
            Self.confirm(title: "End the session?",
                         message: "Leaves the meeting, finishes any recording, and shuts OBS down.",
                         confirm: "End session") {
                ParticipantGridWindowController.requestEndSession()
            }
        }
        endSession.tag = Self.railBreakTag
        railControls.append(endSession)

        // Dimmed and disabled until the subsystem behind them exists. Showing
        // the full control set from the first frame is the point - the teacher
        // can see what is coming - but a button that looks live and silently
        // does nothing is worse than one that admits it is not ready.
        let live = session.readiness.isLive
        for control in railControls where !(control is NSTextField) {
            control.alphaValue = live ? 1 : 0.35
            (control as? NSControl)?.isEnabled = live
        }

        railControls.forEach { railContent.addSubview($0) }
    }

    /// One shape, at every rail width: your picture on top, then its caption,
    /// then the meter, then every control underneath. Never beside.
    ///
    /// There used to be a second shape. On a wide rail - which is the empty room,
    /// so it is what the teacher sees before every single class - the self view
    /// went left and the controls went into a 340pt column stuck to its right.
    /// Two blocks of unequal height sharing a top edge and nothing else, which
    /// read as a panel that had run out of ideas rather than one that was
    /// arranged. Stacking is the only shape now, so there is no width at which
    /// the rail changes its mind about what it is.
    ///
    /// Deleting the branch is not enough on its own: a bare stack at 1190pt draws
    /// a 669pt slab of video with the buttons wrapping fourteen across under it.
    /// So the stack is laid inside one capped, centred content column that every
    /// element shares - see `railColumn`.
    private func layoutRail() {
        let pad = Self.railPad
        railScroll.frame = rail.bounds
        let available = rail.bounds.width - pad * 2
        guard available > 0, rail.bounds.height > 0 else { return }

        let column = railColumn(available: available)
        let x = pad + column.x

        // Two passes. The document view has to be told its height before its
        // children can be placed against the top of it, and the height depends on
        // how the children wrap - so it is measured first, then everything is
        // placed for real. Both passes read the same column width, or the content
        // scrolls to an offset that does not match what is drawn.
        let contentHeight = selfBlockHeight(width: column.width)
            + controlColumnHeight(width: column.width)
            + needsBlockHeight(width: column.width) + 10 + pad * 2

        // Never shorter than the rail itself, or a short list would float.
        let documentHeight = max(contentHeight, rail.bounds.height)
        railContent.frame = NSRect(x: 0, y: 0, width: rail.bounds.width, height: documentHeight)

        let top = documentHeight - pad
        let afterMedia = layoutSelfBlock(x: x, width: column.width, top: top)
        let controlsTop = afterMedia - 10
        let controlsHeight = layoutControlColumn(x: x, width: column.width, top: controlsTop)
        walkNeedsBlock(x: x, width: column.width, top: controlsTop - controlsHeight, place: true)

        // Start at the top, which is where the self view and the mic are.
        railContent.scroll(NSPoint(x: 0, y: documentHeight))
    }

    /// The single content column the whole rail aligns to: picture, caption,
    /// meter and control grid all share these edges.
    ///
    /// Width snaps DOWN to a whole number of control cells. A column of some
    /// arbitrary point width leaves the button grid ending short of the picture
    /// above it - close enough to look like a mistake, far enough to see - and
    /// that ragged right edge is most of what made the rail look unfinished.
    /// Snapping means the last cell in a row lands exactly on the picture's
    /// right edge at every rail width.
    ///
    /// Then it centres, because an empty room hands the rail most of the display
    /// and a column pinned to the left edge of a 1190pt box reads as content that
    /// failed to fill its container. Centred, the margin reads as margin.
    ///
    /// Returns x as an offset inside `available`; the caller adds its own pad.
    private func railColumn(available: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let cellStride = Self.railCell.width + Self.railCellGap
        let fits = Int((available + Self.railCellGap) / cellStride)
        let cells = max(1, min(Self.railMaxCellsPerRow, fits))
        let width = min(available, CGFloat(cells) * cellStride - Self.railCellGap)
        return (x: ((available - width) / 2).rounded(), width: width)
    }

    /// How tall the needs block will be, without placing it.
    private func needsBlockHeight(width: CGFloat) -> CGFloat {
        walkNeedsBlock(x: 0, width: width, top: 0, place: false)
    }

    /// One walk, measuring or placing, for the same reason the control column
    /// has one: two copies of the arithmetic is two places for a gap to be wrong.
    @discardableResult
    private func walkNeedsBlock(x: CGFloat, width: CGFloat, top: CGFloat, place: Bool) -> CGFloat {
        guard !needsEyebrow.stringValue.isEmpty else {
            if place {
                needsEyebrow.frame = .zero
                for row in needsRows { row.frame = .zero }
            }
            return 0
        }
        var y = top
        y -= Self.railGroupGap + 16
        if place { needsEyebrow.frame = NSRect(x: x, y: y, width: width, height: 16) }
        y -= Self.railEyebrowGap

        for row in needsRows where !row.isHidden {
            y -= Self.railRowHeight
            if place {
                row.frame = NSRect(x: x, y: y, width: width, height: Self.railRowHeight)
            }
        }
        return top - y
    }

    /// How tall the self-view block will be at a given width, without placing it.
    private func selfBlockHeight(width: CGFloat) -> CGFloat {
        (width * 9 / 16).rounded() + Self.selfChromeHeight
    }

    /// How tall the wrapped cells will be at a given width, without placing them.
    private func controlColumnHeight(width: CGFloat) -> CGFloat {
        walkControlColumn(x: 0, width: width, top: 0, place: false)
    }

    /// Your picture, its caption, and the microphone meter, as one block.
    /// Returns the y it finished at.
    @discardableResult
    private func layoutSelfBlock(x: CGFloat, width: CGFloat, top: CGFloat) -> CGFloat {
        // 16:9 across the full content column, and the column is already capped,
        // so there is no second cap needed here. There used to be one - height
        // clamped to 55% of the rail - which back-solved a narrower picture than
        // the buttons underneath it on any short rail, and that mismatch is the
        // thing this layout exists to prevent. A rail too short for the result
        // scrolls; that is what railScroll is for.
        //
        // Same expression as selfBlockHeight, deliberately - if the measuring
        // pass and the placing pass disagree the content scrolls to the wrong
        // offset or clips.
        let height = (width * 9 / 16).rounded()
        var y = top - height
        selfViewHost.frame = NSRect(x: x, y: y, width: width, height: height)
        selfVideo?.frame = selfViewHost.bounds

        // Caption and meter share the picture's edges, so the block reads as one
        // unit rather than three things that happen to be stacked.
        y -= Self.selfChrome.caption
        selfViewLabel.frame = NSRect(x: x, y: y, width: width, height: 16)

        y -= Self.selfChrome.micLabel
        micLabel.frame = NSRect(x: x, y: y, width: width, height: 14)

        // The one thing in the block that does NOT take the full column. At
        // 396x12 a part-filled meter is a 33:1 strip, and anything that shape
        // with a partial fill reads as a stalled progress bar rather than a
        // level. Capped, it keeps the column's left edge and stops pretending
        // to be a track with a long way to go.
        //
        // The hint then sits in the room that leaves, on the meter's own line.
        // It glosses what the meter is already saying, so a full row of column
        // to itself was 26pt spent restating a fact in words.
        y -= Self.selfChrome.meter
        let meterWidth = min(width, Self.railMeterWidth)
        micMeter.frame = NSRect(x: x, y: y, width: meterWidth, height: 12)
        let hintX = x + meterWidth + 12
        micHint.frame = NSRect(x: hintX, y: y - 3, width: max(0, width - meterWidth - 12), height: 18)

        y -= Self.selfChrome.trail
        return y
    }

    /// Icon cells wrapped into rows, section eyebrows spanning the full column.
    ///
    /// Wrapping is what makes the rail survive a resize: the cells reflow to
    /// however many fit, where fixed full-width rows could only clip. Laid out
    /// downward from `top` and the total height returned, so the caller knows
    /// whether it overflowed.
    @discardableResult
    private func layoutControlColumn(x: CGFloat, width: CGFloat, top: CGFloat) -> CGFloat {
        walkControlColumn(x: x, width: width, top: top, place: true)
    }

    /// Measures and places in one walk. `place: false` runs the identical
    /// arithmetic and touches no frame, so the two passes cannot disagree.
    ///
    /// They used to be separate, and they disagreed twice over. Both carried the
    /// same phantom gap - finishing a row advanced y by a whole cell, then
    /// opening the next row advanced it by a whole cell again, so every wrap
    /// cost 112pt where 58 was meant and every eyebrow floated 60pt clear of the
    /// row above it. The control set then read as four islands rather than two
    /// labelled groups. On top of that the measuring pass never charged itself
    /// for opening a row at all, so it came out 108pt short of what was actually
    /// drawn; that only stayed invisible because the rail is usually taller than
    /// its content and `max(contentHeight, rail.bounds.height)` papered over it.
    /// One walk means a gap can only ever be wrong in one place.
    ///
    /// Returns the total height consumed below `top`.
    private func walkControlColumn(x: CGFloat, width: CGFloat, top: CGFloat, place: Bool) -> CGFloat {
        let cell = Self.railCell
        let gap = Self.railCellGap
        let perRow = max(1, Int((width + gap) / (cell.width + gap)))
        var y = top
        var column = 0

        for control in railControls {
            // A section eyebrow closes whatever row is open, takes a group break
            // above it, and spans the whole column.
            if control is NSTextField {
                column = 0
                y -= Self.railGroupGap + 16
                if place { control.frame = NSRect(x: x, y: y, width: width, height: 16) }
                y -= Self.railEyebrowGap
                continue
            }
            // Opening a row costs one cell height. A wrap costs the inter-row
            // gap on top of that, and nothing more. A control carrying the break
            // tag wraps whether the row was full or not.
            if column == perRow || (control.tag == Self.railBreakTag && column != 0) {
                y -= gap
                column = 0
            }
            if column == 0 { y -= cell.height }
            if place {
                control.frame = NSRect(x: x + CGFloat(column) * (cell.width + gap),
                                       y: y, width: cell.width, height: cell.height)
            }
            column += 1
        }

        // Session facts under the cells rather than pinned to the floor, so they
        // stay attached to what they describe - and only when they have anything
        // to say. In an empty room the block was one mono line reading
        // "students 0", which the top bar already says as "0 people", orphaned
        // 20pt below End session.
        guard !statsLabel.stringValue.isEmpty else {
            if place { statsLabel.frame = .zero }
            return top - y
        }
        y -= Self.railGroupGap + 36
        if place { statsLabel.frame = NSRect(x: x, y: y, width: width, height: 36) }
        return top - y
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
        let centreX = railWidth + width / 2
        pageLabel.frame = NSRect(x: centreX - pageLabel.frame.width / 2, y: y + 4,
                                 width: pageLabel.frame.width, height: 16)
        pagePrev?.frame = NSRect(x: pageLabel.frame.minX - 30, y: y + 1, width: 24, height: 22)
        pageNext?.frame = NSRect(x: pageLabel.frame.maxX + 6, y: y + 1, width: 24, height: 22)
    }

    private var pageCount: Int? {
        roster.isEmpty ? nil : max(1, Int(ceil(Double(roster.count) / Double(perPage))))
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

        if runAboveEverything(alert) == .alertFirstButtonReturn {
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
        // systemRed, not the brand accent: DESIGN.md bars the accent from text,
        // and red-for-muted is the convention being matched anyway.
        IconCellButton(symbol: symbol,
                       caption: title,
                       tint: destructive || alert ? .systemRed : .labelColor,
                       action: action)
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
        // An icon cell that pops the menu, so a menu and an action look and
        // behave alike in the grid.
        let button = IconCellButton(symbol: symbol, caption: title, tint: .labelColor) {}
        button.attachedMenu = menu
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

    /// Maps a status sentence to a fixed code for the dashboard. The sentences
    /// are written here, so the prefixes are stable; anything new reads as
    /// "other" until it is added, never as the sentence itself.
    fileprivate static func actionCode(for sentence: String) -> String {
        switch true {
        case sentence.hasPrefix("Muted everyone"): return "mute_all"
        case sentence.hasPrefix("Asked everyone"): return "ask_unmute_all"
        case sentence.hasPrefix("Lowered all"): return "lower_all_hands"
        case sentence.hasPrefix("Lowered"): return "lower_hand"
        case sentence.hasPrefix("Cleared spotlight"): return "clear_spotlight"
        case sentence.hasPrefix("Admitted"): return "admit_all"
        case sentence.hasPrefix("Sent"): return "reaction"
        case sentence.hasPrefix("Suspended"): return "suspend_activities"
        case sentence.hasPrefix("Renamed"): return "rename"
        case sentence.hasSuffix("is now the host"): return "make_host"
        case sentence.hasPrefix("Removed"): return "remove"
        default: return "other"
        }
    }

    fileprivate static func perform(_ success: String,
                                    _ body: (ZoomMeetingSDKClient) -> Bool) {
        guard let sdk = ParticipantGridWindowController.sdk else { return }
        let ok = body(sdk)
        // The success string is a sentence for the status log and can name a
        // student, so it is NEVER the event. Only the outcome travels, plus the
        // kind of control, derived from the sentence's fixed opening words.
        Analytics.track(.controlAction, [.action: actionCode(for: success), .refused: ok ? "no" : "yes"])
        // Redraw immediately rather than at the next poll tick, so the control
        // that was just pressed reflects what it did.
        ParticipantGridWindowController.refreshNow()
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

    /// Runs an alert ABOVE the panel, wherever the panel lives.
    ///
    /// The full-screen panel is a borderless window at .statusBar level - that
    /// is what lets it cover the menu bar and Dock on the reference display.
    /// runModal's alert window sits at .modalPanel, which is LOWER, so every
    /// confirmation opened underneath the very surface whose button had just
    /// been pressed - reported live on a two-display setup as End session and
    /// Copy invitation "going behind the participant window". The alert also
    /// centres on the panel's screen, so on two displays it appears where the
    /// teacher is looking rather than on the other monitor.
    private static func runAboveEverything(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        // Setting the ALERT's level does not work, and the first version of
        // this runner proved it: runModal(for:) assigns the window to
        // .modalPanel itself when the modal session begins, clobbering any
        // level set beforehand - and it re-centres the window, clobbering the
        // origin too. Pre-modal mutations of the alert are simply overwritten.
        //
        // So step the PANEL down instead. Nothing in the modal machinery
        // touches other windows' levels, which makes this the version that
        // cannot be clobbered: at .normal the panel sits below .modalPanel for
        // exactly the alert's lifetime, and the saved level comes back after.
        // The menu bar showing through during a dialog is fine - the dialog is
        // the one moment the panel is not the surface being used.
        let panelWindow = ParticipantGridWindowController.panelWindowForAlerts
        let savedLevel = panelWindow?.level
        panelWindow?.level = .normal
        // Placement re-asserted from INSIDE the modal session, where it
        // sticks: the async block runs after runModal has done its own
        // centring, and puts the dialog on the display the teacher is
        // actually looking at.
        if let screen = ParticipantGridWindowController.panelScreen {
            DispatchQueue.main.async { [weak window = alert.window] in
                guard let window else { return }
                let area = screen.visibleFrame
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(x: (area.midX - size.width / 2).rounded(),
                                              y: (area.midY - size.height / 2).rounded()))
            }
        }
        let response = alert.runModal()
        if let savedLevel { panelWindow?.level = savedLevel }
        return response
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
        if runAboveEverything(alert) == .alertFirstButtonReturn { action() }
    }

    private static func prompt(title: String, current: String, action: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: current)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        let response = runAboveEverything(alert)
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
    private var lastLoggedSublayers = -2

    func attach(video newVideo: NSView?) {
        // The common case by far - the poll runs at 1Hz and the view rarely
        // changes. It used to log a full view-state line here, which meant a
        // synchronous open/seek/write/close per tile per second on the main
        // thread: 571 of 632 lines in one session's log, and the reason the
        // panel felt sluggish. The probe had already done its job (it proved
        // the views were on screen and correctly sized, which is what pointed
        // the investigation at subscriptions instead).
        guard video !== newVideo else {
            // Change-only render probe. A rendering element grows its layer
            // tree (1 sublayer bare, 4 once the SDK wires the surface up); one
            // that reports dataType=Video but never leaves 1 is accepting data
            // and drawing none of it - the exact state under investigation.
            let sublayers = video?.layer?.sublayers?.count ?? -1
            if sublayers != lastLoggedSublayers {
                lastLoggedSublayers = sublayers
                ZoomMeetingSDKClient.videoLog("render user=\(userID) sublayers=\(sublayers)"
                    + " size=\(Int(bounds.width))x\(Int(bounds.height))")
            }
            return
        }
        video?.removeFromSuperview()
        video = newVideo
        guard let newVideo else {
            ZoomMeetingSDKClient.videoLog("attach user=\(userID) provider returned nil")
            return
        }
        newVideo.autoresizingMask = [.width, .height]
        newVideo.frame = videoBounds
        addSubview(newVideo, positioned: .below, relativeTo: scrim)
        ZoomMeetingSDKClient.videoLog(Self.viewState("attached", userID: userID,
                                                     video: newVideo, tile: self))
    }

    /// TEMPORARY QA INSTRUMENTATION - remove once the tiles are confirmed.
    private static func viewState(_ stage: String, userID: UInt32,
                                  video: NSView?, tile: NSView) -> String {
        guard let video else { return "\(stage) user=\(userID) video=nil" }
        let layerInfo: String
        if let layer = video.layer {
            layerInfo = "layer=yes sublayers=\(layer.sublayers?.count ?? 0) "
                + "opaque=\(layer.isOpaque) hidden=\(layer.isHidden)"
        } else {
            layerInfo = "layer=NONE"
        }
        return "\(stage) user=\(userID)"
            + " videoFrame=\(Int(video.frame.width))x\(Int(video.frame.height))"
            + " tileBounds=\(Int(tile.bounds.width))x\(Int(tile.bounds.height))"
            + " superview=\(video.superview == nil ? "NONE" : "ok")"
            + " window=\(video.window == nil ? "NONE" : (video.window!.isVisible ? "visible" : "hidden"))"
            + " hidden=\(video.isHidden) alpha=\(String(format: "%.2f", video.alphaValue))"
            + " subviews=\(video.subviews.count) \(layerInfo)"
            + " tileInWindow=\(tile.window == nil ? "NONE" : "ok")"
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

// MARK: - An icon control

/// A compact icon cell: symbol above a short caption, no border until you point
/// at it.
///
/// Replaces full-width bordered rows. Those read as a settings form - a stack of
/// long identical buttons where only the text distinguishes them - which is wrong
/// for something glanced at and hit mid-lesson. An icon is recognised by shape
/// before it is read, and cells wrap, so the rail reflows instead of clipping
/// when the window changes size.
@MainActor
private final class IconCellButton: NSButton {

    private let body: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    private var tint: NSColor = .labelColor
    /// Set instead of an action when this cell opens a menu.
    var attachedMenu: NSMenu?

    init(symbol: String, caption: String, tint: NSColor, action: @escaping () -> Void) {
        self.body = action
        super.init(frame: .zero)
        self.tint = tint
        target = self
        self.action = #selector(fire)
        isBordered = false
        imagePosition = .imageAbove
        title = caption
        font = .systemFont(ofSize: 9)
        // A slightly heavier symbol so a 17pt glyph still reads at a glance.
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: caption)?
            .withSymbolConfiguration(config)
        contentTintColor = tint
        wantsLayer = true
        layer?.cornerRadius = 8            // DESIGN.md radius, one step below md
        toolTip = caption
    }

    required init?(coder: NSCoder) { nil }

    @objc private func fire() {
        if let attachedMenu {
            // Above the cell: the rail is tall and a menu dropping downward off
            // the bottom would be clipped.
            attachedMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
            return
        }
        body()
    }

    /// See TileView.acceptsFirstMouse - the panel is rarely key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Hover and press are drawn here rather than left to the bezel, because a
    /// borderless button gives no feedback at all otherwise - and feedback on
    /// press is most of what makes a control feel like it worked.
    override func draw(_ dirtyRect: NSRect) {
        let background: NSColor? = isHighlighted
            ? tint.withAlphaComponent(0.28)
            : hovering ? NSColor.white.withAlphaComponent(0.10) : nil
        if let background {
            background.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
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
/// The start sequence, drawn as named steps rather than a spinner.
///
/// A spinner would have been less work and it would have been a lie: it says
/// "wait" and nothing else, so a start stuck on OBS looks exactly like a start
/// that is about to finish. Named steps cost the same wait and spend it telling
/// the teacher what is happening and roughly how much is left.
///
/// Motion budget per DESIGN.md: the bar eases to its new width over 250ms and
/// the active step carries the platform's own spinner. Nothing else moves.
/// The start sequence on a machine with one display.
///
/// The participant panel carries this beautifully when it owns a screen to
/// itself. On a single display it cannot: it is off by default there, because
/// a large private control surface has no business sitting on top of the
/// workspace this app exists to assemble, and when it IS on it is an ordinary
/// window, so the tiling step buries it - the panel gets covered by the very
/// thing it is reporting on.
///
/// So on one display a small floating card carries it instead. Small enough not
/// to fight the layout, above it so the tiling cannot hide it, and gone the
/// moment there is nothing left to say.
enum ReadinessHUDController {

    private final class HUDPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static var panel: HUDPanel?
    private static var view: ReadinessView?
    private static var dismissTask: Task<Void, Never>?
    private static let width: CGFloat = 320
    private static let padding: CGFloat = 20

    static func show(_ readiness: ParticipantGridWindowController.Readiness,
                     on screen: NSScreen) {
        // Nothing left to report. A failure is the exception: it stays up,
        // because the alternative is a card that vanishes at the exact moment
        // it finally had something worth reading.
        guard !readiness.steps.isEmpty || readiness.failure != nil else {
            scheduleDismiss()
            return
        }
        dismissTask?.cancel()
        dismissTask = nil

        let hosting = panel ?? make(on: screen)
        hosting.alphaValue = 1
        view?.apply(readiness)

        let height = (view?.fittingHeight ?? 0) + padding * 2
        // Centred, not tucked in a corner.
        //
        // A corner looks like the polite choice and is not: the side column the
        // workspace tiles - Zoom tile and chat - sits flush to the bottom and,
        // in the default layout, to the right, so bottom-right lands squarely on
        // it. Centre is the one spot that favours no tiled pane over another,
        // and nothing on the display is usable during these seconds anyway. It
        // also reads as a stage in the start rather than a notification that
        // wandered in.
        let area = screen.visibleFrame
        hosting.setFrame(NSRect(x: (area.midX - width / 2).rounded(),
                                y: (area.midY - height / 2).rounded(),
                                width: width, height: height),
                         display: true)
        view?.frame = NSRect(x: padding, y: padding, width: width - padding * 2,
                             height: height - padding * 2)
        // Regardless, and every time: the whole point is to stay on top of a
        // tiling pass that is actively reordering windows. It is small, it is
        // non-activating and it leaves on its own, so this is not the
        // tug-of-war the participant panel deliberately avoids.
        hosting.orderFrontRegardless()
    }

    static func close() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.close()
        panel = nil
        view = nil
    }

    private static func scheduleDismiss() {
        guard panel != nil, dismissTask == nil else { return }
        dismissTask = Task { @MainActor in
            // A beat on the completed list before it goes, so the last step
            // being ticked is something the teacher sees rather than infers.
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let hosting = panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25          // DESIGN.md, ease-in leaving
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                hosting.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in close() }
            }
        }
    }

    private static func make(on screen: NSScreen) -> HUDPanel {
        let created = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false, screen: screen)
        created.isReleasedWhenClosed = false
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        created.ignoresMouseEvents = true      // purely a readout, nothing to click

        let backing = NSVisualEffectView()
        backing.material = .hudWindow
        backing.blendingMode = .behindWindow
        backing.state = .active
        backing.wantsLayer = true
        backing.layer?.cornerRadius = 14       // DESIGN.md radius-lg
        backing.layer?.masksToBounds = true
        backing.autoresizingMask = [.width, .height]
        created.contentView = backing

        let readiness = ReadinessView()
        backing.addSubview(readiness)
        panel = created
        view = readiness
        return created
    }
}

private final class ReadinessView: NSView {

    private let title = NSTextField(labelWithString: "GETTING READY")
    private let bar = NSView()
    private let barTrack = NSView()
    private var rows: [(glyph: NSImageView, spinner: NSProgressIndicator, label: NSTextField)] = []
    private let failure = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var readiness = ParticipantGridWindowController.Readiness()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        title.textColor = .tertiaryLabelColor
        addSubview(title)

        barTrack.wantsLayer = true
        barTrack.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.2).cgColor
        barTrack.layer?.cornerRadius = 1.5
        addSubview(barTrack)

        bar.wantsLayer = true
        // A fill, which is the one thing DESIGN.md allows the lime to be.
        bar.layer?.backgroundColor = RootView.accent.cgColor
        bar.layer?.cornerRadius = 1.5
        addSubview(bar)

        failure.font = .systemFont(ofSize: 12)
        failure.textColor = .systemRed
        failure.maximumNumberOfLines = 3
        failure.usesSingleLineMode = false
        failure.lineBreakMode = .byWordWrapping
        failure.isHidden = true
        addSubview(failure)

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.usesSingleLineMode = false
        detail.lineBreakMode = .byTruncatingTail
        detail.isHidden = true
        addSubview(detail)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func apply(_ next: ParticipantGridWindowController.Readiness) {
        guard next != readiness else { return }
        let countChanged = next.steps.count != readiness.steps.count
        readiness = next
        if countChanged { rebuildRows() }

        for (index, step) in next.steps.enumerated() where index < rows.count {
            let row = rows[index]
            row.label.stringValue = step.label
            switch step.state {
            case .pending:
                row.label.textColor = .tertiaryLabelColor
                Self.setGlyph(row, symbol: "circle", tint: .tertiaryLabelColor, spinning: false)
            case .active:
                row.label.textColor = .labelColor
                Self.setGlyph(row, symbol: nil, tint: .labelColor, spinning: true)
            case .done:
                row.label.textColor = .secondaryLabelColor
                Self.setGlyph(row, symbol: "checkmark.circle.fill",
                              tint: RootView.accent, spinning: false)
            case .skipped:
                row.label.textColor = .tertiaryLabelColor
                Self.setGlyph(row, symbol: "minus.circle", tint: .tertiaryLabelColor, spinning: false)
            case .failed:
                row.label.textColor = .systemRed
                Self.setGlyph(row, symbol: "exclamationmark.circle.fill",
                              tint: .systemRed, spinning: false)
            }
        }

        title.stringValue = next.failure == nil ? "GETTING READY" : "COULD NOT START"
        failure.stringValue = next.failure ?? ""
        failure.isHidden = next.failure == nil
        // Suppressed once a failure is on screen: the red line IS the detail
        // then, and repeating the last progress note under it only competes.
        detail.stringValue = next.detail ?? ""
        detail.isHidden = next.failure != nil || (next.detail ?? "").isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private static func setGlyph(_ row: (glyph: NSImageView, spinner: NSProgressIndicator, label: NSTextField),
                                 symbol: String?, tint: NSColor, spinning: Bool) {
        row.spinner.isHidden = !spinning
        spinning ? row.spinner.startAnimation(nil) : row.spinner.stopAnimation(nil)
        row.glyph.isHidden = spinning
        guard let symbol else { return }
        row.glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        row.glyph.contentTintColor = tint
    }

    private func rebuildRows() {
        for row in rows {
            row.glyph.removeFromSuperview()
            row.spinner.removeFromSuperview()
            row.label.removeFromSuperview()
        }
        rows = readiness.steps.map { _ in
            let glyph = NSImageView()
            glyph.imageScaling = .scaleProportionallyDown
            addSubview(glyph)
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.isDisplayedWhenStopped = false
            addSubview(spinner)
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 13)
            addSubview(label)
            return (glyph, spinner, label)
        }
    }

    /// Height this needs at its current step count, so the caller can centre it.
    var fittingHeight: CGFloat {
        16 + 12 + 3 + 16 + CGFloat(rows.count) * Self.rowHeight
            + (readiness.failure == nil ? 0 : 12 + 48)
            + (detail.isHidden ? 0 : 10 + 30)
    }
    private static let rowHeight: CGFloat = 26

    override func layout() {
        super.layout()
        let width = bounds.width
        var y: CGFloat = 0
        title.frame = NSRect(x: 0, y: y, width: width, height: 16)
        y += 16 + 12

        barTrack.frame = NSRect(x: 0, y: y, width: width, height: 3)
        let fraction = readiness.steps.isEmpty
            ? 0 : CGFloat(readiness.settled) / CGFloat(readiness.steps.count)
        let target = NSRect(x: 0, y: y, width: (width * fraction).rounded(), height: 3)
        // 250ms is DESIGN.md's budget for a layout move. Only animated once the
        // bar has a width to grow FROM, or the first step would slide in from
        // zero as entrance choreography, which the same document forbids.
        if bar.frame.width > 0 && bar.frame != target {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.animator().frame = target
            }
        } else {
            bar.frame = target
        }
        y += 3 + 16

        for row in rows {
            row.glyph.frame = NSRect(x: 0, y: y + 2, width: 16, height: 16)
            row.spinner.frame = NSRect(x: 0, y: y + 2, width: 16, height: 16)
            row.label.frame = NSRect(x: 26, y: y, width: max(0, width - 26), height: 20)
            y += Self.rowHeight
        }

        if !detail.isHidden {
            y += 10
            detail.frame = NSRect(x: 0, y: y, width: width, height: 30)
            y += 30
        }

        if !failure.isHidden {
            y += 12
            failure.frame = NSRect(x: 0, y: y, width: width, height: 48)
        }
    }
}

private final class LevelMeterView: NSView {

    var level: Double = 0 { didSet { if abs(level - oldValue) > 0.01 { needsDisplay = true } } }
    /// Drawn hollow when the mic is muted in Zoom, so a moving meter never
    /// implies the class can hear you.
    var muted = false { didSet { needsDisplay = true } }

    /// Follows the width, so a segment is always about 10pt and the meter reads
    /// the same whatever it is given. Fixed at 20 it was fine at toolbar widths
    /// and wrong in the rail, where twenty cells stretched across the column
    /// turned a level into a progress track.
    private var segments: Int { max(6, min(20, Int(bounds.width / 12))) }

    override func draw(_ dirtyRect: NSRect) {
        let segments = self.segments
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

private extension CGFloat {
    /// Small helper so the self-view sizing reads as one expression.
    func clamped(max upper: CGFloat) -> CGFloat { Swift.min(self, upper) }
}
