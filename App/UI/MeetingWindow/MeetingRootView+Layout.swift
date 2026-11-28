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
        // Below narrowWidth the panel covers the stage's right edge instead of
        // taking a column off it, and the stage keeps its full width.
        let regions = MeetingWindowLayout.regions(size: bounds.size, topBar: barHeight, toolbar: toolbarHeight,
                                                  slotForm: hoverChrome, panelOpen: panel != nil)
        let stage = regions.stage
        let clearRight = regions.clearRight      // left of the panel

        sidePanelHost.isHidden = panel == nil
        if let panel, let panelFrame = regions.panel {
            sidePanelHost.frame = panelFrame
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
        let pages = MeetingWindowLayout.pageCount(listed: listed.count, perPage: perPage)
        // Paging is two arrows at the sides (layoutPager), not a band.

        // You, in the corner, over the grid: laid out after it and never part of
        // its arithmetic. "Hide self view" only hides this picture, here.
        // In Speaker view you are one of the strip's small tiles, at its right
        // end; in Multi-speaker the strip's too; in Gallery you are the corner picture.
        let mode = layoutMode
        let inStrip = MeetingWindowLayout.selfInStrip(mode: mode, hidesSelf: hideSelfView, hasOthers: others,
                                                      hasRest: !plan.rest.isEmpty)
        let areaRight = MeetingWindowLayout.areaRight(area: area, clearRight: clearRight)
        selfPreview.isHidden = hideSelfView
        selfPreview.frame = MeetingWindowLayout.selfPreviewFrame(area: area, areaRight: areaRight, mode: mode,
                                                                 inStrip: inStrip, stripHeight: Self.stripHeight,
                                                                 tileGap: MeetingTheme.tileGap)
        // Its video host is sized in its own layout pass; the self element is
        // attached later in this same update and needs real bounds.
        selfPreview.layoutSubtreeIfNeeded()

        if isSpeakerMode {
            // Zoom puts the strip of small tiles along the TOP in Speaker view.
            gridHost.layer?.backgroundColor = NSColor.clear.cgColor
            // The preview owns the strip's right-hand end.
            gridHost.frame = MeetingWindowLayout.gridHostFrame(area: area, areaRight: areaRight, mode: mode,
                                                               hasOthers: others, inStrip: inStrip,
                                                               stripHeight: Self.stripHeight, tileGap: MeetingTheme.tileGap)
            stageHost.isHidden = (roster.isEmpty || plan.everyoneHidden) && !shareOnStage && !selfCardShown
            stageHost.frame = MeetingWindowLayout.stageHostFrame(area: area, hasOthers: others, stripHeight: Self.stripHeight)
            stageChrome.frame = stageHost.bounds
            selfShareCard.isHidden = !selfCardShown
            if selfCardShown {
                selfShareCard.frame = MeetingWindowLayout.shareCardFrame(in: stageHost.bounds.size,
                                                                         card: SelfShareCardView.size)
            }
            layoutPager(pages: 1, y: area.minY, width: area.width)
        } else if isMultiMode {
            gridHost.layer?.backgroundColor = NSColor.clear.cgColor
            stageHost.isHidden = true
            gridHost.frame = MeetingWindowLayout.gridHostFrame(area: area, areaRight: areaRight, mode: mode,
                                                               hasOthers: others, inStrip: inStrip,
                                                               stripHeight: Self.stripHeight, tileGap: MeetingTheme.tileGap)
            layoutPager(pages: 1, y: area.minY, width: area.width)
        } else {
            gridHost.layer?.backgroundColor = NSColor.clear.cgColor
            stageHost.isHidden = true
            // 4pt all round, so the gaps between tiles and the window's edge agree.
            gridHost.frame = MeetingWindowLayout.gridHostFrame(area: area, areaRight: areaRight, mode: mode,
                                                               hasOthers: others, inStrip: inStrip,
                                                               stripHeight: Self.stripHeight, tileGap: MeetingTheme.tileGap)
            layoutPager(pages: pages, y: area.minY, width: area.width)
        }

        if !isSpeakerMode { selfShareCard.isHidden = true }
        let shareArea = side?.share ?? MeetingWindowLayout.shareArea(stage: stage, clearRight: clearRight)
        layoutShareChip(in: shareArea)
        emptyState.isHidden = !(roster.isEmpty || plan.everyoneHidden) || shareOnStage || selfCardShown
        emptyState.frame = MeetingWindowLayout.emptyNoteFrame(area: area, areaRight: areaRight)

        inspector.isHidden = selected == nil
        updateEscapeMonitor(active: selected != nil)
        if selected != nil {
            inspector.frame = MeetingWindowLayout.inspectorFrame(stage: stage, clearRight: clearRight,
                                                                 width: ParticipantInspectorView.width,
                                                                 wantedHeight: inspector.height())
        }

        layoutMeetingTopBar()
        layoutTiles()
    }
}
