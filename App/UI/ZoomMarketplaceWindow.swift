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
    /// A "Do this step" run is under way, and the words after the last one (cleared when the page changes).
    @Published private(set) var working = false
    private var actorNote: String?
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
    /// The page's key fields Greenroom still lacks (the coach points at the first); nil off the credentials pages.
    var missingKeys: (ZoomMarketplacePage) -> [ZoomKeyField]? = { _ in nil }
    /// A key copied with Zoom's own copy button while a credentials page is (or just was) shown. Never logged.
    var onCopied: (ZoomMarketplacePage, String) -> Void = { _, _ in }
    /// Which parts have all their keys in Greenroom, and the remembered app IDs, for the bar.
    var barState: () -> (meeting: Bool, hosting: Bool, ids: ZoomAppIDs, lines: [ZoomCheckLine], running: Bool) = { (false, false, ZoomAppIDs(), [], false) }
    /// A "Do this step" run finished: look at the check again while something fails.
    var onStepDone: () -> Void = {}
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
    #if DEBUG
    private var recorderWork: DispatchWorkItem?
    private var lastRecorded: ZoomPageSnapshot?
    #endif

    // MARK: Clipboard pickup (R17)

    private var credentialsPage: ZoomMarketplacePage?
    private var leftCredentialsAt: Date?
    private var pasteboardCount = NSPasteboard.general.changeCount
    private var pasteboardTimer: Timer?

    /// Called whenever the page changes: remember a credentials page, and when it was left.
    private func trackCredentialsPage(_ page: ZoomMarketplacePage?) {
        if let page, ZoomMarketplacePages.keyFields(on: page) != nil {
            credentialsPage = page; leftCredentialsAt = nil
        } else if credentialsPage != nil, leftCredentialsAt == nil {
            leftCredentialsAt = Date()
        }
        if pasteboardTimer == nil {
            pasteboardCount = NSPasteboard.general.changeCount
            pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollPasteboard() }
            }
        }
    }

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        let onPage = lastPage.map { ZoomMarketplacePages.keyFields(on: $0) != nil } ?? false
        let since = leftCredentialsAt.map { Date().timeIntervalSince($0) }
        #if DEBUG
        if ZoomRecorder.coachOff { pasteboardCount = count; return }
        #endif
        guard ZoomClipboardRules.isWatching(onCredentialsPage: onPage, secondsSinceLeaving: since), let page = credentialsPage else {
            pasteboardCount = count   // not watching: a copy made elsewhere never counts
            return
        }
        guard count != pasteboardCount else { return }
        pasteboardCount = count
        if let text = pb.string(forType: .string) { onCopied(page, text) }
    }

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
        ucc.add(self, name: "zoomCopy")
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
        pasteboardTimer?.invalidate(); pasteboardTimer = nil
        credentialsPage = nil; leftCredentialsAt = nil
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
                                            hasMatchingRow: appRows.map { !ZoomCoachRules.matchingRows(requestedPartForBar, $0).isEmpty } ?? false,
                                            working: working, checkLines: s.lines, checkRunning: s.running))
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
        if page != lastPage { lastPage = page; actorNote = nil; onPage(page) }
        #if DEBUG
        recorderNudge()
        #endif
        trackCredentialsPage(page)
        signIn = ZoomSignInStateRules.state(page: page, header: nil, current: signIn)
        updateBar()
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

    /// Draws the coach for this page and, on a credential page, reads the keys.
    func refresh() {
        updateBar()
        #if DEBUG
        recorderNudge()
        #endif
        guard let webView, let url = webView.url else { return }
        readSignIn(url)
        if let back = ZoomMarketplacePages.resumeAfterSignIn(sawSignIn: sawSignIn, now: url, heading: heading) {
            sawSignIn = false
            note(nil, "resume-after-sign-in")
            webView.load(URLRequest(url: back))
            return
        }
        guard let page = ZoomMarketplacePages.page(for: url) else { note(nil, "no-page"); return }
        #if DEBUG
        if ZoomDomDump.enabled, ZoomMarketplacePages.isMarketplace(url) {
            let labelsOnly = ZoomMarketplacePages.keyFields(on: page) != nil
            webView.evaluateJavaScript(ZoomDomDump.script(labelsOnly: labelsOnly), in: nil, in: .defaultClient) { result in
                if case .success(let v) = result, let json = v as? String { ZoomDomDump.append(kind: page.kindName, json: json) }
            }
        }
        #endif
        if page.isSignIn { sawSignIn = true }
        if page == .createdApps {
            scanAppRows(page) { [weak self] in
                self?.followDialog(page) { self?.drawCoach(page) }
            }
        } else {
            if appRows != nil { appRows = nil; updateBar() }
            drawCoach(page)
        }
        readKeys(on: page)
    }

    /// Computes the coach for the page and draws (or clears) it; the script's one-word answer is noted in DEBUG.
    private func drawCoach(_ page: ZoomMarketplacePage) {
        guard let webView else { return }
        #if DEBUG
        if ZoomRecorder.coachOff { return }   // a recording run sees Zoom's pages untouched
        #endif
        let part = page.app.map { $0 == .sdk ? ZoomGuidePart.meetingApp : .hostingApp } ?? requestedPart
        var coach = ZoomCoachRules.offeringAction(
            ZoomCoachRules.coach(part: part, page: page, keysFilled: keysFilled(), tipsOn: tipsOn,
                                 needsApp: needsApp(part), appRows: appRows, missingKeys: missingKeys(page)), part: part, page: page)
        coach?.busy = working
        coach?.note = actorNote
        let ring = Self.ringColor, mark = Self.markDataURI, fill = Self.fillColor
        webView.evaluateJavaScript(ZoomCoachScript.source, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .failure(let error) = result { self.note(page, "coach-source-error " + Self.describe(error)) }
                self.webView?.evaluateJavaScript(ZoomCoachScript.call(coach?.json, ring: ring, mark: mark, fill: fill), in: nil, in: .defaultClient) { result in
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

    /// A dialog that names a type ("Create a Server-to-Server OAuth app", or the type picked in "What kind of app")
    /// moves the coach, the bar and the next pages to that part (spec R16).
    private func followDialog(_ page: ZoomMarketplacePage, then done: @escaping () -> Void) {
        webView?.evaluateJavaScript(ZoomDialogScript.source, in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .success(let value) = result, let json = value as? String, json != "null",
                   let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                   let part = ZoomCoachRules.partFollowing(obj["heading"] as? String, obj["chosen"] as? String), part != self.requestedPart {
                    self.requestedPart = part
                    self.note(page, "part follows dialog")
                    self.updateBar()
                }
                done()
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

    private func readKeys(on page: ZoomMarketplacePage, then done: (() -> Void)? = nil) {
        #if DEBUG
        if ZoomRecorder.coachOff { done?(); return }   // no automatic key fill in a recording run
        #endif
        guard let fields = ZoomMarketplacePages.keyFields(on: page), let webView else { done?(); return }
        webView.evaluateJavaScript(ZoomKeyReaderScript.call(fields: fields), in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                if case .failure(let error) = result { self?.note(page, "reader-error " + Self.describe(error)) }
                guard let self, case .success(let value) = result, let json = value as? String,
                      let data = json.data(using: .utf8),
                      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                      self.webView?.url.flatMap(ZoomMarketplacePages.page(for:)) == page else { done?(); return }
                // Lengths only: how each field was read ("accountID=input22;clientID=missing").
                if let diag = raw["_diag"] { self.note(page, "read " + diag) }
                var found: [ZoomKeyField: String] = [:]
                if let v = raw["accountID"] { found[.accountID] = v }
                if let v = raw["clientID"] { found[.clientID] = v }
                if let v = raw["clientSecret"] { found[.clientSecret] = v }
                if !found.isEmpty { self.onKeys(page, found) }
                done?()
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
                done(ZoomPageSnapshot.decode(reading: json, address: ZoomMarketplacePages.page(for: url)))
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

    // MARK: Do this step (R16)

    /// Runs the page's one safe step, on the person's press only (the coach card's button).
    private func runStep(_ name: String) {
        guard !working, let webView, let url = webView.url, ZoomMarketplacePages.isMarketplace(url),
              let page = ZoomMarketplacePages.page(for: url) else { return }
        let part = page.app.map { $0 == .sdk ? ZoomGuidePart.meetingApp : .hostingApp } ?? requestedPart
        // The card names the step it is offering; Swift only runs a known step on that step's own pages.
        guard let step = ZoomActorStep(rawValue: name), ZoomActorRules.pageAllows(step, page) else { note(page, "step refused"); return }
        working = true; actorNote = nil
        updateBar(); drawCoach(page)
        note(page, "step:\(step.logName) start")
        if step == .readKeys { runReadKeys(page, part: part); return }
        webView.callAsyncJavaScript(ZoomActorScript.body, arguments: ZoomActorScript.arguments(step, part: part), in: nil,
                                    in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                var r = ZoomActorResult(code: "error")
                switch result {
                case .success(let value):
                    if let json = value as? String, let decoded = try? JSONDecoder().decode(ZoomActorResult.self, from: Data(json.utf8)) { r = decoded }
                case .failure(let error):
                    self.note(page, "step:\(step.logName) error " + Self.describe(error))
                }
                for line in r.log ?? [] { self.note(page, "step:\(step.logName) \(line)") }
                self.note(page, "step:\(step.logName) result \(r.code)")
                self.actorNote = ZoomActorRules.message(step, r)
                self.working = false
                self.updateBar()
                self.refresh()
                self.onStepDone()
            }
        }
    }

    /// Do this step on a keys page: read what the page shows, then press the page's OWN Copy control for each key still
    /// missing (Greenroom picks each up from the clipboard), and put the clipboard back as it was. Nothing else is pressed.
    private func runReadKeys(_ page: ZoomMarketplacePage, part: ZoomGuidePart) {
        readKeys(on: page) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let pb = NSPasteboard.general
                let plain = (pb.types ?? []).allSatisfy { $0 == .string }
                let previous = plain ? pb.string(forType: .string) : nil
                var missing = self.missingKeys(page) ?? []
                let wanted = missing.count
                var copied = 0
                var code = missing.isEmpty ? "done" : "no-copy"
                for field in missing {
                    let args = ZoomActorScript.arguments(.readKeys, part: part, field: ZoomCoachRules.keyLabel(field))
                    let r = try? await self.webView?.callAsyncJavaScript(ZoomActorScript.body, arguments: args, in: nil, contentWorld: .defaultClient)
                    if let json = r as? String, let d = try? JSONDecoder().decode(ZoomActorResult.self, from: Data(json.utf8)) {
                        for line in d.log ?? [] { self.note(page, "step:keys \(line)") }
                        guard d.code == "copied" else { break }
                    } else { break }
                    // The clipboard pickup fills the field; wait for it (at most 3s).
                    for _ in 0..<10 {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if !(self.missingKeys(page) ?? []).contains(field) { copied += 1; break }
                    }
                }
                missing = self.missingKeys(page) ?? []
                if wanted > 0 { code = missing.isEmpty ? "done" : (copied > 0 || missing.count < wanted ? "partial" : "no-copy") }
                // Put the clipboard back as it was (or clear it): the secret must not stay on it.
                pb.clearContents()
                if case .restore(let text) = ZoomActorRules.restoration(previous: previous) { pb.setString(text, forType: .string) }
                self.pasteboardCount = pb.changeCount
                self.note(page, "step:keys result \(code)")
                self.actorNote = ZoomActorRules.message(.readKeys, ZoomActorResult(code: code))
                self.working = false
                self.updateBar()
                self.refresh()
                self.onStepDone()
            }
        }
    }

    /// Brand.buttonFill as a CSS colour: the coach's "Do this step" fill (white label).
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
        case "zoomCopy": copied(message.body as? String)
        case "coach":
            switch message.body as? String {
            case "hide": tipsOn = false
            case .some(let body) where body.hasPrefix("do:"): runStep(String(body.dropFirst(3)))
            default: break
            }
        default: break
        }
    }

    /// What Zoom's own Copy tried to put on the clipboard (live run, 2026-11-27: WebKit refuses a
    /// page's clipboard write without a real click, so a pressed Copy copied nothing). Kept only on a
    /// credentials page and only when key-shaped; in memory, never logged.
    private(set) var lastCopiedKey: (text: String, at: Date)?
    var onCopiedKey: ((String) -> Void)?
    private func copied(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), let url = webView?.url,
              let page = ZoomMarketplacePages.page(for: url), page.isCredentialsPage, ZoomMarketplacePages.isKey(text) else { return }
        lastCopiedKey = (text, Date())
        #if DEBUG
        note(page, "copied key len=\(text.count)")
        #endif
        onCopiedKey?(text)
    }

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
