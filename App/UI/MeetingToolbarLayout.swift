//
//  MeetingToolbarLayout.swift
//  Greenroom
//
//  What the meeting window's toolbar shows at a given width. Pure arithmetic, no
//  views: the toolbar asks this how much of itself fits, and puts the rest in
//  More. It is a function of the width, not a fixed breakpoint, so a window that
//  is one cell short drops one control, not half of them.
//
//  Order, left to right (DESIGN.md: one control style, icon over a caption):
//
//      you | the class | teaching | recording | More ...... clock  End
//      Mute+caret  Camera+caret | Security  People  Chat  React |
//      Share+caret  Draw  Notes | Record  Pause | More
//
//  One run, centred on the window: the same gap between any two controls, a
//  wider one with a hairline between groups, so nothing floats loose. The
//  groups read like the floating bar's (you, the class, teaching, recording).
//  Security shows for a host or co-host only. Mute is never dropped; More is
//  always there, because Meeting info and "Open in the Zoom app" live in it.
//
import CoreGraphics
import Foundation

enum ToolbarItemID: String, CaseIterable {
    case mute, video, security, people, chat, react, share, draw, notes, record
}

struct ToolbarItemSpec: Equatable {
    let id: ToolbarItemID
    /// Controls are grouped by the dividers between them.
    let group: Int
    let width: CGFloat
    /// The higher, the longer it stays on the bar. Dropped lowest first.
    let keep: Int
}

enum MeetingToolbarLayout {
    /// One control: icon over caption.
    static let cell: CGFloat = 68
    /// The caption's point size (system font, regular), under every glyph.
    static let captionSize: CGFloat = 11
    /// The camera control is wider than the rest: its caption is the camera state's own name
    /// (CameraState.name, the words every other surface uses) or "Start video", and the longest,
    /// "Only the meeting", is 90pt at `captionSize`. 68pt cut it and "Everyone & me" (1.10.0).
    /// MeetingToolbarTests measures every caption against this.
    static let cameraCell: CGFloat = 94
    /// The little chevron beside Mute, Stop Video and Share.
    static let caret: CGFloat = 18
    /// Between groups: the hairline sits in the middle (the gaps either side
    /// come on top), so a group break is 4 + 17 + 4 = 25pt against 4pt inside one.
    static let divider: CGFloat = 17
    /// Between any two controls in a group, and around every divider.
    static let gap: CGFloat = 4
    static let side: CGFloat = 12
    static let more: CGFloat = 68
    static let clock: CGFloat = 56
    static let end: CGFloat = 60
    /// End armed: "Keep going" and "End for everyone" side by side (EndConfirmButtons, 12pt,
    /// 12pt padding each side): 87 + 8 + 124 = 219 measured; 224 leaves air. The test measures it.
    static let endArmed: CGFloat = 224
    static let endArmedGap: CGFloat = 8
    /// Air kept between the last control and the clock, so they never touch.
    static let spacer: CGFloat = 8
    /// The clock sits between Draw and Security in the drop order: it goes
    /// before the controls that do something.
    static let clockKeep = 5

    /// The items in toolbar order. `security` appears for a host or co-host.
    /// While recording, Record is two cells wide: Stop (with the timer) and Pause.
    static func specs(showsSecurity: Bool, recording: Bool = false) -> [ToolbarItemSpec] {
        var out: [ToolbarItemSpec] = [
            .init(id: .mute, group: 0, width: cell + caret, keep: 11),
            .init(id: .video, group: 0, width: cameraCell + caret, keep: 10),
        ]
        if showsSecurity { out.append(.init(id: .security, group: 1, width: cell, keep: 6)) }
        out += [
            .init(id: .people, group: 1, width: cell, keep: 8),
            .init(id: .chat, group: 1, width: cell, keep: 7),
            .init(id: .react, group: 1, width: cell, keep: 3),
            .init(id: .share, group: 2, width: cell + caret, keep: 9),
            .init(id: .draw, group: 2, width: cell, keep: 4),
            .init(id: .notes, group: 2, width: cell, keep: 1),
            .init(id: .record, group: 3, width: recording ? cell * 2 + gap : cell, keep: 2),
        ]
        return out
    }

    struct Fit: Equatable {
        /// On the bar, in order.
        var visible: [ToolbarItemID]
        /// In More, in toolbar order.
        var overflow: [ToolbarItemID]
        var showsClock: Bool
    }

    /// The width the toolbar's HStack needs for these items, More and End
    /// included: every child, both spacers at their minimum, and the gap between
    /// all of them. The two balancing pads (the shorter outer group padded to
    /// the longer, to centre the middle) count as nothing: they give way first
    /// when the row is tight, so only the gaps around them count.
    static func required(items: [ToolbarItemSpec], showsClock: Bool, endWidth: CGFloat = end) -> CGFloat {
        var dividers = 0
        var last: Int?
        for item in items { if let last, last != item.group { dividers += 1 }; last = item.group }
        // The divider before More (More is always there, and is its own group).
        let beforeMore = items.isEmpty ? 0 : 1
        // Children: the balancing pad, two spacers, the controls, dividers,
        // More, the clock, End.
        let children = 1 + 2 + items.count + dividers + beforeMore + 1 + (showsClock ? 1 : 0) + 1
        var total = side * 2 + endWidth + more + spacer * 2 + gap * CGFloat(children - 1)
        total += items.reduce(0) { $0 + $1.width }
        total += CGFloat(dividers + beforeMore) * divider
        if showsClock { total += clock }
        return total
    }

    /// Drops the least important control until what is left fits `width`.
    static func fit(specs: [ToolbarItemSpec], width: CGFloat, endWidth: CGFloat = end) -> Fit {
        var items = specs
        var clock = true
        while required(items: items, showsClock: clock, endWidth: endWidth) > width {
            // The clock is one more candidate, ranked by `clockKeep`.
            let weakest = items.filter { $0.id != .mute }.min { $0.keep < $1.keep }
            if clock, weakest == nil || clockKeep < weakest!.keep {
                clock = false
            } else if let weakest {
                items.removeAll { $0.id == weakest.id }
            } else if clock {
                clock = false
            } else {
                break
            }
        }
        let kept = Set(items.map(\.id))
        return Fit(visible: items.map(\.id),
                   overflow: specs.map(\.id).filter { !kept.contains($0) },
                   showsClock: clock)
    }
}
