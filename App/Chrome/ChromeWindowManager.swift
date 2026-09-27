//
//  ChromeWindowManager.swift
//  Greenroom
//
//  Opens a BROWSER window tiled to a slice of the main screen, optionally
//  loading a chosen URL - for any browser speaking Chrome's AppleScript
//  dictionary (windows with settable `bounds`, tabs with URL). That's
//  Chrome and the whole Chromium family: Ulaa ships Chrome's
//  scripting.sdef verbatim (verified), Edge/Brave/Vivaldi likewise.
//  Needs only the per-app one-time "Greenroom wants to control X"
//  Automation permission (plus NSAppleEventsUsageDescription in
//  Info.plist, without which macOS silently denies the events).
//
//  Why scripting instead of the generic NSWorkspace-open + AX path:
//  handing a URL to a running browser opens a TAB IN THE EXISTING
//  window (confirmed by a real complaint - the session tiled someone's
//  whole tab pile), while `make new window` gives the session its own
//  window. MainPaneManager tries this route for every browser and falls
//  back to the generic path only when the dictionary isn't understood.
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
    static func openWindow(bundleID: String = chromeBundleID, occupying layout: WorkspaceLayout, urlString: String = "") async -> String? {
        guard let rect = layout.mainPaneTopLeftFrame() else {
            return "Couldn't read the main screen's size."
        }

        let appName = AppCatalog.displayName(forBundleID: bundleID) ?? bundleID
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
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

        // Activate LAST, not first. `activate` sends macOS to the desktop
        // holding the app's front window; with Ulaa already open full screen
        // on another desktop, Start jumped there and `make new window` then
        // opened the session's window on top of that full-screen space. Made
        // and placed while the class's desktop is still the current one, the
        // new window lands here; raised to index 1 before `activate`, it is
        // the window activation brings forward, so nothing switches desktops.
        let source = """
        tell application id "\(bundleID)"
            \(windowLine)
            delay 0.3
            set bounds of targetWindow to \(boundsList)
            \(urlLine)
            set index of targetWindow to 1
            activate
            return id of targetWindow
        end tell
        """

        let (failure, output) = await runAppleScriptCapturing(source)
        guard let failure else {
            // Remembered so End Session can close exactly this window, and
            // not whichever one happens to be in front by then.
            let id = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty { sessionWindowIDs[bundleID] = id }
            return nil
        }
        if failure.code == -1743 {
            return "Greenroom isn't authorized to control \(appName) yet. Approve it in System Settings \u{2192} Privacy & Security \u{2192} Automation, then try again."
        }
        return "Couldn't position the \(appName) window: \(failure.message) (code \(failure.code))"
    }

    /// The window each browser's Start opened, by its scripting id.
    /// Kept as text and compared as text: Ulaa answers `id of window` in a
    /// form that never equals the same number written in a script, so
    /// `id of candidate is 487374464` matched nothing (seen live).
    private static var sessionWindowIDs: [String: String] = [:]

    /// Closes the window this session's Start opened in `bundleID`, and only
    /// that one. Every other window and tab the teacher has is left alone.
    /// Returns a line for the status log, or nil when there was nothing to
    /// close (no window remembered, or the teacher already closed it).
    static func closeSessionWindow(bundleID: String) async -> String? {
        guard let id = sessionWindowIDs.removeValue(forKey: bundleID),
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        let appName = AppCatalog.displayName(forBundleID: bundleID) ?? bundleID
        let source = """
        tell application id "\(bundleID)"
            repeat with candidate in windows
                if (id of candidate as text) is "\(id)" then
                    close candidate
                    return "closed"
                end if
            end repeat
        end tell
        return "gone"
        """
        let (failure, output) = await runAppleScriptCapturing(source)
        if let failure { return "Couldn't close the \(appName) window: \(failure.message)" }
        return output.contains("closed") ? "Closed the \(appName) window Start opened." : nil
    }

    /// Re-tiles Chrome's existing front window to its slice WITHOUT
    /// creating a new window or touching its URL - the "snap back" case
    /// after the user has dragged things around. No-op when Chrome isn't
    /// running.
    @discardableResult
    static func repositionFrontWindow(bundleID: String = chromeBundleID, occupying layout: WorkspaceLayout) async -> String? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        guard let rect = layout.mainPaneTopLeftFrame() else {
            return "Couldn't read the main screen's size."
        }
        let appName = AppCatalog.displayName(forBundleID: bundleID) ?? bundleID
        let source = """
        tell application id "\(bundleID)"
            if (count of windows) > 0 then
                set bounds of front window to {\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.maxX)), \(Int(rect.maxY))}
            end if
        end tell
        """
        guard let failure = await runAppleScript(source) else { return nil }
        if failure.code == -1743 {
            return "Greenroom isn't authorized to control \(appName) yet. Approve it in System Settings \u{2192} Privacy & Security \u{2192} Automation, then try again."
        }
        return "Couldn't reposition the \(appName) window: \(failure.message) (code \(failure.code))"
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
    /// runAppleScript, keeping what the script returned (its stdout).
    private static func runAppleScriptCapturing(_ source: String, timeout: TimeInterval = 30) async -> ((code: Int, message: String)?, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let stderrPipe = Pipe(), stdoutPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = stdoutPipe
            let watchdog = DispatchWorkItem { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            process.terminationHandler = { finished in
                watchdog.cancel()
                let output = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let message = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: (nil, output))
                } else {
                    let code = message.contains("-1743") ? -1743 : Int(finished.terminationStatus)
                    continuation.resume(returning: ((code, message.isEmpty ? "script timed out or was killed" : message), output))
                }
            }
            do { try process.run() } catch {
                watchdog.cancel()
                continuation.resume(returning: ((-1, error.localizedDescription), ""))
            }
        }
    }

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
