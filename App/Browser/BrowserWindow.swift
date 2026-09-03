//
//  BrowserWindow.swift
//  Greenroom
//
//  Greenroom's own browser for the main pane - a WebKit window the app owns
//  outright, so tiling it is a plain setFrame like the chat window: no
//  Accessibility grant, no Automation prompt, no hunting for another
//  process's window, and never someone's whole tab pile.
//
//  Deliberately the everyday subset of a browser and nothing more: tabs,
//  back/forward/reload, an address bar that also searches, the usual
//  shortcuts, downloads to ~/Downloads. No extensions, no bookmarks, no
//  history view - the external browsers in the picker are for those.
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
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    /// A failed load, shown above the page. Cleared by the next navigation.
    @Published var lastError: String?
    /// A one-line note that isn't an error - "saved to Downloads".
    @Published var notice: String?
    /// Nothing loaded yet: the empty state, with the address field focused.
    @Published private(set) var isBlank = true
    /// The last URL asked for via load() - known before WebKit has started
    /// the navigation, which is what the session-restore match needs.
    private(set) var requestedURL: URL?

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
    /// window.close asks for this one to go, title changes reach the
    /// window title, and URL changes update the saved session.
    var openInNewTab: ((WKWebViewConfiguration) -> BrowserTab)?
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
                    self?.addressText = view.url?.absoluteString ?? ""
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

    // MARK: Address suggestions

    /// Called on every edit while the field is focused. History matches
    /// show at once; the search engine's completions follow 150ms after
    /// the last keystroke, and only when the setting allows the request.
    func addressEdited() {
        suggestionTask?.cancel()
        highlightedSuggestion = nil
        let typed = addressText.trimmingCharacters(in: .whitespaces)
        guard addressFocused, !typed.isEmpty else {
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
        for entry in BrowserHistory.shared.matching(typed).prefix(3) {
            list.append(Suggestion(kind: .history, text: entry.displayTitle, detail: entry.host, url: URL(string: entry.url)))
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

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { lastError = nil; webView.reload() }
    func stop() { webView.stopLoading() }

    /// ⌘+ / ⌘- / ⌘0, in Safari's steps.
    func zoom(by factor: CGFloat) {
        webView.pageZoom = min(max(webView.pageZoom * factor, 0.5), 3.0)
    }
    func resetZoom() { webView.pageZoom = 1 }

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
}

// MARK: Navigation

extension BrowserTab: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastError = nil
        notice = nil
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
        if navigationAction.request.url != nil, !(navigationAction.request.url?.absoluteString.isEmpty ?? true) {
            tab.load(navigationAction.request.url!)
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

    var onSelectedTitleChange: ((String) -> Void)?
    var onLastTabClosed: (() -> Void)?
    /// Tabs opened, closed or navigated - the saved session is stale.
    var onTabsChanged: (() -> Void)?

    var selected: BrowserTab? { tabs.first { $0.id == selectedID } }

    /// What to bring back next launch: every tab's current page, in order.
    var sessionURLs: [String] {
        tabs.compactMap { ($0.webView.url ?? $0.requestedURL)?.absoluteString }
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
        case "w" where !shift: closeSelected(); return true
        case "l" where !shift: addressFocusRequest += 1; return true
        case "f" where !shift: showFind(); return true
        case "g": shift ? selected?.findPrevious() : selected?.findNext(); return true
        case "y" where !shift: historyShown.toggle(); return true
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

struct BrowserWindowView: View {
    @ObservedObject var model: BrowserModel
    @FocusState private var addressFocused: Bool
    @FocusState private var findFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            if let tab = model.selected {
                // Above everything below it, so the suggestion dropdown it
                // hangs draws over the find bar and the page.
                AddressBar(model: model, tab: tab, focused: $addressFocused)
                    .zIndex(1)
                Divider()
                if tab.isFinding {
                    FindBar(tab: tab, focused: $findFocused)
                    Divider()
                }
                TabContent(tab: tab)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onChange(of: model.addressFocusRequest) { _, _ in addressFocused = true }
        .onChange(of: model.findFocusRequest) { _, _ in findFocused = true }
    }
}

/// The row of tabs. Tabs share the width equally, between 72pt and 200pt
/// each, and scroll once even 72pt no longer fits.
private struct TabStrip: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        GeometryReader { geometry in
            let count = CGFloat(max(model.tabs.count, 1))
            let available = geometry.size.width - 16 - 32 // padding + the "+" button
            let width = min(200, max(72, available / count))
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.tabs) { tab in
                            TabChip(tab: tab,
                                    selected: tab.id == model.selectedID,
                                    width: width,
                                    select: { model.select(tab) },
                                    close: { model.close(tab) })
                        }
                    }
                }
                Button { model.newTab() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Tab (\u{2318}T)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: geometry.size.height)
        }
        .frame(height: 32)
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
                }
                .buttonStyle(.borderless)
                .help("Close Tab (\u{2318}W)")
            }
        }
        .padding(.horizontal, 8)
        .frame(width: width, height: 26)
        .background(
            selected ? Color(nsColor: .controlBackgroundColor)
                     : (hovering ? Color.primary.opacity(0.06) : Color.clear),
            in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

private struct AddressBar: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject var tab: BrowserTab
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Button(action: tab.goBack) {
                Image(systemName: "chevron.left")
            }
            .disabled(!tab.canGoBack)
            .help("Back (\u{2318}[)")

            Button(action: tab.goForward) {
                Image(systemName: "chevron.right")
            }
            .disabled(!tab.canGoForward)
            .help("Forward (\u{2318}])")

            TextField("Address", text: $tab.addressText, prompt: Text("Search or enter a website"))
                .textFieldStyle(.roundedBorder)
                .focused(focused)
                .onSubmit {
                    tab.go()
                    focused.wrappedValue = false
                }
                .onChange(of: focused.wrappedValue) { _, isFocused in
                    tab.addressFocused = isFocused
                    if isFocused { tab.addressEdited() }
                }
                // accept() drops focus from the model side (Return on a
                // highlighted row never reaches the field).
                .onChange(of: tab.addressFocused) { _, isFocused in
                    if !isFocused { focused.wrappedValue = false }
                }
                .onChange(of: tab.addressText) { _, _ in tab.addressEdited() }

            if tab.isLoading {
                Button(action: tab.stop) {
                    Image(systemName: "xmark")
                }
                .help("Stop (\u{2318}.)")
            } else {
                Button(action: tab.reload) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload (\u{2318}R)")
            }

            Button { model.showFind() } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Find in Page (\u{2318}F)")

            Button { model.historyShown.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .help("History (\u{2318}Y)")
            .popover(isPresented: $model.historyShown, arrowEdge: .bottom) {
                HistoryView { url in
                    tab.load(url)
                    model.historyShown = false
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        // The dropdown hangs off the bar's bottom edge: its bottom guide is
        // redefined as its top, so "align bottoms" puts its top on our bottom.
        .overlay(alignment: .bottom) {
            if tab.suggestionsVisible {
                SuggestionList(tab: tab)
                    .padding(.horizontal, 12)
                    .alignmentGuide(.bottom) { $0[.top] }
            }
        }
    }
}

/// What the address bar proposes while typing: the typed text (open or
/// search), recent history that mentions it, then the engine's
/// completions. Hover or ↑/↓ highlights, click or Return accepts.
private struct SuggestionList: View {
    @ObservedObject var tab: BrowserTab

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
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
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
                Image(systemName: "chevron.up")
            }
            .disabled(tab.findText.isEmpty)
            .help("Previous (\u{21E7}\u{2318}G)")

            Button(action: tab.findNext) {
                Image(systemName: "chevron.down")
            }
            .disabled(tab.findText.isEmpty)
            .help("Next (\u{2318}G)")

            Spacer()

            Button("Done") { tab.hideFind() }
                .help("Close (Esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
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
                if tab.isBlank { emptyState }
            }
        }
    }

    /// A new tab before anything is typed. Blank white read as "broken".
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("Search or enter a website")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("\u{2318}L jumps to the address bar.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
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

// MARK: - Window

/// Same shape as ChatWindowController: one window, kept across close and
/// reopen (`isReleasedWhenClosed = false`) so the tabs and their history
/// survive a Stop/Start.
@MainActor
enum BrowserWindowController {
    private static var window: NSWindow?
    private static var model: BrowserModel?
    private static var keyMonitor: Any?

    private static let defaultTitle = "Greenroom Browser"

    /// Settings → Layout → "Reopen last session's tabs on Start". Kept
    /// current by CoordinatorController; read on the first show() after
    /// launch, which is the only moment there is a session to bring back.
    static var restoresTabs = true
    /// Settings → Layout → "Suggest searches as you type". Off keeps the
    /// address bar to local history only - no request leaves the Mac.
    static var searchSuggestions = true
    private static let sessionKey = "browserLastSessionTabs"

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
            // A fresh launch with nothing open yet: last time's tabs first
            // (when the setting is on), then the configured page on top -
            // selected, and not duplicated if it is already among them.
            if model.tabs.isEmpty, restoresTabs {
                for saved in savedSessionURLs() {
                    model.newTab(url: saved, select: false)
                }
            }
            let configured = AppCatalog.normalizedWebURL(from: urlString)
                ?? (model.tabs.isEmpty ? URL(string: AppLinks.site) : nil)
            if let configured {
                if let existing = model.tabs.first(where: { $0.requestedURL == configured || $0.webView.url == configured }) {
                    model.select(existing)
                } else {
                    model.newTab(url: configured)
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
        newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        newWindow.tabbingMode = .disallowed
        newWindow.isReleasedWhenClosed = false // ARC + close() below manage its lifetime

        model.onSelectedTitleChange = { [weak newWindow] title in
            newWindow?.title = title.isEmpty ? defaultTitle : title
        }
        model.onLastTabClosed = { [weak newWindow] in
            newWindow?.close()
        }
        // Saved on every change rather than at quit: a force-quit or a
        // crash then loses nothing, and the write is a handful of strings.
        model.onTabsChanged = {
            UserDefaults.standard.set(model.sessionURLs, forKey: sessionKey)
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
        window?.close()
    }
}
