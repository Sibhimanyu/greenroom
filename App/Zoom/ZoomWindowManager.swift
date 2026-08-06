//
//  ZoomWindowManager.swift
//  Greenroom
//
//  Parks Zoom's meeting window into the top of the side column, above the
//  chat window - Zoom has no AppleScript dictionary (unlike Chrome), so
//  this rides on AppWindowManager's generic Accessibility-API positioning
//  (extracted from here when the main pane got generalized). Without the
//  Accessibility grant everything else still works; the Zoom window just
//  stays wherever Zoom put it.
//
//  What stays Zoom-specific: finding the meeting window by title ("Zoom
//  Meeting" in the English client), polling for it (it only exists once
//  the meeting has actually started - which can be many seconds after
//  Start), and minimizing Zoom's other windows.
//
import AppKit
import ApplicationServices

enum ZoomWindowManager {

    static var hasAccessibilityPermission: Bool { AppWindowManager.hasAccessibilityPermission }

    static func promptForAccessibilityPermission() {
        AppWindowManager.promptForAccessibilityPermission()
    }

    /// Polls until Zoom's meeting window exists, then parks it in `frame`
    /// (top-left-origin AX coordinates). Returns the window's ACTUAL
    /// resulting frame - Zoom clamps resizes below its minimum window
    /// size, so what was asked for and what happened can differ, and the
    /// chat window below needs the truth. Nil if the window never
    /// appeared before the timeout. Pinned top-right so the tile hugs the
    /// slot's outer corner regardless of clamping.
    static func positionMeetingWindow(frame: CGRect, timeout: TimeInterval) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = findMeetingWindow(),
               let actual = AppWindowManager.setFrame(frame, of: window, pinTopRight: true) {
                return actual
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    /// Minimizes Zoom's OTHER windows (the "Zoom Workplace" home window,
    /// mainly) so the parked meeting tile is all that's left of Zoom on
    /// screen. Windows with empty titles are left alone - Zoom's floating
    /// meeting-controls panels are title-less and minimizing them breaks
    /// in-meeting controls.
    static func minimizeNonMeetingWindows() {
        for window in AppWindowManager.windows(ofAppWithBundleID: ZoomLauncher.bundleIdentifier) {
            guard let title = AppWindowManager.title(of: window), !title.isEmpty,
                  !title.localizedCaseInsensitiveContains("zoom meeting") else { continue }
            AppWindowManager.minimize(window)
        }
    }

    /// The meeting window's live frame (AX top-left coordinates) - what
    /// the chat window aligns itself under. Read fresh every time because
    /// Zoom reshapes its own window (starting/stopping a screen share,
    /// user drags) long after the initial parking.
    static func currentMeetingWindowFrame() -> CGRect? {
        findMeetingWindow().flatMap { AppWindowManager.frame(of: $0) }
    }

    private static func findMeetingWindow() -> AXUIElement? {
        AppWindowManager.windows(ofAppWithBundleID: ZoomLauncher.bundleIdentifier).first { window in
            AppWindowManager.title(of: window)?.localizedCaseInsensitiveContains("zoom meeting") ?? false
        }
    }
}
