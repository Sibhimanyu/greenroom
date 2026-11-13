//
//  SlideShowFollow.swift
//  Greenroom
//
//  Presentation follow (phase 6 of the Recorditor port). While one window is
//  shared, a slide show of the same app (Keynote or PowerPoint play mode, a
//  browser's Present, a PDF presentation mode) opens as a NEW full-screen
//  window. The capture should move to it, and come back when it ends.
//
//  The rule is pure so it can be tested without a screen. Ported in spirit
//  from Recorditor's ScreenRecorder.checkTrackedWindow (ZRecorditor @7210322,
//  native/MacRecorder/Recording/ScreenRecorder.swift); see
//  docs/recorditor-integration/follow-port-log.md for every difference.
//
import CoreGraphics
import Foundation

enum SlideShowFollow {
    /// One window as the window list reports it (global CoreGraphics points,
    /// top-left origin).
    struct Window: Equatable {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let frame: CGRect
    }

    /// What to do on this look.
    enum Move: Equatable {
        case stay
        case follow(CGWindowID)
        case backToOriginal
    }

    /// Frame equal to a display's frame, give or take a point or two. With
    /// `allowNotchGap`, a frame that is the display minus a top strip as tall
    /// as that display's own top safe-area inset also counts (`notchInsets`,
    /// keyed by display frame; empty or 0 for a display without a notch). macOS
    /// keeps most apps' full-screen windows below the camera housing, so that
    /// is what a show looks like there. The gap is never a constant, and it is
    /// only allowed when the caller has a second signal (see `slideShowWindow`),
    /// because a window maximised with the Dock hidden has the same frame.
    static func isFullScreen(frame: CGRect, displayFrames: [CGRect], tolerance: CGFloat = 2,
                             notchInsets: [CGRect: CGFloat] = [:], allowNotchGap: Bool = false) -> Bool {
        displayFrames.contains { display in
            func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
            if near(display.minX, frame.minX), near(display.minY, frame.minY),
               near(display.width, frame.width), near(display.height, frame.height) { return true }
            guard allowNotchGap, let inset = notchInsets[display], inset > 0 else { return false }
            return near(display.minX, frame.minX) && near(display.width, frame.width)
                && near(display.minY + inset, frame.minY) && near(display.height - inset, frame.height)
        }
    }

    /// The slide-show window, if there is one: an ordinary-layer window of the
    /// SAME process, as big as a display, that is not `excluding` (the window
    /// already captured) and sits in front of the original window. Another
    /// app's window is never a candidate. `onScreenFrontToBack` is the
    /// on-screen window list in its own order; anything behind the original
    /// does not count, so a second maximised window of the app behind the
    /// shared one is not mistaken for a show.
    ///
    /// A notch-gap frame counts only with one of two signals: the window is
    /// NEW (its id is not in `knownWindowIDs`, the app's windows when following
    /// began or at the previous look), or the original is not on screen (the
    /// show took its own full-screen Space). `knownWindowIDs` nil means no
    /// history, so only the Space signal can apply.
    static func slideShowWindow(onScreenFrontToBack: [Window], original: CGWindowID, pid: pid_t,
                                displayFrames: [CGRect], notchInsets: [CGRect: CGFloat] = [:],
                                knownWindowIDs: Set<CGWindowID>? = nil) -> CGWindowID? {
        let originalAway = !contains(onScreenFrontToBack, id: original)
        for window in onScreenFrontToBack {
            if window.id == original { return nil }
            let secondSignal = originalAway || !(knownWindowIDs?.contains(window.id) ?? true)
            guard window.pid == pid, window.layer == 0,
                  isFullScreen(frame: window.frame, displayFrames: displayFrames,
                               notchInsets: notchInsets, allowNotchGap: secondSignal) else { continue }
            return window.id
        }
        return nil
    }

    /// Whether the shared (original) window is on the visible list at all.
    static func contains(_ windows: [Window], id: CGWindowID) -> Bool {
        windows.contains { $0.id == id }
    }

    /// One look. `current` is the window being captured now; `original` is
    /// the one the person chose. `onScreen` is front to back; `existing` is
    /// every window id that still exists, here or on another Space.
    static func decide(original: CGWindowID, current: CGWindowID, pid: pid_t,
                       onScreen: [Window], existing: Set<CGWindowID>,
                       displayFrames: [CGRect], notchInsets: [CGRect: CGFloat] = [:],
                       knownWindowIDs: Set<CGWindowID>? = nil) -> Move {
        if current == original {
            if let show = slideShowWindow(onScreenFrontToBack: onScreen, original: original, pid: pid,
                                          displayFrames: displayFrames, notchInsets: notchInsets,
                                          knownWindowIDs: knownWindowIDs) {
                return .follow(show)
            }
            return .stay
        }
        // Following a show. It ends when its window is gone, or when it is no
        // longer here and the original is. A show merely on another Space
        // (original not here either) is kept.
        let showHere = contains(onScreen, id: current)
        if !existing.contains(current) { return existing.contains(original) ? .backToOriginal : .stay }
        if !showHere, contains(onScreen, id: original) { return .backToOriginal }
        return .stay
    }
}
