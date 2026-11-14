//
//  MeetingViewContent.swift
//  Greenroom
//
//  What one view window draws inside its frame (.context/meeting-views-plan.md).
//  Plain values in (MeetingViewSnapshot), tiles and lists out, video views from a
//  provider closure. No SDK here: the live window's runtime hands the provider
//  the SDK's render views, and the off-screen render in .context/vw hands it
//  coloured stand-ins, so the same code draws both.
//
//  Two steps per second, because the video budget is shared across windows:
//    1. `slotPlans`    where each person's tile goes, and the tier it would like;
//    2. `render`       lay the tiles out FIRST, then ask for the video views.
//
import AppKit
import SwiftUI

// MARK: - What a window is shown

struct ShareChoice: Equatable {
    var sourceID: UInt32
    var name: String
}

struct MeetingViewSnapshot: Equatable {
    /// Everyone but you, in roster order.
    var others: [MeetingViewPerson] = []
    var me: MeetingViewPerson?
    /// Active speaker and Speaker + strip: who the stage shows. A 1:1 is the other person.
    var stage: MeetingViewPerson?
    /// Multi-speaker: the person in each place, by place (0, 1, 2).
    var places: [Int: MeetingViewPerson] = [:]
    /// How many places there are (3, or fewer in a small meeting).
    var placeCount = 0
    /// Spotlight student: the pick, and whether anyone is picked at all.
    var spotlight: MeetingViewPerson?
    var spotlightPicked = false
    var spotlightName = ""
    /// Shared screen: whose screen, and every screen to choose from.
    var share: ShareChoice?
    var shareChoices: [ShareChoice] = []
    var hands = HandsUpContent()
    var peopleHands: [MeetingParticipantRow] = []
    var peopleEveryone: [MeetingParticipantRow] = []
    var peopleTotal = 0
    var peopleWaiting: [MeetingWaitingRow] = []
    var canDeny = false
    var isHost = false
    /// Mini: the other person on the stage, you as the small inset, or you alone, large.
    var miniStage: MeetingViewPerson?
    var miniInset: MeetingViewPerson?
    var miniSelfFills = false
}

struct MeetingViewSlotPlan: Equatable {
    var slot: ViewSlot
    var person: MeetingViewPerson
    /// In the content view's coordinates.
    var frame: NSRect
    var wanted: VideoTier
    var floor: VideoTier
    var priority: Int
}

// MARK: - The view

@MainActor
final class MeetingViewContentView: NSView {

    let view: MeetingView
    /// The title bar's height: the content starts below it.
    static let titleInset: CGFloat = 28
    static let pad: CGFloat = 4
    /// The Mini has no title bar and no air: the picture fills the window.
    private var topInset: CGFloat { view == .mini ? 0 : Self.titleInset }
    private var edgePad: CGFloat { view == .mini ? 0 : Self.pad }
    /// The Mini's hover strip (nil in every other view).
    private(set) var miniChrome: MeetingMiniChrome?
    private var hoverArea: NSTrackingArea?

    // Callbacks the live window wires.
    var onChange: (() -> Void)?
    var onSpotlight: ((MeetingViewPerson) -> Void)?
    var onPickShare: ((UInt32) -> Void)?
    var onUseMeetingWindow: (() -> Void)?
    var handsActions: HandsUpActions { get { hands.actions } set { hands.actions = newValue } }
    var peopleActions = MeetingParticipantsActions()

    private(set) var page = 0
    private(set) var pageCount = 1
    /// The black-window fallback is showing.
    private(set) var videoFailed = false

    private var tiles: [ViewSlot: MeetingVideoTile] = [:]
    private var ghosts: [NSView] = []
    private let message = NSTextField(wrappingLabelWithString: "")
    private let shareTile = MeetingVideoTile(frame: .zero)
    private var shareVideo: NSView?
    private let failure = NSView()
    private let failureText = NSTextField(wrappingLabelWithString: "Video didn\u{2019}t start in this window")
    private lazy var failureButton = ClosureButton { [weak self] in self?.onUseMeetingWindow?() }
    private lazy var previous = pagerButton("chevron.left", "Previous page") { [weak self] in self?.turn(-1) }
    private lazy var next = pagerButton("chevron.right", "Next page") { [weak self] in self?.turn(1) }
    private let pageLabel = NSTextField(labelWithString: "")
    private let hands = HandsUpView(frame: .zero)
    private let people = MeetingPeopleView(frame: .zero)
    private var lastSnapshot = MeetingViewSnapshot()

    init(view: MeetingView, frame: NSRect) {
        self.view = view
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = MeetingTheme.windowNS.cgColor

        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.textColor = MeetingTheme.secondaryTextNS
        message.alignment = .center
        message.isHidden = true
        addSubview(message)

        failure.wantsLayer = true
        failure.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        failure.isHidden = true
        failureText.font = .systemFont(ofSize: 15, weight: .medium)
        failureText.textColor = .white
        failureText.alignment = .center
        failureButton.title = "Use the meeting window"
        failureButton.bezelStyle = .rounded
        failureButton.controlSize = .regular
        failure.addSubview(failureText)
        failure.addSubview(failureButton)

        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pageLabel.textColor = .white
        pageLabel.alignment = .center
        for v in [previous, next, pageLabel] as [NSView] { v.isHidden = true; addSubview(v) }

        switch view {
        case .handsUp:
            addSubview(hands)
        case .people:
            people.onSelect = { [weak self] in self?.peopleActions.select($0) }
            people.onAdmit = { [weak self] in self?.peopleActions.admit($0) }
            people.onDeny = { [weak self] in self?.peopleActions.deny($0) }
            people.onAdmitAll = { [weak self] in self?.peopleActions.admitAll() }
            people.onInvite = { [weak self] in self?.peopleActions.invite() }
            people.onMuteAll = { [weak self] in self?.peopleActions.muteAll() }
            people.onAskAllToUnmute = { [weak self] in self?.peopleActions.askAllToUnmute() }
            addSubview(people)
        case .sharedScreen:
            shareTile.isHidden = true
            addSubview(shareTile)
        default: break
        }
        addSubview(failure)
        if view == .mini {
            layer?.cornerRadius = 10
            layer?.masksToBounds = true
            let chrome = MeetingMiniChrome(frame: .zero)
            miniChrome = chrome
            addSubview(chrome)
            chrome.place(in: bounds)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hover (the Mini's strip)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        guard view == .mini else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { miniChrome?.setVisible(true) }
    override func mouseExited(with event: NSEvent) { miniChrome?.setVisible(false) }

    // MARK: Geometry

    /// Where video may go: under the title bar, with a little air.
    var area: NSRect {
        NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - topInset))
            .insetBy(dx: edgePad, dy: edgePad)
    }

    // MARK: Step 1: where the tiles go

    func slotPlans(_ s: MeetingViewSnapshot, pageSize: Int = 16) -> [MeetingViewSlotPlan] {
        let area = self.area
        guard area.width > 0, area.height > 0 else { return [] }
        switch view {
        case .activeSpeaker:
            guard let p = s.stage else { return [] }
            return [MeetingViewSlotPlan(slot: .stage, person: p, frame: area, wanted: .p720, floor: .p360, priority: 10)]
        case .spotlight:
            guard let p = s.spotlight else { return [] }
            return [MeetingViewSlotPlan(slot: .stage, person: p, frame: area, wanted: .p720, floor: .p360, priority: 11)]
        case .speakerStrip:
            guard let stage = s.stage else { return [] }
            let stripHeight = MeetingTheme.stripHeight
            let capacity = MeetingVideoLayout.stripCapacity(width: area.width, tileHeight: stripHeight)
            let strip = Array(s.others.filter { $0.id != stage.id }.prefix(capacity))
            var plans: [MeetingViewSlotPlan] = []
            var stageFrame = area
            if !strip.isEmpty {
                let frames = MeetingVideoLayout.strip(count: strip.count, in: area.size, tileHeight: stripHeight)
                for (person, local) in zip(strip, frames) {
                    plans.append(MeetingViewSlotPlan(
                        slot: .user(person.id), person: person,
                        frame: local.offsetBy(dx: area.minX, dy: area.minY),
                        wanted: .p180, floor: .p90, priority: 21))
                }
                let used = stripHeight + MeetingTheme.tileGap
                stageFrame = NSRect(x: area.minX, y: area.minY, width: area.width, height: max(0, area.height - used))
            }
            plans.insert(MeetingViewSlotPlan(slot: .stage, person: stage, frame: stageFrame,
                                             wanted: .p720, floor: .p360, priority: 20), at: 0)
            return plans
        case .multiSpeaker:
            let columns = max(0, s.placeCount)
            guard columns > 0 else { return [] }
            let gap = MeetingTheme.tileGap
            let width = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            return (0..<columns).compactMap { index in
                guard let person = s.places[index] else { return nil }
                let frame = NSRect(x: (area.minX + CGFloat(index) * (width + gap)).rounded(), y: area.minY,
                                   width: width.rounded(), height: area.height)
                return MeetingViewSlotPlan(slot: .place(index), person: person, frame: frame,
                                           wanted: .p360, floor: .p180, priority: 30)
            }
        case .gallery:
            let size = max(1, pageSize)
            let pages = max(1, Int(ceil(Double(s.others.count) / Double(size))))
            let current = min(page, pages - 1)
            let slice = Array(s.others.dropFirst(current * size).prefix(size))
            let reserved: CGFloat = pages > 1 ? 34 : 0
            let galleryArea = NSRect(x: area.minX, y: area.minY + reserved, width: area.width, height: max(0, area.height - reserved))
            let frames = MeetingVideoLayout.gallery(count: slice.count, in: galleryArea.size)
            return zip(slice, frames).map { person, local in
                let frame = local.offsetBy(dx: galleryArea.minX, dy: galleryArea.minY)
                return MeetingViewSlotPlan(slot: .user(person.id), person: person, frame: frame,
                                           wanted: VideoBudget.galleryTier(tileHeight: frame.height), floor: .p90, priority: 50)
            }
        case .selfView:
            guard let me = s.me else { return [] }
            return [MeetingViewSlotPlan(slot: .selfView, person: me, frame: area, wanted: .p360, floor: .p180, priority: 60)]
        case .mini:
            if s.miniSelfFills, let me = s.me {
                return [MeetingViewSlotPlan(slot: .selfView, person: me, frame: area, wanted: .p360, floor: .p180, priority: 60)]
            }
            guard let stage = s.miniStage else { return [] }
            var plans = [MeetingViewSlotPlan(slot: .stage, person: stage, frame: area,
                                             wanted: .p360, floor: .p180, priority: 15)]
            if let me = s.miniInset {
                let inset = MeetingMiniPlan.frames(in: area.size).inset.offsetBy(dx: area.minX, dy: area.minY)
                plans.append(MeetingViewSlotPlan(slot: .selfView, person: me, frame: inset,
                                                 wanted: .p180, floor: .p90, priority: 61))
            }
            return plans
        case .people, .sharedScreen, .handsUp:
            return []
        }
    }

    // MARK: Step 2: lay out, then ask for the video

    /// `tiers` is VideoBudget's answer by plan key; a nil tier means the budget is
    /// spent and the tile shows its person without video for now. `video` gives
    /// the view for a slot at a tier; `shareView` the shared screen's view.
    func render(_ s: MeetingViewSnapshot, plans: [MeetingViewSlotPlan], pageSize: Int = 16,
                tiers: [String: VideoTier?],
                video: (MeetingViewSlotPlan, VideoTier) -> NSView?,
                shareView: ((NSRect) -> NSView?)? = nil) {
        lastSnapshot = s
        let live = Set(plans.map(\.slot))
        for (slot, tile) in tiles where !live.contains(slot) {
            tile.detachVideo()
            tile.removeFromSuperview()
            tiles.removeValue(forKey: slot)
        }
        // Layout first, so the elements are made against a real size in a visible window.
        for plan in plans {
            let tile = tiles[plan.slot] ?? makeTile(plan.slot)
            if tile.frame != plan.frame { tile.frame = plan.frame }
            tile.apply(plan.person)
        }
        layoutGhosts(s)
        layoutPager(s, pageSize: pageSize)
        layoutOverlays(s)
        layoutSubtreeIfNeeded()
        for plan in plans {
            guard let tile = tiles[plan.slot] else { continue }
            if let tier = tiers[planKey(plan)] ?? nil {
                tile.attach(video: video(plan, tier))
            } else {
                tile.detachVideo()
            }
        }
        renderLists(s)
        renderShare(s, shareView: shareView)
    }

    /// The key VideoBudget and the runtime use for this slot of this window.
    func planKey(_ plan: MeetingViewSlotPlan) -> String { "\(view.rawValue)/\(plan.slot)" }

    private func makeTile(_ slot: ViewSlot) -> MeetingVideoTile {
        let tile = MeetingVideoTile(frame: .zero)
        tile.onSpotlight = { [weak self] in self?.onSpotlight?($0) }
        tiles[slot] = tile
        addSubview(tile, positioned: .below, relativeTo: failure)
        return tile
    }

    /// Multi-speaker keeps a dark place where nobody is yet, so tiles never move.
    private func layoutGhosts(_ s: MeetingViewSnapshot) {
        ghosts.forEach { $0.removeFromSuperview() }
        ghosts = []
        guard view == .multiSpeaker, s.placeCount > 0 else { return }
        let area = self.area
        let gap = MeetingTheme.tileGap
        let width = (area.width - gap * CGFloat(s.placeCount - 1)) / CGFloat(s.placeCount)
        for index in 0..<s.placeCount where s.places[index] == nil {
            let ghost = NSView(frame: NSRect(x: (area.minX + CGFloat(index) * (width + gap)).rounded(), y: area.minY,
                                             width: width.rounded(), height: area.height))
            ghost.wantsLayer = true
            ghost.layer?.backgroundColor = MeetingTheme.tileNS.cgColor
            ghost.layer?.cornerRadius = MeetingTheme.tileRadius
            addSubview(ghost, positioned: .below, relativeTo: failure)
            ghosts.append(ghost)
        }
    }

    private func layoutPager(_ s: MeetingViewSnapshot, pageSize: Int) {
        guard view == .gallery else { return }
        let size = max(1, pageSize)
        pageCount = max(1, Int(ceil(Double(s.others.count) / Double(size))))
        if page >= pageCount { page = pageCount - 1 }
        let show = pageCount > 1
        for v in [previous, next, pageLabel] as [NSView] { v.isHidden = !show }
        guard show else { return }
        pageLabel.stringValue = "\(page + 1) / \(pageCount)"
        let area = self.area
        pageLabel.frame = NSRect(x: area.midX - 36, y: area.minY + 6, width: 72, height: 18)
        previous.frame = NSRect(x: pageLabel.frame.minX - 32, y: area.minY + 3, width: 28, height: 24)
        next.frame = NSRect(x: pageLabel.frame.maxX + 4, y: area.minY + 3, width: 28, height: 24)
        previous.isEnabled = page > 0
        next.isEnabled = page < pageCount - 1
    }

    private func turn(_ delta: Int) {
        page = max(0, min(pageCount - 1, page + delta))
        onChange?()
    }

    private func pagerButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(action)
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        b.contentTintColor = .white
        b.toolTip = label
        b.setAccessibilityLabel(label)
        return b
    }

    // MARK: Words, lists, shares

    /// The one line a window shows when there is nothing to draw.
    func emptyMessage(_ s: MeetingViewSnapshot) -> String? {
        switch view {
        case .activeSpeaker, .speakerStrip: return s.stage == nil ? "Waiting for others" : nil
        case .multiSpeaker, .gallery: return s.others.isEmpty ? "Waiting for others" : nil
        case .spotlight:
            if !s.spotlightPicked { return "Choose a student in the title bar" }
            return s.spotlight == nil ? "\(s.spotlightName.isEmpty ? "They" : s.spotlightName) left" : nil
        case .selfView: return s.me == nil ? "Not in the meeting yet" : nil
        case .mini: return (s.miniStage == nil && !s.miniSelfFills) ? "Waiting for others" : nil
        case .sharedScreen: return s.share == nil ? "No one is sharing" : nil
        case .people, .handsUp: return nil
        }
    }

    private func layoutOverlays(_ s: MeetingViewSnapshot) {
        if let text = emptyMessage(s) {
            message.stringValue = text
            message.isHidden = false
            let area = self.area
            message.frame = NSRect(x: area.minX + 16, y: area.midY - 14, width: max(0, area.width - 32), height: 28)
        } else {
            message.isHidden = true
        }
        failure.isHidden = !videoFailed
        failure.frame = area
        if videoFailed {
            let fa = failure.bounds
            failureText.frame = NSRect(x: 16, y: fa.midY + 2, width: max(0, fa.width - 32), height: 24)
            failureButton.sizeToFit()
            let w = failureButton.frame.width + 16
            failureButton.frame = NSRect(x: fa.midX - w / 2, y: fa.midY - 36, width: w, height: 28)
        }
    }

    func setVideoFailed(_ failed: Bool) {
        guard failed != videoFailed else { return }
        videoFailed = failed
        layoutOverlays(lastSnapshot)
    }

    private func renderLists(_ s: MeetingViewSnapshot) {
        let full = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - topInset))
        switch view {
        case .handsUp:
            hands.frame = full
            var content = s.hands
            content.canDeny = s.canDeny
            hands.apply(content)
        case .people:
            people.frame = full
            people.apply(waiting: s.peopleWaiting, canDeny: s.canDeny, isHost: s.isHost,
                         hands: s.peopleHands, everyone: s.peopleEveryone, total: s.peopleTotal)
        default: break
        }
    }

    private func renderShare(_ s: MeetingViewSnapshot, shareView: ((NSRect) -> NSView?)?) {
        guard view == .sharedScreen else { return }
        guard let share = s.share else {
            shareVideo?.removeFromSuperview()
            shareVideo = nil
            shareTile.isHidden = true
            return
        }
        shareTile.isHidden = false
        if shareTile.frame != area { shareTile.frame = area }
        shareTile.apply(MeetingViewPerson(id: share.sourceID, name: "\(share.name)\u{2019}s screen"),
                        model: MeetingTileModel(name: "\(share.name)\u{2019}s screen"))
        shareTile.layoutSubtreeIfNeeded()
        if let provider = shareView, let v = provider(shareTile.videoBounds) {
            shareTile.attach(video: v)
            shareVideo = v
        }
    }

    /// Clears every video view: the window is hidden, covered or closing.
    func detachAllVideo() {
        tiles.values.forEach { $0.detachVideo() }
        shareTile.detachVideo()
        shareVideo = nil
    }

    func resetPage() { page = 0 }

    override func layout() {
        super.layout()
        // The runtime re-plans every second; between ticks keep what is there coherent.
        if view == .people || view == .handsUp { renderLists(lastSnapshot) }
        layoutOverlays(lastSnapshot)
        miniChrome?.place(in: bounds)
    }
}
