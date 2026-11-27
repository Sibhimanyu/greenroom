//
//  ZoomMarketplaceWindow.swift
//  Greenroom
//
//  The "Zoom window" (docs/specs/zoom-setup-assist.md R1, R8; docs/specs/zoom-setup-flow.md): Zoom
//  App Marketplace in a normal macOS window beside the setup guide. It uses the default website data
//  store (the sign-in is kept in Greenroom, separate from Safari, until Zoom ends it) and a Safari user
//  agent; links that ask for a new window load in place. Above the page is the Greenroom bar
//  (`ZoomBarView`): "Step n of 8 \u{00B7} title", the step's one button, Back, Forward, Reload, Tips and a menu
//  with Open in Safari and (only when signed in) Sign out of Zoom. It opens large and centred on the
//  guide's screen; the guide is not moved.
//
//  This is the real adapter of the `ZoomPage` seam (read, perform, draw) and nothing else: it decides no
//  steps. `ZoomSetupAssist` owns the flow and hands the window the step to show. Greenroom clicks on
//  Zoom's pages only through `ZoomActor` plans (`perform`). Key values come back through the copy hook,
//  in memory; they are never logged, put in the title or kept here. The window's title is always "Zoom".
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
    /// The step the flow is on (the bar and the coach show it) and what the page says about sign-in.
    @Published private(set) var step: SetupStep?
    @Published private(set) var signedIn: Bool?
    @Published private(set) var copied = false
    /// A step is being done (a plan is running); the bar shows it.
    @Published private(set) var working = false
    @Published private(set) var loadFailed = false
    /// "Set up for me" is driving the page: the coach stays quiet, and the bar shows this line and Stop.
    @Published private(set) var autopilotLine: String?
    /// The coach on or off for this setup; "Hide tips" and the toolbar's Tips both set it.
    @Published var tipsOn = true { didSet { if tipsOn != oldValue { redraw() } } }

    /// Told when the window shows a different page (nil: not a Marketplace page, or closed).
    var onPage: (ZoomMarketplacePage?) -> Void = { _ in }
    /// Told to look again (Marketplace is a single-page app that draws late).
    var onRefresh: () -> Void = {}
    /// The card's or the bar's button: do what the current step's call to action says.
    var onAct: () -> Void = {}
    /// Stop pressed while Set up for me runs, or the window closed during it.
    var onStop: () -> Void = {}

    private var window: NSWindow?
    private var webView: WKWebView?
    private var observers: [NSKeyValueObservation] = []
    /// Where setup sent the window, and whether a sign-in page has shown since:
    /// after a sign-in, Zoom's home page sends the window back there once.
    private var heading: URL?
    private var sawSignIn = false
    private var lastPage: ZoomMarketplacePage?
    private var timers: [DispatchWorkItem] = []
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private var lastDrawing: CoachDrawing?
    #if DEBUG
    private var recorderWork: DispatchWorkItem?
    private var lastRecorded: ZoomPageSnapshot?
    #endif

    var isOpen: Bool { window != nil }
    var currentURL: URL? { webView?.url }
    func close() { window?.close() }
    private var autopilotOn: Bool { autopilotLine != nil }

    /// What the flow says now: the bar shows it and the coach draws it (unless tips are off or Set up for me is running).
    func present(step: SetupStep?, signedIn: Bool?, working: Bool) {
        self.step = step; self.signedIn = signedIn; self.working = working
        // Signed out on a Marketplace page (Guide me, or a session Zoom ended): go straight to Zoom's sign-in
        // page instead of leaving a "Sign In" link to find (owner, 2026-11-27). Once per opening.
        if signedIn == false, !sentToSignIn, let url = webView?.url, let page = ZoomMarketplacePages.page(for: url), !page.isSignIn {
            sentToSignIn = true
            goToSignIn()
        }
        redraw()
    }

    func setAutopilot(_ line: String?) {
        let was = autopilotOn
        autopilotLine = line
        if autopilotOn != was { redraw() }
    }

    /// Opens the window (beside the guide) or brings it forward, and goes to `url` when given.
    func show(url: URL?, guideWindow: NSWindow?) {
        if let url { heading = url }
        sentToSignIn = false
        if window == nil { make(guideWindow: guideWindow) }
        window?.makeKeyAndOrderFront(nil)
        if let url, let webView {
            if webView.url == nil || webView.url != url { webView.load(URLRequest(url: url)) }
        }
        scheduleRefresh()
    }

    private func make(guideWindow: NSWindow?) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let ucc = config.userContentController
        ucc.add(self, name: "route")
        ucc.add(self, contentWorld: .defaultClient, name: "coach")
        ucc.addUserScript(WKUserScript(source: Self.routeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "zoomCopy")
        ucc.add(self, name: "zoomSave")
        ucc.addUserScript(WKUserScript(source: Self.saveHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-zoomDiag") {
            ucc.add(self, name: "zoomDiag")
            ucc.addUserScript(WKUserScript(source: Self.diagScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        #endif
        ucc.addUserScript(WKUserScript(source: Self.copyHookScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #if DEBUG
        if ZoomRecorder.enabled {
            ucc.add(self, contentWorld: .defaultClient, name: "zoomRecord")
            ucc.addUserScript(WKUserScript(source: ZoomRecorder.clickScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        }
        #endif

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
        resumeLoadWaiter()
        if autopilotOn { onStop() }
        autopilotLine = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "route")
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "coach", contentWorld: .defaultClient)
        #if DEBUG
        if ZoomRecorder.enabled {
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "zoomRecord", contentWorld: .defaultClient)
            recorderWork?.cancel(); recorderWork = nil; lastRecorded = nil
        }
        #endif
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        observers = []
        webView = nil
        window = nil
        lastPage = nil
        lastDrawing = nil
        location = ""
        step = nil; signedIn = nil
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
    private var sentToSignIn = false
    /// Sign-in starts from Marketplace's own Sign In button (live, 2026-11-27): only that start carries
    /// Marketplace's return details, so Zoom's sign-in (Google included) comes back to Marketplace signed in.
    /// A direct zoom.us/signin signed in to Zoom but left Marketplace signed out. The press only opens the
    /// sign-in page; typing stays the person's. Not on Marketplace: open its home first, then press.
    func goToSignIn() {
        guard let webView else { return }
        if let url = webView.url, ZoomMarketplacePages.isMarketplace(url) { pressMarketplaceSignIn(); return }
        pendingSignInPress = true
        webView.load(URLRequest(url: URL(string: "https://marketplace.zoom.us/")!))
    }
    private var pendingSignInPress = false
    private func pressMarketplaceSignIn() {
        let js = "(function () { \(ZoomPageScript.library) var el = resolve('signIn'); if (!el) return 'none'; el.click(); return 'ok'; })();"
        webView?.evaluateJavaScript(js, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                // The button draws late: try again on the next look.
                if case .success(let v) = result, (v as? String) == "none" { self?.pendingSignInPress = true }
            }
        }
    }

    /// The same address in Safari (R8).
    func openInSafari() {
        NSWorkspace.shared.open(webView?.url ?? ZoomMarketplaceGuide.builderURL)
    }

    /// Clears what Zoom's sites remembered in this window, then starts again at Created Apps.
    func signOut() {
        let reload = webView != nil
        signedIn = false
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
        if page?.isSignIn == true { sawSignIn = true }
        #if DEBUG
        recorderNudge()
        #endif
        scheduleRefresh()
    }

    /// The page is a single-page app that draws late: look again a few times after each change.
    private func scheduleRefresh() {
        cancelTimers()
        // Marketplace draws its list late (rows=0 then rows=1 in the real log): keep looking for a while.
        for delay in [0.2, 0.8, 2.0, 4.0, 7.0, 10.0, 15.0] {
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            timers.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func cancelTimers() { timers.forEach { $0.cancel() }; timers = [] }

    /// Looks again: after a sign-in Zoom's home page sends the window back to where setup was heading, then the flow re-reads.
    func refresh() {
        #if DEBUG
        recorderNudge()
        if ZoomRecorder.coachOff { return }   // a recording run sees Zoom's pages untouched
        #endif
        guard let webView, let url = webView.url else { return }
        if pendingSignInPress, ZoomMarketplacePages.isMarketplace(url) { pendingSignInPress = false; pressMarketplaceSignIn() }
        if let back = ZoomMarketplacePages.resumeAfterSignIn(sawSignIn: sawSignIn, now: url, heading: heading) {
            sawSignIn = false
            webView.load(URLRequest(url: back))
            return
        }
        #if DEBUG
        if ZoomDomDump.enabled, ZoomMarketplacePages.isMarketplace(url), let page = ZoomMarketplacePages.page(for: url) {
            let labelsOnly = ZoomMarketplacePages.keyFields(on: page) != nil
            webView.evaluateJavaScript(ZoomDomDump.script(labelsOnly: labelsOnly), in: nil, in: .defaultClient) { result in
                if case .success(let v) = result, let json = v as? String { ZoomDomDump.append(kind: page.kindName, json: json) }
            }
        }
        #endif
        onRefresh()
    }

    // MARK: The coach (draw)

    /// Draws the current step's card, or clears it (tips off, Set up for me running, nothing to say).
    private func redraw() {
        var drawing: CoachDrawing?
        if tipsOn, !autopilotOn, !working, let step { drawing = step.coach }
        lastDrawing = drawing
        draw(drawing)
    }

    func draw(_ coach: CoachDrawing?) {
        guard let webView, ZoomMarketplacePages.isMarketplace(webView.url ?? URL(fileURLWithPath: "/")) else { return }
        let ring = Self.ringColor, mark = Self.markDataURI, fill = Self.fillColor
        let json = coach.map { ZoomCoachScript.json($0) }
        webView.evaluateJavaScript(ZoomCoachScript.source, in: nil, in: .defaultClient) { [weak self] _ in
            self?.webView?.evaluateJavaScript(ZoomCoachScript.call(json, ring: ring, mark: mark, fill: fill), in: nil, in: .defaultClient) { _ in }
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

    /// Reads the page into a `ZoomPageSnapshot` (one read-only script). The values in it stay in memory.
    func readSnapshot(_ done: @escaping (ZoomPageSnapshot?) -> Void) {
        guard let webView, let url = webView.url else { done(nil); return }
        webView.evaluateJavaScript(ZoomPageScript.source, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, let json = value as? String,
                      self?.webView?.url == url else {
                    if case .success(let value) = result, let text = value as? String { self?.note(nil, "snapshot " + String(text.prefix(60))) }
                    done(nil); return
                }
                var snapshot = ZoomPageSnapshot.decode(reading: json, address: ZoomMarketplacePages.page(for: url))
                if let id = snapshot?.address?.appID, self?.refusedSaves.contains(id) == true { snapshot?.saveRefused = true }
                done(snapshot)
            }
        }
    }

    #if DEBUG
    // MARK: Recorder (-zoomRecord YES): see ZoomRecorder

    /// Something may have changed: read once, about 700ms from now (further nudges meanwhile are folded in).
    private func recorderNudge() {
        guard ZoomRecorder.enabled, recorderWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recorderWork = nil
                self.readSnapshot { snapshot in
                    guard let snapshot else { return }
                    let redacted = snapshot.redacted()
                    guard redacted != self.lastRecorded else { return }
                    self.lastRecorded = redacted
                    ZoomRecorder.append(ZoomRecordingLine.snapshot(snapshot, at: Date()))
                }
            }
        }
        recorderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// DEBUG probe only (`ZoomDomDump.commands` whitelist): run a look-only command, then look again.
    func debugRun(_ js: String) {
        webView?.evaluateJavaScript(js, in: nil, in: .defaultClient) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { self?.refresh() }
        }
    }
    func debugLoad(_ url: URL) { webView?.load(URLRequest(url: url)) }
    func debugEval(_ js: String, _ done: @escaping (String) -> Void) {
        guard let webView else { done("no window"); return }
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let v): done((v as? String) ?? "?")
                case .failure(let e): done("error \((e as NSError).code)")
                }
            }
        }
    }
    #endif

    // MARK: DEBUG log (never page text, never values)

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

    /// Brand.buttonFill as a CSS colour: the coach's button fill (white label).
    private static var fillColor: String {
        let c = NSColor(Brand.buttonFill).usingColorSpace(.sRGB) ?? .systemGreen
        return String(format: "rgb(%d,%d,%d)", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    /// Brand.green as a CSS colour for the coach's ring (never a literal in code).
    private static var ringColor: String {
        let c = NSColor(Brand.green).usingColorSpace(.sRGB) ?? NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemGreen
        return String(format: "rgb(%d,%d,%d)", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    // MARK: WKNavigationDelegate / WKUIDelegate / WKScriptMessageHandler

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loadFailed = false; scheduleRefresh(); resumeLoadWaiter() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { noteFailure(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { noteFailure(error) }
    private func noteFailure(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { loadFailed = true; resumeLoadWaiter() }
    }
    private func resumeLoadWaiter() { loadWaiter?.resume(); loadWaiter = nil }

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
        #if DEBUG
        case "zoomRecord":
            guard ZoomRecorder.enabled, let body = message.body as? [String: Any] else { break }
            if body["click"] != nil {
                ZoomRecorder.append(ZoomRecordingLine.click(control: body["control"] as? String, role: body["role"] as? String,
                                                            text: body["text"] as? String, at: Date()))
            }
            recorderNudge()
        #endif
        case "route": scheduleRefresh()
        case "zoomCopy": copiedByZoom(message.body as? String)
        case "zoomSave":
            // The app ID from the page's own address at the moment Zoom refused its save.
            if let url = webView?.url, let page = ZoomMarketplacePages.page(for: url), let id = page.appID { refusedSaves.insert(id) }
        #if DEBUG
        case "zoomDiag": if let t = message.body as? String { ZoomDomDump.log("page " + t) }
        #endif
        case "coach":
            switch message.body as? String {
            case "hide": tipsOn = false
            case "act": onAct()
            default: break
            }
        default: break
        }
    }

    /// What Zoom's own Copy tried to put on the clipboard (live run, 2026-11-27: WebKit refuses a
    /// page's clipboard write without a real click, so a pressed Copy copied nothing). Kept only on a
    /// credentials page and only when key-shaped; in memory, never logged.
    fileprivate(set) var lastCopiedKey: (text: String, at: Date)?
    private func copiedByZoom(_ text: String?) {
        guard let text, let key = ZoomClipboardRules.clean(text), let url = webView?.url,
              let page = ZoomMarketplacePages.page(for: url), page.isCredentialsPage else { return }
        lastCopiedKey = (key, Date())
        #if DEBUG
        note(page, "copied key len=\(key.count)")
        #endif
    }

    #if DEBUG
    /// DEBUG diagnostics: the page's own errors and failed requests (path and status only, never bodies or queries).
    static let diagScript = """
    (function () {
      if (window.__grDiag) return; window.__grDiag = true;
      function post(t) { try { window.webkit.messageHandlers.zoomDiag.postMessage(String(t).replace(/[A-Za-z0-9_-]{16,}/g, '#').slice(0, 220)); } catch (e) {} }
      function path(u) { try { var x = new URL(u, location.href); return x.host + x.pathname; } catch (e) { return '?'; } }
      window.addEventListener('error', function (e) { post('error ' + (e.message || '') + ' @' + path(e.filename || '')); }, true);
      window.addEventListener('unhandledrejection', function (e) { post('rejection ' + ((e.reason && e.reason.message) || String(e.reason)).slice(0, 120)); });
      var of = window.fetch;
      if (of) window.fetch = function (u, o) { var p = path(typeof u === 'string' ? u : (u && u.url)); return of.apply(this, arguments).then(function (r) { if (r.status >= 400) post('fetch ' + r.status + ' ' + p); return r; }, function (err) { post('fetch failed ' + p + ' ' + (err && err.message)); throw err; }); };
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__grP = path(u); return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () { var x = this; x.addEventListener('loadend', function () { if (x.status === 0 || x.status >= 400) post('xhr ' + x.status + ' ' + x.__grP); }); return os.apply(this, arguments); };
    })();
    """
    #endif

    /// Apps whose save Zoom refused (401/403) in this window: the account may not change them (live run 6).
    private var refusedSaves: Set<String> = []

    /// Page world, document start: reports a SAVE (not a read) to Marketplace's app API that Zoom refuses
    /// with 401 or 403. Only the fact is posted, never the request or its answer.
    static let saveHookScript = """
    (function () {
      if (window.__grSave || location.host !== 'marketplace.zoom.us') return; window.__grSave = true;
      function isAppWrite(m, u) { m = (m || 'GET').toUpperCase(); return m !== 'GET' && m !== 'HEAD' && /\\/api\\/v1\\/apps\\//.test(String(u || '')); }
      function post() { try { window.webkit.messageHandlers.zoomSave.postMessage('refused'); } catch (e) {} }
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__grW = isAppWrite(m, u); return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () { var x = this; if (x.__grW) x.addEventListener('loadend', function () { if (x.status === 401 || x.status === 403) post(); }); return os.apply(this, arguments); };
      var of = window.fetch;
      if (of) window.fetch = function (u, o) { var w = isAppWrite(o && o.method, typeof u === 'string' ? u : (u && u.url)); return of.apply(this, arguments).then(function (r) { if (w && (r.status === 401 || r.status === 403)) post(); return r; }); };
    })();
    """

    /// Page world, document start: wraps navigator.clipboard.writeText and the copy event so the text a
    /// Copy button hands over reaches Greenroom, then lets the page's own copy carry on.
    static let copyHookScript = """
    (function () {
      if (window.__grCopy || location.host !== 'marketplace.zoom.us') return; window.__grCopy = true;
      function post(t) { try { if (typeof t === 'string' && t.length && t.length < 200) window.webkit.messageHandlers.zoomCopy.postMessage(t); } catch (e) {} }
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          var orig = navigator.clipboard.writeText.bind(navigator.clipboard);
          navigator.clipboard.writeText = function (t) { post(t); return orig(t).catch(function () {}); };
        }
      } catch (e) {}
      document.addEventListener('copy', function () { try { post(String(window.getSelection() || '')); } catch (e) {} }, true);
    })();
    """

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

// MARK: - The ZoomPage seam, real adapter

extension ZoomMarketplaceWindow: ZoomPage {
    func read() async -> ZoomPageSnapshot? {
        await withCheckedContinuation { continuation in readSnapshot { continuation.resume(returning: $0) } }
    }

    func perform(_ action: ZoomPageAction) async -> ZoomActionResult {
        guard let webView else { return .notFound }
        let js: String
        switch action {
        case .navigate(let place):
            guard let url = ZoomMarketplacePages.url(for: place) else { return .notFound }
            webView.load(URLRequest(url: url))
            // Loading an address is navigation: wait for the page (at most 12 s), then the reader takes over.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                resumeLoadWaiter()
                loadWaiter = c
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.resumeLoadWaiter() }
            }
            return .done
        case .press(let c): js = ZoomPageScript.action(verb: "press", id: c.id)
        case .pressDeep(let c): js = ZoomPageScript.action(verb: "pressdeep", id: c.id)
        case .hover(let c): js = ZoomPageScript.action(verb: "hover", id: c.id)
        case .type(let c, let text): js = ZoomPageScript.action(verb: "type", id: c.id, text: text)
        }
        guard ZoomMarketplacePages.isMarketplace(webView.url ?? URL(fileURLWithPath: "/")) else { return .notFound }
        let answer: String = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
                if case .success(let v) = result, let s = v as? String { continuation.resume(returning: s) }
                else { continuation.resume(returning: "none") }
            }
        }
        switch answer {
        case "ok": return .done
        case "denied": return .denied
        default: return .notFound
        }
    }

    func takeCopiedKey() -> String? {
        guard let k = lastCopiedKey, Date().timeIntervalSince(k.at) < 15 else { return nil }
        lastCopiedKey = nil
        return k.text
    }
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
            ZoomBarView(step: window.step, signedIn: window.signedIn, working: window.working,
                        canGoBack: window.canGoBack, canGoForward: window.canGoForward,
                        tipsOn: $window.tipsOn, loadFailed: window.loadFailed, copied: window.copied, address: window.location,
                        onBack: { window.goBack() }, onForward: { window.goForward() }, onReload: { window.reload() },
                        onCopyScopes: { window.copyScopes() }, onSignIn: { window.goToSignIn() },
                        onAct: { window.onAct() }, onOpenInSafari: { window.openInSafari() },
                        onSignOut: { window.signOut() },
                        autopilot: window.autopilotLine, onStop: { window.onStop() })
            Divider()
            ZStack {
                ZoomWebView(web: web)
                if let line = window.autopilotLine {
                    ZoomAutopilotHUD(line: line, step: window.step?.number, total: SetupStep.total,
                                     needsYou: needsYou, needsYouTitle: needsYouTitle, onStop: { window.onStop() })
                }
            }
            .animation(.easeOut(duration: 0.2), value: window.autopilotLine == nil)
            .animation(.easeOut(duration: 0.2), value: needsYou)
            .onChange(of: blocking) { _, now in
                // While Greenroom drives, typing must not land on Zoom's page either.
                if now { web.window?.makeFirstResponder(nil) }
            }
        }
    }

    /// What Set up for me is waiting for the person to do (sign-in is always theirs).
    private var needsYou: String? {
        guard window.autopilotLine != nil, let cta = window.step?.cta else { return nil }
        switch cta {
        case .press(.signIn, _): return "Sign in to Zoom in this window. Greenroom carries on by itself once you\u{2019}re in."
        case .press(.tryAnotherWay, _): return "Passkeys don\u{2019}t work in this window: press Try another way and use your password. Greenroom carries on after."
        case .fill(_, let text): return text + " Greenroom carries on by itself."
        default: return nil
        }
    }
    private var blocking: Bool { window.autopilotLine != nil && needsYou == nil }
    private var needsYouTitle: String? {
        if case .fill(.infoField(.contactEmail), _)? = window.step?.cta { return "Type your email to continue" }
        if case .fill? = window.step?.cta { return "Fill this in to continue" }
        return nil
    }
}
