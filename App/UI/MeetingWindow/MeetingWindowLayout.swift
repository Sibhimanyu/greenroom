//
//  MeetingWindowLayout.swift
//  Greenroom
//
//  The Meeting window's own arithmetic, with no views: how many people a page
//  holds, where the stage area, side panel, your preview, the grid host, the
//  drawer and the arrows go. MeetingRootView asks this and only applies the
//  rectangles. Tile rectangles (gallery, strip, split) are MeetingVideoLayout and
//  MeetingSplit. Behaviour as recorded in docs/specs/meeting-window-layout.md,
//  quirks included. AppKit coordinates: origin bottom left.
//
import CoreGraphics
import Foundation

enum MeetingWindowLayout {
    /// The three views as the layout sees them.
    enum Mode: Equatable { case gallery, speaker, multiSpeaker }

    /// Below this the side panel overlays the stage instead of taking a column.
    static let narrowWidth: CGFloat = 900
    /// DESIGN.md's drawer range is 280-320pt; the side panel takes the top.
    static let sidePanelWidth: CGFloat = 320
    /// Your preview as a corner picture.
    static let selfPreviewSize = CGSize(width: 192, height: 108)

    static func isNarrow(width: CGFloat) -> Bool { width < narrowWidth }

    // MARK: Pages

    /// People per page in Gallery, from the grid's real size, in a few steps so a
    /// page does not change by one on every few pixels of resize.
    static func galleryPageSize(width: CGFloat, height: CGFloat) -> Int {
        guard width > 0, height > 0 else { return 9 }
        // ~260x150 is the smallest tile a face and a name label stay legible in.
        let fits = Int(width / 260) * Int(height / 150)
        switch fits {
        case ..<2: return 1
        case ..<4: return 2
        case ..<6: return 4
        case ..<9: return 6
        case ..<12: return 9
        default: return 12
        }
    }

    static func pageSize(mode: Mode, galleryWidth: CGFloat, galleryHeight: CGFloat,
                         stripCapacity: Int, largeCount: Int) -> Int {
        switch mode {
        case .speaker: return stripCapacity
        case .multiSpeaker: return max(1, largeCount) + stripCapacity
        case .gallery: return galleryPageSize(width: galleryWidth, height: galleryHeight)
        }
    }

    /// How many small tiles the strip holds, after leaving `reservedRight` free.
    static func stripCapacity(gridWidth: CGFloat, stripHeight: CGFloat, reservedRight: CGFloat) -> Int {
        MeetingVideoLayout.stripCapacity(width: max(0, gridWidth - reservedRight), tileHeight: stripHeight - 8)
    }

    /// Multi-speaker's strip leaves its right end to your preview.
    static func reservedRight(mode: Mode, stripHeight: CGFloat, hidesSelf: Bool) -> CGFloat {
        guard mode == .multiSpeaker, !hidesSelf else { return 0 }
        return stripSelfSize(stripHeight: stripHeight).width + 8
    }

    /// Your preview as one of the strip's tiles: 16:9 at the tile height.
    static func stripSelfSize(stripHeight: CGFloat) -> CGSize {
        let tile = stripHeight - 8
        return CGSize(width: (tile * 16 / 9).rounded(), height: tile)
    }

    static func pageCount(listed: Int, perPage: Int) -> Int {
        max(1, Int(ceil(Double(listed) / Double(perPage))))
    }

    static func pageRange(page: Int, perPage: Int, listed: Int) -> Range<Int> {
        let start = page * perPage
        guard start < listed else { return 0..<0 }
        return start..<min(start + perPage, listed)
    }

    static func isLastPage(page: Int, perPage: Int, listed: Int) -> Bool {
        (page + 1) * perPage >= listed
    }

    // MARK: Regions

    struct Regions: Equatable {
        /// What is left between the bars, without the panel's column when it takes one.
        var stage: CGRect
        var panel: CGRect?
        /// Where the panel's left edge is, or the window's width with no panel.
        var clearRight: CGFloat
    }

    static func regions(size: CGSize, topBar: CGFloat, toolbar: CGFloat, slotForm: Bool, panelOpen: Bool) -> Regions {
        let width = size.width, height = size.height
        let reserveTop = slotForm ? 0 : topBar
        let reserveBottom = slotForm ? 0 : toolbar
        let panelWidth = panelOpen ? min(sidePanelWidth, width) : 0
        let stageRight = (panelOpen && !isNarrow(width: width)) ? width - panelWidth : width
        let clearRight = panelOpen ? width - panelWidth : width
        let stage = CGRect(x: 0, y: reserveBottom, width: stageRight,
                           height: max(0, height - reserveTop - reserveBottom))
        let panel = panelOpen
            ? CGRect(x: width - panelWidth, y: reserveBottom, width: panelWidth, height: stage.height) : nil
        return Regions(stage: stage, panel: panel, clearRight: clearRight)
    }

    // MARK: Your preview, the grid host and the stage

    static func areaRight(area: CGRect, clearRight: CGFloat) -> CGFloat { min(area.maxX, clearRight) }

    static func selfInStrip(mode: Mode, hidesSelf: Bool, hasOthers: Bool, hasRest: Bool) -> Bool {
        !hidesSelf && ((mode == .speaker && hasOthers) || (mode == .multiSpeaker && hasRest))
    }

    static func selfPreviewFrame(area: CGRect, areaRight: CGFloat, mode: Mode, inStrip: Bool,
                                 stripHeight: CGFloat, tileGap: CGFloat) -> CGRect {
        let size = inStrip ? stripSelfSize(stripHeight: stripHeight) : selfPreviewSize
        if mode == .multiSpeaker, inStrip {
            return CGRect(x: areaRight - tileGap - size.width, y: area.minY + tileGap, width: size.width, height: size.height)
        }
        return inStrip
            ? CGRect(x: areaRight - size.width - 4, y: area.maxY - 4 - size.height, width: size.width, height: size.height)
            : CGRect(x: areaRight - size.width - 12, y: area.minY + 12, width: size.width, height: size.height)
    }

    static func gridHostFrame(area: CGRect, areaRight: CGFloat, mode: Mode, hasOthers: Bool, inStrip: Bool,
                              stripHeight: CGFloat, tileGap: CGFloat) -> CGRect {
        switch mode {
        case .speaker:
            // Zoom puts the strip of small tiles along the TOP in Speaker view.
            let strip: CGFloat = hasOthers ? stripHeight : 0
            let preview = stripSelfSize(stripHeight: stripHeight).width
            return CGRect(x: area.minX, y: area.maxY - strip,
                          width: max(0, areaRight - area.minX - (inStrip ? preview + 8 : 0)), height: strip)
        case .multiSpeaker:
            return CGRect(x: area.minX + tileGap, y: area.minY + tileGap,
                          width: max(0, areaRight - area.minX - tileGap * 2),
                          height: max(0, area.height - tileGap * 2))
        case .gallery:
            return area.insetBy(dx: tileGap, dy: tileGap)
        }
    }

    /// Speaker's stage. Quirk: it ignores the right limit, so in a narrow window it
    /// runs under the side panel.
    static func stageHostFrame(area: CGRect, hasOthers: Bool, stripHeight: CGFloat) -> CGRect {
        let strip: CGFloat = hasOthers ? stripHeight : 0
        return CGRect(x: area.minX + 4, y: area.minY + 4,
                      width: max(0, area.width - 8), height: max(0, area.height - strip - 8))
    }

    static func emptyNoteFrame(area: CGRect, areaRight: CGFloat) -> CGRect {
        CGRect(x: area.minX + 40, y: area.midY - 40, width: max(80, areaRight - area.minX - 80), height: 80)
    }

    // MARK: Shares, drawer, arrows

    static func shareCardFrame(in bounds: CGSize, card: CGSize) -> CGRect {
        CGRect(x: (bounds.width - card.width) / 2, y: (bounds.height - card.height) / 2,
               width: card.width, height: card.height)
    }

    /// Quirk: for a stage under 24 wide the width goes negative.
    static func shareChipFrame(in stage: CGRect, textWidth: CGFloat) -> CGRect {
        let width = min(stage.width - 24, textWidth + 24)
        return CGRect(x: stage.midX - width / 2, y: stage.maxY - 12 - 26, width: width, height: 26)
    }

    /// With no share beside, the share area is the stage up to the panel.
    static func shareArea(stage: CGRect, clearRight: CGFloat) -> CGRect {
        CGRect(x: stage.minX, y: stage.minY, width: min(stage.maxX, clearRight) - stage.minX, height: stage.height)
    }

    /// Quirk: for a stage under 32 high the height goes negative.
    static func inspectorFrame(stage: CGRect, clearRight: CGFloat, width: CGFloat, wantedHeight: CGFloat) -> CGRect {
        let drawer = min(wantedHeight, stage.height - 32)
        return CGRect(x: clearRight - width - 16, y: stage.maxY - drawer - 16, width: width, height: drawer)
    }

    static func pagerArrows(in grid: CGRect) -> (previous: CGRect, next: CGRect) {
        let size = CGSize(width: 30, height: 56)
        return (CGRect(x: grid.minX + 6, y: grid.midY - size.height / 2, width: size.width, height: size.height),
                CGRect(x: grid.maxX - 6 - size.width, y: grid.midY - size.height / 2,
                       width: size.width, height: size.height))
    }

    // MARK: Side panel

    static let sidePanelHead: CGFloat = 44

    struct SidePanelParts: Equatable {
        var body: CGRect
        var divider: CGRect
        var close: CGRect
        var title: CGRect
    }

    static func sidePanelParts(size: CGSize, titleSize: CGSize) -> SidePanelParts {
        let width = size.width, height = size.height, head = sidePanelHead
        return SidePanelParts(
            body: CGRect(x: 0, y: 0, width: width, height: max(0, height - head)),
            divider: CGRect(x: 0, y: 0, width: 1, height: height),
            close: CGRect(x: width - 36, y: height - head + 10, width: 24, height: 24),
            title: CGRect(x: 16, y: height - head + (head - titleSize.height) / 2,
                          width: min(titleSize.width, max(0, width - 64)), height: titleSize.height))
    }

    /// The needs block and Cues take what they want, up to 45% of the body.
    static func queueHeight(wanted: CGFloat, bodyHeight: CGFloat) -> CGFloat {
        wanted == 0 ? 0 : min(wanted, (bodyHeight * 0.45).rounded())
    }

    static func peopleSplit(bodyHeight: CGFloat, width: CGFloat, queueHeight: CGFloat) -> (queue: CGRect, roster: CGRect) {
        (CGRect(x: 0, y: bodyHeight - queueHeight, width: width, height: queueHeight),
         CGRect(x: 0, y: 0, width: width, height: max(0, bodyHeight - queueHeight)))
    }
}
