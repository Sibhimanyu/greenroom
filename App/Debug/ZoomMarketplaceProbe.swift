#if DEBUG
//
//  ZoomMarketplaceProbe.swift
//  Greenroom
//
//  DEBUG-only research probe. Opens https://marketplace.zoom.us/user/build in a
//  real window and logs how Marketplace's pages are addressed and laid out, so a
//  guided Zoom setup can be designed against facts. Debug UI never ships: this
//  whole file, and every call to it, is inside #if DEBUG.
//
//  Log: ~/Library/Logs/Greenroom/zoom-marketplace-probe.jsonl, one JSON object
//  per line. It records structure and LENGTHS only: never the text of an input,
//  nor of anything next to Account ID / Client ID / Client Secret / Secret Token
//  / Verification Token.
//
//  Open it from the app menu ("Zoom Marketplace probe...") or launch with
//  `-zoomMarketplaceProbe YES`.
//

import AppKit
import SwiftUI
import WebKit

@MainActor
final class ZoomMarketplaceProbe: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSWindowDelegate {
    static let shared = ZoomMarketplaceProbe()

    static let startURL = URL(string: "https://marketplace.zoom.us/user/build")!
    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Greenroom/zoom-marketplace-probe.jsonl")

    private var window: NSWindow?
    private var webView: WKWebView?
    private var pending: DispatchWorkItem?

    /// Opens the window, or brings it forward when it is already open.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let ucc = config.userContentController
        ucc.add(self, name: "route")
        ucc.addUserScript(WKUserScript(source: Self.routeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = Self.safariUA
        web.navigationDelegate = self
        web.uiDelegate = self

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 850),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Zoom Marketplace probe"
        win.contentView = web
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        window = win
        webView = web
        web.load(URLRequest(url: Self.startURL))
    }

    func windowWillClose(_ notification: Notification) {
        pending?.cancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "route")
        webView?.navigationDelegate = nil
        webView = nil
        window = nil
    }

    /// Opens the probe at launch when asked to. Called from AppDelegate.
    static func startIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-zoomMarketplaceProbe"), i + 1 < args.count,
              ["YES", "yes", "1", "true"].contains(args[i + 1]) else { return }
        DispatchQueue.main.async { shared.show() }
    }

    // MARK: Recording

    private func scheduleRecord(_ reason: String) {
        record(reason)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.record(reason + "+1.5s") }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func record(_ reason: String) {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.snapshotScript) { [weak self] result, error in
            guard self != nil else { return }
            var entry: [String: Any] = [
                "ts": ISO8601DateFormatter().string(from: Date()),
                "reason": reason,
                "url": Self.safeURL(webView.url?.absoluteString ?? ""),
            ]
            if let s = result as? String,
               let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                entry.merge(obj) { _, new in new }
            } else if let error {
                entry["error"] = String(describing: error)
            }
            Self.append(entry)
        }
    }

    /// Scheme, host and path only; each query value becomes its length and the
    /// fragment is dropped, so sign-in codes and tokens in a redirect never reach the log.
    static func safeURL(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return "" }
        c.fragment = nil
        c.queryItems = c.queryItems?.map { URLQueryItem(name: $0.name, value: "[\($0.value?.count ?? 0)]") }
        return c.string ?? ""
    }

    private static func append(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }

    // MARK: WKNavigationDelegate / WKScriptMessageHandler

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { scheduleRecord("commit") }

    /// Links that open a new window (Marketplace's "Developers", target=_blank)
    /// load in this same window instead, and are logged as such.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            Self.append(["ts": ISO8601DateFormatter().string(from: Date()), "reason": "new-window", "url": Self.safeURL(url.absoluteString)])
            webView.load(URLRequest(url: url))
        }
        return nil
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { scheduleRecord("finish") }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = (message.body as? String) ?? ""
        let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
        scheduleRecord("route:" + (parts.first ?? "") + (parts.count > 1 ? " " + Self.safeURL(parts[1]) : ""))
    }

    // MARK: Scripts

    /// Reports history.pushState / replaceState / popstate / hashchange.
    static let routeScript = """
    (function () {
      if (window.__grProbe) return; window.__grProbe = true;
      function post(kind) {
        try { window.webkit.messageHandlers.route.postMessage(kind + " " + location.href); } catch (e) {}
      }
      ['pushState', 'replaceState'].forEach(function (name) {
        var orig = history[name];
        history[name] = function () {
          var r = orig.apply(this, arguments);
          setTimeout(function () { post(name); }, 0);
          return r;
        };
      });
      window.addEventListener('popstate', function () { post('popstate'); });
      window.addEventListener('hashchange', function () { post('hashchange'); });
    })();
    """

    /// Returns a JSON string. Structure and lengths only; no input or credential text.
    static let snapshotScript = """
    (function () {
      var CRED = ['Account ID', 'Client ID', 'Client Secret', 'Secret Token', 'Verification Token'];
      // Every recorded text passes here: any key-like run (16+ letters, digits, _ or -,
      // no spaces) becomes its length only, so a key shown beside a label never lands in the log.
      function scrub(s) { return s.replace(/[A-Za-z0-9_\\-]{16,}/g, function (m) { return '[token ' + m.length + ']'; }); }
      function clip(s, n) { s = scrub((s || '').replace(/\\s+/g, ' ').trim()); return s.length > n ? s.slice(0, n) + '...' : s; }
      function path(el) {
        var parts = [];
        while (el && el.nodeType === 1 && parts.length < 6 && el !== document.body) {
          var p = el.tagName.toLowerCase();
          if (el.id) { p += '#' + el.id; parts.unshift(p); break; }
          var c = (typeof el.className === 'string' ? el.className : '').trim().split(/\\s+/)[0];
          if (c) p += '.' + c;
          parts.unshift(p);
          el = el.parentElement;
        }
        return parts.join(' > ');
      }
      function dataNames(el) {
        var out = [];
        for (var i = 0; i < el.attributes.length; i++) {
          if (el.attributes[i].name.indexOf('data-') === 0) out.push(el.attributes[i].name);
        }
        return out;
      }
      function describe(el) {
        return {
          tag: el.tagName.toLowerCase(), id: el.id || '', name: el.getAttribute('name') || '',
          type: el.getAttribute('type') || '',
          cls: clip(typeof el.className === 'string' ? el.className : '', 120),
          data: dataNames(el), path: path(el)
        };
      }
      function labelFor(el) {
        var t = '';
        var aria = el.getAttribute('aria-label');
        if (aria) t = aria;
        else if (el.id) {
          var l = document.querySelector('label[for="' + el.id.replace(/"/g, '') + '"]');
          if (l) t = l.textContent;
        }
        if (!t) { var cl = el.closest('label'); if (cl) t = cl.textContent; }
        if (!t && el.previousElementSibling) t = el.previousElementSibling.textContent;
        t = clip(t, 60);
        return t;
      }
      function own(el) {
        var t = '';
        for (var i = 0; i < el.childNodes.length; i++) if (el.childNodes[i].nodeType === 3) t += el.childNodes[i].nodeValue;
        return clip(t, 200);
      }
      var out = { title: document.title, headings: [], links: [], fields: [], buttons: [] };
      document.querySelectorAll('h1,h2,h3').forEach(function (h) { out.headings.push({ tag: h.tagName.toLowerCase(), text: clip(h.textContent, 120) }); });

      var seen = {};
      document.querySelectorAll('a[href], [role=tab], nav a, nav li, [role=menuitem]').forEach(function (el) {
        var href = el.getAttribute('href') || (el.querySelector('a[href]') || {getAttribute: function () { return ''; }}).getAttribute('href') || '';
        if (href.indexOf('marketplace.zoom.us') < 0 && href.charAt(0) !== '/') return;
        var key = href + '|' + el.textContent;
        if (seen[key]) return; seen[key] = 1;
        var d = describe(el);
        out.links.push({ text: clip(el.textContent, 80), href: href.split('#')[0].split('?')[0] + (href.indexOf('?') >= 0 ? '?[query]' : ''), tag: d.tag, role: el.getAttribute('role') || '',
                         selected: el.getAttribute('aria-selected') || el.getAttribute('aria-current') || '', path: d.path });
      });

      // Inputs: label and length only.
      document.querySelectorAll('input, textarea').forEach(function (el) {
        var f = describe(el);
        f.kind = 'input';
        f.label = labelFor(el);
        f.readonly = !!el.readOnly;
        f.valueLength = (el.value || '').length;
        out.fields.push(f);
      });

      // Credential labels: find the smallest element whose own visible text is the label.
      var seenCred = [];
      document.querySelectorAll('body *').forEach(function (el) {
        if (el.children.length > 3) return;
        var t = own(el);
        if (CRED.indexOf(t) < 0 && CRED.indexOf(clip(el.textContent, 40)) < 0) return;
        var label = CRED.indexOf(t) >= 0 ? t : clip(el.textContent, 40);
        if (seenCred.indexOf(el) >= 0) return; seenCred.push(el);
        var f = describe(el);
        f.kind = 'credential-label';
        f.label = label;
        // The adjacent displayed value: next sibling, else parent's text after the label. Length only.
        var adj = el.nextElementSibling;
        var len = adj ? (adj.textContent || '').trim().length : -1;
        if (len <= 0 && el.parentElement) {
          var pl = (el.parentElement.textContent || '').trim().length - (el.textContent || '').trim().length;
          len = pl;
        }
        f.adjacentValueLength = len;
        f.adjacentPath = adj ? path(adj) : '';
        var inp = (adj && adj.querySelector && adj.querySelector('input,textarea')) ||
                  (el.parentElement && el.parentElement.querySelector('input,textarea'));
        if (inp) f.adjacentInputValueLength = (inp.value || '').length;
        out.fields.push(f);
      });

      var n = 0;
      document.querySelectorAll('button, [role=button]').forEach(function (b) {
        if (n >= 60) return;
        n++;
        out.buttons.push({ text: clip(b.textContent, 80), disabled: !!b.disabled || b.getAttribute('aria-disabled') === 'true', path: path(b) });
      });
      return JSON.stringify(out);
    })();
    """
}

#endif
