//
//  ShareTarget.swift
//  Greenroom
//
//  What the meeting sees behind the webcam: a whole display, one app, or one
//  window. The display choice itself still lives in `screenCaptureDisplayUUID`
//  (a whole display uses it, and so does an app, whose windows are captured on
//  that display); this adds what to narrow it to.
//
//  Windows are remembered by app and title, never by window ID. An ID is
//  minted when the window opens and dies with it, so a saved ID points at
//  nothing after the app relaunches. The ID is looked up afresh at every
//  Start, and if the title has changed - a browser window is titled after its
//  current tab - the app's front window stands in.
//
import AppKit
import CoreGraphics
import Foundation

struct ShareTarget: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case display, app, window
        var id: String { rawValue }

        var label: String {
            switch self {
            case .display: return "Whole screen"
            case .app: return "One app"
            case .window: return "One window"
            }
        }

        /// The `type` OBS's macOS screen capture source reads: display,
        /// window, application. Read off the mac-capture plugin in OBS 32.
        var obsType: Int {
            switch self {
            case .display: return 0
            case .window: return 1
            case .app: return 2
            }
        }
    }

    var kind: Kind = .display
    /// The app for `.app` and `.window`.
    var appBundleID: String = ""
    /// Kept so a saved app that is not running can still be named.
    var appName: String = ""
    /// `.window` only. Empty means the app's front window.
    var windowTitle: String = ""

    // MARK: Turning it into an OBS source

    /// What `ensureConfigured` hands OBS, and what it tells the teacher.
    struct Resolved {
        let kind: Kind
        let settings: [String: Any]
        /// "Keynote", "Chrome - Lesson plan", or nil for a display.
        let label: String?
        /// Set when the choice could not be honoured and the display is shared
        /// instead. Said out loud, because the alternative is the class seeing
        /// the whole screen when the teacher thought they had narrowed it.
        let fallback: String?

        /// Whether an existing OBS source already captures exactly this.
        func matches(_ existing: [String: Any]) -> Bool {
            // A missing type is OBS's default, a display.
            guard ((existing["type"] as? Int) ?? 0) == kind.obsType,
                  (existing["capture_audio"] as? Bool) == false else { return false }
            switch kind {
            case .display:
                return (existing["display_uuid"] as? String) == settings["display_uuid"] as? String
            case .app:
                return (existing["application"] as? String) == settings["application"] as? String
                    && (existing["display_uuid"] as? String) == settings["display_uuid"] as? String
            case .window:
                return (existing["window"] as? Int) == settings["window"] as? Int
            }
        }
    }

    /// The source settings for this target, falling back to the display when
    /// the app is not running or has no window to show.
    ///
    /// `capture_audio: false` on every kind, for the crash recorded in
    /// `ensureConfigured`. `show_hidden_windows` lets OBS find a window that
    /// is on another Space; without it OBS only looks on the current one and
    /// the ID resolved here would match nothing.
    func resolve(displayUUID: String) -> Resolved {
        let display: [String: Any] = ["type": 0, "display_uuid": displayUUID, "capture_audio": false]
        func fallBack(_ reason: String) -> Resolved {
            Resolved(kind: .display, settings: display, label: nil, fallback: reason)
        }

        switch kind {
        case .display:
            return Resolved(kind: .display, settings: display, label: nil, fallback: nil)

        case .app:
            guard !appBundleID.isEmpty else { return fallBack("No app is picked to share") }
            guard Self.isRunning(bundleID: appBundleID) else {
                return fallBack("\(displayName) isn\u{2019}t open")
            }
            return Resolved(kind: .app,
                            settings: ["type": 2, "application": appBundleID,
                                       "display_uuid": displayUUID, "capture_audio": false],
                            label: displayName, fallback: nil)

        case .window:
            guard !appBundleID.isEmpty else { return fallBack("No window is picked to share") }
            guard let window = Self.bestWindow(for: self, among: Self.windows()) else {
                return fallBack("\(displayName) has no window open")
            }
            let label = window.title.isEmpty ? window.appName : "\(window.appName) \u{2013} \(window.title)"
            return Resolved(kind: .window,
                            settings: ["type": 1, "window": Int(window.id), "show_shadow": false,
                                       "show_hidden_windows": true, "capture_audio": false],
                            label: label, fallback: nil)
        }
    }

    var displayName: String {
        if !appName.isEmpty { return appName }
        return AppCatalog.displayName(forBundleID: appBundleID) ?? "The app"
    }

    // MARK: What is on screen

    struct Window: Identifiable, Hashable {
        let id: CGWindowID
        let bundleID: String
        let appName: String
        /// Empty without Screen Recording permission: macOS hides other apps'
        /// window titles until it is granted.
        let title: String
        let onScreen: Bool

        /// The picker's tag. Title, not ID, for the reason at the top.
        var key: String { ShareTarget.windowKey(bundleID: bundleID, title: title) }
    }

    static func windowKey(bundleID: String, title: String) -> String {
        bundleID + "\u{1F}" + title
    }

    /// Ordinary app windows, front to back.
    ///
    /// CGWindowList rather than ScreenCaptureKit: it needs no permission to
    /// list windows (only their titles), so the picker and the lookup at Start
    /// both work before the teacher has said yes to anything. Layer 0 drops
    /// menus, the Dock and status items; the size floor drops toolbars,
    /// palettes and the invisible helper windows every app keeps. Greenroom's
    /// own windows are left out, because sharing the window you are presenting
    /// from shows the class itself, endlessly.
    static func windows() -> [Window] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let onScreen = Set(windowList(.optionOnScreenOnly).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        return windowList(.optionAll).compactMap { info -> Window? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 200, bounds.height >= 150 else { return nil }
            return Window(id: id, bundleID: bundleID,
                          appName: app.localizedName ?? bundleID,
                          title: info[kCGWindowName as String] as? String ?? "",
                          onScreen: onScreen.contains(id))
        }
    }

    private static func windowList(_ option: CGWindowListOption) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([option, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
    }

    /// The window to share: the saved title if it is still there, otherwise
    /// the app's frontmost window. On-screen windows win over ones on another
    /// Space or minimised, because a minimised window captures as nothing.
    static func bestWindow(for target: ShareTarget, among windows: [Window]) -> Window? {
        let own = windows.filter { $0.bundleID == target.appBundleID }
        let ranked = own.filter(\.onScreen) + own.filter { !$0.onScreen }
        if !target.windowTitle.isEmpty,
           let exact = ranked.first(where: { $0.title == target.windowTitle }) {
            return exact
        }
        return ranked.first
    }

    /// Apps someone could share: running, with a Dock icon, not Greenroom.
    static func runningApps() -> [(bundleID: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier, id != own,
                  seen.insert(id).inserted else { return nil }
            return (id, app.localizedName ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
