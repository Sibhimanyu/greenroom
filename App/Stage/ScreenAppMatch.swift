//
//  ScreenAppMatch.swift
//  Greenroom
//
//  Which of ScreenCaptureKit's windows belong to the app a teacher picked.
//  Pure: plain values in, a verdict out, so it can be tested without a screen.
//
//  Why this is more than `bundleIdentifier ==`. ScreenCaptureKit's list of
//  running applications is not the Dock's. An Electron app (Conductor, Slack,
//  VS Code) draws its windows from the main process but may be listed under a
//  helper's bundle id, or not listed at all while its windows are. So an app
//  is matched three ways, in order: by bundle id, by the process ids macOS
//  gives that bundle id, and by "<bundle id>.helper..." for helper processes.
//  What is captured is the windows, which is what an app filter was always
//  going to show.
//
import CoreGraphics
import Foundation

struct ScreenWindowInfo: Equatable {
    var id: CGWindowID
    var pid: pid_t
    var bundleID: String?
    var frame: CGRect
    var layer: Int
    var onScreen: Bool
}

struct ScreenDisplayInfo: Equatable {
    var index: Int          // 1-based, for "Display 2"
    var frame: CGRect
    var isMain: Bool
}

enum ScreenAppMatch: Equatable {
    /// Capture the app on the chosen display (SCWindow ids, all on its
    /// current Space).
    case windows([CGWindowID])
    /// The app has no normal window on that display's current Space: it is
    /// full screen on its own desktop, or on another desktop or display.
    /// Capture this one window, which macOS follows wherever it is.
    /// `onScreen` is true when it is visible on another display, false when
    /// it is on another desktop.
    case elsewhere(window: CGWindowID, onScreen: Bool)
    /// The app is not running, or has no window that can give a picture.
    case noWindows

    /// `pids` are the process ids macOS reports for `bundleID`
    /// (NSRunningApplication); may be empty. `ownPID` is Greenroom itself,
    /// whose windows are never shared.
    static func match(bundleID: String, pids: Set<pid_t>,
                      windows: [ScreenWindowInfo],
                      display: ScreenDisplayInfo,
                      allDisplays: [ScreenDisplayInfo],
                      ownPID: pid_t = -1) -> ScreenAppMatch {
        let id = bundleID.lowercased()
        let mine = windows.filter { w in
            guard w.pid != ownPID,
                  ScreenWindowRules.isCapturable(layer: w.layer, size: w.frame.size) else { return false }
            if pids.contains(w.pid) { return true }
            guard let b = w.bundleID?.lowercased() else { return false }
            return b == id || b.hasPrefix(id + ".helper")
        }
        let here = mine.filter {
            $0.onScreen && display.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
        if !here.isEmpty { return .windows(here.map(\.id)) }
        // Prefer one that is visible somewhere (another display), then the
        // largest. A full-screen window on its own Space is the common case.
        let best = mine.max { a, b in
            if a.onScreen != b.onScreen { return !a.onScreen }
            return a.frame.width * a.frame.height < b.frame.width * b.frame.height
        }
        if let best { return .elsewhere(window: best.id, onScreen: best.onScreen) }
        return .noWindows
    }
}
