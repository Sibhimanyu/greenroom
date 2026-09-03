//
//  MainPaneManager.swift
//  Greenroom
//
//  Opens whatever app the user picked for the main pane and tiles it to
//  its slice of the screen. Three paths:
//   - Greenroom's own browser (BrowserWindowController) is our window:
//    a plain setFrame, no permission of any kind.
//   - Chrome keeps its dedicated AppleScript route (ChromeWindowManager):
//    more reliable (Chrome scripts its own window bounds and URL under a
//    lightweight per-app Automation permission), and it creates a fresh
//    window rather than grabbing an existing one.
//   - Everything else launches/activates via NSWorkspace (browsers get
//    the URL handed to them) and is positioned with the Accessibility
//    API (AppWindowManager) - the only generic way to move another app's
//    window on macOS.
//
import AppKit

@MainActor
enum MainPaneManager {

    /// A cold-launched app can take a while to show its first window.
    private static let windowTimeout: TimeInterval = 20

    /// Opens/positions the main pane. Returns `nil` on success, or a
    /// human-readable error otherwise (matching ChromeWindowManager's
    /// convention).
    static func openWindow(bundleID: String, urlString: String, layout: WorkspaceLayout) async -> String? {
        if AppCatalog.isBuiltInBrowser(bundleID) {
            BrowserWindowController.show(urlString: urlString, layout: layout)
            let typed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, AppCatalog.normalizedWebURL(from: urlString) == nil {
                return "Opened \(AppCatalog.builtInBrowser.name) without a page \u{2014} \u{201C}\(urlString)\u{201D} is not a usable address. Retype it in Settings (\u{2318},)."
            }
            return nil
        }

        // Browsers: scripted route first, for EVERY browser. Handing a URL
        // to a running browser via NSWorkspace opens a tab in the EXISTING
        // window (and the session then tiles someone's whole tab pile -
        // seen live with Ulaa); `make new window` via the Chromium
        // AppleScript dictionary gives the session its own window. Ulaa
        // ships Chrome's dictionary verbatim; non-Chromium browsers fall
        // through to the generic path below.
        if AppCatalog.isBrowser(bundleID) {
            let scriptError = await ChromeWindowManager.openWindow(bundleID: bundleID, occupying: layout, urlString: urlString)
            guard let scriptError else { return nil }
            if scriptError.contains("isn't authorized") {
                return scriptError // fixable permission problem - surface, don't fall back
            }
            // Dictionary not understood (non-Chromium browser) - generic
            // path below still works, just as a tab in an existing window.
        }

        let name = AppCatalog.displayName(forBundleID: bundleID) ?? bundleID
        guard let frame = layout.mainPaneTopLeftFrame() else {
            return "Couldn't read the main screen's size."
        }
        guard let appURL = AppCatalog.appURL(forBundleID: bundleID) else {
            return "Couldn't find \(name) on this Mac \u{2014} pick a different main app in Settings (\u{2318},)."
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            if AppCatalog.isBrowser(bundleID), let url = AppCatalog.normalizedWebURL(from: urlString) {
                try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
            } else {
                try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
                // Say so when a browser was asked to open an address and the
                // address could not be parsed. This branch used to be silent, so
                // an unusable URL looked exactly like a browser that opens on a
                // blank tab by preference.
                if AppCatalog.isBrowser(bundleID),
                   !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "Opened \(name) without a page \u{2014} \u{201C}\(urlString)\u{201D} is not a usable address. Retype it in Settings (\u{2318},)."
                }
            }
        } catch {
            return "Couldn't open \(name): \(error.localizedDescription)"
        }

        guard AppWindowManager.hasAccessibilityPermission else {
            AppWindowManager.promptForAccessibilityPermission()
            return "\(name) is open, but Greenroom can't move its window without Accessibility permission \u{2014} allow Greenroom under System Settings \u{2192} Privacy & Security \u{2192} Accessibility, then try again."
        }
        guard await AppWindowManager.positionFrontWindow(bundleID: bundleID, frame: frame, timeout: windowTimeout) != nil else {
            return "\(name) launched but never showed a window to tile."
        }
        return nil
    }

    /// Re-tiles the app's existing front window WITHOUT launching
    /// anything or touching URLs - the "snap back" case after the user
    /// has dragged things around. No-op when the app isn't running.
    @discardableResult
    static func repositionFrontWindow(bundleID: String, layout: WorkspaceLayout) async -> String? {
        if AppCatalog.isBuiltInBrowser(bundleID) {
            BrowserWindowController.reposition(layout: layout)
            return nil
        }

        if AppCatalog.isBrowser(bundleID) {
            let scriptError = await ChromeWindowManager.repositionFrontWindow(bundleID: bundleID, occupying: layout)
            guard let scriptError else { return nil }
            if scriptError.contains("isn't authorized") { return scriptError }
            // Non-Chromium browser - fall through to AX repositioning.
        }

        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        guard let frame = layout.mainPaneTopLeftFrame() else {
            return "Couldn't read the main screen's size."
        }
        let name = AppCatalog.displayName(forBundleID: bundleID) ?? bundleID
        guard AppWindowManager.hasAccessibilityPermission else {
            AppWindowManager.promptForAccessibilityPermission()
            return "Greenroom can't move \(name)'s window without Accessibility permission \u{2014} allow it under System Settings \u{2192} Privacy & Security \u{2192} Accessibility."
        }
        guard let window = AppWindowManager.frontWindow(ofAppWithBundleID: bundleID),
              AppWindowManager.setFrame(frame, of: window) != nil else {
            return "Couldn't find a \(name) window to reposition."
        }
        return nil
    }
}
