//
//  AppCatalog.swift
//  Greenroom
//
//  What can go in the main pane: enumerates installed + running apps for
//  the Settings picker, and knows which of them are web browsers (those
//  get the "open this URL" field).
//
import AppKit

struct AppInfo: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL?

    var id: String { bundleID }
}

enum AppCatalog {

    /// Apps from the standard application folders plus whatever regular
    /// apps are currently running (covers apps installed elsewhere),
    /// deduplicated by bundle ID and sorted by name. Greenroom itself is
    /// excluded - tiling our own window into the main pane is nonsense.
    static func installedAndRunning() -> [AppInfo] {
        var byBundleID: [String: AppInfo] = [:]

        let folders = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for item in items where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
                byBundleID[bundleID] = AppInfo(bundleID: bundleID, name: displayName(forAppAt: url), url: url)
            }
        }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, byBundleID[bundleID] == nil else { continue }
            byBundleID[bundleID] = AppInfo(bundleID: bundleID,
                                           name: app.localizedName ?? bundleID,
                                           url: app.bundleURL)
        }

        byBundleID.removeValue(forKey: Bundle.main.bundleIdentifier ?? "")
        return byBundleID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Whether the app registers as an https handler - the practical
    /// definition of "is a browser" (Chrome, Safari, Arc, Firefox, ...).
    /// Cached: the handler list can't change without an install, and
    /// resolving ~10 bundles isn't free inside SwiftUI body evaluations.
    static func isBrowser(_ bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    private static var cachedBrowserIDs: Set<String>?

    private static var browserBundleIDs: Set<String> {
        if let cachedBrowserIDs { return cachedBrowserIDs }
        guard let probe = URL(string: "https://example.com") else { return [] }
        let ids = Set(NSWorkspace.shared.urlsForApplications(toOpen: probe)
            .compactMap { Bundle(url: $0)?.bundleIdentifier })
        cachedBrowserIDs = ids
        return ids
    }

    static func appURL(forBundleID bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func displayName(forBundleID bundleID: String) -> String? {
        appURL(forBundleID: bundleID).map(displayName(forAppAt:))
    }

    static func icon(forBundleID bundleID: String) -> NSImage? {
        appURL(forBundleID: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// "docs.google.com" -> https://docs.google.com; empty/whitespace ->
    /// nil. Shared by the Chrome AppleScript path and the generic
    /// open-in-browser path.
    /// Strips characters a URL cannot contain, wherever they appear.
    ///
    /// Used both when storing the preference and when parsing it. Storing it
    /// clean matters on its own: a control character in the value made the whole
    /// preferences plist fail to parse as XML.
    static func sanitizedURLText(_ raw: String) -> String {
        String(raw.unicodeScalars.filter {
            $0.properties.generalCategory != .control
                && !$0.properties.isDefaultIgnorableCodePoint
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns whatever is in the Settings field into a URL, or nil.
    ///
    /// Control characters are stripped, not just trimmed, and that is the whole
    /// point. A saved address ending in U+001A - which is Ctrl-Z, and reaches the
    /// field far too easily given the app registers a global
    /// Control-Option-Command-Z - survived `trimmingCharacters(in:
    /// .whitespacesAndNewlines)` untouched, because a control character is
    /// neither whitespace nor a newline. `URL(string:)` then returned nil, the
    /// caller quietly fell back to launching the browser with no URL, and the
    /// result was a blank tab with nothing anywhere saying why.
    ///
    /// Stripped from anywhere in the string rather than only the ends: a URL
    /// cannot legally contain a control character in any position, so finding one
    /// in the middle means the same thing.
    static func normalizedWebURL(from raw: String) -> URL? {
        let cleaned = sanitizedURLText(raw)
        guard !cleaned.isEmpty else { return nil }
        let absolute = cleaned.contains("://") ? cleaned : "https://\(cleaned)"
        return URL(string: absolute)
    }

    private static func displayName(forAppAt url: URL) -> String {
        let fromFinder = FileManager.default.displayName(atPath: url.path)
        return fromFinder.hasSuffix(".app") ? String(fromFinder.dropLast(4)) : fromFinder
    }
}
