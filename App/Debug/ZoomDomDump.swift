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

    // MARK: A whitelist of look-only commands (open and close things, never create or save)

    static let commandURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Greenroom/zoom-probe-cmd")
    private static var timer: Timer?

    /// The ONLY things the probe may do on the real account: open the + menu, open the Build dialog, Cancel a dialog or
    /// panel, open the Add Scopes panel, go to an address. Never Create, Save, Done, a toggle, Activate, Regenerate or Delete.
    static let commands: [String: String] = [
        "openPlus": "var b=document.querySelector('button[aria-label=\"Add\"]'); if(b) b.click();",
        "clickBuild": "var els=document.querySelectorAll('[role=menuitem],li,button'); for(var i=0;i<els.length;i++){ if((els[i].textContent||'').trim().indexOf('Build')===0 && els[i].closest('[role=menu],[role=presentation],.MuiPopover-root,.MuiMenu-root')){ els[i].click(); break; } }",
        "cancelDialog": "var ds=document.querySelectorAll('[role=dialog],[aria-modal=\"true\"],.MuiDialog-root,.MuiDrawer-root'); for(var i=ds.length-1;i>=0;i--){ var bs=ds[i].querySelectorAll('button'); for(var j=0;j<bs.length;j++){ if((bs[j].textContent||'').trim()==='Cancel'){ bs[j].click(); i=-1; break; } } }",
        "openAddScopes": "var bs=document.querySelectorAll('button,[role=button]'); for(var i=0;i<bs.length;i++){ var t=(bs[i].textContent||'').replace(/\\s+/g,' ').trim(); if(t.replace('+','').trim().toLowerCase()==='add scopes'){ bs[i].click(); break; } }",
    ]

    /// Polls `zoom-probe-cmd` (one word, or `go <https://marketplace.zoom.us/...>`); runs it and deletes the file.
    @MainActor static func startCommandsIfRequested() {
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let raw = try? String(contentsOf: commandURL, encoding: .utf8) else { return }
                try? FileManager.default.removeItem(at: commandURL)
                let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if word.hasPrefix("go "), let u = URL(string: String(word.dropFirst(3))), ZoomMarketplacePages.isMarketplace(u) {
                    ZoomMarketplaceWindow.shared.debugLoad(u)
                } else if let js = commands[word] {
                    ZoomMarketplaceWindow.shared.debugRun(js)
                }
            }
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
          if (labelsOnly) {
            // R5's reader: where do the credential labels and their inputs sit? Lengths only, never values.
            out.cred = [];
            ['Account ID', 'Client ID', 'Client Secret'].forEach(function (w) {
              var all = document.body.getElementsByTagName('*');
              for (var i = 0; i < all.length; i++) {
                var el = all[i], own = '';
                for (var j = 0; j < el.childNodes.length; j++) if (el.childNodes[j].nodeType === 3) own += el.childNodes[j].nodeValue;
                if (own.replace(/\\s+/g, ' ').trim() !== w || !vis(el)) continue;
                var p = el, found = null, hops = 0;
                for (; p && p !== document.body && hops < 5 && !found; hops++, p = p.parentElement) {
                  var ins = p.querySelectorAll('input');
                  for (var k = 0; k < ins.length; k++) if (el.compareDocumentPosition(ins[k]) & 4) { found = ins[k]; break; }
                }
                var around = [], q = el;
                for (var up = 0; up < 3 && q && q !== document.body; up++, q = q.parentElement) {
                  Array.prototype.forEach.call(q.children, function (ch) {
                    var t = (ch.textContent || '').replace(/\\s+/g, ' ').trim();
                    around.push({ up: up, tag: ch.tagName.toLowerCase(), len: t.length, keyLike: /^[A-Za-z0-9_-]{10,64}$/.test(t), hasInput: !!ch.querySelector('input'), isLabel: t === w });
                  });
                }
                out.cred.push({ around: around.slice(0, 14), label: w, tag: el.tagName.toLowerCase(), path: path(el), hops: hops, input: found ? { type: found.getAttribute('type') || '', len: (found.value || '').length, readonly: !!found.readOnly, path: path(found) } : null });
                break;
              }
            });
            return JSON.stringify(out);
          }
          out.rows = [];
          document.querySelectorAll('tr,[role=row]').forEach(function (r) {
            if (out.rows.length > 20) return;
            var cells = r.querySelectorAll('th,td,[role=cell],[role=gridcell],[role=columnheader]');
            out.rows.push({ vis: vis(r), h: Math.round(r.getBoundingClientRect().height), cells: Array.prototype.map.call(cells, function (c) { return clip(c.textContent, 40); }) });
          });
          var sel = 'button,[role=button],a[href],[role=menuitem],[role=tab],[role=switch],[role=checkbox],[role=radio],input,[role=option],th,[role=columnheader]';
          out.items = [];
          function tree(el, depth) {
            var o = { t: el.tagName.toLowerCase(), r: el.getAttribute('role') || '', c: clip((typeof el.className === 'string' ? el.className : '').split(' ').slice(0, 2).join(' '), 50),
                      ac: el.getAttribute('aria-checked') || el.getAttribute('aria-selected') || '', ty: el.getAttribute('type') || '', own: clip(Array.prototype.filter.call(el.childNodes, function (n) { return n.nodeType === 3; }).map(function (n) { return n.nodeValue; }).join(' '), 60), k: [] };
            if (depth < 5) Array.prototype.forEach.call(el.children, function (ch, i) { if (i < 6) o.k.push(tree(ch, depth + 1)); });
            return o;
          }
          document.querySelectorAll('[role=dialog] li').forEach(function (li, i) { if (i < 3) out.items.push(tree(li, 0)); });
          document.querySelectorAll(sel).forEach(function (el) {
            if (!vis(el) || out.controls.length > 160) return;
            var t = (el.tagName || '').toLowerCase();
            var d = { tag: t, role: el.getAttribute('role') || '', type: el.getAttribute('type') || '', ariaLabel: clip(el.getAttribute('aria-label'), 50),
                      ariaChecked: el.getAttribute('aria-checked') || '', checked: el.checked === true, disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
                      placeholder: clip(el.getAttribute('placeholder'), 40), path: path(el) };
            if (t !== 'input') d.text = clip(el.textContent, 70);
            else { var n = el, hops = 0; while (n && hops++ < 4 && clip(n.textContent, 70).length < 3) n = n.parentElement; d.near = clip(n ? n.textContent : '', 70); }
            out.controls.push(d);
          });
          return JSON.stringify(out);
        })(\(labelsOnly ? "true" : "false"));
        """
    }
}
#endif
