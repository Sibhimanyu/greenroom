//
//  MeetingViewWindow.swift
//  Greenroom
//
//  One window per open meeting view (.context/meeting-views-plan.md): Active
//  speaker, Gallery, Multi-speaker, Speaker + strip, Self view, People list,
//  Shared screen, Spotlight student, Hands up. Each is a non-activating panel,
//  forced dark (MeetingTheme), with a transparent title bar that shows the view's
//  name. They draw with MeetingViewContentView and the shared tile chrome.
//
//  MeetingViewWindows is the runtime: the registry, the one-second tick that
//  builds a snapshot, shares the video budget between windows, lays out and then
//  asks for video, and the rules around them:
//
//    - render order (the lesson of 028a189): show the panel, lay it out, create
//      the elements, subscribe once the window is visible;
//    - windows open half a second apart;
//    - a window hidden, closed or covered for 3 s or more gives its elements back,
//      and a window that comes back makes new ones;
//    - the black-window fallback: 6 s with the camera on and no video, and the
//      window says so and offers "Use the meeting window" (logged "View window:");
//    - the pick of Spotlight student lasts for the session.
//
import AppKit
import ZoomSDK

/// Never key unless the view needs typing (the People list's search), and never
/// main: it must not take focus from the teacher's slides.
final class MeetingViewPanel: NSPanel {
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

/// A pop-up that answers the first click: the panel is rarely key.
private final class FirstClickPopUp: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class MeetingViewWindowController: NSObject, NSWindowDelegate {
    let view: MeetingView
    let panel: MeetingViewPanel
    let content: MeetingViewContentView
    /// Since when the window has not been on screen (hidden, covered, minimised).
    var coveredSince: Date?
    var videoReleased = false
    var closingByCode = false
    private(set) var picker: NSPopUpButton?
    private var pickerSignature = ""
    var onClosedByUser: ((MeetingView) -> Void)?

    init(view: MeetingView, frame: NSRect, screen: NSScreen?) {
        self.view = view
        let panel = MeetingViewPanel(contentRect: frame,
                                     styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                                     backing: .buffered, defer: false, screen: screen)
        self.panel = panel
        self.content = MeetingViewContentView(view: view, frame: NSRect(origin: .zero, size: frame.size))
        super.init()
        panel.title = view.title
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)     // Zoom's window is dark whatever the system is
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .visible
        panel.backgroundColor = MeetingTheme.windowNS
        panel.level = .normal
        panel.collectionBehavior = [.managed, .fullScreenAuxiliary]
        panel.keyable = view == .people
        panel.minSize = NSSize(width: view.minimumPoints.width, height: view.minimumPoints.height + MeetingViewContentView.titleInset)
        panel.delegate = self
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        if view == .spotlight || view == .sharedScreen { addPicker() }
    }

    func windowWillClose(_ notification: Notification) {
        if !closingByCode { onClosedByUser?(view) }
    }

    // MARK: The title bar's picker

    private func addPicker() {
        let button = FirstClickPopUp(frame: NSRect(x: 0, y: 0, width: 190, height: 22), pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.setAccessibilityLabel(view == .spotlight ? "Choose a student" : "Choose whose screen")
        let controller = NSTitlebarAccessoryViewController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 202, height: 28))
        button.frame = NSRect(x: 0, y: 3, width: 190, height: 22)
        host.addSubview(button)
        controller.view = host
        controller.layoutAttribute = .trailing
        panel.addTitlebarAccessoryViewController(controller)
        picker = button
    }

    /// Rebuilt only when the choices change.
    func setPicker(signature: String, items: [(title: String, selected: Bool, action: () -> Void)], placeholder: String) {
        guard let picker, signature != pickerSignature else { return }
        pickerSignature = signature
        picker.removeAllItems()
        if items.isEmpty {
            picker.addItem(withTitle: placeholder)
            picker.isEnabled = false
            return
        }
        picker.isEnabled = true
        for entry in items {
            let item = MeetingMenuBuilder.Item(entry.title, handler: entry.action)
            item.state = entry.selected ? .on : .off
            picker.menu?.addItem(item)
        }
        if let chosen = items.firstIndex(where: \.selected) {
            picker.selectItem(at: chosen)
        } else {
            picker.menu?.insertItem(NSMenuItem(title: placeholder, action: nil, keyEquivalent: ""), at: 0)
            picker.selectItem(at: 0)
        }
    }

    func showPicker(_ show: Bool) { picker?.superview?.isHidden = !show }
}

// MARK: - The runtime

@MainActor
enum MeetingViewWindows {

    // MARK: Wiring (set by the coordinator)

    private static weak var client: ZoomMeetingSDKClient?
    private static var log: (String) -> Void = { _ in }
    /// Where the layout puts a view right now, or nil when the layout has no piece for it.
    private static var frameFor: (MeetingView) -> (frame: NSRect, screen: NSScreen?)? = { _ in nil }
    private static var copyInvite: () -> Void = {}
    private static var openMeetingWindow: () -> Void = {}

    static func configure(client: ZoomMeetingSDKClient,
                          log: @escaping (String) -> Void,
                          frameFor: @escaping (MeetingView) -> (frame: NSRect, screen: NSScreen?)?,
                          copyInvite: @escaping () -> Void,
                          openMeetingWindow: @escaping () -> Void) {
        self.client = client
        self.log = log
        self.frameFor = frameFor
        self.copyInvite = copyInvite
        self.openMeetingWindow = openMeetingWindow
    }

    // MARK: State

    private static var controllers: [MeetingView: MeetingViewWindowController] = [:]
    private static var queue: [(view: MeetingView, frame: NSRect?)] = []
    private static var openTask: Task<Void, Never>?
    /// The pick of Spotlight student: for the whole session.
    private(set) static var spotlightUserID: UInt32?
    private static var spotlightName = ""
    private static var handStamps = HandStamps()
    /// Set by "Use the meeting window": the views are off for the rest of the session.
    private(set) static var meetingWindowOnly = false
    /// ⌥⌘Z hid the views (none of them is brought forward until it shows them).
    private(set) static var hiddenTogether = false
    /// Tells the Views menu to redraw.
    static var onChanged: (() -> Void)?

    static let coverRelease: TimeInterval = 3
    static let noVideoAfter: TimeInterval = 6
    static let openSpacing: UInt64 = 500_000_000

    static var isEnabled: Bool { MeetingViewPieces.enabled && (client?.didUseCustomUI ?? false) && !meetingWindowOnly }
    static var openViews: Set<MeetingView> { Set(controllers.keys) }
    static func isOpen(_ view: MeetingView) -> Bool { controllers[view] != nil }
    static var anyOpen: Bool { !controllers.isEmpty }
    static func owns(_ window: NSWindow) -> Bool { controllers.values.contains { $0.panel === window } }

    /// The Views menu's checkmarks and offer.
    static var menuState: MeetingMenus.ViewsMenuState {
        MeetingMenus.ViewsMenuState(meetingWindowOpen: ParticipantGridWindowController.meetingWindowIsOpen,
                                    openViews: openViews,
                                    viewsAvailable: MeetingViewPieces.enabled && !meetingWindowOnly
                                        && (client?.didUseCustomUI ?? true))
    }

    // MARK: Opening and closing

    /// Opens a view at `frame` (the layout's rectangle), else where it was last
    /// left, else a first place. Windows open half a second apart.
    static func open(_ view: MeetingView, at frame: NSRect? = nil) {
        guard MeetingViewPieces.enabled, client?.didUseCustomUI == true else { return }
        if meetingWindowOnly, view.drawsVideo {
            log("View window: \(view.title) is off for this session. The meeting window shows the video.")
            return
        }
        if let existing = controllers[view] {
            if let frame { existing.panel.setFrame(frame, display: true) }
            if !hiddenTogether { existing.panel.orderFrontRegardless() }
            return
        }
        guard !queue.contains(where: { $0.view == view }) else { return }
        queue.append((view, frame))
        guard openTask == nil else { return }
        openTask = Task { @MainActor in
            while !queue.isEmpty {
                let next = queue.removeFirst()
                create(next.view, at: next.frame)
                try? await Task.sleep(nanoseconds: openSpacing)
            }
            openTask = nil
        }
    }

    private static func create(_ view: MeetingView, at explicit: NSRect?) {
        guard controllers[view] == nil, let client else { return }
        let placed = explicit.map { (frame: $0, screen: nil as NSScreen?) } ?? frameFor(view)
        let screen = placed?.screen ?? NSScreen.main
        let frame = placed?.frame ?? defaultFrame(for: view, on: screen)
        let controller = MeetingViewWindowController(view: view, frame: frame, screen: screen)
        wire(controller, client: client)
        controllers[view] = controller

        let panel = controller.panel
        let key = "MeetingView.\(view.rawValue)"
        _ = panel.setFrameAutosaveName(key)
        if let explicit = placed?.frame {
            panel.setFrame(explicit, display: false)
        } else if UserDefaults.standard.string(forKey: "NSWindow Frame \(key)") == nil
                    || !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            panel.setFrame(frame, display: false)
        }
        // Render order: show it and lay it out FIRST; the tick creates the elements after.
        panel.orderFrontRegardless()
        controller.content.layoutSubtreeIfNeeded()
        ZoomMeetingSDKClient.viewLog("opened '\(view.title)' frame=\(Int(panel.frame.width))x\(Int(panel.frame.height))")
        onChanged?()
        tick()
    }

    private static func defaultFrame(for view: MeetingView, on screen: NSScreen?) -> NSRect {
        let area = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let min = view.minimumPoints
        let width = Swift.min(area.width - 40, Swift.max(min.width * 1.6, 380))
        let height = Swift.min(area.height - 40, Swift.max(min.height * 1.6, 260) + MeetingViewContentView.titleInset)
        let step = CGFloat(controllers.count) * 28
        return NSRect(x: area.midX - width / 2 + step, y: area.midY - height / 2 - step, width: width, height: height)
    }

    static func close(_ view: MeetingView) {
        queue.removeAll { $0.view == view }
        guard let controller = controllers.removeValue(forKey: view) else { return }
        teardown(controller)
        controller.closingByCode = true
        controller.panel.close()
        ZoomMeetingSDKClient.viewLog("closed '\(view.title)'")
        updateShareOwnership()
        onChanged?()
    }

    static func toggle(_ view: MeetingView) {
        if isOpen(view) { close(view) } else { open(view, at: frameFor(view)?.frame) }
    }

    static func closeAll() {
        queue = []
        openTask?.cancel()
        openTask = nil
        for view in Array(controllers.keys) { close(view) }
    }

    /// The meeting is over: everything goes, and the session's choices with it.
    static func reset() {
        closeAll()
        client?.releaseAllViewVideo()
        client?.shareViewer.setWindowOwnsShare(false)
        spotlightUserID = nil
        spotlightName = ""
        handStamps = HandStamps()
        meetingWindowOnly = false
        hiddenTogether = false
    }

    /// The layout wants this view in this rectangle: (re)place it, open it if it is
    /// not open. Hidden together (⌥⌘Z, or "Starts hidden"), it stays away.
    static func place(_ view: MeetingView, frame: NSRect, hidden: Bool) {
        if hidden {
            hide(view)
            return
        }
        if let controller = controllers[view] {
            controller.panel.setFrame(frame, display: true)
            if !hiddenTogether { controller.panel.orderFrontRegardless() }
        } else {
            open(view, at: frame)
        }
    }

    static func hide(_ view: MeetingView) {
        controllers[view]?.panel.orderOut(nil)
    }

    /// ⌥⌘Z: every view goes out, or comes back, with the Meeting window.
    static func setHiddenTogether(_ hidden: Bool) {
        hiddenTogether = hidden
        for controller in controllers.values {
            if hidden { controller.panel.orderOut(nil) } else { controller.panel.orderFrontRegardless() }
        }
    }

    // MARK: Spotlight

    /// Right-click on any tile: that person, large, in a window of their own.
    static func spotlight(userID: UInt32, name: String) {
        spotlightUserID = userID
        spotlightName = name
        log("Spotlight student: \(name)")
        if isOpen(.spotlight) { tick() } else { open(.spotlight, at: frameFor(.spotlight)?.frame) }
    }

    // MARK: Fallback

    /// "Use the meeting window": the views that draw video close, and the Meeting
    /// window shows the video for the rest of the session.
    static func useMeetingWindow() {
        meetingWindowOnly = true
        log("View window: no video here, so the views are off for the rest of this session. The meeting window shows the video.")
        ZoomMeetingSDKClient.viewLog("fallback to the meeting window for the session")
        for view in controllers.keys where view.drawsVideo { close(view) }
        openMeetingWindow()
        onChanged?()
    }

    // MARK: Wiring one window

    private static func wire(_ controller: MeetingViewWindowController, client: ZoomMeetingSDKClient) {
        controller.onClosedByUser = { view in
            guard let gone = controllers.removeValue(forKey: view) else { return }
            queue.removeAll { $0.view == view }
            teardown(gone)
            ZoomMeetingSDKClient.viewLog("window closed by hand '\(view.title)'")
            updateShareOwnership()
            onChanged?()
        }
        let content = controller.content
        content.onChange = { tick() }
        content.onSpotlight = { person in spotlight(userID: person.id, name: person.name) }
        content.onPickShare = { client.shareViewer.pick($0); tick() }
        content.onUseMeetingWindow = { useMeetingWindow() }
        content.handsActions = HandsUpActions(
            admit: { id in perform("Admitted \(name(of: id))") { $0.admitFromWaitingRoom(userID: id) } },
            deny: { id in perform("Denied \(name(of: id))") { $0.denyWaiting(userID: id) } },
            admitAll: { perform("Admitted everyone waiting") { $0.admitEveryoneWaiting() } },
            lower: { id in perform("Lowered \(name(of: id))\u{2019}s hand") { $0.lowerHand(userID: id) } },
            askToUnmute: { id in perform("Asked \(name(of: id)) to unmute") { $0.setMuted(false, userID: id) } })
        content.peopleActions = MeetingParticipantsActions(
            select: { _ in },
            admit: { id in perform("Admitted \(name(of: id))") { $0.admitFromWaitingRoom(userID: id) } },
            deny: { id in perform("Denied \(name(of: id))") { $0.denyWaiting(userID: id) } },
            admitAll: { perform("Admitted everyone waiting") { $0.admitEveryoneWaiting() } },
            invite: { copyInvite() },
            muteAll: { perform("Muted everyone") { $0.muteEveryone() } },
            askAllToUnmute: { perform("Asked everyone to unmute") { $0.askEveryoneToUnmute() } })
    }

    /// A name for the log line: a participant, or someone at the door.
    private static func name(of id: UInt32) -> String {
        client?.participantName(userID: id)
            ?? client?.waitingRoomNames().first { $0.id == id }?.name
            ?? "them"
    }

    private static func perform(_ sentence: String, _ body: (ZoomMeetingSDKClient) -> Bool) {
        guard let client else { return }
        log(body(client) ? sentence : "Couldn\u{2019}t do that: \(sentence.lowercased()).")
        tick()
    }

    private static func teardown(_ controller: MeetingViewWindowController) {
        controller.content.detachAllVideo()
        client?.releaseViewVideo(of: controller.view)
    }

    private static func updateShareOwnership() {
        client?.shareViewer.setWindowOwnsShare(controllers[.sharedScreen] != nil && !(controllers[.sharedScreen]?.videoReleased ?? true))
    }

    // MARK: The tick (one second, and on demand)

    static func tick() {
        guard let client, !controllers.isEmpty else { return }
        let now = Date()
        let roster = client.meetingRoster()
        let snapshot = makeSnapshot(client: client, roster: roster, now: now)

        // Who is on screen, who has been away long enough to give its video back.
        var live: [MeetingViewWindowController] = []
        for controller in controllers.values.sorted(by: { order($0.view) < order($1.view) }) {
            let panel = controller.panel
            let onScreen = panel.isVisible && !panel.isMiniaturized && panel.occlusionState.contains(.visible)
            if onScreen {
                controller.coveredSince = nil
                if controller.videoReleased {
                    controller.videoReleased = false
                    ZoomMeetingSDKClient.viewLog("'\(controller.view.title)' is back on screen: new elements")
                }
            } else {
                controller.coveredSince = controller.coveredSince ?? now
                if !controller.videoReleased, now.timeIntervalSince(controller.coveredSince ?? now) >= coverRelease {
                    controller.videoReleased = true
                    teardown(controller)
                    ZoomMeetingSDKClient.viewLog("'\(controller.view.title)' covered or hidden for \(Int(coverRelease))s: elements released")
                }
            }
            if !controller.videoReleased { live.append(controller) }
        }
        updateShareOwnership()

        // The budget: everyone but the gallery first, then the gallery gets a page
        // as big as the 180p streams left.
        let external = client.meetingWindowVideoUsage()
        var plans: [MeetingView: [MeetingViewSlotPlan]] = [:]
        func requests(_ views: [MeetingViewWindowController]) -> [VideoRequest] {
            views.flatMap { controller in
                (plans[controller.view] ?? []).map { plan in
                    VideoRequest(key: key(controller.view, plan), priority: plan.priority, wanted: plan.wanted,
                                 floor: plan.floor, current: client.viewVideo.tier(of: ViewVideoKey(view: controller.view, slot: plan.slot)))
                }
            }
        }
        let first = live.filter { $0.view != .gallery }
        for controller in first { plans[controller.view] = controller.content.slotPlans(snapshot) }
        var pageSize = 16
        if let gallery = live.first(where: { $0.view == .gallery }) {
            let chosen = VideoBudget.allocate(requests(first).filter { !$0.key.hasSuffix("/selfView") }, external: external)
            var used = external
            for case let tier? in chosen.values { used.take(tier) }
            pageSize = VideoBudget.galleryPageSize(used: used)
            plans[.gallery] = gallery.content.slotPlans(snapshot, pageSize: pageSize)
        }
        // Your own picture is free: it asks for a tier but never spends one.
        let paid = requests(live).filter { !$0.key.hasSuffix("/selfView") }
        var allocation = VideoBudget.allocate(paid, external: external)
        for controller in live {
            for plan in plans[controller.view] ?? [] where plan.slot == .selfView {
                allocation[key(controller.view, plan)] = .some(.p360)
            }
        }

        for controller in live {
            let view = controller.view
            let myPlans = plans[view] ?? []
            controller.content.render(snapshot, plans: myPlans, pageSize: pageSize, tiers: allocation,
                video: { plan, tier in
                    let id = ViewVideoKey(view: view, slot: plan.slot)
                    return client.viewVideoView(id, userID: plan.person.id,
                                                frame: NSRect(origin: .zero, size: plan.frame.size), tier: tier)
                },
                shareView: view == .sharedScreen ? { frame in
                    let viewer = client.shareViewer
                    guard let v = viewer.stageView(frame: frame) else { return nil }
                    viewer.renderIfReady()
                    return v
                } : nil)
            // Elements for places that are gone are given back.
            if view.drawsVideo && view != .sharedScreen {
                client.releaseViewVideo(of: view, keeping: Set(myPlans.map { ViewVideoKey(view: view, slot: $0.slot) }))
            }
            if view == .sharedScreen, snapshot.share == nil { client.shareViewer.releaseElement() }
            updatePicker(controller, snapshot: snapshot)
            checkForBlackWindow(controller, plans: myPlans, client: client)
        }
    }

    private static func key(_ view: MeetingView, _ plan: MeetingViewSlotPlan) -> String { "\(view.rawValue)/\(plan.slot)" }

    /// Active speaker and Spotlight first (they want the 720p streams), then the
    /// strip, then Multi-speaker, then Gallery and your own picture.
    private static func order(_ view: MeetingView) -> Int {
        switch view {
        case .activeSpeaker: return 10
        case .spotlight: return 11
        case .speakerStrip: return 20
        case .multiSpeaker: return 30
        case .sharedScreen: return 40
        case .gallery: return 50
        case .selfView: return 60
        case .people: return 70
        case .handsUp: return 71
        }
    }

    // MARK: Black window

    private static func checkForBlackWindow(_ controller: MeetingViewWindowController,
                                            plans: [MeetingViewSlotPlan], client: ZoomMeetingSDKClient) {
        guard controller.view.drawsVideo, controller.view != .sharedScreen else { return }
        var failed = false
        for plan in plans where plan.person.videoOn {
            let id = ViewVideoKey(view: controller.view, slot: plan.slot)
            if let waited = client.viewVideoWaiting(id), waited >= noVideoAfter {
                client.noteViewVideoMissing(id)
                failed = true
            }
        }
        controller.content.setVideoFailed(failed)
    }

    // MARK: Pickers in the title bar

    private static func updatePicker(_ controller: MeetingViewWindowController, snapshot s: MeetingViewSnapshot) {
        switch controller.view {
        case .spotlight:
            let items = s.others.map { person in
                (title: person.name, selected: person.id == spotlightUserID, action: { () -> Void in
                    spotlightUserID = person.id
                    spotlightName = person.name
                    tick()
                })
            }
            controller.setPicker(signature: "\(spotlightUserID ?? 0)|" + s.others.map { "\($0.id):\($0.name)" }.joined(separator: ","),
                                 items: items, placeholder: s.others.isEmpty ? "No one else is here" : "Choose a student")
        case .sharedScreen:
            controller.showPicker(s.shareChoices.count > 1)
            let items = s.shareChoices.map { choice in
                (title: "\(choice.name)\u{2019}s screen", selected: choice.sourceID == s.share?.sourceID,
                 action: { () -> Void in
                    client?.shareViewer.pick(choice.sourceID)
                    tick()
                 })
            }
            controller.setPicker(signature: s.shareChoices.map { "\($0.sourceID):\($0.name)" }.joined(separator: ",") + "|\(s.share?.sourceID ?? 0)",
                                 items: items, placeholder: "No one is sharing")
        default: break
        }
    }

    // MARK: The snapshot

    private static func person(_ e: ZoomMeetingSDKClient.RosterEntry) -> MeetingViewPerson {
        MeetingViewPerson(id: e.id, name: e.name, isMe: e.isMyself, muted: e.isMuted, hasAudio: e.hasJoinedAudio,
                          videoOn: e.videoOn, speaking: e.isTalking, handUp: e.isRaisingHand, isHost: e.isHost,
                          isCoHost: e.isCoHost, isSpotlighted: e.isSpotlighted)
    }

    private static func makeSnapshot(client: ZoomMeetingSDKClient, roster: [ZoomMeetingSDKClient.RosterEntry],
                                     now: Date) -> MeetingViewSnapshot {
        var s = MeetingViewSnapshot()
        let people = roster.map(person)
        s.me = people.first { $0.isMe }
        s.others = people.filter { !$0.isMe }
        let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })

        if isOpen(.activeSpeaker) || isOpen(.speakerStrip) {
            s.stage = client.stagePerson().map(person)
        }
        if isOpen(.multiSpeaker) {
            s.placeCount = min(3, s.others.count)
            var occupied = client.multiSpeakerPlaces(roster: roster)
            if occupied.isEmpty {
                // Nobody has spoken yet: the first people, until someone does.
                occupied = s.others.prefix(s.placeCount).enumerated().map { (place: $0.offset, userID: $0.element.id) }
            } else if occupied.contains(where: { $0.place >= s.placeCount }) {
                // Someone left and the meeting is smaller than the places: close the gap.
                occupied = occupied.enumerated().map { (place: $0.offset, userID: $0.element.userID) }
            }
            for entry in occupied where entry.place < s.placeCount {
                if let p = byID[entry.userID] { s.places[entry.place] = p }
            }
        }
        if isOpen(.spotlight) {
            s.spotlightPicked = spotlightUserID != nil
            s.spotlightName = spotlightName
            if let id = spotlightUserID, let p = s.others.first(where: { $0.id == id }) {
                s.spotlight = p
                spotlightName = p.name
                s.spotlightName = p.name
            }
        }
        if isOpen(.sharedScreen) {
            let viewer = client.shareViewer
            if let now = viewer.current { s.share = ShareChoice(sourceID: now.sourceID, name: now.name) }
            s.shareChoices = viewer.choices.map { ShareChoice(sourceID: $0.sourceID, name: $0.name) }
        }
        if isOpen(.handsUp) || isOpen(.people) {
            handStamps.update(raised: Set(roster.filter(\.isRaisingHand).map(\.id)), now: now)
            let flags = client.roomFlags()
            s.isHost = flags.iAmHostOrCoHost
            s.canDeny = client.canExpelFromWaitingRoom()
            let waiting = client.waitingRoomNames().map { MeetingWaitingRow(id: $0.id, name: $0.name) }
            s.hands = HandsUpContent(
                waiting: waiting, canDeny: s.canDeny,
                hands: handStamps.ordered(roster.map { (id: $0.id, name: $0.name, muted: $0.isMuted && $0.hasJoinedAudio) }))
            s.peopleWaiting = waiting
            func row(_ e: ZoomMeetingSDKClient.RosterEntry) -> MeetingParticipantRow {
                var tags: [String] = []
                if e.isHost { tags.append("Host") } else if e.isCoHost { tags.append("Co-host") }
                if e.isMyself { tags.append("me") }
                return MeetingParticipantRow(id: e.id, name: e.name, tags: tags, detail: e.isSpotlighted ? "spotlit" : "",
                                             handUp: e.isRaisingHand, muted: e.isMuted, hasAudio: e.hasJoinedAudio,
                                             cameraOff: !e.videoOn, selected: false)
            }
            let queueIDs = s.hands.hands.map(\.id)
            let byEntry = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, $0) })
            s.peopleHands = queueIDs.compactMap { byEntry[$0] }.map(row)
            let handSet = Set(queueIDs)
            let me = roster.first(where: \.isMyself).map { entry -> MeetingParticipantRow in
                var r = row(entry)
                r.muted = client.iAmMuted
                r.cameraOff = !client.myVideoIsOn
                return r
            }
            s.peopleEveryone = (me.map { [$0] } ?? []) + roster.filter { !$0.isMyself && !handSet.contains($0.id) }.map(row)
            s.peopleTotal = roster.count
        }
        return s
    }
}
