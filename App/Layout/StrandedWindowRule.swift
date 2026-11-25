//
//  StrandedWindowRule.swift
//  Greenroom
//
//  When a Greenroom window counts as stranded after a display change, and where
//  it goes (R45.7). Pure: Foundation and CoreGraphics only.
//
//  Owner's log, 2026-11-26: while an AirPlay display renegotiated, "Display
//  settings changed" kept coming with both screens still listed, and each time
//  "A Greenroom window was on a screen that is gone" moved a window onto the
//  other screen and back. The old rule (WindowRescue.rescuedFrame) judged a
//  window by the screens' usable areas, which read as nothing for a moment, and
//  also slid windows whose title bar was out of reach. Now a window is stranded
//  only when its frame touches no listed screen at all, and the caller asks
//  again after the displays have been quiet for `settleSeconds`.
//
import Foundation
import CoreGraphics

enum StrandedWindowRule {

    /// One listed screen: its name for the log, its whole frame, its usable area.
    struct Screen: Equatable {
        var name: String
        var frame: CGRect
        var visibleFrame: CGRect
    }

    /// How long the displays must be quiet before a rescue is looked at again.
    /// A newer display change starts the wait again.
    static let settleSeconds: TimeInterval = 1.5

    /// Where a stranded window goes, or nil when it stays. A window whose frame
    /// overlaps any listed screen's frame is never moved, however little of it
    /// shows. One on no screen goes onto `preferred` (else the first screen),
    /// shrunk to fit its usable area and centred there. Frames in AppKit's
    /// global space.
    static func rescuedFrame(for frame: CGRect, screens: [Screen], preferred: Screen?) -> CGRect? {
        guard !screens.isEmpty, frame.width > 0, frame.height > 0 else { return nil }
        let onAScreen = screens.contains { screen in
            let hit = frame.intersection(screen.frame)
            return !hit.isNull && hit.width > 0 && hit.height > 0
        }
        if onAScreen { return nil }
        guard let target = preferred ?? screens.first else { return nil }
        let area = target.visibleFrame.width > 0 && target.visibleFrame.height > 0 ? target.visibleFrame : target.frame
        let width = min(frame.width, area.width), height = min(frame.height, area.height)
        return CGRect(x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(),
                      width: width.rounded(), height: height.rounded())
    }

    /// The log line for a rescue: which window, where it was, where it went, and
    /// every screen listed at that moment.
    static func logLine(windowTitle: String, frame: CGRect, movedTo: CGRect, onto: String, screens: [Screen]) -> String {
        let name = windowTitle.isEmpty ? "A Greenroom window" : "\u{201C}\(windowTitle)\u{201D}"
        let listed = screens.map { "\($0.name) \(describe($0.frame))" }.joined(separator: "; ")
        return "\(name) at \(describe(frame)) was on no screen; moved it onto \(onto) at \(describe(movedTo)). Screens: \(listed)."
    }

    static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))\u{00D7}\(Int(rect.height))"
    }
}
