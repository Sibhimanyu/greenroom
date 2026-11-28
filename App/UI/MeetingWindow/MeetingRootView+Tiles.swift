//
//  MeetingRootView+Tiles.swift
//  Greenroom
//
//  Which people are on the page, their tiles, their video, and the Gallery, Speaker and Multi-speaker frames.
//
import AppKit
import SwiftUI
import Combine

@MainActor
extension MeetingRootView {

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
    var perPage: Int {
        // Speaker view's filmstrip is one row, as many as fit; Multi-speaker adds its large tiles.
        if isSpeakerMode { return stripCapacity }
        if isMultiMode { return max(1, plan.large.count) + stripCapacity }
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

    /// How many 16:9 filmstrip tiles fit along the strip, capped so the strip
    /// stays a strip. Quantised by whole tiles, so it moves only when a tile does.
    private var stripCapacity: Int {
        MeetingVideoLayout.stripCapacity(width: max(0, gridHost.bounds.width - stripReservedRight),
                                         tileHeight: Self.stripHeight - 8)
    }

    /// Multi-speaker's strip leaves its right end to your preview.
    private var stripReservedRight: CGFloat {
        guard isMultiMode, !hideSelfView else { return 0 }
        return ((Self.stripHeight - 8) * 16 / 9).rounded() + 8
    }

    /// Who the gallery or the filmstrip lists: everyone, or everyone but the
    /// person already on the stage.
    var listed: [ZoomMeetingSDKClient.RosterEntry] {
        let byID = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return plan.listed.compactMap { byID[$0] }
    }

    /// Settles who has a tile and where, from the roster, the view, the two
    /// filters and the recent speakers. Cheap; called whenever any of them moves.
    func rebuildPlan() {
        let others = roster.map { MeetingTileCandidate(id: $0.id, videoOn: $0.videoOn) }
        let choice = roster.first(where: \.isSpotlighted)?.id ?? roster.first(where: \.isPinned)?.id ?? featuredSpeaker
        let sharing = sharedNow != nil && !shareBeside
        plan = MeetingTilePlan.make(others: others, mode: viewMode, hideNoVideo: hideNoVideo, stageChoice: choice,
                                    recentSpeakers: recentIDs, shareOnStage: sharing)
        stageSpeakerID = plan.stage
    }

    /// The tracker takes who is talking now and the people the filter leaves.
    func feedMultiSpeakers() {
        let now = Date()
        let shown = MeetingTileFilter.apply(roster.map { MeetingTileCandidate(id: $0.id, videoOn: $0.videoOn) },
                                            hideNoVideo: hideNoVideo).map(\.id)
        multiTracker.heard(roster.filter(\.isTalking).map(\.id), selfID: nil, now: now)
        multiTracker.update(present: Set(shown), now: now)
        recentIDs = multiTracker.occupied.map(\.userID)
    }

    func syncTiles() {
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
                made.onSpotlightInWindow = { [weak self] id in
                    guard let name = self?.roster.first(where: { $0.id == id })?.name else { return }
                    MeetingViewWindows.spotlight(userID: id, name: name)
                }
                tiles[entry.id] = made
                gridHost.addSubview(made)
                return made
            }()
            let badges = tileBadges(entry.id)
            tile.apply(entry: entry, isSelected: selected == entry.id,
                       reaction: badges.reaction, feedback: badges.feedback)
        }
    }

    /// What a tile shows from the room's events: a three-second reaction and the
    /// persistent feedback badge.
    func tileBadges(_ id: UInt32) -> (reaction: String?, feedback: String?) {
        guard let ledger = ParticipantGridWindowController.sdk?.roomEvents.reactions else { return (nil, nil) }
        return (ledger.reaction(for: id, now: Date()), ledger.feedbackLabel(for: id))
    }

    /// The SDK renders into a view it owns; the tile only parents it, and only
    /// when it changes. Re-parenting a live video view every refresh would
    /// flicker the whole wall.
    func attachVideo(_ videoProvider: @escaping (UInt32, NSRect) -> NSView?) {
        lastVideoProvider = videoProvider
        for entry in pageRoster {
            guard let tile = tiles[entry.id], !tile.bounds.isEmpty else { continue }
            tile.attach(video: videoProvider(entry.id, tile.videoBounds))
        }
    }

    /// Who is on screen right now, for the caller's stream pruning.
    var visibleIDs: Set<UInt32> { Set(pageRoster.map(\.id)) }

    /// The self view, in its own render element so it never contends with the
    /// speaker window for one NSView.
    func attachSelfVideo(_ provider: @escaping (NSRect) -> NSView?) {
        lastSelfProvider = provider
        let host = selfPreview.videoHost
        guard !host.bounds.isEmpty else { return }
        guard let view = provider(host.bounds) else { return }
        if selfVideo !== view {
            selfVideo?.removeFromSuperview()
            view.autoresizingMask = [.width, .height]
            host.addSubview(view)
            selfVideo = view
        }
        view.frame = host.bounds
    }

    func detachAllVideo() {
        tiles.values.forEach { $0.detachVideo() }
        selfVideo?.removeFromSuperview()
        selfVideo = nil
        stageVideo?.removeFromSuperview()
        stageVideo = nil
        lastReleaseStage?()
        shareVideo?.removeFromSuperview()
        shareVideo = nil
        ParticipantGridWindowController.sdk?.shareViewer.releaseElement()
    }

    /// The students on the current page. Everything downstream - layout, video
    /// subscription, ring state - works from this rather than the whole roster,
    /// so a class of forty does not mean forty live video streams.
    var pageRoster: [ZoomMeetingSDKClient.RosterEntry] {
        let list = listed
        let start = page * perPage
        guard start < list.count else { return [] }
        return Array(list[start..<min(start + perPage, list.count)])
    }

    /// Puts your own picture at `rect` (in the grid host's space): in Gallery and
    /// Multi-speaker you are an ordinary tile of the grid or strip, placed last.
    private func placeSelf(_ rect: CGRect?) {
        guard let rect else { return }
        selfPreview.frame = rect.offsetBy(dx: gridHost.frame.minX, dy: gridHost.frame.minY)
        selfPreview.layoutSubtreeIfNeeded()
    }

    func layoutTiles() {
        if isMultiMode { layoutMultiSpeaker(); return }
        if isSpeakerMode { layoutFilmstrip(); return }
        let visible = pageRoster
        let lastPage = (page + 1) * perPage >= listed.count
        let withSelf = !hideSelfView && lastPage
        placeSelf(MeetingVideoLayout.galleryWithSelf(count: visible.count, includeSelf: withSelf,
                                                     in: gridHost.bounds.size).me)
        guard !visible.isEmpty else { return }
        // Zoom's gallery: an even grid of 16:9 tiles, 4pt apart, centred, you last.
        let frames = MeetingVideoLayout.galleryWithSelf(count: visible.count, includeSelf: withSelf,
                                                        in: gridHost.bounds.size).others
        let shape = (0, 0, visible.count)
        let animate = lastGridShape.count >= 0 && shape != lastGridShape
        lastGridShape = shape
        for (entry, target) in zip(visible, frames) {
            guard let tile = tiles[entry.id], tile.frame != target else { continue }
            if animate, !tile.frame.isEmpty {
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

    /// Multi-speaker: the recent speakers large in a row or grid, everyone else
    /// in a strip along the bottom, your preview at the strip's right end.
    private func layoutMultiSpeaker() {
        let visible = pageRoster
        let largeCount = visible.filter { plan.large.contains($0.id) }.count
        let frames = MeetingVideoLayout.multiSpeaker(largeCount: largeCount, stripCount: visible.count - largeCount,
                                                     in: gridHost.bounds.size, stripHeight: Self.stripHeight,
                                                     includeSelf: !hideSelfView)
        placeSelf(frames.me)
        guard !visible.isEmpty else { return }
        for (entry, target) in zip(visible, frames.large + frames.strip) {
            guard let tile = tiles[entry.id], tile.frame != target else { continue }
            if !tile.frame.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    tile.animator().frame = target
                }
            } else {
                tile.frame = target
            }
        }
    }

    /// Speaker view's filmstrip: one centred row under the stage.
    private func layoutFilmstrip() {
        let visible = pageRoster
        guard !visible.isEmpty else { return }
        // Zoom's strip, along the top of Speaker view. The corner preview owns
        // the strip's right end (the grid host stops short of it).
        let tileHeight = Self.stripHeight - 8
        let size = NSSize(width: gridHost.bounds.width, height: gridHost.bounds.height - 4)
        let frames = MeetingVideoLayout.strip(count: visible.count, in: size, tileHeight: tileHeight)
        for (entry, target) in zip(visible, frames) {
            guard let tile = tiles[entry.id], tile.frame != target else { continue }
            tile.frame = target
        }
    }

    /// The students-overflow carousel. Only drawn when there is a second page.
    func layoutPager(pages: Int, y: CGFloat, width: CGFloat) {
        let show = pages > 1
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
        do {
            // Zoom pages with a pair of arrows at the sides of the gallery.
            let area = gridHost.frame
            let size = NSSize(width: 30, height: 56)
            for button in [pagePrev, pageNext] {
                button?.isBordered = false
                button?.wantsLayer = true
                button?.layer?.cornerRadius = 8
                button?.contentTintColor = .white
                if let arrow = button as? MeetingBarButton {
                    arrow.restColor = MeetingTheme.capsuleNS
                    arrow.hoverColor = MeetingTheme.capsuleHoverNS
                }
            }
            pagePrev?.isEnabled = page > 0
            pageNext?.isEnabled = page < pages - 1
            // An arrow with nowhere to go loses its capsule and fades.
            for button in [pagePrev, pageNext] { button?.alphaValue = button?.isEnabled == true ? 1 : 0.35 }
            pagePrev?.frame = NSRect(x: area.minX + 6, y: area.midY - size.height / 2, width: size.width, height: size.height)
            pageNext?.frame = NSRect(x: area.maxX - 6 - size.width, y: area.midY - size.height / 2,
                                     width: size.width, height: size.height)
            pagePrev?.toolTip = "Previous page"
            pageNext?.toolTip = "Next page"
        }
    }

    private var pageCount: Int? {
        listed.isEmpty ? nil : max(1, Int(ceil(Double(listed.count) / Double(perPage))))
    }

    /// A page change swaps which students are on screen, so tiles, video
    /// subscriptions and layout all have to follow immediately rather than
    /// waiting for the next poll.
    private func pageChanged() {
        selected = nil
        lastBarSignature = barSignature()
        rebuildContextBar()
        layoutEverything()
        if let provider = lastVideoProvider { attachVideo(provider) }
        if let provider = lastSelfProvider { attachSelfVideo(provider) }
    }
}
