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
    static func openWindow(occupying layout: WorkspaceLayout, urlString: String = "") async -> String? {
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

        guard let failure = await runAppleScript(source) else { return nil }
        if failure.code == -1743 {
            return "Greenroom isn't authorized to control Google Chrome yet. Approve it in System Settings \u{2192} Privacy & Security \u{2192} Automation, then try again."
        }
        return "Couldn't position the Chrome window: \(failure.message) (code \(failure.code))"
    }

    /// Re-tiles Chrome's existing front window to its slice WITHOUT
    /// creating a new window or touching its URL - the "snap back" case
    /// after the user has dragged things around. No-op when Chrome isn't
    /// running.
    @discardableResult
    static func repositionFrontWindow(occupying layout: WorkspaceLayout) async -> String? {
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
        guard let failure = await runAppleScript(source) else { return nil }
        if failure.code == -1743 {
            return "Greenroom isn't authorized to control Google Chrome yet. Approve it in System Settings \u{2192} Privacy & Security \u{2192} Automation, then try again."
        }
        return "Couldn't reposition the Chrome window: \(failure.message) (code \(failure.code))"
    }

    /// Runs a script via /usr/bin/osascript OFF the main thread.
    /// NSAppleScript.executeAndReturnError blocked whatever thread called
    /// it - and the cold-start script (repeat 25 / delay 0.2, plus
    /// activate) held the MAIN thread for multi-second stretches: a
    /// beachball users reasonably read as a crash. The subprocess also
    /// gets a kill-timeout, so a wedged Chrome can't hang callers.
    /// Returns nil on success, or (code, stderr text) on failure - with
    /// osascript's "(-1743)" automation-permission marker surfaced as the
    /// code so callers keep their specific guidance.
    private static func runAppleScript(_ source: String, timeout: TimeInterval = 30) async -> (code: Int, message: String)? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe()

            let watchdog = DispatchWorkItem { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            process.terminationHandler = { finished in
                watchdog.cancel()
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    let code = message.contains("-1743") ? -1743 : Int(finished.terminationStatus)
                    continuation.resume(returning: (code, message.isEmpty ? "script timed out or was killed" : message))
                }
            }
            do {
                try process.run()
            } catch {
                watchdog.cancel()
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
