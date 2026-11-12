//
//  MeetingMorph.swift
//  Greenroom
//
//  The arithmetic of the one-click switch between the meeting window and the
//  floating control bar. Plain CGRect and numbers, no views, so the test target
//  compiles this file as it is.
//
//  The picture the teacher sees: a snapshot of the window travels to where the
//  bar will be and fades out while the bar fades in (or the reverse). Everything
//  is driven by one number, `windowness`: 1 is the window as it was, 0 is the
//  bar. A shrink runs it 1 to 0, an expand 0 to 1, and a click in the middle
//  simply gives it a new target from wherever it has got to.
//
import CoreGraphics
import Foundation

enum MeetingMorph {

    /// A full trip, window to bar or back. DESIGN.md's layout-move budget is
    /// 250ms and its spring about 0.4s; this is between, ease in and out.
    static let duration: TimeInterval = 0.35

    /// What to draw at one instant.
    struct Keyframe: Equatable {
        /// The snapshot's frame, in screen coordinates.
        var frame: CGRect
        var snapshotAlpha: CGFloat
        var barAlpha: CGFloat
    }

    /// Smooth start and finish: a cubic ease in and out.
    static func ease(_ t: CGFloat) -> CGFloat {
        let t = min(1, max(0, t))
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// The snapshot at `windowness` (0 bar, 1 window). Under Reduce Motion nothing
    /// moves: the snapshot stays at the window's frame and the two crossfade.
    static func keyframe(window: CGRect, bar: CGRect, windowness t: CGFloat, reduceMotion: Bool) -> Keyframe {
        let t = min(1, max(0, t))
        let frame = reduceMotion ? window : lerp(bar, window, t)
        return Keyframe(frame: frame, snapshotAlpha: t, barAlpha: 1 - t)
    }

    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// One leg of the morph: from where it is to a target, started at `began`.
    struct Timeline: Equatable {
        var from: CGFloat
        var to: CGFloat
        var began: TimeInterval
        var length: TimeInterval

        /// A leg from `from` to `to`. A shorter way to go takes proportionally
        /// less time, so a reversal near the start is quick and the pace stays
        /// the same whichever way it is going.
        static func start(from: CGFloat, to: CGFloat, at now: TimeInterval) -> Timeline {
            Timeline(from: from, to: to, began: now, length: max(0.001, duration * Double(abs(to - from))))
        }

        func progress(at now: TimeInterval) -> CGFloat {
            CGFloat(min(1, max(0, (now - began) / length)))
        }

        func windowness(at now: TimeInterval) -> CGFloat {
            from + (to - from) * ease(progress(at: now))
        }

        func isDone(at now: TimeInterval) -> Bool { now - began >= length }
    }

    /// A click while a leg is running: a new leg back the other way from where
    /// this one has got to. Nil when the target already is the one asked for.
    static func retarget(_ current: Timeline, toward target: CGFloat, at now: TimeInterval) -> Timeline? {
        guard current.to != target else { return nil }
        return .start(from: current.windowness(at: now), to: target, at: now)
    }
}
