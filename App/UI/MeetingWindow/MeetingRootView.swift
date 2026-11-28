//
//  MeetingRootView.swift
//  Greenroom
//
//  The meeting window's root view: its stored state, init, the refresh from the roster, and the overrides.
//  The rest of it is in the MeetingRootView+ files beside this one.
//
import AppKit
import SwiftUI
import Combine

/// Top bar, video grid, contextual strip, bottom bar.
///
/// Hand-laid rather than Auto Layout: the video views come from the SDK with
/// frames of their own and are re-framed every refresh anyway, so one layout
/// pass over explicit rects is both simpler and cheaper than maintaining
/// constraints for a grid whose shape changes as students join.
@MainActor
final class MeetingRootView: NSView {

    /// Which form this window is. Fixed for the life of the view: a change of
    /// form is a new window (see `refresh`).
    let form: ParticipantGridWindowController.Form

    /// The small slot form shows its top bar and toolbar only while the pointer
    /// is over it; there is no room to give them a permanent band.
    var hoverChrome: Bool { form.isSlot }

    let bottomBar = ToolbarFootView()

    /// The selected student's drawer, over the grid's right edge. Exists only
    /// while somebody is selected - see ParticipantInspectorView.
    let inspector = ParticipantInspectorView(frame: .zero)

    /// Live only while the drawer is open. The panel is non-activating and is
    /// rarely key, so Escape has to be caught before the responder chain gets
    /// a chance not to deliver it.
    var escapeMonitor: Any?

    /// Clicks, while the drawer is open. See `updateEscapeMonitor`.
    var clickMonitor: Any?

    /// Below this the window stops being a grid with panels beside it.
    ///
    /// Phase 4: on a laptop the queue and the drawer would leave the class
    /// itself a strip, so they overlay the grid's right edge instead of taking
    /// a column off it. 900pt is where 320 + 300 + a usable canvas stops
    /// fitting side by side.
    var isNarrow: Bool { MeetingWindowLayout.isNarrow(width: bounds.width) }

    let gridHost = NSView()

    let emptyState = NSTextField(labelWithString: "")

    var tiles: [UInt32: TileView] = [:]

    var selected: UInt32?

    var lastGridShape: (cols: Int, rows: Int, count: Int) = (0, 0, -1)

    /// What the inspector was last built from. Deliberately excludes who is TALKING:
    /// that changes constantly and only affects tile rings, never a button.
    var lastBarSignature = ""

    /// Held so a page change can re-attach video without waiting for the poll.
    var lastVideoProvider: ((UInt32, NSRect) -> NSView?)?

    var lastSelfProvider: ((NSRect) -> NSView?)?

    typealias ViewMode = MeetingViewMode

    var viewMode: ViewMode = .gallery

    /// The layouts drawn right now (MeetingViewRules.swift): Multi-speaker shows as
    /// Speaker with fewer than three people. Rebuilt by `rebuildPlan`.
    var plan = MeetingTilePlan.empty

    var isSpeakerMode: Bool { plan.mode == .speaker }

    var isMultiMode: Bool { plan.mode == .multiSpeaker }

    /// Speaker and Multi-speaker both keep a filmstrip.
    private var usesStrip: Bool { isSpeakerMode || isMultiMode }

    let prefs = MeetingViewPrefs()

    var shareLayout: MeetingShareLayout = .standard

    var splitFraction = MeetingSplit.defaultFraction

    var hideSelfView = false

    var hideNoVideo = false

    var featuredSpeaker: UInt32?

    /// Who holds Multi-speaker's large tiles: four places, kept for at least 3 s,
    /// fed from who is talking each time the roster is read.
    var multiTracker = RecentSpeakers(limit: 4, minimumStay: 3)

    var recentIDs: [UInt32] = []

    /// The stage as last laid out, for the divider's drag.
    var lastSideStage = NSRect.zero

    /// The View menu's three choices, held as a control so the rest of the window
    /// keeps one way to read and write the mode. It is not on screen: the top bar's
    /// View button is the visible control.
    lazy var modeControl = FirstClickSegmented(labels: MeetingViewMode.menuOrder.map(\.title),
                                                       trackingMode: .selectOne,
                                                       target: self, action: #selector(modeChanged(_:)))

    /// Zoom-style slim top bar, in the title-bar area (MeetingTopBar.swift).
    let meetingTopBar = MeetingTopBarView(frame: .zero)

    let stageChrome = MeetingTileChrome(frame: .zero)

    /// The frame to go back to when Fullscreen is turned off.
    var frameBeforeFullscreen: NSRect?

    var isFilling: Bool { frameBeforeFullscreen != nil }

    /// Speaker view's big picture. It is NOT a tile: a view has one superview,
    /// and the speaker's filmstrip tile is a different element. See
    /// ZoomMeetingSDKClient.stageView.
    let stageHost = NSView()

    let stageScrim = NSView()

    let stageName = NSTextField(labelWithString: "")

    var stageVideo: NSView?

    /// Who the stage shows: spotlight, then a local pin, then whoever speaks.
    var stageSpeakerID: UInt32?

    // Shared screens (phase 2). A share takes the stage and forces Speaker; Gallery
    // gets a chip that says whose screen it is and brings it back.
    var shareVideo: NSView?

    lazy var shareChip: ClosureButton = {
        let button = ClosureButton { [weak self] in self?.shareChipPressed() }
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        button.layer?.cornerRadius = 13
        button.isHidden = true
        return button
    }()

    lazy var selfShareCard = SelfShareCardView { [weak self] in self?.stopOwnShare() }

    /// A share chose the view; the one to go back to when it ends.
    var shareForcedSpeaker = false

    /// Side-by-side: the share on the left, its own host, with a divider.
    let shareHost = NSView()

    let shareChrome = MeetingTileChrome(frame: .zero)

    let splitDivider = MeetingSplitDivider(frame: .zero)

    var viewBeforeShare: ViewMode?

    var userChoseDuringShare = false

    var sharedNow: (sourceID: UInt32, userID: UInt32, name: String)? {
        ParticipantGridWindowController.sdk?.shareViewer.current
    }

    var selfSharingNow: Bool { ParticipantGridWindowController.sdk?.shareViewer.selfSharing ?? false }

    /// Someone else's share is the stage's picture.
    var shareOnStage: Bool { plan.mode == .speaker && sharedNow != nil && !shareBeside }

    /// Someone else's share on the left of a view, with the divider between.
    var shareBeside: Bool { !form.isSlot && sharedNow != nil && shareLayout.isSideBySide }

    /// Your own share, as a card where the picture would be.
    var selfCardShown: Bool { plan.mode == .speaker && selfSharingNow && sharedNow == nil }

    var lastStageProvider: ((UInt32, NSRect) -> NSView?)?

    var lastReleaseStage: (() -> Void)?

    /// While the Shared screen window draws the share, the stage says so.
    let shareElsewhere: NSTextField = {
        let label = NSTextField(labelWithString: "Showing in Shared screen window")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = MeetingTheme.secondaryTextNS
        label.alignment = .center
        label.isHidden = true
        return label
    }()

    let sidePanelHost = BarView()

    let sidePanelDivider = NSView()

    /// Solid #1A1A1A under the panel: the system material would show the window through it.
    let sidePanelBacking = NSView()

    let sidePanelTitle = NSTextField(labelWithString: "")

    /// "12 \u{00B7} 2 hands up" beside the People title.
    let sidePanelCount = NSTextField(labelWithString: "")

    /// Copies the invite link, the one `meetingInvite().joinURL` gives.
    lazy var inviteButton: ClosureButton = {
        let button = ClosureButton { [weak self] in self?.controls?.copyInviteLink() }
        button.title = "Invite"
        button.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.toolTip = "Copy the invite link"
        button.setAccessibilityLabel("Copy invite link")
        return button
    }()

    lazy var sidePanelClose = MeetingBarButton { [weak self] in self?.controls?.sidePanel = nil }

    var chatHost: NSView?

    let peopleView = MeetingPeopleView(frame: .zero)

    var controlsSub: AnyCancellable?

    var chromeHover = false

    private var chromeHideWork: DispatchWorkItem?

    var controls: MeetingControlsModel? { ParticipantGridWindowController.controls }


    static let stripHeight: CGFloat = MeetingTheme.stripHeight

    var roster: [ZoomMeetingSDKClient.RosterEntry] = []

    var page = 0

    /// The queue's own scroller, at the top of the People panel: Cues's cards.
    let queueScroll = NSScrollView()

    /// Your own picture, over the grid.
    let selfPreview = SelfPreviewView(frame: .zero)

    var lastMicLevel: Double = 0

    var selfVideo: NSView?

    /// Cues's cards, in the People panel's container. Its own view with a
    /// discipline: a fixed pool, updated in place, one measuring/placing walk.
    let cuesBlock = CuesRailBlock(frame: .zero)

    /// The exception panel on the right of the grid. Fixed width.
    lazy var liveQueue = LiveQueueView(assist: cuesBlock)

    /// When each currently-raised hand went up.
    ///
    /// The SDK reports `isRaisingHand` as a bare bool with no timestamp, so
    /// raise order is remembered here or not at all. It has to be remembered:
    /// a set of raised hands tells a teacher how many, and the one thing they
    /// actually need from it is who to call on first.
    var handRaisedAt: [UInt32: Date] = [:]

    var pagePrev: NSButton?

    var pageNext: NSButton?

    var flags = ZoomMeetingSDKClient.RoomFlags()

    var waiting: [(id: UInt32, name: String)] = []

    var session = ParticipantGridWindowController.SessionInfo()

    init(frame frameRect: NSRect, form: ParticipantGridWindowController.Form) {
        self.form = form
        super.init(frame: frameRect)
        wantsLayer = true
        // The meeting window's background is the frost behind it (WindowFrost).
        layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(bottomBar)
        gridHost.wantsLayer = true
        gridHost.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(gridHost)

        queueScroll.drawsBackground = false
        queueScroll.hasVerticalScroller = true
        queueScroll.scrollerStyle = .overlay
        queueScroll.autohidesScrollers = true
        queueScroll.documentView = liveQueue

        // The preview goes on the window, above the grid, so the grid never
        // measures around it. Actions are the two that are about you.
        selfPreview.actions = SelfPreviewView.Actions(
            toggleMute: {
                guard let sdk = ParticipantGridWindowController.sdk else { return }
                let muted = sdk.iAmMuted
                Self.perform(muted ? "Unmuted yourself" : "Muted yourself") { $0.setMyMute(!muted) }
            },
            // The camera button's click (R6.6); while video is stopped, Start video (R49).
            toggleVideo: { [weak self] in
                self?.controls?.pressCameraButton()
                ParticipantGridWindowController.refreshNow()
            })
        addSubview(selfPreview)

        inspector.onClose = { [weak self] in
            guard let self else { return }
            self.selected = nil
            self.selectionChanged()
        }
        inspector.isHidden = true
        addSubview(inspector)

        emptyState.font = .systemFont(ofSize: 15)
        emptyState.textColor = .secondaryLabelColor
        emptyState.alignment = .center
        emptyState.maximumNumberOfLines = 3
        emptyState.usesSingleLineMode = false
        emptyState.lineBreakMode = .byWordWrapping
        addSubview(emptyState)

        setupMeetingForm()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    func update(roster: [ZoomMeetingSDKClient.RosterEntry],
                flags: ZoomMeetingSDKClient.RoomFlags,
                waiting: [(id: UInt32, name: String)],
                session: ParticipantGridWindowController.SessionInfo,
                featured: UInt32?,
                videoProvider: @escaping (UInt32, NSRect) -> NSView?,
                selfProvider: @escaping (NSRect) -> NSView?,
                stageProvider: @escaping (UInt32, NSRect) -> NSView?,
                releaseStage: @escaping () -> Void) {
        self.roster = roster
        featuredSpeaker = featured
        syncShareMode()
        feedMultiSpeakers()
        rebuildPlan()
        lastStageProvider = stageProvider
        lastReleaseStage = releaseStage
        self.flags = flags
        self.waiting = waiting
        self.session = session

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
        let pages = MeetingWindowLayout.pageCount(listed: listed.count, perPage: perPage)
        page = min(page, pages - 1)

        syncTiles()
        updateChromeText()
        if let popOut = PeoplePopOutController.view { feedPeople(popOut) }
        // Rebuilt ONLY when something the inspector actually shows has changed:
        // tearing buttons down on every tick of a one-second poll races the
        // accessibility tree and drops clicks that land mid-teardown.
        let signature = barSignature()
        if signature != lastBarSignature {
            lastBarSignature = signature
            rebuildContextBar()
        }
        layoutEverything()
        // Video is attached only once the tiles have real frames. The SDK
        // resizes its render element to whatever rect it is handed, and handing
        // it the zero rect a freshly created tile still has produces an element
        // that never draws.
        attachVideo(videoProvider)
        attachSelfVideo(selfProvider)
        attachStage()
        updateMeetingChrome()
    }

    /// Selection changes the tile rings, the contextual strip, and therefore
    /// the height available to the grid - so all three are redone, without
    /// waiting for the next poll. A click has to feel immediate.
    func selectionChanged() {
        for entry in pageRoster {
            let badges = tileBadges(entry.id)
            tiles[entry.id]?.apply(entry: entry, isSelected: selected == entry.id,
                                   reaction: badges.reaction, feedback: badges.feedback)
        }
        lastBarSignature = barSignature()
        rebuildContextBar()
        layoutEverything()
    }

    /// Fed at 20Hz from the mic monitor, independent of the roster poll.
    func applyMicLevel(_ level: Double, running: Bool) {
        selfPreview.setLevel(running ? level : 0)
        guard running else { return }
        lastMicLevel = level
    }

    var infoPopover: NSPopover?

    /// The pointer over the small slot form brings its chrome in; leaving takes
    /// it out after a beat, so a menu opened from the toolbar is not pulled out
    /// from under the pointer.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard hoverChrome else { return }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard hoverChrome else { return }
        chromeHideWork?.cancel()
        guard !chromeHover else { return }
        chromeHover = true
        layoutEverything()
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverChrome else { return }
        chromeHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.chromeHover = false
            self?.layoutEverything()
        }
        chromeHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    override func layout() {
        super.layout()
        layoutEverything()
    }

    /// A global monitor outlives the view that installed it, so ending a
    /// session with the drawer open would leave one running for the rest of
    /// the app's life, swallowing Escape everywhere.
    deinit {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }
}
