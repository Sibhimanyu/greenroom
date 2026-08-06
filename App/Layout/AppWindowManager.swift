//
//  AppWindowManager.swift
//  Greenroom
//
//  Reusable Accessibility-API window positioning for ANY running app,
//  extracted from ZoomWindowManager (which now delegates here). Most apps
//  have no AppleScript dictionary (Chrome being the notable exception -
//  see ChromeWindowManager), so moving another app's windows means the raw
//  AX API, which needs the one-time grant under System Settings ->
//  Privacy & Security -> Accessibility. That grant is for GREENROOM as a
//  whole, not per target app - once given, every app's windows are
//  movable. Without it, every setter here silently does nothing.
//
import AppKit
import ApplicationServices

enum AppWindowManager {

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Shows the system's "grant Accessibility" prompt (once; macOS
    /// ignores repeat calls until the user acts).
    static func promptForAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Jumps straight to the Accessibility pane - the system prompt above
    /// only appears once ever, so Settings UIs need a way back in.
    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// All AX windows of the app, front-to-back. Empty when the app isn't
    /// running or the Accessibility grant is missing.
    static func windows(ofAppWithBundleID bundleID: String) -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return []
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return []
        }
        return windows
    }

    /// The app's focused window, falling back to the first listed one -
    /// what "the window" means for tiling a freshly launched app.
    static func frontWindow(ofAppWithBundleID bundleID: String) -> AXUIElement? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
               let focused = focusedRef {
                return (focused as! AXUIElement)
            }
        }
        return windows(ofAppWithBundleID: bundleID).first
    }

    static func title(of window: AXUIElement) -> String? {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        return titleRef as? String
    }

    /// The window's live frame in AX (top-left-origin) coordinates.
    static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = readPosition(of: window), let size = readSize(of: window) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// Sets the window's frame (AX top-left coordinates) and returns the
    /// ACTUAL resulting frame - apps clamp resizes below their minimum
    /// window size, so what was asked for and what happened can differ,
    /// and callers laying out around the window need the truth.
    ///
    /// `pinTopRight` places the window so its top-RIGHT corner lands on
    /// the frame's top-right corner regardless of clamping (what the Zoom
    /// meeting slot wants); otherwise the origin is pinned as usual, with
    /// the size re-asserted after the move in case the window's original
    /// position didn't leave room to grow.
    @discardableResult
    static func setFrame(_ frame: CGRect, of window: AXUIElement, pinTopRight: Bool = false) -> CGRect? {
        var requestedSize = CGSize(width: frame.width, height: frame.height)
        guard let sizeValue = AXValueCreate(.cgSize, &requestedSize) else { return nil }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        let actualSize = readSize(of: window) ?? requestedSize
        var position = pinTopRight
            ? CGPoint(x: frame.maxX - actualSize.width, y: frame.minY)
            : frame.origin
        guard let positionValue = AXValueCreate(.cgPoint, &position) else { return nil }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)

        if !pinTopRight {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }

        let finalPosition = readPosition(of: window) ?? position
        let finalSize = readSize(of: window) ?? actualSize
        return CGRect(origin: finalPosition, size: finalSize)
    }

    static func minimize(_ window: AXUIElement) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
    }

    /// Polls until the app has a window (a cold-launched app takes a
    /// while to show its first one), then parks the front window in
    /// `frame` (AX top-left coordinates). Returns the window's actual
    /// resulting frame, or nil if no window appeared before the timeout.
    static func positionFrontWindow(bundleID: String, frame: CGRect, timeout: TimeInterval) async -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = frontWindow(ofAppWithBundleID: bundleID),
               let actual = setFrame(frame, of: window) {
                return actual
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    private static func readSize(of window: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let value = sizeRef else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func readPosition(of window: AXUIElement) -> CGPoint? {
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              let value = positionRef else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }
}
