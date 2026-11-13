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
//      Mute+caret  Stop Video+caret  |  Security  People  Chat  React  Share+caret  |
//      Record  Notes  |  More  ..........  clock  End
//
//  Security shows for a host or co-host only. Mute is never dropped; More is
//  always there, because Meeting info and "Open in the Zoom app" live in it.
//
import CoreGraphics
import Foundation

enum ToolbarItemID: String, CaseIterable {
    case mute, video, security, people, chat, react, share, record, notes
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
    /// The little chevron beside Mute, Stop Video and Share.
    static let caret: CGFloat = 18
    static let divider: CGFloat = 13
    static let gap: CGFloat = 2
    static let side: CGFloat = 12
    static let more: CGFloat = 68
    static let clock: CGFloat = 56
    static let end: CGFloat = 60
    /// Air kept between the last control and the clock, so they never touch.
    static let spacer: CGFloat = 8
    /// The clock sits between Security and Chat in the drop order: it goes
    /// before the controls that do something.
    static let clockKeep = 4

    /// The items in toolbar order. `security` appears for a host or co-host.
    /// While recording, Record is two cells wide: Stop (with the timer) and Pause.
    static func specs(showsSecurity: Bool, recording: Bool = false) -> [ToolbarItemSpec] {
        var out: [ToolbarItemSpec] = [
            .init(id: .mute, group: 0, width: cell + caret, keep: 10),
            .init(id: .video, group: 0, width: cell + caret, keep: 9),
        ]
        if showsSecurity { out.append(.init(id: .security, group: 1, width: cell, keep: 5)) }
        out += [
            .init(id: .people, group: 1, width: cell, keep: 7),
            .init(id: .chat, group: 1, width: cell, keep: 6),
            .init(id: .react, group: 1, width: cell, keep: 3),
            .init(id: .share, group: 1, width: cell + caret, keep: 8),
            .init(id: .record, group: 2, width: recording ? cell * 2 + gap : cell, keep: 2),
            .init(id: .notes, group: 2, width: cell, keep: 1),
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

    /// The width the bar needs for these items, More and End included.
    static func required(items: [ToolbarItemSpec], showsClock: Bool) -> CGFloat {
        var total = side * 2 + end + more + spacer
        total += items.reduce(0) { $0 + $1.width + gap }
        // A divider between neighbouring groups, and one before More.
        var groups = 0
        var last: Int?
        for item in items where item.group != last { groups += 1; last = item.group }
        total += CGFloat(max(0, groups - 1)) * divider
        if !items.isEmpty { total += divider }
        total += gap                       // More's own gap
        if showsClock { total += clock + gap }
        return total
    }

    /// Drops the least important control until what is left fits `width`.
    static func fit(specs: [ToolbarItemSpec], width: CGFloat) -> Fit {
        var items = specs
        var clock = true
        while required(items: items, showsClock: clock) > width {
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
