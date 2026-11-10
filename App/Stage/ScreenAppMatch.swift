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
    /// Capture these windows (SCWindow ids) on the chosen display.
    case windows([CGWindowID])
    /// The app has windows, but all on other displays.
    case otherDisplay(String)
    /// The app is not running, or has nothing on any screen.
    case noWindows

    /// `pids` are the process ids macOS reports for `bundleID`
    /// (NSRunningApplication); may be empty.
    static func match(bundleID: String, pids: Set<pid_t>,
                      windows: [ScreenWindowInfo],
                      display: ScreenDisplayInfo,
                      allDisplays: [ScreenDisplayInfo]) -> ScreenAppMatch {
        let id = bundleID.lowercased()
        let mine = windows.filter { w in
            guard w.layer == 0, w.onScreen, w.frame.width >= 50, w.frame.height >= 50 else { return false }
            if pids.contains(w.pid) { return true }
            guard let b = w.bundleID?.lowercased() else { return false }
            return b == id || b.hasPrefix(id + ".helper")
        }
        let here = mine.filter { display.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        if !here.isEmpty { return .windows(here.map(\.id)) }
        for other in allDisplays where other != display {
            if mine.contains(where: { other.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }) {
                return .otherDisplay("Display \(other.index)" + (other.isMain ? " (the main one)" : ""))
            }
        }
        return .noWindows
    }
}
