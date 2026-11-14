//
//  MeetingViewRules.swift
//  Greenroom
//
//  The meeting window's video layouts as pure values: which view modes there
//  are, the share layouts (Standard, or the share beside a view), the draggable
//  split, the two tile filters, who gets a tile where, and the arithmetic that
//  turns that into rectangles. No SDK and no views, so GreenroomTests can test
//  all of it and the off-screen render draws the same rectangles the window does.
//
//  Zoom's SDK gives us video elements, not layouts: every one of these is ours.
//
import Foundation

// MARK: - Modes

/// What the video area shows. The raw value is what a Mac remembers.
enum MeetingViewMode: String, CaseIterable {
    case speaker, gallery, multiSpeaker

    /// The order of the View menu and of the segmented control.
    static let menuOrder: [MeetingViewMode] = [.speaker, .gallery, .multiSpeaker]

    var title: String {
        switch self {
        case .speaker: return "Speaker"
        case .gallery: return "Gallery"
        case .multiSpeaker: return "Multi-speaker"
        }
    }

    var segmentIndex: Int { Self.menuOrder.firstIndex(of: self) ?? 0 }

    init(segment: Int) {
        self = Self.menuOrder.indices.contains(segment) ? Self.menuOrder[segment] : .gallery
    }

    /// The Cycle meeting view shortcut: Speaker, Gallery, Multi-speaker, round.
    /// Multi-speaker is skipped when it would only show Speaker again (fewer
    /// than three people), so a key press never looks like it did nothing.
    func next(multiSpeakerAvailable: Bool = true) -> MeetingViewMode {
        let order = Self.menuOrder
        let following = order[(segmentIndex + 1) % order.count]
        if following == .multiSpeaker, !multiSpeakerAvailable { return order[(segmentIndex + 2) % order.count] }
        return following
    }
}

/// How a share sits in the window. Standard is the share filling the stage with
/// the people in a filmstrip; the others put it on the left of a video layout.
enum MeetingShareLayout: String, CaseIterable {
    case standard, sideBySideSpeaker, sideBySideGallery, sideBySideMulti

    var sideMode: MeetingViewMode? {
        switch self {
        case .standard: return nil
        case .sideBySideSpeaker: return .speaker
        case .sideBySideGallery: return .gallery
        case .sideBySideMulti: return .multiSpeaker
        }
    }

    var isSideBySide: Bool { sideMode != nil }

    static func sideBySide(_ mode: MeetingViewMode) -> MeetingShareLayout {
        switch mode {
        case .speaker: return .sideBySideSpeaker
        case .gallery: return .sideBySideGallery
        case .multiSpeaker: return .sideBySideMulti
        }
    }

    var menuTitle: String {
        guard let mode = sideMode else { return "Standard" }
        return "Side-by-side: \(mode.title)"
    }
}

// MARK: - The split

/// The share's share of the width in a side-by-side layout.
enum MeetingSplit {
    static let defaultFraction = 0.70
    static let minimum = 0.50
    static let maximum = 0.85

    static func clamp(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return defaultFraction }
        return min(maximum, max(minimum, fraction))
    }

    /// Where the pointer is, as a fraction of the stage, clamped.
    static func fraction(forBoundaryX x: CGFloat, in stage: CGRect) -> Double {
        guard stage.width > 0 else { return defaultFraction }
        return clamp(Double((x - stage.minX) / stage.width))
    }

    struct Regions: Equatable {
        /// Where the share is drawn.
        var share: CGRect
        /// The strip the pointer grabs, centred on the boundary.
        var divider: CGRect
        /// What is left for the chosen layout. Its edges carry the same 4 pt the
        /// layouts inset themselves by, less half the gap, so the two panes end up
        /// `gap` apart.
        var video: CGRect
    }

    static func regions(stage: CGRect, fraction: Double, inset: CGFloat = 4, gap: CGFloat = 4,
                        grab: CGFloat = 12) -> Regions {
        let boundary = stage.minX + (stage.width * CGFloat(clamp(fraction))).rounded()
        let shareRight = boundary - gap / 2
        let videoLeft = boundary - inset + gap / 2
        return Regions(
            share: CGRect(x: stage.minX + inset, y: stage.minY + inset,
                          width: max(0, shareRight - stage.minX - inset), height: max(0, stage.height - inset * 2)),
            divider: CGRect(x: boundary - grab / 2, y: stage.minY + inset, width: grab, height: max(0, stage.height - inset * 2)),
            video: CGRect(x: videoLeft, y: stage.minY, width: max(0, stage.maxX - videoLeft), height: stage.height))
    }
}

// MARK: - What a Mac remembers

/// The choices that belong to the Mac, not to a meeting. The defaults are
/// injectable so a test never touches the real ones.
struct MeetingViewPrefs {
    var defaults: UserDefaults = .standard

    static let viewKey = "meetingWindow.view"
    static let shareLayoutKey = "meetingWindow.shareLayout"
    static let splitKey = "meetingWindow.shareSplit"
    static let hideSelfKey = "meetingWindow.hideSelfView"
    static let hideNoVideoKey = "meetingWindow.hideVideoOff"

    var view: MeetingViewMode {
        get { MeetingViewMode(rawValue: defaults.string(forKey: Self.viewKey) ?? "") ?? .gallery }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.viewKey) }
    }

    var shareLayout: MeetingShareLayout {
        get { MeetingShareLayout(rawValue: defaults.string(forKey: Self.shareLayoutKey) ?? "") ?? .standard }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.shareLayoutKey) }
    }

    var splitFraction: Double {
        get {
            guard defaults.object(forKey: Self.splitKey) != nil else { return MeetingSplit.defaultFraction }
            return MeetingSplit.clamp(defaults.double(forKey: Self.splitKey))
        }
        nonmutating set { defaults.set(MeetingSplit.clamp(newValue), forKey: Self.splitKey) }
    }

    var hideSelfView: Bool {
        get { defaults.bool(forKey: Self.hideSelfKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.hideSelfKey) }
    }

    var hideNoVideo: Bool {
        get { defaults.bool(forKey: Self.hideNoVideoKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.hideNoVideoKey) }
    }
}

// MARK: - Filters and the tile plan

struct MeetingTileCandidate: Equatable {
    var id: UInt32
    var videoOn: Bool
}

enum MeetingTileFilter {
    static let emptyNote = "Everyone else has video off"

    /// "Hide participants with video off". Order is kept.
    static func apply(_ others: [MeetingTileCandidate], hideNoVideo: Bool) -> [MeetingTileCandidate] {
        hideNoVideo ? others.filter(\.videoOn) : others
    }
}

/// Who gets a tile, and where, for one moment. `others` is everyone but you:
/// you are the corner preview (or a filmstrip tile), which the window hides
/// separately for "Hide self view".
struct MeetingTilePlan: Equatable {
    /// The layout actually drawn. Multi-speaker becomes Speaker with fewer than
    /// three people in the meeting, as Zoom's own does.
    var mode: MeetingViewMode = .gallery
    /// Speaker: who is on the big stage.
    var stage: UInt32?
    /// Multi-speaker: the large tiles, in their places.
    var large: [UInt32] = []
    /// Gallery: everyone. Speaker and Multi-speaker: the filmstrip.
    var rest: [UInt32] = []
    /// There are other people, but "Hide participants with video off" hid them all.
    var everyoneHidden = false

    static let empty = MeetingTilePlan()

    /// Everyone who has a tile, large ones first.
    var listed: [UInt32] { large + rest }

    static let multiSpeakerMinimumPeople = 3
    static let multiSpeakerLargeRange = 2...4

    /// `stageChoice`: the person the stage would show (spotlight, pin, the active
    /// speaker). `recentSpeakers`: the Multi-speaker tracker's places, in place
    /// order. `shareOnStage`: a share fills the stage, so nobody is on it.
    static func make(others: [MeetingTileCandidate], mode requested: MeetingViewMode, hideNoVideo: Bool,
                     stageChoice: UInt32?, recentSpeakers: [UInt32], shareOnStage: Bool) -> MeetingTilePlan {
        let visible = MeetingTileFilter.apply(others, hideNoVideo: hideNoVideo).map(\.id)
        var plan = MeetingTilePlan()
        plan.everyoneHidden = hideNoVideo && !others.isEmpty && visible.isEmpty
        let people = others.count + 1
        plan.mode = requested == .multiSpeaker && people < multiSpeakerMinimumPeople ? .speaker : requested

        switch plan.mode {
        case .gallery:
            plan.rest = visible
        case .speaker:
            if shareOnStage {
                plan.rest = visible
            } else {
                // The stage person, unless the filter hid them, then the first who shows.
                if let choice = stageChoice {
                    plan.stage = visible.contains(choice) ? choice : visible.first
                }
                plan.rest = visible.filter { $0 != plan.stage }
            }
        case .multiSpeaker:
            plan.large = multiSpeakerSelection(recent: recentSpeakers, visible: visible)
            plan.rest = visible.filter { !plan.large.contains($0) }
        }
        return plan
    }

    /// The large tiles: the recent speakers who are still shown, topped up to two
    /// with whoever is next in the list so there is never a lone big tile, and
    /// never more than four.
    static func multiSpeakerSelection(recent: [UInt32], visible: [UInt32]) -> [UInt32] {
        var chosen: [UInt32] = []
        for id in recent where visible.contains(id) && !chosen.contains(id) && chosen.count < multiSpeakerLargeRange.upperBound {
            chosen.append(id)
        }
        let want = min(visible.count, max(multiSpeakerLargeRange.lowerBound, chosen.count))
        for id in visible where chosen.count < want && !chosen.contains(id) { chosen.append(id) }
        return chosen
    }
}

// MARK: - Rectangles

/// Where tiles go. AppKit coordinates (origin bottom left); index 0 is the top
/// left. Pure, so the render and the window share it.
enum MeetingVideoLayout {
    /// MeetingTheme.tileGap; the same number, kept here so this file has no
    /// dependency on AppKit.
    static let defaultGap: CGFloat = 4

    /// The grid that gives 16:9 tiles the most area. Tiles are 16:9 like the
    /// pictures they hold, packed with `gap` between them and centred in `size`,
    /// the last row centred too.
    static func gallery(count: Int, in size: CGSize, gap: CGFloat = defaultGap) -> [CGRect] {
        guard count > 0, size.width > 0, size.height > 0 else { return [] }
        var best: (cols: Int, rows: Int, w: CGFloat, h: CGFloat) = (1, count, 0, 0)
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let maxW = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let maxH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            guard maxW > 0, maxH > 0 else { continue }
            let w = min(maxW, maxH * 16 / 9), h = w * 9 / 16
            if w * h > best.w * best.h { best = (cols, rows, w, h) }
        }
        let gridHeight = CGFloat(best.rows) * best.h + CGFloat(best.rows - 1) * gap
        let top = (size.height + gridHeight) / 2
        var out: [CGRect] = []
        for index in 0..<count {
            let row = index / best.cols, column = index % best.cols
            let inRow = min(best.cols, count - row * best.cols)
            let rowWidth = CGFloat(inRow) * best.w + CGFloat(inRow - 1) * gap
            let x = (size.width - rowWidth) / 2 + CGFloat(column) * (best.w + gap)
            let y = top - CGFloat(row + 1) * best.h - CGFloat(row) * gap
            out.append(CGRect(x: x.rounded(), y: y.rounded(), width: best.w.rounded(), height: best.h.rounded()))
        }
        return out
    }

    /// Speaker view's strip: one row of 16:9 tiles along the top of `size`,
    /// centred, leaving `reservedRight` free at the right end.
    static func strip(count: Int, in size: CGSize, tileHeight: CGFloat, reservedRight: CGFloat = 0,
                      gap: CGFloat = defaultGap) -> [CGRect] {
        guard count > 0 else { return [] }
        let width = (tileHeight * 16 / 9).rounded()
        let total = CGFloat(count) * width + CGFloat(count - 1) * gap
        let room = max(0, size.width - reservedRight)
        let start = max(0, ((room - total) / 2).rounded())
        return (0..<count).map { index in
            CGRect(x: start + CGFloat(index) * (width + gap), y: size.height - tileHeight, width: width, height: tileHeight)
        }
    }

    /// How many strip tiles fit in `width`.
    static func stripCapacity(width: CGFloat, tileHeight: CGFloat, gap: CGFloat = defaultGap) -> Int {
        let tile = (tileHeight * 16 / 9).rounded() + gap
        return min(8, max(1, Int((width + gap) / tile)))
    }

    /// Multi-speaker: the large tiles as a gallery in the upper area, a strip of
    /// small ones along the bottom. `stripHeight` is MeetingTheme.stripHeight (the
    /// tile and its margins); `reservedStripRight` leaves the strip's right end
    /// to your own preview.
    static func multiSpeaker(largeCount: Int, stripCount: Int, in size: CGSize, stripHeight: CGFloat,
                             reservedStripRight: CGFloat = 0, gap: CGFloat = defaultGap)
        -> (large: [CGRect], strip: [CGRect]) {
        let tileHeight = stripHeight - 8
        let band: CGFloat = stripCount > 0 ? tileHeight + gap : 0
        let upper = CGSize(width: size.width, height: max(0, size.height - band))
        let large = gallery(count: largeCount, in: upper, gap: gap).map { $0.offsetBy(dx: 0, dy: band) }
        let strip = self.strip(count: stripCount, in: CGSize(width: size.width, height: tileHeight), tileHeight: tileHeight,
                               reservedRight: reservedStripRight, gap: gap)
        return (large, strip)
    }
}
