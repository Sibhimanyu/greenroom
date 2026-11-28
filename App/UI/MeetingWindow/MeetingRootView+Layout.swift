//
//  MeetingRootView+Layout.swift
//  Greenroom
//
//  The one layout pass: every frame in the window is set here.
//
import AppKit
import SwiftUI
import Combine

@MainActor
extension MeetingRootView {

    func layoutEverything() {
        let width = bounds.width, height = bounds.height
        let barHeight = MeetingTheme.topBarHeight, toolbarHeight = MeetingToolbarView.height
        let panel = controls?.sidePanel
        let chrome = !hoverChrome || chromeHover || panel != nil

        meetingTopBar.isHidden = !chrome
        bottomBar.isHidden = !chrome
        // The window's frost is the toolbar's background. Only the slot form,
        // where the toolbar lies over live video, keeps a blur to read against.
        bottomBar.showsBlur = hoverChrome
        meetingTopBar.frame = NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
        meetingTopBar.needsLayout = true   // re-lifts its tip above tiles added since
        bottomBar.frame = NSRect(x: 0, y: 0, width: width, height: toolbarHeight)

        // The slot form has no room for permanent chrome, so it lies over the
        // video; the full form gives the stage what is left between the bars.
        let reserveTop = hoverChrome ? 0 : barHeight
        let reserveBottom = hoverChrome ? 0 : toolbarHeight
        let panelWidth = panel == nil ? 0 : min(Self.sidePanelWidth, width)
        // Below narrowWidth the panel covers the stage's right edge instead of
        // taking a column off it, and the stage keeps its full width.
        let overlay = isNarrow
        let stageRight = (panel != nil && !overlay) ? width - panelWidth : width
        let clearRight = panel != nil ? width - panelWidth : width      // left of the panel
        let stage = NSRect(x: 0, y: reserveBottom, width: stageRight,
                           height: max(0, height - reserveTop - reserveBottom))

        sidePanelHost.isHidden = panel == nil
        if let panel {
            sidePanelHost.frame = NSRect(x: width - panelWidth, y: reserveBottom,
                                         width: panelWidth, height: stage.height)
            layoutSidePanel(panel)
        }

        // Beside a share, the chosen view lives in the right part of the stage.
        let side = shareBeside ? MeetingSplit.regions(stage: stage, fraction: splitFraction) : nil
        lastSideStage = stage
        shareHost.isHidden = side == nil
        splitDivider.isHidden = side == nil
        if let side {
            shareHost.frame = side.share
            shareChrome.frame = shareHost.bounds
            splitDivider.frame = side.divider
        }
        let area = side?.video ?? stage

        let others = !listed.isEmpty
        let pages = max(1, Int(ceil(Double(listed.count) / Double(perPage))))
        // Paging is two arrows at the sides (layoutPager), not a band.
        let pagerHeight: CGFloat = 0

        // You, in the corner, over the grid: laid out after it and never part of
        // its arithmetic. "Hide self view" only hides this picture, here.
        let stripTile = Self.stripHeight - 8
        // In Speaker view you are one of the strip's small tiles, at its right
        // end; in Multi-speaker the strip's too; in Gallery you are the corner picture.
        let inStrip = !hideSelfView && ((isSpeakerMode && others) || (isMultiMode && !plan.rest.isEmpty))
        let preview = inStrip ? NSSize(width: (stripTile * 16 / 9).rounded(), height: stripTile) : Self.selfPreviewSize
        let areaRight = min(area.maxX, clearRight)
        selfPreview.isHidden = hideSelfView
        if isMultiMode, inStrip {
            selfPreview.frame = NSRect(x: areaRight - MeetingTheme.tileGap - preview.width, y: area.minY + MeetingTheme.tileGap,
                                       width: preview.width, height: preview.height)
        } else {
            selfPreview.frame = inStrip
                ? NSRect(x: areaRight - preview.width - 4, y: area.maxY - 4 - preview.height,
                         width: preview.width, height: preview.height)
                : NSRect(x: areaRight - preview.width - 12,
                         y: area.minY + 12 + pagerHeight, width: preview.width, height: preview.height)
        }
        // Its video host is sized in its own layout pass; the self element is
        // attached later in this same update and needs real bounds.
        selfPreview.layoutSubtreeIfNeeded()

        if isSpeakerMode {
            // Zoom puts the strip of small tiles along the TOP in Speaker view.
            let strip: CGFloat = others ? Self.stripHeight : 0
            gridHost.layer?.backgroundColor = NSColor.clear.cgColor
            // The preview owns the strip's right-hand end.
            gridHost.frame = NSRect(x: area.minX, y: area.maxY - strip,
                                    width: max(0, areaRight - area.minX - (inStrip ? preview.width + 8 : 0)),
                                    height: strip)
            stageHost.isHidden = (roster.isEmpty || plan.everyoneHidden) && !shareOnStage && !selfCardShown
            stageHost.frame = NSRect(x: area.minX + 4, y: area.minY + 4,
                                     width: max(0, area.width - 8), height: max(0, area.height - strip - 8))
            stageChrome.frame = stageHost.bounds
            selfShareCard.isHidden = !selfCardShown
            if selfCardShown {
                let card = SelfShareCardView.size
                selfShareCard.frame = NSRect(x: (stageHost.bounds.width - card.width) / 2,
                                             y: (stageHost.bounds.height - card.height) / 2,
                                             width: card.width, height: card.height)
            }
            layoutPager(pages: 1, y: area.minY, width: area.width)
        } else if isMultiMode {
            gridHost.layer?.backgroundColor = NSColor.clear.cgColor
            stageHost.isHidden = true
            gridHost.frame = NSRect(x: area.minX + MeetingTheme.tileGap, y: area.minY + MeetingTheme.tileGap,
                                    width: max(0, areaRight - area.minX - MeetingTheme.tileGap * 2),
                                    height: max(0, area.height - MeetingTheme.tileGap * 2))
            layoutPager(pages: 1, y: area.minY, width: area.width)
        } else {
            gridHost.layer?.backgroundColor = NSColor.clear.cgColor
            stageHost.isHidden = true
            // 4pt all round, so the gaps between tiles and the window's edge agree.
            gridHost.frame = area.insetBy(dx: MeetingTheme.tileGap, dy: MeetingTheme.tileGap)
            layoutPager(pages: pages, y: area.minY, width: area.width)
        }

        if !isSpeakerMode { selfShareCard.isHidden = true }
        let shareArea = side?.share ?? NSRect(x: stage.minX, y: stage.minY,
                                              width: min(stage.maxX, clearRight) - stage.minX, height: stage.height)
        layoutShareChip(in: shareArea)
        emptyState.isHidden = !(roster.isEmpty || plan.everyoneHidden) || shareOnStage || selfCardShown
        emptyState.frame = NSRect(x: area.minX + 40, y: area.midY - 40,
                                  width: max(80, areaRight - area.minX - 80), height: 80)

        inspector.isHidden = selected == nil
        updateEscapeMonitor(active: selected != nil)
        if selected != nil {
            let drawer = min(inspector.height(), stage.height - 32)
            inspector.frame = NSRect(x: clearRight - ParticipantInspectorView.width - 16,
                                     y: stage.maxY - drawer - 16,
                                     width: ParticipantInspectorView.width, height: drawer)
        }

        layoutMeetingTopBar()
        layoutTiles()
    }
}
