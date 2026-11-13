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

    /// Frame equal to a display's frame, give or take a point or two.
    static func isFullScreen(frame: CGRect, displayFrames: [CGRect], tolerance: CGFloat = 2) -> Bool {
        displayFrames.contains {
            abs($0.minX - frame.minX) <= tolerance && abs($0.minY - frame.minY) <= tolerance
                && abs($0.width - frame.width) <= tolerance && abs($0.height - frame.height) <= tolerance
        }
    }

    /// The slide-show window, if there is one: an ordinary-layer window of the
    /// SAME process, as big as a display, that is not `excluding` (the window
    /// already captured) and sits in front of the original window. Another
    /// app's window is never a candidate. `onScreenFrontToBack` is the
    /// on-screen window list in its own order; anything behind the original
    /// does not count, so a second maximised window of the app behind the
    /// shared one is not mistaken for a show.
    static func slideShowWindow(onScreenFrontToBack: [Window], original: CGWindowID, pid: pid_t,
                                displayFrames: [CGRect]) -> CGWindowID? {
        for window in onScreenFrontToBack {
            if window.id == original { return nil }
            guard window.pid == pid, window.layer == 0,
                  isFullScreen(frame: window.frame, displayFrames: displayFrames) else { continue }
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
                       displayFrames: [CGRect]) -> Move {
        if current == original {
            if let show = slideShowWindow(onScreenFrontToBack: onScreen, original: original, pid: pid,
                                          displayFrames: displayFrames)
                ?? offSpaceShow(onScreen: onScreen, original: original, pid: pid, displayFrames: displayFrames) {
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

    /// The original is not in the on-screen list (another Space, or hidden):
    /// take a full-screen window of the same app that is here.
    private static func offSpaceShow(onScreen: [Window], original: CGWindowID, pid: pid_t,
                                     displayFrames: [CGRect]) -> CGWindowID? {
        guard !contains(onScreen, id: original) else { return nil }
        return onScreen.first {
            $0.pid == pid && $0.layer == 0 && $0.id != original
                && isFullScreen(frame: $0.frame, displayFrames: displayFrames)
        }?.id
    }
}
