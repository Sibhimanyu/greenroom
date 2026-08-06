//
//  WorkspaceLayout.swift
//  Greenroom
//
//  The whole session's window arrangement, as one value: a main app pane
//  occupying a horizontal slice of the screen, and a side column (the
//  remainder) holding the Zoom meeting tile stacked over the chat window.
//  Generalizes what used to be ChromeWindowManager.Layout (a fixed
//  three-case enum) - the span/remainderSpan math is moved here verbatim.
//
import AppKit

struct WorkspaceLayout: Codable, Equatable {

    /// How much of the screen's width the main pane takes.
    enum Split: String, Codable, CaseIterable, Identifiable {
        case half, twoThirds, threeQuarters

        var id: String { rawValue }

        var fraction: Double {
            switch self {
            case .half: return 0.5
            case .twoThirds: return 2.0 / 3.0
            case .threeQuarters: return 0.75
            }
        }

        var glyph: String {
            switch self {
            case .half: return "\u{00BD}"
            case .twoThirds: return "\u{2154}"
            case .threeQuarters: return "\u{00BE}"
            }
        }
    }

    var split: Split
    var mainOnLeft: Bool
    /// What occupies the side column. Both on: Zoom tile stacked over the
    /// chat. One off: the other takes the full column. Both off: the
    /// column is left free.
    var sideShowsZoomTile: Bool
    var sideShowsChat: Bool
    /// Fraction of the side column's height for the Zoom tile, chat below
    /// taking the rest - only meaningful when both occupants are on. The
    /// 0.4 default came from real use (a 16:9-of-column-width first cut
    /// was cramped - see the old ZoomWindowManager.meetingSlotRatio).
    var zoomSlotRatio: Double

    init(split: Split = .half,
         mainOnLeft: Bool = true,
         sideShowsZoomTile: Bool = true,
         sideShowsChat: Bool = true,
         zoomSlotRatio: Double = 0.4) {
        self.split = split
        self.mainOnLeft = mainOnLeft
        self.sideShowsZoomTile = sideShowsZoomTile
        self.sideShowsChat = sideShowsChat
        self.zoomSlotRatio = zoomSlotRatio
    }

    var label: String { (mainOnLeft ? "Left " : "Right ") + split.glyph }

    /// The main pane as fractions of the visible width (0 = left edge,
    /// 1 = right edge). Full height always.
    var span: (start: Double, end: Double) {
        mainOnLeft ? (0, split.fraction) : (1 - split.fraction, 1)
    }

    /// Whatever's left once the main pane's slice is taken - e.g. Left ¾
    /// (0...0.75) leaves (0.75...1), the right quarter. The main pane
    /// always touches one screen edge, so the leftover is a single
    /// contiguous slice on the other side.
    var remainderSpan: (start: Double, end: Double) {
        span.start > 0 ? (0, span.start) : (span.end, 1.0)
    }

    /// The Zoom tile's share of the side column once the toggles are
    /// applied: its slider value with the chat below, the whole column
    /// with the chat off, nothing when the tile itself is off.
    var effectiveZoomSlotRatio: CGFloat {
        guard sideShowsZoomTile else { return 0 }
        return sideShowsChat ? min(max(zoomSlotRatio, 0.1), 1.0) : 1.0
    }

    // MARK: Screen frames

    /// The main pane's slice in TOP-LEFT-origin coordinates - the space
    /// both AppleScript window `bounds` and the Accessibility API speak,
    /// unlike AppKit's NSScreen (bottom-left-origin).
    func mainPaneTopLeftFrame() -> CGRect? {
        guard let screen = NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let top = screen.frame.height - visible.origin.y - visible.height
        let x = visible.origin.x + visible.width * span.start
        let width = visible.width * (span.end - span.start)
        return CGRect(x: x, y: top, width: width, height: visible.height)
    }

    /// The side column in NSWindow (bottom-left-origin) coordinates -
    /// NSWindow.setFrame and NSScreen.visibleFrame already share that
    /// space, so no conversion needed there.
    func sideColumnNSFrame() -> CGRect? {
        guard let screen = NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let remainder = remainderSpan
        let x = visible.origin.x + visible.width * remainder.start
        let width = visible.width * (remainder.end - remainder.start)
        return CGRect(x: x, y: visible.origin.y, width: width, height: visible.height)
    }

    // MARK: Codable - every field optional on decode, so a partial or
    // older exported-settings file imports cleanly.

    private enum CodingKeys: String, CodingKey {
        case split, mainOnLeft, sideShowsZoomTile, sideShowsChat, zoomSlotRatio
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            split: (try? container.decodeIfPresent(Split.self, forKey: .split)) ?? .half,
            mainOnLeft: (try? container.decodeIfPresent(Bool.self, forKey: .mainOnLeft)) ?? true,
            sideShowsZoomTile: (try? container.decodeIfPresent(Bool.self, forKey: .sideShowsZoomTile)) ?? true,
            sideShowsChat: (try? container.decodeIfPresent(Bool.self, forKey: .sideShowsChat)) ?? true,
            zoomSlotRatio: (try? container.decodeIfPresent(Double.self, forKey: .zoomSlotRatio)) ?? 0.4
        )
    }

    // MARK: Persistence + migration

    private static let defaultsKey = "workspaceLayout"

    /// The pre-generalization era stored ChromeWindowManager.Layout's
    /// rawValue under "chromeLayout" - map those three cases so existing
    /// setups keep their layout.
    init?(legacyChromeLayout raw: String) {
        switch raw {
        case "leftHalf": self.init()
        case "rightHalf": self.init(mainOnLeft: false)
        case "leftThreeQuarters": self.init(split: .threeQuarters)
        default: return nil
        }
    }

    static func load(from defaults: UserDefaults) -> WorkspaceLayout {
        if let data = defaults.data(forKey: defaultsKey),
           let layout = try? JSONDecoder().decode(WorkspaceLayout.self, from: data) {
            return layout
        }
        if let raw = defaults.string(forKey: "chromeLayout"),
           let migrated = WorkspaceLayout(legacyChromeLayout: raw) {
            return migrated
        }
        return WorkspaceLayout()
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
