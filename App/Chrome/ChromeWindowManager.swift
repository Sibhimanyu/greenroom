//
//  ChromeWindowManager.swift
//  Greenroom
//
//  Opens a Chrome window tiled to a slice of the main screen, optionally
//  loading a chosen URL. Uses Chrome's own AppleScript dictionary (it
//  supports setting a window's `bounds` directly) rather than the
//  system-wide Accessibility API - all this needs is Chrome's own one-time
//  "Greenroom wants to control Google Chrome" automation permission
//  (plus NSAppleEventsUsageDescription in Info.plist, without which macOS
//  silently denies the events and never even shows that prompt).
//
//  Kept as a deliberate special case of the generic main pane
//  (MainPaneManager routes Chrome here, every other app through
//  AppWindowManager's Accessibility path) - this route is more reliable
//  for Chrome and creates a fresh window instead of grabbing one.
//
import AppKit

enum ChromeWindowManager {

    static let chromeBundleID = "com.google.Chrome"

    /// Returns `nil` on success, or a human-readable error otherwise.
    ///
    /// Confirmed by testing: if Chrome isn't running yet, `activate` starts
    /// it and Chrome opens its own startup window - naively also calling
    /// `make new window` then leaves TWO windows. So: only create a window
    /// when Chrome was already running; on a cold start, wait for Chrome's
    /// own startup window to appear and take that one over instead.
    @discardableResult
    static func openWindow(occupying layout: WorkspaceLayout, urlString: String = "") -> String? {
        guard let rect = layout.mainPaneTopLeftFrame() else {
            return "Couldn't read the main screen's size."
        }

        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID).isEmpty
        let boundsList = "{\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.maxX)), \(Int(rect.maxY))}"

        let windowLine = wasRunning
            ? "set targetWindow to make new window"
            : """
            repeat 25 times
                    if (count of windows) > 0 then exit repeat
                    delay 0.2
                end repeat
                if (count of windows) = 0 then
                    set targetWindow to make new window
                else
                    set targetWindow to front window
                end if
            """

        let urlLine = AppCatalog.normalizedWebURL(from: urlString).map {
            "set URL of active tab of targetWindow to \"\($0.absoluteString)\""
        } ?? ""

        let source = """
        tell application "Google Chrome"
            activate
            \(windowLine)
            delay 0.3
            set bounds of targetWindow to \(boundsList)
            \(urlLine)
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }

        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -1743 {
            return "Greenroom isn't authorized to control Google Chrome yet. Approve it in System Settings \u{2192} Privacy & Security \u{2192} Automation, then try again."
        }
        let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown error"
        return "Couldn't position the Chrome window: \(message) (code \(code))"
    }

    /// Re-tiles Chrome's existing front window to its slice WITHOUT
    /// creating a new window or touching its URL - the "snap back" case
    /// after the user has dragged things around. No-op when Chrome isn't
    /// running.
    @discardableResult
    static func repositionFrontWindow(occupying layout: WorkspaceLayout) -> String? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID).isEmpty else { return nil }
        guard let rect = layout.mainPaneTopLeftFrame() else {
            return "Couldn't read the main screen's size."
        }
        let source = """
        tell application "Google Chrome"
            if (count of windows) > 0 then
                set bounds of front window to {\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.maxX)), \(Int(rect.maxY))}
            end if
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return nil }
        let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -1743 {
            return "Greenroom isn't authorized to control Google Chrome yet. Approve it in System Settings \u{2192} Privacy & Security \u{2192} Automation, then try again."
        }
        return "Couldn't reposition the Chrome window: \((error[NSAppleScript.errorMessage] as? String) ?? "unknown error") (code \(code))"
    }
}
