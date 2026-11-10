//
//  ShareTarget.swift
//  Greenroom
//
//  What the meeting sees behind the webcam: a whole display, one app, one
//  window, or nothing at all. The display choice itself still lives in `screenCaptureDisplayUUID`
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
        /// No shared content: the camera fills the frame on the backdrop.
        /// For a talking-head recording, or a meeting where the screen is
        /// shared some other way. The compositor lets the screen go and
        /// draws the camera alone - see `StageLayout.showsContent`.
        case nothing
        var id: String { rawValue }

        var label: String {
            switch self {
            case .display: return "Whole screen"
            case .app: return "One app"
            case .window: return "One window"
            case .nothing: return "Nothing"
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

    // MARK: Resolving it

    /// What the compositor captures, and what it tells the teacher.
    struct Resolved {
        let kind: Kind
        /// The window to capture, for `.window`.
        let windowID: Int?
        /// "Keynote", "Chrome - Lesson plan", or nil for a display.
        let label: String?
        /// Set when the choice could not be honoured and the display is shared
        /// instead. Said out loud, because the alternative is the class seeing
        /// the whole screen when the teacher thought they had narrowed it.
        let fallback: String?
    }

    /// The thing to capture for this target, falling back to the display when
    /// the app is not running or has no window to show.
    func resolve(displayUUID: String) -> Resolved {
        func fallBack(_ reason: String) -> Resolved {
            Resolved(kind: .display, windowID: nil, label: nil, fallback: reason)
        }

        switch kind {
        // Nothing is shared, so nothing is captured from this. A display is
        // returned so a caller that does capture from it gets a valid source.
        case .display, .nothing:
            return Resolved(kind: .display, windowID: nil, label: nil, fallback: nil)

        case .app:
            guard !appBundleID.isEmpty else { return fallBack("No app is picked to share") }
            guard Self.isRunning(bundleID: appBundleID) else {
                return fallBack("\(displayName) isn\u{2019}t open")
            }
            return Resolved(kind: .app, windowID: nil, label: displayName, fallback: nil)

        case .window:
            guard !appBundleID.isEmpty else { return fallBack("No window is picked to share") }
            guard let window = Self.bestWindow(for: self, among: Self.windows()) else {
                return fallBack("\(displayName) has no window open")
            }
            let label = window.title.isEmpty ? window.appName : "\(window.appName) \u{2013} \(window.title)"
            return Resolved(kind: .window, windowID: Int(window.id), label: label, fallback: nil)
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
        /// Here, full screen elsewhere, or on another desktop. A window that
        /// is not here is still shareable: macOS follows it.
        var placement: ScreenWindowRules.Placement = .here

        /// The picker's tag. Title, not ID, for the reason at the top.
        var key: String { ShareTarget.windowKey(bundleID: bundleID, title: title) }
    }

    static func windowKey(bundleID: String, title: String) -> String {
        bundleID + "\u{1F}" + title
    }

    /// Ordinary app windows, on this desktop first, then on others, each
    /// group front to back.
    ///
    /// Windows on other Spaces (and full-screen ones) are included, marked by
    /// `placement`: a window capture follows them there. What is still left
    /// out is what cannot give a picture, per `ScreenWindowRules.isCandidate`:
    /// hidden helper windows, tiny ones, transparent ones. fcf0a12 dropped all
    /// off-screen windows because a capture of one came out blank; the capture
    /// now says so itself if that happens (a window that is minimised looks
    /// like one on another desktop from here).
    ///
    /// CGWindowList rather than ScreenCaptureKit: it needs no permission to
    /// list windows (only their titles), so the picker and the lookup at Start
    /// both work before the teacher has said yes to anything. Layer 0 drops
    /// menus, the Dock and status items. Greenroom's own windows are left
    /// out, because sharing the window you are presenting from shows the
    /// class itself, endlessly.
    static func windows() -> [Window] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displaySizes = NSScreen.screens.map(\.frame.size)
        let listed = windowList(.optionAll).compactMap { info -> Window? in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo) else { return nil }
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let title = info[kCGWindowName as String] as? String ?? ""
            guard ScreenWindowRules.isCandidate(layer: info[kCGWindowLayer as String] as? Int ?? -1,
                                                size: bounds.size,
                                                alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                                                onScreen: onScreen, title: title),
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier else { return nil }
            return Window(id: id, bundleID: bundleID,
                          appName: app.localizedName ?? bundleID, title: title,
                          placement: ScreenWindowRules.placement(onScreen: onScreen, size: bounds.size,
                                                                 displaySizes: displaySizes))
        }
        // Stable: on this desktop first, so a lookup by title or "front
        // window" prefers a window that is certainly drawn.
        return listed.filter { $0.placement == .here } + listed.filter { $0.placement != .here }
    }

    private static func windowList(_ option: CGWindowListOption) -> [[String: Any]] {
        (CGWindowListCopyWindowInfo([option, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
    }

    /// The window to share: the saved title if it is still there, otherwise
    /// the app's frontmost window.
    static func bestWindow(for target: ShareTarget, among windows: [Window]) -> Window? {
        let own = windows.filter { $0.bundleID == target.appBundleID }
        if !target.windowTitle.isEmpty,
           let exact = own.first(where: { $0.title == target.windowTitle }) {
            return exact
        }
        return own.first
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
