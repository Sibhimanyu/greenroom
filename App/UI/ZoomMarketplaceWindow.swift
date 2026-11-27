//
//  ZoomMarketplaceWindow.swift
//  Greenroom
//
//  The "Zoom window" (docs/specs/zoom-setup-assist.md, R1, R5, R6, R8): Zoom
//  App Marketplace in a normal macOS window beside the setup guide. It uses the
//  default website data store (the sign-in is kept in Greenroom, separate from
//  Safari, until Zoom ends it) and a Safari user agent; links that ask for a
//  new window load in place. Its toolbar: Back, Forward, Reload, where you
//  are, Tips, Sign out of Zoom and Open in Safari.
//
//  Greenroom never clicks or submits anything on Zoom's pages. It does two
//  things there: draw the coach (ZoomCoachScript, pointer-events none) and, on
//  the two credential pages only, read the key inputs (ZoomKeyReaderScript).
//  Values go straight to `onKeys`; they are not logged, not put in the title
//  and not kept here. The window's title is always "Zoom".
//
import AppKit
import SwiftUI
import WebKit

@MainActor
final class ZoomMarketplaceWindow: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate,
                                   WKScriptMessageHandler, NSWindowDelegate {
    static let shared = ZoomMarketplaceWindow()

    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    // What the toolbar shows.
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var location = ""
    @Published private(set) var loadFailed = false
    /// The coach on or off for this setup; "Hide tips" and the toolbar's Tips both set it.
    @Published var tipsOn = true { didSet { if tipsOn != oldValue { refresh() } } }

    /// Told when the window shows a different page (nil: not a Marketplace page, or closed).
    var onPage: (ZoomMarketplacePage?) -> Void = { _ in }
    /// Told what the credential page's inputs hold. Never logged.
    var onKeys: (ZoomMarketplacePage, [ZoomKeyField: String]) -> Void = { _, _ in }
    /// Whether the keys on this page are already in Greenroom (the coach says "Got it").
    var keysFilled: () -> Bool = { false }
    /// Whether a part has keys filled in but no remembered app ID (the coach asks which app).
    var needsApp: (ZoomGuidePart) -> Bool = { _ in false }

    private var window: NSWindow?
    private var webView: WKWebView?
    private var observers: [NSKeyValueObservation] = []
    private var requestedPart: ZoomGuidePart = .meetingApp
    private var lastPage: ZoomMarketplacePage?
    private var timers: [DispatchWorkItem] = []

    var isOpen: Bool { window != nil }
    var currentURL: URL? { webView?.url }

    /// Opens the window (beside the guide) or brings it forward, and goes to `url` when given.
    /// `part` is the guide part the person is working on, so the coach knows which radio to point at.
    func show(url: URL?, part: ZoomGuidePart?, guideWindow: NSWindow?) {
        if let part { requestedPart = part }
        if window == nil { make(guideWindow: guideWindow) }
        window?.makeKeyAndOrderFront(nil)
        if let url, let webView {
            if webView.url == nil || webView.url != url { webView.load(URLRequest(url: url)) }
        }
        refresh()
    }

    private func make(guideWindow: NSWindow?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let ucc = config.userContentController
        ucc.add(self, name: "route")
        ucc.add(self, contentWorld: .defaultClient, name: "coach")
        ucc.addUserScript(WKUserScript(source: Self.routeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = Self.safariUA
        web.navigationDelegate = self
        web.uiDelegate = self
        observers = [
            web.observe(\.canGoBack, options: [.initial, .new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            web.observe(\.canGoForward, options: [.initial, .new]) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
            web.observe(\.url, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.urlChanged() } },
        ]

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Zoom"
        win.contentMinSize = NSSize(width: 480, height: 500)
        win.contentView = NSHostingView(rootView: ZoomWindowView(window: self, web: web).tint(Brand.green))
        win.isReleasedWhenClosed = false
        win.delegate = self
        place(win, beside: guideWindow)
        window = win
        webView = web
    }

    private func place(_ win: NSWindow, beside guideWindow: NSWindow?) {
        if let guideWindow, guideWindow.isVisible, let screen = guideWindow.screen {
            let f = ZoomMarketplaceWindowPlacement.frames(screen: screen.visibleFrame, guide: guideWindow.frame)
            if f.guide != guideWindow.frame { guideWindow.setFrame(f.guide, display: true, animate: true) }
            win.setFrame(f.zoom, display: false)
        } else if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            win.setFrame(ZoomMarketplaceWindowPlacement.alone(screen: visible), display: false)
        } else {
            win.center()
        }
    }

    func windowWillClose(_ notification: Notification) {
        cancelTimers()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "route")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "coach", contentWorld: .defaultClient)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        observers = []
        webView = nil
        window = nil
        lastPage = nil
        location = ""
        onPage(nil)
    }

    // MARK: Toolbar actions

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { loadFailed = false; webView?.reload() }

    /// The same address in Safari (R8).
    func openInSafari() {
        NSWorkspace.shared.open(webView?.url ?? ZoomMarketplaceGuide.builderURL)
    }

    /// Clears what Zoom's sites remembered in this window, then starts again at Created Apps.
    func signOut() {
        let reload = webView != nil
        let store = WKWebsiteDataStore.default()
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            let zoom = records.filter { $0.displayName.localizedCaseInsensitiveContains("zoom") }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: zoom) {
                MainActor.assumeIsolated {
                    if reload { self?.webView?.load(URLRequest(url: ZoomMarketplaceGuide.builderURL)) }
                }
            }
        }
    }

    // MARK: Following the page

    private func urlChanged() {
        guard let url = webView?.url else { return }
        loadFailed = false
        location = (url.host ?? "") + url.path
        let page = ZoomMarketplacePages.page(for: url)
        if page != lastPage { lastPage = page; onPage(page) }
        scheduleRefresh()
    }

    /// The page is a single-page app that draws late: look again a few times after each change.
    private func scheduleRefresh() {
        cancelTimers()
        for delay in [0.2, 0.8, 2.0, 4.0] {
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            timers.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelTimers() { timers.forEach { $0.cancel() }; timers = [] }

    /// Draws the coach for this page and, on a credential page, reads the keys.
    func refresh() {
        guard let webView, let url = webView.url, let page = ZoomMarketplacePages.page(for: url) else { return }
        let part = page.app.map { $0 == .sdk ? ZoomGuidePart.meetingApp : .hostingApp } ?? requestedPart
        let coach = ZoomCoachRules.coach(part: part, page: page, keysFilled: keysFilled(), tipsOn: tipsOn, needsApp: needsApp(part))
        let ring = Self.ringColor
        webView.evaluateJavaScript(ZoomCoachScript.source, in: nil, in: .defaultClient) { _ in
            MainActor.assumeIsolated {
                self.webView?.evaluateJavaScript(ZoomCoachScript.call(coach?.json, ring: ring), in: nil, in: .defaultClient) { _ in }
            }
        }
        readKeys(on: page)
    }

    private func readKeys(on page: ZoomMarketplacePage) {
        guard let fields = ZoomMarketplacePages.keyFields(on: page), let webView else { return }
        webView.evaluateJavaScript(ZoomKeyReaderScript.call(fields: fields), in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, case .success(let value) = result, let json = value as? String,
                      let data = json.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      self.webView?.url.flatMap(ZoomMarketplacePages.page(for:)) == page else { return }
                var found: [ZoomKeyField: String] = [:]
                if let v = raw["accountID"] { found[.accountID] = v }
                if let v = raw["clientID"] { found[.clientID] = v }
                if let v = raw["clientSecret"] { found[.clientSecret] = v }
                if !found.isEmpty { self.onKeys(page, found) }
            }
        }
    }

    /// Brand.green as a CSS colour for the coach's ring (never a literal in code).
    private static var ringColor: String {
        let c = NSColor(Brand.green).usingColorSpace(.sRGB) ?? NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemGreen
        return String(format: "rgb(%d,%d,%d)", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    // MARK: WKNavigationDelegate / WKUIDelegate / WKScriptMessageHandler

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loadFailed = false; scheduleRefresh() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { noteFailure(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { noteFailure(error) }
    private func noteFailure(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { loadFailed = true }
    }

    /// Only web addresses load; Zoom's app-launch links (zoommtg:) and the like do not.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        let web = ["http", "https", "about", "blob", "data"].contains(scheme)
        decisionHandler(web || navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel)
    }

    /// Links that open a new window (Marketplace's "Developers", target=_blank) load in this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // The page's own messages are only a nudge to look again; the web view's address is the truth.
        switch message.name {
        case "route": scheduleRefresh()
        case "coach": if (message.body as? String) == "hide" { tipsOn = false }
        default: break
        }
    }

    /// Reports history.pushState / replaceState / popstate so a route change is noticed at once.
    static let routeScript = """
    (function () {
      if (window.__grRoute) return; window.__grRoute = true;
      function post() { try { window.webkit.messageHandlers.route.postMessage('change'); } catch (e) {} }
      ['pushState', 'replaceState'].forEach(function (name) {
        var orig = history[name];
        history[name] = function () {
          var r = orig.apply(this, arguments);
          setTimeout(post, 0);
          return r;
        };
      });
      window.addEventListener('popstate', post);
      window.addEventListener('hashchange', post);
    })();
    """
}

private struct ZoomWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct ZoomWindowView: View {
    @ObservedObject var window: ZoomMarketplaceWindow
    let web: WKWebView

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { window.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!window.canGoBack).help("Back").accessibilityLabel("Back")
                Button { window.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!window.canGoForward).help("Forward").accessibilityLabel("Forward")
                Button { window.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload").accessibilityLabel("Reload")
                Text(window.location)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(window.location)
                if window.loadFailed {
                    Text("Couldn\u{2019}t load this page.").font(.caption).foregroundStyle(Brand.netText)
                }
                Toggle("Tips", isOn: $window.tipsOn)
                    .toggleStyle(.button)
                    .help("Show or hide Greenroom\u{2019}s tips on Zoom\u{2019}s page")
                Button("Sign out of Zoom") { window.signOut() }
                    .help("Clears the sign-in Greenroom remembers for Zoom, then starts again")
                Button("Open in Safari") { window.openInSafari() }
                    .help("Opens this page in Safari")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ZoomWebView(web: web)
        }
    }
}
