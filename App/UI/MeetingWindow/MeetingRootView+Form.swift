//
//  MeetingRootView+Form.swift
//  Greenroom
//
//  The meeting form: setting it up, the View menu, the top bar, chrome text and the view mode choices.
//
import AppKit
import SwiftUI
import Combine

@MainActor
extension MeetingRootView {

    /// The meeting window's views: a Gallery/Speaker control in the top bar, the
    /// stage, one side panel on the right and the toolbar along the foot. The
    /// self view is the corner preview, and Cues sits at the top of the People panel.
    func setupMeetingForm() {
        viewMode = form.isSlot ? .speaker : prefs.view
        shareLayout = prefs.shareLayout
        splitFraction = prefs.splitFraction
        hideSelfView = prefs.hideSelfView
        hideNoVideo = prefs.hideNoVideo
        modeControl.selectedSegment = viewMode.segmentIndex
        rebuildPlan()
        modeControl.setAccessibilityLabel("Video layout")
        meetingTopBar.actions = MeetingTopBarView.Actions(
            showInfo: { [weak self] anchor in self?.showMeetingInfoPopover(from: anchor) },
            viewMenu: { [weak self] in self?.viewMenuEntries() ?? [] },
            shrink: { [weak self] in self?.controls?.collapseMeeting() },
            tipClosed: { MeetingShrinkTip.markDone() })
        addSubview(meetingTopBar)
        installClickMonitor()

        // A black stage: letterboxing against window-background grey reads as a
        // rendering fault.
        stageHost.wantsLayer = true
        stageHost.layer?.backgroundColor = MeetingTheme.tileNS.cgColor
        stageHost.layer?.cornerRadius = MeetingTheme.tileRadius
        stageHost.layer?.masksToBounds = true
        addSubview(stageHost, positioned: .below, relativeTo: emptyState)
        // Layer-backed so the caption composites ABOVE the SDK's render surface.
        stageScrim.wantsLayer = true
        stageScrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        stageHost.addSubview(stageScrim)
        stageScrim.isHidden = true      // the chrome below draws the name instead
        stageHost.addSubview(stageChrome)
        // Side-by-side's share, on its own host so the stage can hold the speaker.
        shareHost.wantsLayer = true
        shareHost.layer?.backgroundColor = MeetingTheme.tileNS.cgColor
        shareHost.layer?.cornerRadius = MeetingTheme.tileRadius
        shareHost.layer?.masksToBounds = true
        shareHost.isHidden = true
        addSubview(shareHost, positioned: .below, relativeTo: emptyState)
        shareHost.addSubview(shareChrome)
        splitDivider.isHidden = true
        splitDivider.onDrag = { [weak self] x in self?.dragSplit(toBoundaryX: x) }
        splitDivider.onEnd = { [weak self] in
            guard let self else { return }
            self.prefs.splitFraction = self.splitFraction
        }
        splitDivider.onReset = { [weak self] in
            guard let self else { return }
            self.splitFraction = MeetingSplit.defaultFraction
            self.prefs.splitFraction = self.splitFraction
            self.relayoutAfterSplit()
        }
        selfShareCard.isHidden = true
        stageHost.addSubview(selfShareCard)
        stageName.font = .systemFont(ofSize: 13, weight: .medium)
        stageName.textColor = .white
        stageName.lineBreakMode = .byTruncatingTail
        stageScrim.addSubview(stageName)

        sidePanelHost.isHidden = true
        sidePanelBacking.wantsLayer = true
        sidePanelBacking.layer?.backgroundColor = NSColor.clear.cgColor // the window's frost shows through
        sidePanelHost.addSubview(sidePanelBacking)
        sidePanelTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        sidePanelTitle.textColor = .white
        sidePanelDivider.wantsLayer = true
        sidePanelDivider.layer?.backgroundColor = MeetingTheme.hairlineNS.cgColor
        sidePanelClose.isBordered = false
        sidePanelClose.imagePosition = .imageOnly
        sidePanelClose.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close panel")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        sidePanelClose.contentTintColor = MeetingTheme.secondaryTextNS
        sidePanelClose.toolTip = "Close panel"
        sidePanelCount.font = .systemFont(ofSize: 12)
        sidePanelCount.textColor = MeetingTheme.secondaryTextNS
        for view in [sidePanelDivider, sidePanelTitle, sidePanelCount, inviteButton, sidePanelClose, queueScroll, peopleView] as [NSView] {
            sidePanelHost.addSubview(view)
        }
        peopleView.onSelect = { [weak self] id in
            if id == ParticipantGridWindowController.myEntry?.id { return }
            self?.selected = id
            self?.selectionChanged()
        }
        // The waiting room's three answers, and the footer's two room-wide ones.
        // Each is `perform`: one definition, one log line, one redraw.
        peopleView.onAdmit = { [weak self] id in
            let name = self?.waiting.first { $0.id == id }?.name ?? "them"
            Self.perform("Admitted \(name)") { $0.admitFromWaitingRoom(userID: id) }
        }
        peopleView.onDeny = { [weak self] id in
            let name = self?.waiting.first { $0.id == id }?.name ?? "them"
            Self.perform("Denied \(name)") { $0.denyWaiting(userID: id) }
        }
        peopleView.onInvite = { [weak self] in self?.controls?.copyInviteLink() }
        peopleView.onAdmitAll = { Self.perform("Admitted everyone waiting") { $0.admitEveryoneWaiting() } }
        peopleView.onMuteAll = { Self.perform("Muted everyone") { $0.muteEveryone() } }
        peopleView.onAskAllToUnmute = { Self.perform("Asked everyone to unmute") { $0.askEveryoneToUnmute() } }
        // A row's hover Mute and "...", and the footer's "...": the shared lists.
        peopleView.onQuick = { id in
            guard let sdk = ParticipantGridWindowController.sdk else { return }
            ParticipantActionRunner.runQuick(userID: id, client: sdk, surface: Self.actionSurface)
        }
        peopleView.personMenu = { id in
            ParticipantGridWindowController.sdk.map { ParticipantActionRunner.menu(userID: id, client: $0, surface: Self.actionSurface) } ?? []
        }
        peopleView.hostMenu = {
            ParticipantGridWindowController.sdk.map { ParticipantActionRunner.hostMenu(client: $0, surface: Self.actionSurface) } ?? []
        }

        if let controls {
            let host = FirstMouseHostingView(rootView: MeetingToolbarView(model: controls, coordinator: controls.coordinator)
                .tint(Brand.green))
            host.frame = bottomBar.bounds
            host.autoresizingMask = [.width, .height]
            bottomBar.addSubview(host)
            // Published fires before the value lands; lay out on the next turn.
            controlsSub = controls.$sidePanel.sink { [weak self] _ in
                DispatchQueue.main.async { self?.sidePanelChanged() }
            }
        }
        // Chrome last, so in the hover form it sits over the video.
        for view in [splitDivider, shareChip, selfPreview, sidePanelHost, inspector, bottomBar] as [NSView] {
            addSubview(view)
        }
    }

    func cycleViewMode() -> Bool {
        guard !form.isSlot else { return false }
        let others = roster.count + 1 >= MeetingTilePlan.multiSpeakerMinimumPeople
        modeControl.selectedSegment = viewMode.next(multiSpeakerAvailable: others).segmentIndex
        modeChanged(modeControl)
        return true
    }

    /// The View button's menu. Without a share: Speaker, Gallery, Multi-speaker.
    /// While someone shares: Standard and the three Side-by-side layouts. Then the
    /// two tile filters, then Fullscreen.
    private func viewMenuEntries() -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if !form.isSlot {
            if sharedNow != nil {
                for layout in MeetingShareLayout.allCases {
                    entries.append(.item(layout.menuTitle, checked: shareLayout == layout) { [weak self] in
                        self?.chooseShareLayout(layout)
                    })
                }
            } else {
                for mode in MeetingViewMode.menuOrder {
                    entries.append(.item(mode.title, checked: viewMode == mode) { [weak self] in self?.chooseMode(mode) })
                }
            }
            entries.append(.separator)
            entries.append(.item("Hide self view", checked: hideSelfView) { [weak self] in
                guard let self else { return }
                self.hideSelfView.toggle()
                self.prefs.hideSelfView = self.hideSelfView
                self.applyViewChange()
            })
            entries.append(.item("Hide participants with video off", checked: hideNoVideo) { [weak self] in
                guard let self else { return }
                self.hideNoVideo.toggle()
                self.prefs.hideNoVideo = self.hideNoVideo
                self.applyViewChange()
            })
            entries.append(.separator)
        }
        entries.append(.item(isFilling ? "Exit Fullscreen" : "Fullscreen") { [weak self] in self?.toggleFill() })
        return entries
    }

    private func chooseMode(_ mode: ViewMode) {
        guard viewMode != mode else { return }
        modeControl.selectedSegment = mode.segmentIndex
        modeChanged(modeControl)
    }

    /// Standard, or the share beside a layout. Remembered for the next share; while
    /// one is up it takes effect now, and the view the person had comes back after.
    private func chooseShareLayout(_ layout: MeetingShareLayout) {
        shareLayout = layout
        prefs.shareLayout = layout
        if sharedNow != nil, !form.isSlot {
            setViewMode(layout.sideMode ?? .speaker)
            applyViewChange()
        }
    }

    /// Fullscreen fills the display the window is on, over the menu bar and Dock
    /// notwithstanding, and goes back to where it was. It is not a macOS
    /// fullscreen Space: a window in a Space cannot be re-framed (2026-08-24).
    private func toggleFill() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        if let before = frameBeforeFullscreen {
            frameBeforeFullscreen = nil
            window.setFrame(before, display: true, animate: true)
        } else {
            frameBeforeFullscreen = window.frame
            window.setFrame(screen.frame, display: true, animate: true)
        }
        updateMeetingTopBar()
    }

    private func showMeetingInfoPopover(from anchor: NSView) {
        if let infoPopover, infoPopover.isShown { infoPopover.close(); return }
        let invite = ParticipantGridWindowController.sdk?.meetingInvite()
        let facts = MeetingMenus.MeetingFacts(number: invite?.number ?? "", passcode: invite?.passcode ?? "",
                                              joinURL: invite?.joinURL ?? "")
        let view = MeetingInfoView(title: invite?.topic ?? "", facts: facts) { text, what in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ParticipantGridWindowController.report("\(what) copied.")
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        infoPopover = popover
    }

    private func updateMeetingTopBar() {
        var state = MeetingTopBarState()
        state.title = session.presetName.isEmpty ? "Meeting" : session.presetName
        state.recording = session.isRecording
        state.mode = viewMode
        state.isFullscreen = isFilling
        state.canShrink = !form.isSlot
        state.shrinkShortcut = ShortcutStore.shared.bindings.combo(for: .action(.shrinkToBar))?.glyphs ?? ""
        meetingTopBar.apply(state)
    }

    @objc func modeChanged(_ sender: NSSegmentedControl) {
        let mode = ViewMode(segment: sender.selectedSegment)
        let beside = shareBeside
        setViewMode(mode)
        if beside {
            // Beside a share the choice is the share layout; the view the person had
            // before the share is what comes back when it ends.
            shareLayout = .sideBySide(mode)
            prefs.shareLayout = shareLayout
        } else {
            // A choice made while a share is up stays: it is not undone when the share ends.
            if shareForcedSpeaker { userChoseDuringShare = true }
            if !form.isSlot { prefs.view = viewMode }
        }
        applyViewChange()
    }

    /// A different list of people is on screen, so tiles, then layout, then
    /// video, in that order and without waiting for the poll.
    private func applyViewChange() {
        rebuildPlan()
        let pages = max(1, Int(ceil(Double(listed.count) / Double(perPage))))
        page = min(page, pages - 1)
        syncTiles()
        updateChromeText()
        layoutEverything()
        if let provider = lastVideoProvider { attachVideo(provider) }
        attachStage()
    }

    private func sidePanelChanged() {
        controls?.refresh()
        layoutEverything()
    }

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        modeControl.selectedSegment = mode.segmentIndex
        page = 0
        rebuildPlan()
    }

    /// Your corner preview and the roster, rewritten once a second.
    func updateMeetingChrome() {
        if let sdk = ParticipantGridWindowController.sdk {
            let coordinator = controls?.coordinator
            let stopped = coordinator?.videoStopped ?? false
            let look = coordinator?.selfViewLook
            selfPreview.apply(muted: sdk.iAmMuted, camera: coordinator?.cameraState ?? .everyoneAndMe,
                              videoStopped: stopped, content: look?.content ?? .everyoneSees,
                              name: sdk.myName ?? "You", mark: look?.mark, level: lastMicLevel)
        }
        if shareBeside, let now = sharedNow {
            shareChrome.apply(MeetingTileModel(name: "\(now.name)\u{2019}s screen"))
        }
        if shareOnStage, let now = sharedNow {
            stageName.stringValue = "\(now.name)\u{2019}s screen"
            stageChrome.apply(MeetingTileModel(name: stageName.stringValue))
        } else if let id = stageSpeakerID, let entry = roster.first(where: { $0.id == id }) {
            var name = entry.name
            if entry.isHost { name += " \u{00B7} host" } else if entry.isCoHost { name += " \u{00B7} co-host" }
            stageName.stringValue = name
            stageChrome.apply(MeetingTileModel(name: entry.name, muted: entry.isMuted && entry.hasJoinedAudio,
                                               videoOn: entry.videoOn, speaking: entry.isTalking, handUp: entry.isRaisingHand))
        }
        updateMeetingTopBar()
    }

    /// The Zoom-style bar lays itself out; this only keeps its state current.
    func layoutMeetingTopBar() {
        updateMeetingTopBar()
    }

    func updateChromeText() {
        emptyState.stringValue = plan.everyoneHidden ? MeetingTileFilter.emptyNote : waiting.isEmpty
            ? "Waiting for others.\nThey appear here as they join."
            : "\(waiting.count) waiting to be let in.\nOpen Participants to admit them."
    }
}
