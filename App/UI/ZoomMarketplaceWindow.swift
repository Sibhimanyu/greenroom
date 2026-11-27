//
//  ZoomMarketplaceWindow.swift
//  Greenroom
//
//  The "Zoom window" (docs/specs/zoom-setup-assist.md, R1, R5, R6, R8): Zoom
//  App Marketplace in a normal macOS window beside the setup guide. It uses the
//  default website data store (the sign-in is kept in Greenroom, separate from
//  Safari, until Zoom ends it) and a Safari user agent; links that ask for a
//  new window load in place. Above the page is the Greenroom bar
//  (`ZoomBarView`, content from `ZoomBarRules`): part and step, Copy scopes,
//  Next / Back to Greenroom, Back, Forward, Reload, Tips and a menu with Open in
//  Safari and (only when signed in) Sign out of Zoom. It opens large and
//  centred on the guide's screen; the guide is not moved.
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
    /// What the bar shows, from `ZoomBarRules`.
    @Published private(set) var bar = ZoomBar(title: "", context: .none, primary: .none, offersSignOut: false)
    @Published private(set) var signIn = ZoomSignInState.unknown
    @Published private(set) var copied = false
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
    /// Which parts have all their keys in Greenroom, and the remembered app IDs, for the bar.
    var barState: () -> (meeting: Bool, hosting: Bool, ids: ZoomAppIDs) = { (false, false, ZoomAppIDs()) }
    /// The bar's "Back to Greenroom" hands over to the guide.
    var onBackToGreenroom: () -> Void = {}

    private var window: NSWindow?
    private var webView: WKWebView?
    private var observers: [NSKeyValueObservation] = []
    private var requestedPart: ZoomGuidePart = .meetingApp
    /// Where setup sent the window, and whether a sign-in page has shown since:
    /// after a sign-in, Zoom's home page sends the window back there once.
    private var heading: URL?
    private var sawSignIn = false
    /// The Type text of each row on Created apps (nil until scanned, and on every other page).
    private var appRows: [String]?
    private var lastPage: ZoomMarketplacePage?
    private var timers: [DispatchWorkItem] = []

    var isOpen: Bool { window != nil }
    var currentURL: URL? { webView?.url }

    /// Opens the window (beside the guide) or brings it forward, and goes to `url` when given.
    /// `part` is the guide part the person is working on, so the coach knows which radio to point at.
    func show(url: URL?, part: ZoomGuidePart?, guideWindow: NSWindow?) {
        if let part { requestedPart = part }
        if let url { heading = url }
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

    /// Large and centred on the guide's screen (the guide is not moved).
    private func place(_ win: NSWindow, beside guideWindow: NSWindow?) {
        if let visible = (guideWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            win.setFrame(ZoomMarketplaceWindowPlacement.frame(screen: visible), display: false)
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
        signIn = .unknown
        updateBar()
        onPage(nil)
    }

    // MARK: Toolbar actions

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { loadFailed = false; webView?.reload() }

    /// Copy scopes: the same text as the guide's (one per line).
    func copyScopes() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ZoomScopes.names.joined(separator: "\n"), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copied = false }
    }

    /// The bar's Sign in: Marketplace itself redirects to Zoom's sign-in. Nothing is pressed on the page.
    func goToSignIn() { webView?.load(URLRequest(url: ZoomMarketplaceGuide.builderURL)) }

    func pressPrimary() {
        switch bar.primary {
        case .none: break
        case .next(let part, let page):
            requestedPart = part
            if let url = ZoomMarketplacePages.url(for: page) { webView?.load(URLRequest(url: url)) }
        case .backToGreenroom:
            window?.close()
            onBackToGreenroom()
        }
    }

    private var requestedPartForBar: ZoomGuidePart { lastPage?.app.map { $0 == .sdk ? .meetingApp : .hostingApp } ?? requestedPart }

    /// Recomputes the bar from the page, the keys in Greenroom and the sign-in state.
    func updateBar() {
        let s = barState()
        bar = ZoomBarRules.bar(ZoomBarFacts(part: requestedPart, page: lastPage, ids: s.ids, meetingComplete: s.meeting,
                                            hostingComplete: s.hosting, signIn: signIn,
                                            hasMatchingRow: appRows.map { !ZoomCoachRules.matchingRows(requestedPartForBar, $0).isEmpty } ?? false))
    }

    /// The same address in Safari (R8).
    func openInSafari() {
        NSWorkspace.shared.open(webView?.url ?? ZoomMarketplaceGuide.builderURL)
    }

    /// Clears what Zoom's sites remembered in this window, then starts again at Created Apps.
    func signOut() {
        let reload = webView != nil
        signIn = ZoomSignInStateRules.afterSignOut
        updateBar()
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
        signIn = ZoomSignInStateRules.state(page: page, header: nil, current: signIn)
        updateBar()
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
        updateBar()
        guard let webView, let url = webView.url else { return }
        readSignIn(url)
        if let back = ZoomMarketplacePages.resumeAfterSignIn(sawSignIn: sawSignIn, now: url, heading: heading) {
            sawSignIn = false
            note(nil, "resume-after-sign-in")
            webView.load(URLRequest(url: back))
            return
        }
        guard let page = ZoomMarketplacePages.page(for: url) else { note(nil, "no-page"); return }
        if page.isSignIn { sawSignIn = true }
        if page == .createdApps {
            scanAppRows(page) { [weak self] in self?.drawCoach(page) }
        } else {
            if appRows != nil { appRows = nil; updateBar() }
            drawCoach(page)
        }
        readKeys(on: page)
    }

    /// Computes the coach for the page and draws (or clears) it; the script's one-word answer is noted in DEBUG.
    private func drawCoach(_ page: ZoomMarketplacePage) {
        guard let webView else { return }
        let part = page.app.map { $0 == .sdk ? ZoomGuidePart.meetingApp : .hostingApp } ?? requestedPart
        let coach = ZoomCoachRules.coach(part: part, page: page, keysFilled: keysFilled(), tipsOn: tipsOn,
                                         needsApp: needsApp(part), appRows: appRows)
        let ring = Self.ringColor, mark = Self.markDataURI
        webView.evaluateJavaScript(ZoomCoachScript.source, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .failure(let error) = result { self.note(page, "coach-source-error " + Self.describe(error)) }
                self.webView?.evaluateJavaScript(ZoomCoachScript.call(coach?.json, ring: ring, mark: mark), in: nil, in: .defaultClient) { result in
                    MainActor.assumeIsolated {
                        switch result {
                        case .success(let value): self.note(page, coach == nil ? "no-coach" : "coach " + ((value as? String) ?? "?"))
                        case .failure(let error): self.note(page, "coach-call-error " + Self.describe(error))
                        }
                    }
                }
            }
        }
    }

    /// Reads the Created apps table's Type column (never an app's name) and remembers it for the coach and the bar.
    private func scanAppRows(_ page: ZoomMarketplacePage, then done: @escaping () -> Void) {
        webView?.evaluateJavaScript(ZoomAppListScript.source, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                var types: [String]?
                switch result {
                case .success(let value):
                    if let json = value as? String, let data = json.data(using: .utf8),
                       let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        types = list.compactMap { $0["typeText"] as? String }
                    }
                case .failure(let error):
                    self.note(page, "scan-error " + Self.describe(error))
                }
                self.note(page, "scan rows=\(types?.count ?? -1)")
                if self.appRows != types { self.appRows = types; self.updateBar() }
                done()
            }
        }
    }

    /// Looks at Marketplace's header (read only) for a "Sign In" link or an account menu.
    private func readSignIn(_ url: URL) {
        guard ZoomMarketplacePages.isMarketplace(url), ZoomMarketplacePages.page(for: url)?.isSignIn != true else { return }
        webView?.evaluateJavaScript(ZoomSignInHeaderScript.source, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                if case .failure(let error) = result { self?.note(self?.lastPage, "header-error " + Self.describe(error)) }
                guard let self, case .success(let value) = result, let word = value as? String,
                      let report = ZoomHeaderReport(rawValue: word),
                      self.webView?.url == url else { return }
                let next = ZoomSignInStateRules.state(page: self.lastPage, header: report, current: self.signIn)
                if next != self.signIn { self.signIn = next; self.updateBar() }
            }
        }
    }

    private func readKeys(on page: ZoomMarketplacePage) {
        guard let fields = ZoomMarketplacePages.keyFields(on: page), let webView else { return }
        webView.evaluateJavaScript(ZoomKeyReaderScript.call(fields: fields), in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                if case .failure(let error) = result { self?.note(page, "reader-error " + Self.describe(error)) }
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

    /// The Greenroom app icon at 64px as a PNG data URI, for the coach card's header (never an address).
    /// The small-size app icon, since DESIGN.md's mark minimum is 24px tall and the card shows it at 16pt.
    private static let markDataURI: String? = {
        let side = 64
        guard let icon = NSApp?.applicationIconImage,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }()

    // MARK: DEBUG log (never page text, never values)

    /// A script error as its domain, code and our own script's exception text; nothing from the page.
    private static func describe(_ error: Error) -> String {
        let e = error as NSError
        let message = (e.userInfo["WKJavaScriptExceptionMessage"] as? String).map { String($0.prefix(120)) } ?? ""
        return "\(e.domain) \(e.code) \(message)"
    }

    /// DEBUG builds append "time, page kind, what" to ~/Library/Logs/Greenroom/zoom-window.log. Release builds do nothing.
    private func note(_ page: ZoomMarketplacePage?, _ what: String) {
        #if DEBUG
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(page?.kindName ?? "other") \(what)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Greenroom/zoom-window.log")
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
        #endif
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
            ZoomBarView(bar: window.bar, canGoBack: window.canGoBack, canGoForward: window.canGoForward,
                        tipsOn: $window.tipsOn, loadFailed: window.loadFailed, copied: window.copied, address: window.location,
                        onBack: { window.goBack() }, onForward: { window.goForward() }, onReload: { window.reload() },
                        onCopyScopes: { window.copyScopes() }, onSignIn: { window.goToSignIn() },
                        onPrimary: { window.pressPrimary() }, onOpenInSafari: { window.openInSafari() },
                        onSignOut: { window.signOut() })
            Divider()
            ZoomWebView(web: web)
        }
    }
}
