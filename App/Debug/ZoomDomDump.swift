#if DEBUG
//
//  ZoomDomDump.swift
//  Greenroom
//
//  DEBUG-only: with the launch argument `-zoomDomDump YES`, the Zoom window writes the
//  STRUCTURE of Marketplace's page to ~/Library/Logs/Greenroom/zoom-dom.jsonl on every
//  refresh: dialog headings, and each button, link, menu item, tab, switch, checkbox,
//  radio and input's tag, role, aria state, type, checked and disabled state, visible
//  text (any key-like run of 16+ characters is replaced by its length) and a short
//  path. NEVER an input's value. On credentials pages only headings and labels.
//  `-zoomWindowURL <url>` opens the window at a marketplace.zoom.us address at launch.
//  Debug UI never ships: this whole file, and every call to it, is inside #if DEBUG.
//
import Foundation
import WebKit

enum ZoomDomDump {
    static var enabled: Bool {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-zoomDomDump"), i + 1 < a.count else { return false }
        return ["YES", "yes", "1", "true"].contains(a[i + 1])
    }

    /// `-zoomWindowURL <https://marketplace.zoom.us/...>`: only the real Marketplace host.
    static var startURL: URL? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-zoomWindowURL"), i + 1 < a.count, let u = URL(string: a[i + 1]),
              ZoomMarketplacePages.isMarketplace(u) else { return nil }
        return u
    }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Greenroom/zoom-dom.jsonl")

    static func append(kind: String, json: String) {
        let line = "{\"ts\":\"\(ISO8601DateFormatter().string(from: Date()))\",\"page\":\"\(kind)\",\"dom\":\(json)}\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }

    /// Read-only. `labelsOnly`: credentials pages, where no control is described.
    static func script(labelsOnly: Bool) -> String {
        """
        (function (labelsOnly) {
          function scrub(s) { return s.replace(/[A-Za-z0-9_\\-]{16,}/g, function (m) { return '[token ' + m.length + ']'; }); }
          function clip(s, n) { s = scrub((s || '').replace(/\\s+/g, ' ').trim()); return s.length > n ? s.slice(0, n) + '...' : s; }
          function vis(el) { var r = el.getBoundingClientRect(); if (r.width < 2 || r.height < 2) return false; var c = getComputedStyle(el); return c.visibility !== 'hidden' && c.display !== 'none'; }
          function path(el) { var p = [], n = 0; while (el && el.nodeType === 1 && el !== document.body && n++ < 5) { var t = el.tagName.toLowerCase(); var r = el.getAttribute('role'); p.unshift(t + (r ? '[' + r + ']' : '')); el = el.parentElement; } return p.join(' > '); }
          var out = { title: clip(document.title, 60), dialogs: [], headings: [], controls: [] };
          document.querySelectorAll('[role=dialog],[aria-modal="true"],.MuiDialog-root,.MuiDrawer-root,[role=menu]').forEach(function (d) {
            if (!vis(d)) return;
            var h = d.querySelector('h1,h2,h3,h4,h5,h6,[role=heading]');
            out.dialogs.push({ tag: d.tagName.toLowerCase(), role: d.getAttribute('role') || '', cls: clip((typeof d.className === 'string' ? d.className : '').split(' ')[0], 40), heading: clip(h ? h.textContent : '', 80), path: path(d) });
          });
          document.querySelectorAll('h1,h2,h3,[role=heading],label').forEach(function (h) { if (vis(h) && out.headings.length < 60) out.headings.push({ tag: h.tagName.toLowerCase(), text: clip(h.textContent, 80) }); });
          if (labelsOnly) return JSON.stringify(out);
          var sel = 'button,[role=button],a[href],[role=menuitem],[role=tab],[role=switch],[role=checkbox],[role=radio],input,[role=option],th,[role=columnheader]';
          document.querySelectorAll(sel).forEach(function (el) {
            if (!vis(el) || out.controls.length > 160) return;
            var t = (el.tagName || '').toLowerCase();
            var d = { tag: t, role: el.getAttribute('role') || '', type: el.getAttribute('type') || '', ariaLabel: clip(el.getAttribute('aria-label'), 50),
                      ariaChecked: el.getAttribute('aria-checked') || '', checked: el.checked === true, disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
                      placeholder: clip(el.getAttribute('placeholder'), 40), path: path(el) };
            if (t !== 'input') d.text = clip(el.textContent, 70);
            out.controls.push(d);
          });
          return JSON.stringify(out);
        })(\(labelsOnly ? "true" : "false"));
        """
    }
}
#endif
