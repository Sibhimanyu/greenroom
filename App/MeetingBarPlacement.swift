//
//  MeetingBarPlacement.swift
//  Greenroom
//
//  The arithmetic behind the floating meeting bar's position: where it lands
//  when it is dropped, how it grows and shrinks between the full bar and the
//  small round puck, and how far the notes bar and toasts must stay above it.
//  Plain CGRect in, CGRect out (all in AppKit's bottom-left screen coordinates),
//  so the test target compiles this file as it is.
//
import CoreGraphics
import Foundation

enum MeetingBarPlacement {

    /// A drop this close to a screen edge docks to it.
    static let snapDistance: CGFloat = 24
    /// Where a docked bar rests: clear of the edge, and where the bar has always sat at the bottom.
    static let edgeMargin: CGFloat = 16
    /// Pointer travel before a press becomes a drag. Below it, it is a click.
    static let dragThreshold: CGFloat = 4
    /// Space between the bar and whatever stacks above it.
    static let stackGap: CGFloat = 12
    /// Where a toast sits when nothing else claims the floor.
    static let toastDefaultFloor: CGFloat = 120

    // MARK: Fitting inside a screen

    /// The frame moved the least it takes to sit fully inside `area`. Larger than
    /// the area, it pins to the leading and bottom edges.
    static func clamp(_ frame: CGRect, to area: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(f.origin.x, area.maxX - f.width)
        f.origin.x = max(f.origin.x, area.minX)
        f.origin.y = min(f.origin.y, area.maxY - f.height)
        f.origin.y = max(f.origin.y, area.minY)
        return f
    }

    /// Docks to an edge when within `snapDistance` of it, per axis. When both
    /// opposite edges are in range the nearer wins.
    static func snap(_ frame: CGRect, to area: CGRect) -> CGRect {
        var f = frame
        let left = f.minX - area.minX, right = area.maxX - f.maxX
        if min(left, right) <= snapDistance {
            f.origin.x = left <= right ? area.minX + edgeMargin : area.maxX - edgeMargin - f.width
        }
        let bottom = f.minY - area.minY, top = area.maxY - f.maxY
        if min(bottom, top) <= snapDistance {
            f.origin.y = bottom <= top ? area.minY + edgeMargin : area.maxY - edgeMargin - f.height
        }
        return f
    }

    /// The screen a frame belongs to: the one holding most of it, or failing
    /// that the one whose centre is nearest.
    static func area(for frame: CGRect, in areas: [CGRect]) -> CGRect? {
        func overlap(_ a: CGRect) -> CGFloat {
            let i = a.intersection(frame)
            return i.isNull ? 0 : i.width * i.height
        }
        if let best = areas.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 { return best }
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return areas.min(by: { dist($0, c) < dist($1, c) })
    }

    private static func dist(_ a: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = a.midX - p.x, dy = a.midY - p.y
        return dx * dx + dy * dy
    }

    /// Where a dropped frame ends up: on the screen it was dropped on, docked to
    /// a near edge, fully inside that screen's visible area.
    static func drop(_ frame: CGRect, areas: [CGRect]) -> CGRect {
        guard let area = area(for: frame, in: areas) else { return frame }
        return clamp(snap(frame, to: area), to: area)
    }

    // MARK: Default and saved spots

    /// Bottom centre of the area.
    static func defaultFrame(size: CGSize, in area: CGRect) -> CGRect {
        CGRect(x: (area.midX - size.width / 2).rounded(), y: area.minY + edgeMargin,
               width: size.width, height: size.height)
    }

    /// A saved frame as it should be used now. Kept (clamped) when its centre is
    /// still on some screen; otherwise, or with nothing saved, the default spot.
    /// The saved size is ignored: the bar is as wide as it is today, around the
    /// saved centre.
    static func restore(saved: CGRect?, size: CGSize, areas: [CGRect], defaultArea: CGRect) -> CGRect {
        guard let saved,
              let area = areas.first(where: { $0.contains(CGPoint(x: saved.midX, y: saved.midY)) })
        else { return defaultFrame(size: size, in: defaultArea) }
        let f = CGRect(x: (saved.midX - size.width / 2).rounded(), y: (saved.midY - size.height / 2).rounded(),
                       width: size.width, height: size.height)
        return clamp(f, to: area)
    }

    // MARK: Collapsing and expanding

    /// Which side a frame hangs on, per axis: the screen third it sits in. The
    /// middle third keeps its centre.
    enum Hang { case low, middle, high }

    static func hang(of frame: CGRect, in area: CGRect) -> (x: Hang, y: Hang) {
        func pick(_ v: CGFloat, _ lo: CGFloat, _ len: CGFloat) -> Hang {
            let t = len > 0 ? (v - lo) / len : 0.5
            return t < 1.0 / 3 ? .low : t > 2.0 / 3 ? .high : .middle
        }
        return (pick(frame.midX, area.minX, area.width), pick(frame.midY, area.minY, area.height))
    }

    /// The frame at a new size, keeping the edge or corner nearest the screen
    /// edge where it is, so it grows away from that edge and stays on screen.
    static func resized(from old: CGRect, to size: CGSize, in area: CGRect) -> CGRect {
        let h = hang(of: old, in: area)
        var f = CGRect(origin: .zero, size: size)
        switch h.x {
        case .low: f.origin.x = old.minX
        case .high: f.origin.x = old.maxX - size.width
        case .middle: f.origin.x = old.midX - size.width / 2
        }
        switch h.y {
        case .low: f.origin.y = old.minY
        case .high: f.origin.y = old.maxY - size.height
        case .middle: f.origin.y = old.midY - size.height / 2
        }
        return clamp(f, to: area)
    }

    // MARK: What stacks above the bar

    /// How far above the area's bottom the notes bar rests. Normally one gap
    /// above the bar's default row; when the bar sits where the notes bar would,
    /// above the bar. A bar elsewhere leaves the notes bar at its own default.
    static func notesRestingY(bar: CGRect, area: CGRect, notesSize: CGSize) -> CGFloat {
        let own = CGRect(x: (area.midX - notesSize.width / 2).rounded(), y: area.minY + edgeMargin,
                         width: notesSize.width, height: notesSize.height)
        guard own.insetBy(dx: -stackGap, dy: -stackGap).intersects(bar) else { return edgeMargin }
        return bar.maxY + stackGap - area.minY
    }

    /// The lowest a toast may sit: above the notes bar when the bar is down at
    /// the bottom with it, else the usual spot.
    static func toastFloorY(bar: CGRect, area: CGRect, notesHeight: CGFloat) -> CGFloat {
        guard bar.minY - area.minY < toastDefaultFloor, bar.intersects(area) else { return toastDefaultFloor }
        return max(toastDefaultFloor, bar.maxY - area.minY + stackGap + notesHeight + stackGap)
    }

    // MARK: Motion

    /// How long the bar's own frame takes to settle, in seconds.
    static let settleSeconds: Double = 0.4

    /// A critically damped spring with a 250ms response: DESIGN.md's
    /// `snappy(0.25)`, as a number the window frame can follow (AppKit has no
    /// spring of its own). 0 at the start, no overshoot, 1 once settled.
    static func spring(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < settleSeconds else { return 1 }
        let w = 2 * Double.pi / 0.25
        return 1 - exp(-w * t) * (1 + w * t)
    }

    /// `from` to `to`, `p` of the way.
    static func lerp(_ from: CGRect, _ to: CGRect, _ p: Double) -> CGRect {
        let k = CGFloat(p)
        return CGRect(x: from.minX + (to.minX - from.minX) * k, y: from.minY + (to.minY - from.minY) * k,
                      width: from.width + (to.width - from.width) * k,
                      height: from.height + (to.height - from.height) * k)
    }
}
