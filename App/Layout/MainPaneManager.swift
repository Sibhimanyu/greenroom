//
//  MainPaneManager.swift
//  Greenroom
//
//  Opens an App piece of the layout and tiles it to its frame. Three paths:
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

    /// Opens an App piece and puts it in `frame`. Returns `nil` on success, or a
    /// line for the status log otherwise (an app that is not installed, a
    /// missing Accessibility grant, a full-screen window, an app that kept its
    /// own size - none of them stops the rest of the layout).
    static func openWindow(bundleID: String, url urlString: String, frame: LayoutFrames) async -> String? {
        if AppCatalog.isBuiltInBrowser(bundleID) {
            let framed = BrowserWindowController.show(urlString: urlString, frame: frame.ns)
            let typed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty, AppCatalog.normalizedWebURL(from: urlString) == nil {
                return "Opened \(AppCatalog.builtInBrowser.name) without a page \u{2014} \u{201C}\(urlString)\u{201D} is not a usable address. Retype it in Settings (\u{2318},)."
            }
            if !framed { return "\(AppCatalog.builtInBrowser.name) is full screen, so Greenroom left its window where it is." }
            return nil
        }

        let name = AppCatalog.displayName(forBundleID: bundleID) ?? bundleID
        guard let appURL = AppCatalog.appURL(forBundleID: bundleID) else {
            return "\(name) isn\u{2019}t on this Mac, so it was skipped."
        }

        // Browsers: scripted route first, for EVERY browser. Handing a URL
        // to a running browser via NSWorkspace opens a tab in the EXISTING
        // window (and the session then tiles someone's whole tab pile -
        // seen live with Ulaa); `make new window` via the Chromium
        // AppleScript dictionary gives the session its own window. Ulaa
        // ships Chrome's dictionary verbatim; non-Chromium browsers fall
        // through to the generic path below.
        if AppCatalog.isBrowser(bundleID) {
            let scriptError = await ChromeWindowManager.openWindow(bundleID: bundleID, occupying: frame.ax, urlString: urlString)
            guard let scriptError else { return nil }
            if scriptError.contains("isn't authorized") {
                return scriptError // fixable permission problem - surface, don't fall back
            }
            // Dictionary not understood (non-Chromium browser) - generic
            // path below still works, just as a tab in an existing window.
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
        switch await AppWindowManager.placeFrontWindow(bundleID: bundleID, frame: frame.ax, timeout: windowTimeout) {
        case .noWindow:
            return "\(name) launched but never showed a window to tile."
        case .fullScreen:
            return "\(name) is full screen, so Greenroom left its window where it is."
        case .placed(let actual):
            return refusedSizeLine(name: name, asked: frame.ax, actual: actual)
        }
    }

    /// Re-tiles the app's existing front window WITHOUT launching
    /// anything or touching URLs - the "snap back" case after the user
    /// has dragged things around. No-op when the app isn't running.
    @discardableResult
    static func repositionFrontWindow(bundleID: String, frame: LayoutFrames) async -> String? {
        if AppCatalog.isBuiltInBrowser(bundleID) {
            return BrowserWindowController.reposition(frame: frame.ns)
                ? nil : "\(AppCatalog.builtInBrowser.name) is full screen, so Greenroom left its window where it is."
        }

        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return nil }
        let name = AppCatalog.displayName(forBundleID: bundleID) ?? bundleID

        if AppCatalog.isBrowser(bundleID) {
            let scriptError = await ChromeWindowManager.repositionFrontWindow(bundleID: bundleID, occupying: frame.ax)
            guard let scriptError else { return nil }
            if scriptError.contains("isn't authorized") { return scriptError }
            // Non-Chromium browser - fall through to AX repositioning.
        }

        guard AppWindowManager.hasAccessibilityPermission else {
            AppWindowManager.promptForAccessibilityPermission()
            return "Greenroom can't move \(name)'s window without Accessibility permission \u{2014} allow it under System Settings \u{2192} Privacy & Security \u{2192} Accessibility."
        }
        guard let window = AppWindowManager.frontWindow(ofAppWithBundleID: bundleID) else {
            return "Couldn't find a \(name) window to reposition."
        }
        if AppWindowManager.isFullScreen(window) {
            return "\(name) is full screen, so Greenroom left its window where it is."
        }
        guard let actual = AppWindowManager.setFrame(frame.ax, of: window) else {
            return "Couldn't find a \(name) window to reposition."
        }
        return refusedSizeLine(name: name, asked: frame.ax, actual: actual)
    }

    /// An app that clamps a size keeps what it returns; nothing else moves to
    /// make room. Said once, so a layout that does not quite fit is explained.
    private static func refusedSizeLine(name: String, asked: CGRect, actual: CGRect) -> String? {
        guard LayoutResolver.differs(actual, from: asked) else { return nil }
        return "\(name) kept its own size: \(Int(actual.width))\u{00D7}\(Int(actual.height)) instead of \(Int(asked.width))\u{00D7}\(Int(asked.height)). Left as it is."
    }
}
