//
//  BrowserWindow.swift
//  Greenroom
//
//  Greenroom's own browser for the main pane - a WebKit window the app owns
//  outright, so tiling it is a plain setFrame like the chat window: no
//  Accessibility grant, no Automation prompt, no hunting for another
//  process's window, and never someone's whole tab pile.
//
//  Deliberately the everyday subset of a browser and nothing more: tabs in
//  the title bar, back/forward/reload, an address bar that also searches
//  and suggests, find in page, history, favicons, downloads to
//  ~/Downloads, the usual shortcuts. No extensions, no bookmarks yet - the
//  external browsers in the picker are for those.
//
//  Sign-ins persist: the default (on-disk) website data store keeps cookies
//  between sessions, so the reading doc opens signed in every morning
//  instead of at a login wall.
//
import SwiftUI
import AppKit
import WebKit

// MARK: - Tab

/// One tab: a WKWebView plus its state mirrored for SwiftUI. The web view
/// has to outlive view updates (an NSViewRepresentable rebuild would reload
/// the page on every toolbar change), so it lives here, not in the view.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView

    /// What the address field shows. Follows the page while it navigates;
    /// the user's typing takes over until they submit or the page moves.
    @Published var addressText = ""
    @Published var title = ""
    @Published var favicon: NSImage?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    /// A failed load, shown above the page. Cleared by the next navigation.
    @Published var lastError: String?
    /// A one-line note that isn't an error - "saved to Downloads".
    @Published var notice: String?
    /// Nothing loaded yet: the new-tab page, with the address field focused.
    @Published private(set) var isBlank = true
    /// The last URL asked for via load() - known before WebKit has started
    /// the navigation, which is what the session-restore match needs.
    private(set) var requestedURL: URL?
    /// The tab Start opened for the website in Settings. Remembered across
    /// launches so the next Start selects it instead of opening the same
    /// site again - redirects mean its URL rarely matches the setting.
    var openedFromSettings = false

    // Find in page (⌘F). WebKit highlights and scrolls to the match
    // itself; all that is ours is the bar and whether the last search hit.
    @Published var isFinding = false
    @Published var findText = ""
    @Published var findMatched: Bool?

    // Address suggestions - the dropdown under the field while typing.
    /// Mirrors the field's focus; nothing is suggested to an unfocused field.
    @Published var addressFocused = false {
        didSet { if !addressFocused { dismissSuggestions() } }
    }
    @Published private(set) var suggestions: [Suggestion] = []
    @Published var highlightedSuggestion: Int?
    private var suggestionTask: Task<Void, Never>?
    /// The address as the PAGE last set it. Suggestions appear only once
    /// the field differs from this - focus alone, or a navigation while
    /// focused, must not pop a list of completions for the current URL.
    private var addressFromPage = ""

    var suggestionsVisible: Bool { addressFocused && !suggestions.isEmpty }

    struct Suggestion: Identifiable, Hashable {
        enum Kind { case search, history }
        let kind: Kind
        let text: String
        let detail: String?
        let url: URL?
        var id: String { "\(kind)|\(text)|\(url?.absoluteString ?? "")" }
    }

    /// Wired by BrowserModel: target="_blank" / window.open ask for a tab,
    /// ⌘-click asks for a background tab, window.close asks for this one to
    /// go, title changes reach the window title, URL changes update the
    /// saved session.
    var openInNewTab: ((WKWebViewConfiguration) -> BrowserTab)?
    var openInBackgroundTab: ((URL) -> Void)?
    var requestClose: (() -> Void)?
    var titleChanged: (() -> Void)?
    var urlChanged: (() -> Void)?

    private var observers: [NSKeyValueObservation] = []

    /// One configuration for every tab: they share the on-disk cookie jar
    /// and a process pool, exactly like tabs in any browser.
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Google's sign-in refuses the bare WebKit user agent ("this browser
        // or app may not be secure"). Appending Safari's product token makes
        // the UA read exactly like Safari's, which it is, engine-wise.
        configuration.applicationNameForUserAgent = "Version/17.4 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    /// `configuration` is the one WebKit hands over for a page-opened tab -
    /// it MUST be used for that web view, or the opener loses its handle
    /// (OAuth pop-ups post their result back through it).
    init(configuration: WKWebViewConfiguration? = nil) {
        webView = WKWebView(frame: .zero, configuration: configuration ?? Self.makeConfiguration())
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        // KVO is the only feed for these; WKNavigationDelegate has no
        // progress or title callbacks. WKWebView posts on the main thread.
        observers = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    let text = view.url?.absoluteString ?? ""
                    self?.addressFromPage = text
                    self?.addressText = text
                    if let url = view.url {
                        self?.isBlank = false
                        // Recorded at the URL change, not at didFinish: a
                        // single-page app moving between documents never
                        // "finishes" a navigation, but it does change URL.
                        BrowserHistory.shared.record(url: url, title: view.title ?? "")
                    }
                    self?.urlChanged?()
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.title = view.title ?? ""
                    self?.titleChanged?()
                    if let url = view.url {
                        BrowserHistory.shared.updateTitle(view.title ?? "", for: url)
                    }
                }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
        ]
    }

    /// What the tab chip and the window title show.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let host = webView.url?.host { return host }
        return isBlank ? "New Tab" : "Loading\u{2026}"
    }

    func load(_ url: URL) {
        lastError = nil
        notice = nil
        isBlank = false
        requestedURL = url
        webView.load(URLRequest(url: url))
    }

    /// The address field was submitted. An address loads (same
    /// normalisation as the Settings field, so "docs.google.com" works);
    /// anything else - a word, a phrase - is a search, as in every browser.
    func go() {
        let typed = AppCatalog.sanitizedURLText(addressText)
        guard !typed.isEmpty else { return }
        dismissSuggestions()
        if Self.looksLikeAddress(typed), let url = AppCatalog.normalizedWebURL(from: typed) {
            load(url)
            return
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: typed)]
        if let url = components.url { load(url) }
    }

    private static func looksLikeAddress(_ typed: String) -> Bool {
        typed.contains("://")
            || typed.hasPrefix("localhost")
            || (!typed.contains(" ") && typed.contains("."))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { lastError = nil; webView.reload() }
    func stop() { webView.stopLoading() }

    /// ⌘+ / ⌘- / ⌘0, in Safari's steps.
    func zoom(by factor: CGFloat) {
        webView.pageZoom = min(max(webView.pageZoom * factor, 0.5), 3.0)
    }
    func resetZoom() { webView.pageZoom = 1 }

    /// ⌘P. The print operation needs the view's frame set by hand -
    /// WKWebView returns one with a zero frame and prints blank pages.
    func printPage() {
        guard webView.url != nil else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// The escape hatch for the rare page that refuses WebKit.
    func openInDefaultBrowser() {
        if let url = webView.url { NSWorkspace.shared.open(url) }
    }

    // MARK: Address suggestions

    /// Called on every edit while the field is focused. History matches
    /// show at once; the search engine's completions follow 150ms after
    /// the last keystroke, and only when the setting allows the request.
    func addressEdited() {
        suggestionTask?.cancel()
        highlightedSuggestion = nil
        let typed = addressText.trimmingCharacters(in: .whitespaces)
        guard addressFocused, !typed.isEmpty, addressText != addressFromPage else {
            suggestions = []
            return
        }
        suggestions = localSuggestions(for: typed)
        guard BrowserWindowController.searchSuggestions else { return }
        suggestionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, self.addressFocused else { return }
            let remote = await Self.googleSuggestions(for: typed)
            // The field moved on while the request was in flight.
            guard !Task.isCancelled,
                  self.addressText.trimmingCharacters(in: .whitespaces) == typed else { return }
            let completions = remote
                .filter { $0.caseInsensitiveCompare(typed) != .orderedSame }
                .prefix(5)
                .map { Suggestion(kind: .search, text: $0, detail: nil, url: nil) }
            self.suggestions = self.localSuggestions(for: typed) + completions
        }
    }

    /// The typed text itself first (open it, or search for it), then the
    /// three most recent history entries that mention it.
    private func localSuggestions(for typed: String) -> [Suggestion] {
        var list = [Suggestion(kind: .search,
                               text: typed,
                               detail: Self.looksLikeAddress(typed) ? "Open" : "Search Google",
                               url: nil)]
        // One row per distinct title+host: two Google searches for the same
        // words differ only in the query string and read as a duplicate.
        var seen = Set<String>()
        for entry in BrowserHistory.shared.matching(typed) where seen.insert("\(entry.displayTitle)|\(entry.host)").inserted {
            list.append(Suggestion(kind: .history, text: entry.displayTitle, detail: entry.host, url: URL(string: entry.url)))
            if seen.count == 3 { break }
        }
        return list
    }

    /// Google's completion endpoint, the same one Chrome and Firefox use.
    /// `client=firefox` returns plain JSON: `[query, [completion, ...]]`.
    nonisolated private static func googleSuggestions(for query: String) async -> [String] {
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        components.queryItems = [URLQueryItem(name: "client", value: "firefox"),
                                 URLQueryItem(name: "q", value: query)]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count > 1,
              let completions = json[1] as? [String] else { return [] }
        return completions
    }

    func accept(_ suggestion: Suggestion) {
        if let url = suggestion.url {
            load(url)
        } else {
            addressText = suggestion.text
            go()
        }
        dismissSuggestions()
        addressFocused = false
    }

    func acceptHighlightedSuggestion() -> Bool {
        guard let index = highlightedSuggestion, suggestions.indices.contains(index) else { return false }
        accept(suggestions[index])
        return true
    }

    /// ↓ from nothing lands on the first row, ↑ from nothing on the last;
    /// both wrap.
    func moveHighlight(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let count = suggestions.count
        let current = highlightedSuggestion ?? (delta > 0 ? -1 : 0)
        highlightedSuggestion = (current + delta + count) % count
    }

    func dismissSuggestions() {
        suggestionTask?.cancel()
        suggestions = []
        highlightedSuggestion = nil
    }

    // MARK: Find in page

    func showFind() { isFinding = true }

    func hideFind() {
        isFinding = false
        findMatched = nil
    }

    /// Typing searches forward from the current match; Return / ⌘G go to
    /// the next, ⇧Return / ⌘⇧G to the previous. Wraps at either end.
    func findNext() { find(backwards: false) }
    func findPrevious() { find(backwards: true) }

    private func find(backwards: Bool) {
        guard !findText.isEmpty else { findMatched = nil; return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(findText, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated { self?.findMatched = result.matchFound }
        }
    }

    // MARK: Favicon

    /// Asks the page for its declared icon, falling back to /favicon.ico.
    /// Cached per icon URL, so ten Wikipedia tabs fetch one image.
    private func fetchFavicon() {
        guard let pageURL = webView.url, let host = pageURL.host else { return }
        let script = "(function(){var l=document.querySelector('link[rel~=\"icon\"]');return l?l.href:null})()"
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            MainActor.assumeIsolated {
                let declared = (result as? String).flatMap(URL.init(string:))
                let fallback = URL(string: "\(pageURL.scheme ?? "https")://\(host)/favicon.ico")
                guard let iconURL = declared ?? fallback else { return }
                FaviconCache.shared.image(for: iconURL) { [weak self] image in
                    // The tab may have moved on to another site meanwhile.
                    guard let self, self.webView.url?.host == host else { return }
                    self.favicon = image
                }
            }
        }
    }
}

// MARK: Navigation

extension BrowserTab: WKNavigationDelegate {

    /// ⌘-click on a link opens it in a background tab, as in every browser
    /// - the results page the teacher is scanning stays put.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           let url = navigationAction.request.url,
           let openInBackgroundTab {
            openInBackgroundTab(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastError = nil
        notice = nil
        favicon = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        fetchFavicon()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    /// Anything WebKit can't render inline (a PDF it can, a .docx it can't)
    /// becomes a download instead of a blank page.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        // -999 is our own cancellation (a new load superseding the old one);
        // 102 is WebKit stepping aside for a download. Neither is a failure
        // the teacher can act on.
        if nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        lastError = nsError.localizedDescription
    }
}

// MARK: Downloads

extension BrowserTab: WKDownloadDelegate {

    /// Straight into ~/Downloads with a unique name - the same place every
    /// other browser puts it, so the teacher's habits carry over.
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            completionHandler(nil)
            return
        }
        var candidate = folder.appendingPathComponent(suggestedFilename)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        }
        completionHandler(candidate)
    }

    func downloadDidFinish(_ download: WKDownload) {
        notice = "Saved to Downloads."
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        lastError = "Download failed: \(error.localizedDescription)"
    }
}

// MARK: Page-initiated UI

extension BrowserTab: WKUIDelegate {

    /// target="_blank" and window.open open a new tab next to this one,
    /// built on the configuration WebKit supplies so the opener keeps its
    /// handle to the new page.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let openInNewTab else { return nil }
        let tab = openInNewTab(configuration)
        if let url = navigationAction.request.url, !url.absoluteString.isEmpty {
            tab.load(url)
        }
        return tab.webView
    }

    /// window.close() - a pop-up that has finished its job.
    func webViewDidClose(_ webView: WKWebView) {
        requestClose?()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page asks"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page asks"
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}

// MARK: - Favicon cache

/// In-memory, per icon URL, for the life of the app. Small images, a few
/// dozen sites a day - nothing worth writing to disk.
@MainActor
final class FaviconCache {
    static let shared = FaviconCache()

    private var images: [URL: NSImage] = [:]
    private var waiting: [URL: [(NSImage?) -> Void]] = [:]

    func image(for url: URL, completion: @escaping (NSImage?) -> Void) {
        if let image = images[url] { completion(image); return }
        if waiting[url] != nil { waiting[url]?.append(completion); return }
        waiting[url] = [completion]
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            image?.size = NSSize(width: 16, height: 16)
            Task { @MainActor in
                if let image { self.images[url] = image }
                self.waiting.removeValue(forKey: url)?.forEach { $0(image) }
            }
        }.resume()
    }
}

// MARK: - Window model

/// The tabs of the one browser window, and the keyboard shortcuts that
/// act on them.
@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var selectedID: BrowserTab.ID? {
        didSet { onSelectedTitleChange?(selected?.displayTitle ?? "") }
    }
    /// Bumped to ask the view to focus the address field (⌘L, new tab).
    @Published var addressFocusRequest = 0
    /// Bumped to ask the view to focus the find field (⌘F).
    @Published var findFocusRequest = 0
    /// The history popover (⌘Y).
    @Published var historyShown = false
    /// ⌘⇧T brings these back, most recent first. Ten is plenty.
    @Published private(set) var recentlyClosed: [URL] = []

    var onSelectedTitleChange: ((String) -> Void)?
    var onLastTabClosed: (() -> Void)?
    /// Tabs opened, closed or navigated - the saved session is stale.
    var onTabsChanged: (() -> Void)?

    var selected: BrowserTab? { tabs.first { $0.id == selectedID } }

    /// What to bring back next launch: every tab's current page, in order.
    var sessionURLs: [String] {
        tabs.compactMap { ($0.webView.url ?? $0.requestedURL)?.absoluteString }
    }

    /// Position of the Settings-website tab within `sessionURLs`, if open.
    var configuredTabIndex: Int? {
        tabs.firstIndex { $0.openedFromSettings && ($0.webView.url ?? $0.requestedURL) != nil }
    }

    var configuredTab: BrowserTab? { tabs.first { $0.openedFromSettings } }

    /// Marks `tab` as the Settings-website tab, and nothing else.
    func markConfigured(_ tab: BrowserTab) {
        for other in tabs { other.openedFromSettings = (other.id == tab.id) }
        onTabsChanged?()
    }

    /// New tabs open next to the current one, as in every browser, so a
    /// link opened from the reading doc sits beside it, not at the far end.
    @discardableResult
    func newTab(configuration: WKWebViewConfiguration? = nil,
                url: URL? = nil,
                after: BrowserTab? = nil,
                select: Bool = true) -> BrowserTab {
        let tab = configuration.map { BrowserTab(configuration: $0) } ?? BrowserTab()
        wire(tab)
        if let after, let index = tabs.firstIndex(where: { $0.id == after.id }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if let url { tab.load(url) }
        if select {
            selectedID = tab.id
            if url == nil { addressFocusRequest += 1 }
        }
        onTabsChanged?()
        return tab
    }

    private func wire(_ tab: BrowserTab) {
        tab.openInNewTab = { [weak self, weak tab] configuration in
            guard let self else { return BrowserTab(configuration: configuration) }
            return self.newTab(configuration: configuration, after: tab)
        }
        tab.openInBackgroundTab = { [weak self, weak tab] url in
            self?.newTab(url: url, after: tab, select: false)
        }
        tab.requestClose = { [weak self, weak tab] in
            if let tab { self?.close(tab) }
        }
        tab.titleChanged = { [weak self, weak tab] in
            guard let self, let tab, tab.id == self.selectedID else { return }
            self.onSelectedTitleChange?(tab.displayTitle)
        }
        tab.urlChanged = { [weak self] in
            self?.onTabsChanged?()
        }
    }

    func select(_ tab: BrowserTab) { selectedID = tab.id }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedID = tabs[index].id
    }

    func selectNext() { step(by: 1) }
    func selectPrevious() { step(by: -1) }

    private func step(by delta: Int) {
        guard let selectedID, let index = tabs.firstIndex(where: { $0.id == selectedID }), !tabs.isEmpty else { return }
        self.selectedID = tabs[(index + delta + tabs.count) % tabs.count].id
    }

    /// Closing the selected tab moves to its right-hand neighbour (the
    /// left one when it was last), matching Safari and Chrome. Closing the
    /// last tab closes the window.
    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.stop()
        if let url = tab.webView.url ?? tab.requestedURL {
            recentlyClosed.insert(url, at: 0)
            if recentlyClosed.count > 10 { recentlyClosed.removeLast() }
        }
        tabs.remove(at: index)
        onTabsChanged?()
        if tabs.isEmpty {
            selectedID = nil
            onLastTabClosed?()
            return
        }
        if selectedID == tab.id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeSelected() {
        if let selected { close(selected) }
    }

    func reopenClosedTab() {
        guard !recentlyClosed.isEmpty else { return }
        let url = recentlyClosed.removeFirst()
        newTab(url: url, after: selected)
    }

    func showFind() {
        selected?.showFind()
        findFocusRequest += 1
    }

    // MARK: Shortcuts

    /// The browser shortcuts, handled in one place. A key monitor on the
    /// window routes here before the menu bar or the text field see the
    /// event, so ⌘W closes a tab rather than the window and ⌘L works from
    /// inside the page. Returns whether the event was consumed.
    func handle(keyDown event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        // The suggestion dropdown owns the arrow keys, Return and Esc while
        // it is showing.
        if let selected, selected.suggestionsVisible, flags.isEmpty {
            switch event.keyCode {
            case 125: selected.moveHighlight(by: 1); return true  // ↓
            case 126: selected.moveHighlight(by: -1); return true // ↑
            case 36, 76: if selected.acceptHighlightedSuggestion() { return true } // Return / Enter
            case 53: selected.dismissSuggestions(); return true  // Esc
            default: break
            }
        }

        // Esc dismisses whatever is on top: the history popover, then the
        // find bar. Nothing else, so the page keeps its own Esc.
        if event.keyCode == 53, flags.isEmpty {
            if historyShown { historyShown = false; return true }
            if let selected, selected.isFinding { selected.hideFind(); return true }
            return false
        }

        // ⌃Tab / ⌃⇧Tab: next / previous tab.
        if event.keyCode == 48, flags.contains(.control) {
            flags.contains(.shift) ? selectPrevious() : selectNext()
            return true
        }

        guard flags.contains(.command), !flags.contains(.control) else { return false }
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)

        // ⌘⌥→ / ⌘⌥← and ⌘⇧] / ⌘⇧[: next / previous tab.
        if option, !shift {
            if event.keyCode == 124 { selectNext(); return true }
            if event.keyCode == 123 { selectPrevious(); return true }
        }
        if shift, !option {
            if chars == "}" || chars == "]" { selectNext(); return true }
            if chars == "{" || chars == "[" { selectPrevious(); return true }
        }

        guard !option else { return false }

        // ⌘1…⌘8 select that tab; ⌘9 the last one.
        if !shift, chars.count == 1, let digit = Int(chars), (1...9).contains(digit) {
            select(index: digit == 9 ? tabs.count - 1 : digit - 1)
            return true
        }

        switch chars.lowercased() {
        case "t" where !shift: newTab(); return true
        case "t" where shift: reopenClosedTab(); return true
        case "w" where !shift: closeSelected(); return true
        case "l" where !shift: addressFocusRequest += 1; return true
        case "f" where !shift: showFind(); return true
        case "g": shift ? selected?.findPrevious() : selected?.findNext(); return true
        case "y" where !shift: historyShown.toggle(); return true
        case "p" where !shift: selected?.printPage(); return true
        case "r" where !shift: selected?.reload(); return true
        case "." where !shift: selected?.stop(); return true
        case "[" where !shift: selected?.goBack(); return true
        case "]" where !shift: selected?.goForward(); return true
        case "=", "+": selected?.zoom(by: 1.1); return true
        case "-" where !shift: selected?.zoom(by: 1 / 1.1); return true
        case "0" where !shift: selected?.resetZoom(); return true
        default: return false
        }
    }
}

// MARK: - Views

/// Hosts whichever tab's WKWebView is selected. A container rather than
/// the web view itself, so switching tabs swaps a subview instead of
/// tearing down and rebuilding the representable.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(webView, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== webView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        install(webView, in: container)
    }

    private func install(_ view: WKWebView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// Reports a view's frame in SCREEN coordinates, and its window, whenever
/// AppKit lays it out. The suggestion panel is a separate window, so it
/// has to be placed in AppKit's space, not SwiftUI's.
private struct AnchorReporter: NSViewRepresentable {
    let onChange: (NSRect, NSWindow?) -> Void

    func makeNSView(context: Context) -> ReporterView {
        let view = ReporterView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReporterView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReporterView: NSView {
        var onChange: ((NSRect, NSWindow?) -> Void)?

        override func layout() {
            super.layout()
            report()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        func report() {
            guard let window else { onChange?(.zero, nil); return }
            let inWindow = convert(bounds, to: nil)
            onChange?(window.convertToScreen(inWindow), window)
        }
    }
}

/// Toolbar chrome shared by every icon button: a 28×24 target (the icon
/// alone was 6×11, which is not a button, it is a dare) and a hover wash.
private struct ToolbarIcon: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 24)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

private extension View {
    func toolbarIcon() -> some View { modifier(ToolbarIcon()) }
}

struct BrowserWindowView: View {
    @ObservedObject var model: BrowserModel
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            if let tab = model.selected {
                AddressBar(model: model, tab: tab, focused: $addressFocused)
                if tab.isFinding {
                    Divider()
                    FindBar(tab: tab, focused: $findFocused)
                }
                Divider()
                TabContent(tab: tab)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        // The window is full-size-content-view; SwiftUI still reserves the
        // title bar as safe area. The tab strip is meant to live there.
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: model.addressFocusRequest) { _, _ in addressFocused = true }
        .onChange(of: model.findFocusRequest) { _, _ in findFocused = true }
    }
}

/// The row of tabs, living in the title bar beside the traffic lights.
/// Tabs share the width equally, between 72pt and 200pt each, and scroll
/// once even 72pt no longer fits. The selected tab wears the toolbar's
/// colour so the two read as one surface.
private struct TabStrip: View {
    @ObservedObject var model: BrowserModel

    /// Room for the close/minimise/zoom buttons at the left of a
    /// full-size-content-view window.
    static let trafficLightInset: CGFloat = 76
    static let height: CGFloat = 36

    var body: some View {
        GeometryReader { geometry in
            let count = CGFloat(max(model.tabs.count, 1))
            let available = geometry.size.width - Self.trafficLightInset - 8 - 36
            let width = min(200, max(72, available / count))
            HStack(alignment: .bottom, spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(model.tabs) { tab in
                            TabChip(tab: tab,
                                    selected: tab.id == model.selectedID,
                                    width: width,
                                    select: { model.select(tab) },
                                    close: { model.close(tab) })
                        }
                    }
                    // A horizontal ScrollView centres content narrower than
                    // itself; one tab then floated mid-strip (AX: x=682).
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { model.newTab() } label: {
                    Image(systemName: "plus")
                        .toolbarIcon()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New Tab")
                .help("New Tab (\u{2318}T)")
                .padding(.bottom, 2)
                Spacer(minLength: 0)
            }
            .padding(.leading, Self.trafficLightInset)
            .padding(.trailing, 8)
            .frame(height: geometry.size.height, alignment: .bottom)
        }
        .frame(height: Self.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct TabChip: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let width: CGFloat
    let select: () -> Void
    let close: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if tab.isLoading {
                ProgressView().controlSize(.mini)
                    .frame(width: 16, height: 16)
            } else if let favicon = tab.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: tab.isBlank ? "plus.square.dashed" : "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }
            Text(tab.displayTitle)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(selected ? .primary : .secondary)
            Spacer(minLength: 0)
            if selected || hovering {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close Tab")
                .help("Close Tab (\u{2318}W)")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 30)
        .background(
            selected ? Color(nsColor: .controlBackgroundColor)
                     : (hovering ? Color.primary.opacity(0.06) : Color.clear),
            in: UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct AddressBar: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: BrowserTab
    var focused: FocusState<Bool>.Binding

    @State private var fieldAnchor: NSRect = .zero
    @State private var fieldWindow: NSWindow?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: tab.goBack) {
                Image(systemName: "chevron.left").toolbarIcon()
            }
            .disabled(!tab.canGoBack)
            .accessibilityLabel("Back")
            .help("Back (\u{2318}[)")
            .contextMenu { historyMenu(tab.webView.backForwardList.backList.reversed()) }

            Button(action: tab.goForward) {
                Image(systemName: "chevron.right").toolbarIcon()
            }
            .disabled(!tab.canGoForward)
            .accessibilityLabel("Forward")
            .help("Forward (\u{2318}])")
            .contextMenu { historyMenu(tab.webView.backForwardList.forwardList) }

            if tab.isLoading {
                Button(action: tab.stop) {
                    Image(systemName: "xmark").toolbarIcon()
                }
                .accessibilityLabel("Stop")
                .help("Stop (\u{2318}.)")
            } else {
                Button(action: tab.reload) {
                    Image(systemName: "arrow.clockwise").toolbarIcon()
                }
                .accessibilityLabel("Reload")
                .help("Reload (\u{2318}R)")
            }

            TextField("Address", text: addressBinding, prompt: Text("Search or enter a website"))
                .textFieldStyle(.roundedBorder)
                .focused(focused)
                .padding(.horizontal, 4)
                .onSubmit {
                    tab.go()
                    focused.wrappedValue = false
                }
                .onChange(of: focused.wrappedValue) { _, isFocused in
                    tab.addressFocused = isFocused
                    // Select, never suggest: typing is what opens the list.
                    if isFocused { selectAllInField() }
                }
                // accept() drops focus from the model side (Return on a
                // highlighted row never reaches the field).
                .onChange(of: tab.addressFocused) { _, isFocused in
                    if !isFocused { focused.wrappedValue = false }
                }
                .onChange(of: tab.addressText) { _, _ in tab.addressEdited() }
                .background(AnchorReporter { rect, window in
                    fieldAnchor = rect
                    fieldWindow = window
                })

            Menu {
                Button("New Tab") { model.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Reopen Closed Tab") { model.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(model.recentlyClosed.isEmpty)
                Divider()
                Button("Find in Page\u{2026}") { model.showFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("History\u{2026}") { model.historyShown = true }
                    .keyboardShortcut("y", modifiers: .command)
                Divider()
                Button("Zoom In") { tab.zoom(by: 1.1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { tab.zoom(by: 1 / 1.1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { tab.resetZoom() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Button("Print\u{2026}") { tab.printPage() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(tab.isBlank)
                Button("Open in Default Browser") { tab.openInDefaultBrowser() }
                    .disabled(tab.isBlank)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // On the Menu, not its label: the label frame does not grow the
            // hit area (it measured 20x14).
            .frame(width: 28, height: 24)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("More")
            .help("More")
            .popover(isPresented: $model.historyShown, arrowEdge: .bottom) {
                HistoryView { url in
                    tab.load(url)
                    model.historyShown = false
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
        // The dropdown is its own window (SuggestionPanel), placed under the
        // field in screen coordinates: nothing in this view hierarchy can
        // draw over the WKWebView below, and a SwiftUI overlay hung the list
        // upwards off the top of the screen.
        .onChange(of: tab.suggestionsVisible) { _, _ in updatePanel() }
        .onChange(of: tab.suggestions.count) { _, _ in updatePanel() }
        .onChange(of: fieldAnchor) { _, _ in updatePanel() }
        .onDisappear { SuggestionPanel.shared.hide() }
    }

    /// The URL without its "https://", "www." and trailing slash while
    /// nobody is editing it - what every browser shows. Focus reveals the
    /// real thing, and edits always go to the real thing.
    private var addressBinding: Binding<String> {
        Binding(
            get: { focused.wrappedValue ? tab.addressText : Self.prettified(tab.addressText) },
            set: { if focused.wrappedValue { tab.addressText = $0 } }
        )
    }

    static func prettified(_ address: String) -> String {
        var text = address
        if text.hasPrefix("https://") { text.removeFirst("https://".count) }
        if text.hasPrefix("www.") { text.removeFirst("www.".count) }
        if text.hasSuffix("/"), !text.dropLast().contains("/") { text.removeLast() }
        return text
    }

    /// Focus selects the whole address, so typing replaces it - the
    /// behaviour every browser has and SwiftUI's field does not.
    private func selectAllInField() {
        DispatchQueue.main.async {
            (fieldWindow?.firstResponder as? NSTextView)?.selectAll(nil)
        }
    }

    private func updatePanel() {
        guard let window = fieldWindow else { SuggestionPanel.shared.hide(); return }
        SuggestionPanel.shared.update(tab: tab, anchor: fieldAnchor, parent: window)
    }

    /// Right-click on Back / Forward: the pages in that direction, nearest
    /// first, so "the results page three hops ago" is one click.
    @ViewBuilder
    private func historyMenu(_ items: [WKBackForwardListItem]) -> some View {
        if items.isEmpty {
            Text("No pages")
        } else {
            ForEach(Array(items.prefix(12).enumerated()), id: \.offset) { _, item in
                Button(item.title?.isEmpty == false ? item.title! : (item.url.host ?? item.url.absoluteString)) {
                    tab.webView.go(to: item)
                }
            }
        }
    }
}

/// What the address bar proposes while typing: the typed text (open or
/// search), recent history that mentions it, then the engine's
/// completions. Hover or ↑/↓ highlights, click or Return accepts.
struct SuggestionList: View {
    @ObservedObject var tab: BrowserTab

    static let rowHeight: CGFloat = 28
    static let padding: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tab.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button { tab.accept(suggestion) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: suggestion.kind == .history ? "clock" : "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(suggestion.text)
                            .lineLimit(1)
                        if let detail = suggestion.detail {
                            Text("\u{2014} \(detail)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: Self.rowHeight)
                    .background(index == tab.highlightedSuggestion ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { tab.highlightedSuggestion = index }
                }
            }
        }
        .padding(Self.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
    }

    static func height(forRows rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + padding * 2
    }
}

/// The suggestion dropdown as a borderless child window under the address
/// field - how Safari and Chrome do it. A child window moves with its
/// parent, floats above the WKWebView, and never activates, so the field
/// keeps focus while the mouse is over the rows.
@MainActor
final class SuggestionPanel {
    static let shared = SuggestionPanel()

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var keyObserver: Any?

    func update(tab: BrowserTab, anchor: NSRect, parent: NSWindow) {
        guard tab.suggestionsVisible, anchor.width > 0 else { hide(); return }
        let panel = self.panel ?? makePanel()
        hosting?.rootView = AnyView(SuggestionList(tab: tab).tint(Brand.green))

        let height = SuggestionList.height(forRows: tab.suggestions.count)
        var frame = NSRect(x: anchor.minX, y: anchor.minY - 4 - height, width: anchor.width, height: height)
        if let screen = parent.screen {
            frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)
        }
        panel.setFrame(frame, display: true)
        hosting?.frame = NSRect(origin: .zero, size: frame.size)

        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        panel.contentView = hosting
        self.hosting = hosting
        self.panel = panel
        // Switching apps must not leave a dropdown floating over someone
        // else's window.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow, window == panel.parent else { return }
            MainActor.assumeIsolated { self?.hide() }
        }
        return panel
    }
}

/// Find in page, under the address bar while active. WebKit does the
/// highlighting; this is the field, the two arrows and a "Not found".
private struct FindBar: View {
    @ObservedObject var tab: BrowserTab
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in page", text: $tab.findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .focused(focused)
                .onSubmit { tab.findNext() }
                .onChange(of: tab.findText) { _, _ in tab.findNext() }

            if tab.findMatched == false {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button(action: tab.findPrevious) {
                Image(systemName: "chevron.up").toolbarIcon()
            }
            .disabled(tab.findText.isEmpty)
            .accessibilityLabel("Previous Match")
            .help("Previous (\u{21E7}\u{2318}G)")

            Button(action: tab.findNext) {
                Image(systemName: "chevron.down").toolbarIcon()
            }
            .disabled(tab.findText.isEmpty)
            .accessibilityLabel("Next Match")
            .help("Next (\u{2318}G)")

            Spacer()

            Button("Done") { tab.hideFind() }
                .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// The history popover: a filter field, visits grouped by day, newest
/// first. Clicking a row opens it in the current tab.
private struct HistoryView: View {
    @ObservedObject private var history = BrowserHistory.shared
    @State private var query = ""
    let open: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search history", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            Divider()

            let entries = history.matching(query)
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(query.isEmpty ? "No history yet" : "Nothing matches")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(dayGroups(entries), id: \.label) { group in
                        Section(group.label) {
                            ForEach(group.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("\(history.entries.count) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History") { history.clear() }
                    .disabled(history.entries.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 440, height: 480)
    }

    private func row(_ entry: BrowserHistory.Entry) -> some View {
        Button {
            if let url = URL(string: entry.url) { open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayTitle)
                        .font(.callout)
                        .lineLimit(1)
                    Text(entry.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(entry.visitedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.url)
    }

    private struct DayGroup {
        let label: String
        let entries: [BrowserHistory.Entry]
    }

    /// "Today", "Yesterday", then dates - entries arrive newest first, so
    /// the groups come out in that order too.
    private func dayGroups(_ entries: [BrowserHistory.Entry]) -> [DayGroup] {
        let calendar = Calendar.current
        var groups: [DayGroup] = []
        var current: (day: Date, entries: [BrowserHistory.Entry])?
        for entry in entries {
            let day = calendar.startOfDay(for: entry.visitedAt)
            if let open = current, open.day == day {
                current?.entries.append(entry)
            } else {
                if let open = current { groups.append(DayGroup(label: label(for: open.day), entries: open.entries)) }
                current = (day, [entry])
            }
        }
        if let open = current { groups.append(DayGroup(label: label(for: open.day), entries: open.entries)) }
        return groups
    }

    private func label(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct TabContent: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        VStack(spacing: 0) {
            // A 2pt line, not a spinner: it says how much is left, and it
            // is gone the moment the page is up.
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * (tab.isLoading ? tab.progress : 0))
            }
            .frame(height: 2)
            .opacity(tab.isLoading ? 1 : 0)

            if let error = tab.lastError {
                messageBar(error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            } else if let notice = tab.notice {
                messageBar(notice, systemImage: "checkmark.circle.fill", tint: .secondary)
            }

            ZStack {
                WebViewHost(webView: tab.webView)
                if tab.isBlank { NewTabPage(open: tab.load) }
            }
        }
    }

    private func messageBar(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(text).font(.caption)
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }
}

/// A new tab before anything is typed: the sites visited most recently,
/// one per host, so the morning's regulars are a click away. The field
/// above already has focus, so no instructions.
private struct NewTabPage: View {
    @ObservedObject private var history = BrowserHistory.shared
    let open: (URL) -> Void

    private var recent: [BrowserHistory.Entry] {
        var seen = Set<String>()
        return history.entries.filter { seen.insert($0.host).inserted }.prefix(8).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if recent.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Search or enter a website above")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("Recently visited")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                VStack(spacing: 2) {
                    ForEach(recent) { entry in
                        Button {
                            if let url = URL(string: entry.url) { open(url) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "globe")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.displayTitle).lineLimit(1)
                                    Text(entry.host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(RecentRowHover())
                    }
                }
            }
        }
        .frame(maxWidth: 520)
        .padding(.top, 48)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A quiet hover wash for list-like rows made of plain buttons.
private struct RecentRowHover: View {
    @State private var hovering = false
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(hovering ? Color.primary.opacity(0.06) : Color.clear)
            .onHover { hovering = $0 }
    }
}

// MARK: - Window

/// Same shape as ChatWindowController: one window, kept across close and
/// reopen (`isReleasedWhenClosed = false`) so the tabs and their history
/// survive a Stop/Start.
@MainActor
enum BrowserWindowController {
    private static var window: NSWindow?
    private static var model: BrowserModel?
    private static var keyMonitor: Any?
    /// The Settings website the current session was opened with.
    private static var configuredURLString: String?

    private static let defaultTitle = "Greenroom Browser"

    /// Settings → Layout → "Reopen last session's tabs on Start". Kept
    /// current by CoordinatorController; read on the first show() after
    /// launch, which is the only moment there is a session to bring back.
    static var restoresTabs = true
    /// Settings → Layout → "Suggest searches as you type". Off keeps the
    /// address bar to local history only - no request leaves the Mac.
    static var searchSuggestions = true
    private static let sessionKey = "browserLastSessionTabs"
    /// Which saved tab was opened for the Settings website, and what that
    /// website was at the time - so a changed setting opens the new site
    /// rather than re-selecting the old tab.
    private static let configuredIndexKey = "browserLastSessionConfiguredIndex"
    private static let configuredURLKey = "browserLastSessionConfiguredURL"

    static var isOpen: Bool { window?.isVisible ?? false }

    /// Whether a window is ours. The title is the page's, so it can say
    /// anything - "Zoom", "Meeting", even "Greenroom" - and every place that
    /// sorts NSApp.windows by title has to ask this first.
    static func owns(_ candidate: NSWindow) -> Bool { candidate == window }

    /// Opens the browser tiled to the main pane. `urlString` opens in a new
    /// tab when the window is new or was closed; a window already on screen
    /// keeps the tabs the teacher has and is only re-tiled and brought
    /// forward - a second press of Start must not throw away where they
    /// were reading.
    static func show(urlString: String, layout: WorkspaceLayout) {
        let model = self.model ?? BrowserModel()
        self.model = model

        let wasVisible = isOpen
        let targetWindow = window ?? makeWindow(model: model)

        if !wasVisible {
            let configured = AppCatalog.normalizedWebURL(from: urlString)
                ?? (model.tabs.isEmpty ? URL(string: AppLinks.site) : nil)

            // A fresh launch with nothing open yet: last time's tabs first
            // (when the setting is on). The tab that was opened for the
            // Settings website keeps that role - as long as the setting still
            // names the same site.
            if model.tabs.isEmpty, restoresTabs {
                let defaults = UserDefaults.standard
                let savedConfiguredURL = defaults.string(forKey: configuredURLKey)
                let savedConfiguredIndex = defaults.object(forKey: configuredIndexKey) as? Int
                for saved in savedSessionURLs() {
                    model.newTab(url: saved, select: false)
                }
                if let index = savedConfiguredIndex, model.tabs.indices.contains(index),
                   savedConfiguredURL == configured?.absoluteString {
                    model.tabs[index].openedFromSettings = true
                }
            }

            // Then the configured page on top - selected, and not opened a
            // second time if a tab already holds it.
            if let configured {
                configuredURLString = configured.absoluteString
                if let existing = model.configuredTab
                    ?? model.tabs.first(where: { $0.requestedURL == configured || $0.webView.url == configured }) {
                    model.markConfigured(existing)
                    model.select(existing)
                } else {
                    model.markConfigured(model.newTab(url: configured))
                }
            } else if model.tabs.isEmpty {
                model.newTab()
            }
        }

        // Frame BEFORE ordering front, unconditionally: reposition(layout:)
        // below skips a hidden window, which is exactly what a brand-new one
        // is at this point - the first cut tiled nothing because of that.
        if let frame = layout.mainPaneNSFrame() {
            targetWindow.setFrame(frame, display: true)
        }
        // Unlike the chat, this IS the window the teacher works in - so it
        // takes focus.
        targetWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Keyboard focus goes to the PAGE, as in every browser. Left alone,
        // AppKit hands a fresh window's first responder to its only text
        // field, and the address bar opened with its dropdown showing.
        if let tab = model.selected, !tab.isBlank {
            targetWindow.makeFirstResponder(tab.webView)
        }
    }

    private static func makeWindow(model: BrowserModel) -> NSWindow {
        let hosting = NSHostingController(rootView: BrowserWindowView(model: model).tint(Brand.green))
        // The layout owns this window's size. Left to SwiftUI, the hosting
        // controller re-fits the window to its preferred size on content
        // changes (a tab strip appearing, say), fighting setFrame.
        hosting.sizingOptions = []
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = defaultTitle
        newWindow.setContentSize(NSSize(width: 960, height: 700))
        newWindow.minSize = NSSize(width: 480, height: 360)
        // Tabs live in the title bar, beside the traffic lights, the way
        // every browser does it: the title is hidden (the selected tab IS
        // the title) but still set, for Mission Control and the app switcher.
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.tabbingMode = .disallowed
        newWindow.isReleasedWhenClosed = false // ARC + close() below manage its lifetime

        model.onSelectedTitleChange = { [weak newWindow] title in
            newWindow?.title = title.isEmpty ? defaultTitle : title
        }
        model.onLastTabClosed = { [weak newWindow] in
            SuggestionPanel.shared.hide()
            newWindow?.close()
        }
        // Saved on every change rather than at quit: a force-quit or a
        // crash then loses nothing, and the write is a handful of strings.
        model.onTabsChanged = {
            let defaults = UserDefaults.standard
            defaults.set(model.sessionURLs, forKey: sessionKey)
            defaults.set(model.configuredTabIndex, forKey: configuredIndexKey)
            defaults.set(configuredURLString, forKey: configuredURLKey)
        }

        // Shortcuts for the whole window in one place - see BrowserModel.handle.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window, event.window == window else { return event }
            return MainActor.assumeIsolated { model.handle(keyDown: event) } ? nil : event
        }

        window = newWindow
        return newWindow
    }

    private static func savedSessionURLs() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: sessionKey) ?? []).compactMap(URL.init(string:))
    }

    /// Re-tiles without touching the page. No-op when not open, matching
    /// the external-app path's "not running" case.
    static func reposition(layout: WorkspaceLayout) {
        guard let window, window.isVisible, let frame = layout.mainPaneNSFrame() else { return }
        window.setFrame(frame, display: true)
    }

    /// The end-of-Start focus hand-off: where an external main app gets
    /// `NSRunningApplication.activate()`, ours comes to the front.
    static func activate() {
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        SuggestionPanel.shared.hide()
        window?.close()
    }
}
