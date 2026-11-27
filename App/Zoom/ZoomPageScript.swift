//
//  ZoomPageScript.swift
//  Greenroom
//
//  The ONE page script that reads Zoom Marketplace into a `ZoomPageSnapshot`
//  (docs/specs/zoom-setup-flow.md), and the ONE finder library behind it:
//  `resolve(id)` turns a `ZoomControl` ID into the page's element, so the reader
//  (which controls are present), and later the coach (which one to spotlight) and the
//  actor (which one to press) always mean the same element. It replaces the older
//  finder, dialog, app-list, key-reader and sign-in scripts.
//
//  What it knows about the real pages (docs/specs/zoom-setup-assist.md, R15 to R19):
//  Created apps is a table that fills late; the round + is `button[aria-label="Add"]`
//  and its menu item reads "Build app"; dialogs are MUI `role=dialog` with radio cards,
//  then a name dialog ("Create a General app" / "Create a Server-to-Server OAuth app")
//  with an App Name input; the General app's credentials card shows the Client ID as
//  plain text and the secret behind a hover-only Copy; Server-to-Server credentials are
//  read-only inputs with visible Copy buttons; Embed's Meeting SDK is an
//  `input[type=checkbox]`; the Add scopes dialog has a "Search scope" input and
//  `li > div[role=button]` rows with a checkbox and the scope in `p > span`, then "Done".
//
//  READ ONLY: this script never clicks, focuses, types, dispatches an event, or talks
//  to the network. It returns one JSON string. Key values are in that string (Swift
//  keeps them in memory only; recordings get `redacted()`). Off Marketplace's own host
//  it reports only whether a "Try another way" button is there.
//
import Foundation

enum ZoomPageScript {
    private static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The finder library: plain function declarations to embed inside a function body.
    /// `resolve(id)` -> element or null; `allControlIds()` -> every ID worth testing here.
    static let library: String = """
      var SCOPES = \(json(ZoomScopes.names));
      var NAV = \(json(Dictionary(uniqueKeysWithValues: ZoomNavLink.allCases.map { ($0.rawValue, $0.label) })));
      var KEYLABEL = \(json(Dictionary(uniqueKeysWithValues: [ZoomKeyField.accountID, .clientID, .clientSecret].map { ($0.rawValue, $0.label) })));
      var INFO = \(json(Dictionary(uniqueKeysWithValues: ZoomInfoField.allCases.map { ($0.rawValue, $0.label) })));
      var FIXED = \(json(ZoomControl.fixedIDs));
      var SCOPE_RE = /^[a-z][a-z0-9_]*(:[a-z0-9_]+){2,}$/;
      var KEY_RE = /^[A-Za-z0-9_-]{10,64}$/;

      function norm(s) { return (s || '').replace(/\\s+/g, ' ').replace(/\\+/g, '').trim().toLowerCase(); }
      function clip(s, n) { s = (s || '').replace(/\\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n) : s; }
      function scrub(s) { return (s || '').replace(/[A-Za-z0-9_\\-]{16,}/g, function (m) { return '[token ' + m.length + ']'; }); }
      function shown(el) {
        var r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) return false;
        var cs = window.getComputedStyle(el);
        return cs.visibility !== 'hidden' && cs.display !== 'none';
      }
      function ownText(el) {
        var t = '';
        for (var i = 0; i < el.childNodes.length; i++) if (el.childNodes[i].nodeType === 3) t += el.childNodes[i].nodeValue;
        return norm(t);
      }
      function path() { return location.pathname || ''; }
      function onMarketplace() { return location.hostname === 'marketplace.zoom.us'; }
      function keysPath() {
        var p = path();
        return p.indexOf('/credentials') >= 0 || (p.indexOf('/information') >= 0 && p.indexOf('/develop/applications/') >= 0);
      }
      function isDisabled(el) {
        return !!el.disabled || el.getAttribute('aria-disabled') === 'true' || /Mui-disabled/.test(typeof el.className === 'string' ? el.className : '');
      }
      function isOn(el) {
        if (!el) return false;
        return el.checked === true || el.getAttribute('aria-checked') === 'true' || !!el.closest('.Mui-checked');
      }

      // The smallest visible element whose own text is the label.
      function textElement(label, scope) {
        var want = norm(label), best = null, bestArea = 1e12;
        var root = scope || document.body;
        var all = root ? root.getElementsByTagName('*') : [];
        for (var i = 0; i < all.length; i++) {
          var el = all[i], tag = el.tagName;
          if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') continue;
          if (ownText(el) !== want && !(el.children.length === 0 && norm(el.textContent) === want)) continue;
          if (!shown(el)) continue;
          var r = el.getBoundingClientRect(), a = r.width * r.height;
          if (a < bestArea) { best = el; bestArea = a; }
        }
        return best;
      }
      // A visible button, link or role=button whose whole text (ignoring +) is the label.
      function buttonIn(scope, label) {
        var want = norm(label);
        var els = (scope || document).querySelectorAll('button,[role=button],a');
        for (var i = 0; i < els.length; i++) if (norm(els[i].textContent) === want && shown(els[i])) return els[i];
        return null;
      }
      function openMenuItem(label) {
        var want = norm(label), best = null, bestArea = 1e12;
        var els = document.querySelectorAll('[role=menuitem],[role=option],li,button,[role=button],a');
        for (var i = 0; i < els.length; i++) {
          if (norm(els[i].textContent) !== want || !shown(els[i])) continue;
          if (!els[i].closest('[role=menu],[role=listbox],[role=presentation],[role=tooltip],.MuiPopover-root,.MuiMenu-root,.MuiPopper-root')) continue;
          var r = els[i].getBoundingClientRect(), a = r.width * r.height;
          if (a < bestArea) { best = els[i]; bestArea = a; }
        }
        return best;
      }
      // The round + (Build app): button[aria-label="Add"] on the real page; else a build/create/add label; else the button after "Developer".
      function findPlus() {
        if (path().indexOf('/user/build') !== 0) return null;
        var exact = document.querySelector('button[aria-label="Add"]');
        if (exact && shown(exact)) return exact;
        var btns = document.querySelectorAll('button,[role=button],a');
        for (var i = 0; i < btns.length; i++) {
          var hint = norm((btns[i].getAttribute('aria-label') || '') + ' ' + (btns[i].getAttribute('title') || ''));
          if (shown(btns[i]) && (hint.indexOf('build') >= 0 || hint.indexOf('create') >= 0 || hint.indexOf('add') >= 0)) return btns[i];
        }
        var el = textElement('Developer');
        for (var hops = 0; el && el !== document.body && hops < 4; hops++, el = el.parentElement) {
          var sib = el.nextElementSibling;
          if (!sib) continue;
          var b = sib.matches('button,[role=button],a') ? sib : sib.querySelector('button,[role=button],a');
          if (b && shown(b)) return b;
        }
        return null;
      }

      // The visible modal: a dialog, an aria-modal element, a MUI dialog root or drawer with a visible paper.
      // (A MUI menu popover is not a dialog.)
      function openDialog() {
        var els = document.querySelectorAll('[role=dialog],[aria-modal="true"],.MuiDialog-root,.MuiDrawer-root');
        for (var i = els.length - 1; i >= 0; i--) {
          var el = els[i];
          var paper = el.matches('.MuiDialog-root,.MuiDrawer-root') ? (el.querySelector('.MuiDialog-paper,.MuiDrawer-paper,[role=dialog]') || el) : el;
          if (shown(paper)) return paper;
        }
        return null;
      }
      function dialogHeading(dlg) {
        var h = dlg.querySelector('h1,h2,h3,h4,h5,h6,[role=heading]');
        return clip(h ? h.textContent : (dlg.textContent || ''), 80).toLowerCase();
      }
      function searchIn(scope) {
        var inputs = scope.querySelectorAll('input');
        for (var i = 0; i < inputs.length; i++) {
          var hint = norm((inputs[i].getAttribute('placeholder') || '') + ' ' + (inputs[i].getAttribute('aria-label') || ''));
          if (hint.indexOf('search') >= 0 && shown(inputs[i])) return inputs[i];
        }
        return null;
      }
      function nameInput(dlg) {
        var ins = dlg.querySelectorAll('input[type=text],input:not([type])');
        for (var i = 0; i < ins.length; i++) if (shown(ins[i])) return ins[i];
        return null;
      }
      function nameDialogApp(heading) {
        if (heading.indexOf('create a general app') === 0) return 'meeting';
        if (/^create a server.to.server oauth app/.test(heading)) return 'hosting';
        if (heading.indexOf('create a ') === 0) return 'other';
        return null;
      }
      function closeIn(dlg) {
        var btns = dlg.querySelectorAll('button,[role=button]');
        for (var i = 0; i < btns.length; i++) {
          if (!shown(btns[i])) continue;
          var hint = norm((btns[i].getAttribute('aria-label') || '') + ' ' + (btns[i].getAttribute('title') || ''));
          if (hint.indexOf('close') >= 0 || norm(btns[i].textContent) === 'close') return btns[i];
        }
        for (var j = 0; j < btns.length; j++) {
          if (shown(btns[j]) && !norm(btns[j].textContent) && !btns[j].getAttribute('aria-label')) return btns[j];
        }
        return null;
      }

      // The "What kind of app" radio cards: [{choice, radio, row}].
      function typeChoices(dlg) {
        var radios = dlg.querySelectorAll('input[type=radio],[role=radio]'), out = [];
        for (var i = 0; i < radios.length; i++) {
          var row = radios[i].closest('label') || radios[i].parentElement;
          for (var hops = 0; row && row.parentElement && row.parentElement !== dlg && hops < 4; hops++) {
            if (row.parentElement.querySelectorAll('input[type=radio],[role=radio]').length > 1) break;
            row = row.parentElement;
          }
          var t = norm(row ? row.textContent : '');
          var choice = t.indexOf('general app') === 0 ? 'general' : /^server.to.server/.test(t) ? 'serverToServer' : t.indexOf('webhook') === 0 ? 'webhookOnly' : 'other';
          out.push({ choice: choice, radio: radios[i], row: row });
        }
        return out;
      }

      // The Add scopes rows: [{scope, box}] (li > div[role=button] with a checkbox and the scope string in p > span).
      function scopeRows(dlg) {
        var out = [], boxes = dlg.querySelectorAll('input[type=checkbox],[role=checkbox]');
        for (var i = 0; i < boxes.length; i++) {
          var p = boxes[i].parentElement, found = null;
          for (var hops = 0; p && p !== dlg && hops < 6 && !found; hops++, p = p.parentElement) {
            if (p.querySelectorAll('input[type=checkbox],[role=checkbox]').length !== 1) break;
            var leaves = p.querySelectorAll('span,p,div');
            for (var j = 0; j < leaves.length; j++) {
              if (leaves[j].children.length) continue;
              var t = (leaves[j].textContent || '').trim();
              if (SCOPE_RE.test(t)) { found = t; break; }
            }
          }
          if (found) out.push({ scope: found, box: boxes[i] });
        }
        return out;
      }
      // Scope strings shown on the page itself, outside any dialog or drawer.
      function scopesOnPage() {
        var out = [], seen = {};
        if (!document.body) return out;
        var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), n;
        while ((n = w.nextNode())) {
          var t = (n.nodeValue || '').trim();
          if (t.length < 5 || t.length > 120 || !SCOPE_RE.test(t) || seen[t]) continue;
          var p = n.parentElement;
          if (!p || p.closest('[role=dialog],[aria-modal="true"],.MuiDrawer-root,.MuiModal-root,.MuiDialog-root') || !shown(p)) continue;
          seen[t] = true; out.push(t);
          if (out.length >= 100) break;
        }
        return out;
      }

      // Created apps: one entry per data row, [{el, typeText}] (a table, or Zoom's divs as a fallback).
      function scanAppRows() {
        var typeCol = -1, headerRow = null;
        var heads = document.querySelectorAll('th, [role=columnheader]');
        for (var i = 0; i < heads.length; i++) {
          if (norm(heads[i].textContent) !== 'type') continue;
          var hr = heads[i].closest('tr,[role=row]');
          if (hr) { headerRow = hr; typeCol = Array.prototype.indexOf.call(hr.querySelectorAll('th,[role=columnheader]'), heads[i]); }
          break;
        }
        var KNOWN = ['server-to-server oauth', 'server to server oauth', 'general app', 'webhook only app'];
        var out = [];
        var rows = document.querySelectorAll('tr, [role=row]');
        for (var j = 0; j < rows.length; j++) {
          var row = rows[j];
          if (row === headerRow || row.querySelector('th,[role=columnheader]') || !shown(row)) continue;
          var cells = row.querySelectorAll('td,[role=cell],[role=gridcell]');
          if (cells.length < 2) continue;
          var type = typeCol >= 0 && cells[typeCol] ? norm(cells[typeCol].textContent) : '';
          if (!type) {
            var whole = norm(row.textContent);
            for (var k = 0; k < KNOWN.length; k++) if (whole.indexOf(KNOWN[k]) >= 0) { type = KNOWN[k]; break; }
          }
          out.push({ el: row, typeText: type.slice(0, 80) });
        }
        if (out.length) return out;
        var labels = [], all = document.querySelectorAll('body *');
        for (var a = 0; a < all.length; a++) {
          var el = all[a];
          if (el.children.length > 2 || !shown(el)) continue;
          if (el.closest('[role=dialog],[aria-modal="true"],.MuiDialog-root,.MuiModal-root,[role=menu]')) continue;   // the type dialog's cards are not apps
          var t = norm(el.textContent);
          for (var b = 0; b < KNOWN.length; b++) {
            if (t.indexOf(KNOWN[b]) === 0 && t.length < KNOWN[b].length + 60) {
              if (!labels.some(function (l) { return l.el.contains(el) || el.contains(l.el); })) labels.push({ el: el, type: t });
              break;
            }
          }
        }
        function typeCount(node) { var c = 0; for (var q = 0; q < labels.length; q++) if (node.contains(labels[q].el)) c++; return c; }
        var main = document.querySelector('main') || document.body;
        var wide = main.getBoundingClientRect().width * 0.5;
        labels.forEach(function (l) {
          var node = l.el, rowEl = null;
          while (node && node !== document.body) {
            if (typeCount(node) > 1) break;
            if (node.getBoundingClientRect().width >= wide) rowEl = node;
            node = node.parentElement;
          }
          if (rowEl && !out.some(function (o) { return o.el === rowEl; })) out.push({ el: rowEl, typeText: l.type.slice(0, 80) });
        });
        out.sort(function (x, y) { return x.el.getBoundingClientRect().top - y.el.getBoundingClientRect().top; });
        return out;
      }
      function appKind(typeText) {
        if (typeText.indexOf('general app') >= 0) return 'meeting';
        if (/server.to.server/.test(typeText)) return 'hosting';
        return 'other';
      }

      // Credentials: a key's label, its row, its input or plain-text value, and the row's visible Copy control.
      function labelElement(field) {
        var text = norm(KEYLABEL[field]);
        var all = document.body ? document.body.getElementsByTagName('*') : [];
        for (var i = 0; i < all.length; i++) {
          var t = ownText(all[i]);
          if ((t === text || t === text + ':') && shown(all[i])) return all[i];
        }
        return null;
      }
      function fieldInputs(scope) {
        return Array.prototype.slice.call(scope.querySelectorAll('input')).filter(function (i) {
          var t = (i.getAttribute('type') || 'text').toLowerCase();
          return t === 'text' || t === 'password';
        });
      }
      function credRowOf(labelEl) {
        var p = labelEl;
        for (var hops = 0; p && p !== document.body && hops < 5; hops++, p = p.parentElement) {
          if (p !== labelEl && p.querySelector('input,button,[role=button]')) return p;
        }
        return labelEl.parentElement || labelEl;
      }
      function copyControlIn(row) {
        // Zoom's General app card uses <div aria-label="Copy"> (live run, 2026-11-27).
        var els = row.querySelectorAll('button,[role=button],a,svg,span,div[aria-label],i[aria-label]');
        for (var i = 0; i < els.length; i++) {
          var el = els[i], t = norm(els[i].textContent), a = norm((el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('title') || ''));
          // A hover-only copy control has no size until hovered; it is still the one to press.
          if (t === 'copy' || /^copy\\b/.test(a)) { var c = el.closest('button,[role=button],a') || el; return c; }
        }
        return null;
      }
      function inputAfter(labelEl) {
        var p = labelEl;
        for (var hops = 0; p && p !== document.body && hops < 5; hops++, p = p.parentElement) {
          var inputs = fieldInputs(p);
          for (var j = 0; j < inputs.length; j++) {
            if (labelEl.compareDocumentPosition(inputs[j]) & Node.DOCUMENT_POSITION_FOLLOWING) return inputs[j];
          }
        }
        return null;
      }
      // Plain text beside the label whose whole text is key-shaped (a General app's Client ID).
      function textAfter(labelEl) {
        var p = labelEl;
        for (var hops = 0; p && p !== document.body && hops < 3; hops++, p = p.parentElement) {
          var kids = p.children;
          for (var j = 0; j < kids.length; j++) {
            if (kids[j] === labelEl || kids[j].contains(labelEl) || labelEl.contains(kids[j])) continue;
            if (!(labelEl.compareDocumentPosition(kids[j]) & Node.DOCUMENT_POSITION_FOLLOWING)) continue;
            var t = (kids[j].textContent || '').replace(/\\s+/g, ' ').trim();
            if (KEY_RE.test(t) && !kids[j].querySelector('input')) return t;
          }
        }
        return null;
      }
      function readKey(field) {
        var lab = labelElement(field);
        if (!lab) return { kind: 'absent' };
        var input = inputAfter(lab), v = input ? String(input.value || '').trim() : '';
        if (!KEY_RE.test(v)) { var t = textAfter(lab); v = t || ''; }
        if (KEY_RE.test(v)) return { kind: 'value', value: v };
        return copyControlIn(credRowOf(lab)) ? { kind: 'copyable' } : { kind: 'hidden' };
      }

      function metaSwitch() {
        var lab = textElement('Meeting SDK');
        if (!lab) return null;
        var p = lab;
        for (var hops = 0; p && p !== document.body && hops < 6; hops++, p = p.parentElement) {
          var boxes = p.querySelectorAll('input[type=checkbox],[role=switch]');
          if (boxes.length === 1) return boxes[0];
          if (boxes.length > 1) return null;
        }
        return null;
      }
      function activationState() {
        if (path().indexOf('/activation') < 0) return null;
        if (activationMissing().length) return false;
        var deactivate = buttonIn(null, 'deactivate'), activate = buttonIn(null, 'activate your app') || buttonIn(null, 'activate');
        if (activate) return false;
        if (deactivate) return true;
        var t = ((document.body && document.body.innerText) || '').toLowerCase().replace(/not activated|deactivated|inactive/g, '');
        return t.indexOf('activated') >= 0 ? true : null;
      }
      // "Your app can not be activated yet due to missing the following information:" and its list.
      function activationMissing() {
        if (path().indexOf('/activation') < 0) return [];
        var all = document.body ? document.body.getElementsByTagName('*') : [], head = null;
        for (var i = 0; i < all.length && !head; i++) {
          if (shown(all[i]) && (ownText(all[i]) || (all[i].children.length === 0 ? norm(all[i].textContent) : '')).indexOf('missing the following information') >= 0) head = all[i];
        }
        if (!head) return [];
        var p = head;
        for (var hops = 0; p && hops < 4; hops++, p = p.parentElement) {
          var lists = p.querySelectorAll('ol,ul'), out = [];
          for (var l = 0; l < lists.length; l++) {
            if (!(head.compareDocumentPosition(lists[l]) & Node.DOCUMENT_POSITION_FOLLOWING) || !shown(lists[l])) continue;
            var lis = lists[l].querySelectorAll('li');
            for (var k = 0; k < lis.length && out.length < 12; k++) out.push(scrub(clip(lis[k].textContent, 60)));
            if (out.length) return out;
          }
        }
        return [];
      }
      // The Scopes page's own search (outside any dialog) and its "Found N matching scopes you can add - click here" line.
      function onScopesPage() { return path().indexOf('/scope') >= 0; }
      function pageSearch() {
        if (!onScopesPage()) return null;
        var dlg = openDialog(), ins = document.querySelectorAll('input'), plain = null;
        for (var i = 0; i < ins.length; i++) {
          var el = ins[i], ty = (el.getAttribute('type') || 'text').toLowerCase();
          if (!shown(el) || (dlg && dlg.contains(el)) || ['text', 'search'].indexOf(ty) < 0) continue;
          var hint = norm((el.getAttribute('placeholder') || '') + ' ' + (el.getAttribute('aria-label') || ''));
          if (hint.indexOf('search') >= 0) return el;
          if (!plain && !el.closest('header,nav')) plain = el;
        }
        return plain;
      }
      function scopeMatches() {
        if (!onScopesPage()) return null;
        var m = /found\\s+(\\d+)\\s+matching/i.exec((document.body && document.body.innerText) || '');
        return m ? parseInt(m[1], 10) : null;
      }
      function addLink() {
        if (!onScopesPage() || scopeMatches() === null) return null;
        var el = textElement('click here');
        if (!el) return null;
        var dlg = openDialog();
        if (dlg && dlg.contains(el)) return null;
        return el.closest('a,button,[role=button]') || el;
      }
      // An Information input by its label (the contact ones sit under "Developer Contact Information").
      function bareLabel(s) { return norm(s).replace(/\\*/g, '').trim(); }
      function infoInput(field) {
        var p = path();
        if (p.indexOf('/develop/apps/') < 0 || p.indexOf('/information') < 0 || !INFO[field]) return null;
        // Zoom's own placeholders first (live run, 2026-11-27): steadier than the labels.
        var PH = { appName: 'name your app', shortDescription: 'short description', companyName: 'e.g. acme',
                   contactName: 'e.g. john doe', contactEmail: 'e.g. john.doe@company.com' };
        var byPh = document.querySelectorAll('input[placeholder],textarea[placeholder]');
        for (var b = 0; b < byPh.length; b++) if (norm(byPh[b].getAttribute('placeholder')) === PH[field]) return byPh[b];
        var scope = document.body, want = bareLabel(INFO[field]);
        if (field === 'contactName' || field === 'contactEmail') {
          var sec = textElement('Developer Contact Information');
          if (!sec) return null;
          scope = sec;
          for (var up = 0; up < 6 && scope && scope !== document.body; up++, scope = scope.parentElement) {
            if (scope.querySelectorAll('input,textarea').length >= 2) break;
          }
        }
        var all = scope.getElementsByTagName('*');
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (bareLabel(ownText(el)) !== want || !shown(el)) continue;
          var forId = el.getAttribute && el.getAttribute('for');
          if (forId && document.getElementById(forId)) return document.getElementById(forId);
          var q = el;
          for (var hops = 0; q && q !== document.body && hops < 4; hops++, q = q.parentElement) {
            var ins = q.querySelectorAll('input,textarea');
            for (var j = 0; j < ins.length; j++) if (el.compareDocumentPosition(ins[j]) & Node.DOCUMENT_POSITION_FOLLOWING) return ins[j];
          }
        }
        return null;
      }
      function infoState(input) {
        if (isDisabled(input) && !(input.value || '').length) return 'disabled';
        if ((input.value || '').length) return 'filled';
        var bad = input.getAttribute('aria-invalid') === 'true', q = input;
        if (!bad && input.nextElementSibling && /cannot be empty/i.test(input.nextElementSibling.textContent || '')) bad = true;
        for (var hops = 0; !bad && q && q !== document.body && hops < 3; hops++, q = q.parentElement) {
          if (/cannot be empty/i.test(q.textContent || '')) bad = true;
        }
        return bad ? 'error' : 'empty';
      }
      function emptyRequired() {
        var p = path(), out = [];
        if (p.indexOf('/develop/apps/') < 0 || (p.indexOf('/information') < 0 && p.indexOf('/feature') < 0)) return out;
        var ins = document.querySelectorAll('input,textarea');
        for (var i = 0; i < ins.length; i++) {
          var el = ins[i], ty = (el.getAttribute('type') || 'text').toLowerCase();
          if (!shown(el) || el.disabled || el.readOnly || ['text', 'email', 'url', 'tel', 'search'].indexOf(ty) < 0) continue;
          var lab = el.closest('label') || (el.id ? document.querySelector('label[for="' + el.id + '"]') : null);
          var near = lab ? (lab.textContent || '').replace(/\\s+/g, ' ').trim() : '';
          var required = el.required || el.getAttribute('aria-required') === 'true' || near.indexOf('*') >= 0;
          if (required && !(el.value || '').length) out.push(scrub(clip(near.replace(/\\*/g, ''), 60)));
        }
        return out;
      }
      // Marketplace's header: a "Sign In" link (signed out) or an account menu (signed in).
      function headerState() {
        var all = document.body ? document.body.getElementsByTagName('*') : [], account = false;
        for (var i = 0; i < all.length; i++) {
          var el = all[i], r = el.getBoundingClientRect();
          if (r.width < 4 || r.height < 4 || r.top > 120 || !shown(el)) continue;
          var tag = el.tagName;
          if ((tag === 'A' || tag === 'BUTTON' || el.getAttribute('role') === 'button') && (el.textContent || '').replace(/\\s+/g, ' ').trim() === 'Sign In') return { el: el, signedIn: false };
          var hint = ((el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('alt') || '')).toLowerCase();
          if (hint.indexOf('avatar') >= 0 || hint.indexOf('account') >= 0 || hint.indexOf('profile') >= 0) account = true;
        }
        return { el: null, signedIn: account ? true : null };
      }

      // ZoomControl ID -> the page's element, or null.
      function resolve(id) {
        var dlg = openDialog();
        switch (id) {
          case 'plus': return findPlus();
          case 'buildApp': return openMenuItem('build app') || openMenuItem('build');
          case 'create': return dlg ? buttonIn(dlg, 'create') : null;
          case 'cancel': return dlg ? buttonIn(dlg, 'cancel') : null;
          case 'nameField': return dlg && nameDialogApp(dialogHeading(dlg)) ? nameInput(dlg) : null;
          case 'addScopes': return dlg ? null : buttonIn(null, 'add scopes');
          case 'scopeSearch': return dlg ? searchIn(dlg) : null;
          case 'scopesDone': return dlg && searchIn(dlg) ? buttonIn(dlg, 'done') : null;
          case 'activate': return path().indexOf('/activation') >= 0 ? (buttonIn(null, 'activate your app') || buttonIn(null, 'activate')) : null;
          case 'continue': return buttonIn(null, 'continue');
          case 'signIn': return onMarketplace() ? headerState().el : null;
          case 'tryAnotherWay': return buttonIn(null, 'try another way');
          case 'closeDialog': return dlg ? closeIn(dlg) : null;
          case 'pageScopeSearch': return pageSearch();
          case 'pageScopeAddLink': return addLink();
          case 'meetingSDKSwitch': return path().indexOf('/features/sdk') >= 0 ? metaSwitch() : null;
        }
        var dot = id.indexOf('.'), colon = id.indexOf(':');
        if (colon > 0 && id.slice(0, colon) === 'scopeCheckbox') {
          if (!dlg) return null;
          var want = id.slice(colon + 1), rows = scopeRows(dlg);
          for (var i = 0; i < rows.length; i++) if (rows[i].scope === want) return rows[i].box;
          return null;
        }
        if (dot < 0) return null;
        var kind = id.slice(0, dot), arg = id.slice(dot + 1);
        if (kind === 'typeRadio') {
          if (!dlg) return null;
          var cs = typeChoices(dlg), target = arg === 'meeting' ? 'general' : arg === 'hosting' ? 'serverToServer' : '';
          for (var c = 0; c < cs.length; c++) if (cs[c].choice === target) return cs[c].radio;
          return null;
        }
        if (kind === 'infoField') return infoInput(arg);
        if (kind === 'keyRow') {
          if (!keysPath() || !KEYLABEL[arg]) return null;
          var kl = labelElement(arg);
          return kl ? credRowOf(kl) : null;
        }
        if (kind === 'copy') {
          if (!keysPath() || !KEYLABEL[arg]) return null;
          var lab = labelElement(arg);
          return lab ? copyControlIn(credRowOf(lab)) : null;
        }
        if (kind === 'navLink') {
          if (!NAV[arg]) return null;
          var links = document.querySelectorAll('a,[role=tab],[role=link],button'), w = norm(NAV[arg]);
          for (var l = 0; l < links.length; l++) if (norm(links[l].textContent) === w && shown(links[l])) return links[l];
          return null;
        }
        if (kind === 'appRow') {
          var list = path().indexOf('/user/build') === 0 ? scanAppRows() : [], n = parseInt(arg, 10);
          if (!(n >= 0 && n < list.length)) return null;
          // Press the app's NAME cell (live run 5, 2026-11-27): the whole row also says "Intend to publish: No",
          // which the deny-list rightly refuses. The click still reaches the row and opens the app.
          var row = list[n].el, cell = row.querySelector('td,[role=cell],[role=gridcell]');
          var name = cell ? (cell.querySelector('a,[role=link],p,span') || cell) : row;
          return name;
        }
        return null;
      }
      // Every ID worth testing on this page (the app rows by count).
      function allControlIds(rowCount) {
        var ids = FIXED.slice(), k;
        ids.push('typeRadio.meeting', 'typeRadio.hosting');
        for (k in KEYLABEL) ids.push('copy.' + k);
        for (k in NAV) ids.push('navLink.' + k);
        for (k in INFO) ids.push('infoField.' + k);
        for (var i = 0; i < rowCount; i++) ids.push('appRow.' + i);
        for (var s = 0; s < SCOPES.length; s++) ids.push('scopeCheckbox:' + SCOPES[s]);
        return ids;
      }
    """

    /// The reader: evaluates to one JSON string shaped like `ZoomPageSnapshot` (without the address, which Swift knows from the URL).
    /// A failure inside answers "error: ..." (not JSON), never partial data.
    static let source: String = """
    (function () {
      \(library)
      try {
        if (!document.body) return JSON.stringify({ controls: [] });
        if (!onMarketplace()) return JSON.stringify({ controls: resolve('tryAnotherWay') ? ['tryAnotherWay'] : [] });
        var snap = {};
        var header = headerState();
        if (header.signedIn !== null) snap.signedIn = header.signedIn;

        var dlg = openDialog(), dialog = { kind: 'none' };
        if (dlg) {
          var heading = dialogHeading(dlg), nameApp = nameDialogApp(heading);
          if (heading.indexOf('what kind of app') === 0) {
            var choices = {};
            typeChoices(dlg).forEach(function (c) { choices[c.choice] = !!choices[c.choice] || isOn(c.radio) || isOn(c.row); });
            dialog = { kind: 'appType', choices: choices };
          } else if (nameApp) {
            var input = nameInput(dlg), create = buttonIn(dlg, 'create');
            dialog = { kind: 'name', app: nameApp, filled: !!(input && (input.value || '').length), createEnabled: !!(create && !isDisabled(create)) };
          } else if (searchIn(dlg) || heading.indexOf('scope') >= 0) {
            dialog = { kind: 'addScopes', searchPresent: !!searchIn(dlg),
                       ticked: scopeRows(dlg).filter(function (r) { return isOn(r.box); }).map(function (r) { return r.scope; }) };
          } else {
            dialog = { kind: 'other', heading: scrub(heading).slice(0, 60) };
          }
        }
        snap.dialog = dialog;

        snap.menuItems = [];
        var items = document.querySelectorAll('[role=menuitem],.MuiMenuItem-root');
        for (var m = 0; m < items.length && snap.menuItems.length < 20; m++) {
          if (shown(items[m])) snap.menuItems.push(scrub(clip(items[m].textContent, 40)));
        }

        var rows = path().indexOf('/user/build') === 0 ? scanAppRows() : [];
        snap.appList = rows.map(function (r) { return appKind(r.typeText); });

        if (path().indexOf('/features/sdk') >= 0) { var sw = metaSwitch(); if (sw) snap.meetingSDKOn = isOn(sw); }
        snap.scopesOnPage = scopesOnPage();
        var act = activationState();
        if (act !== null) snap.activated = act;
        snap.infoEmptyRequired = emptyRequired();
        snap.infoFields = {};
        for (var fk in INFO) { var fi = infoInput(fk); if (fi) snap.infoFields[fk] = infoState(fi); }
        var matches = scopeMatches();
        if (matches !== null) snap.scopeSearchMatches = matches;
        snap.activationMissing = activationMissing();

        snap.keys = {};
        if (keysPath()) for (var f in KEYLABEL) snap.keys[f] = readKey(f);

        snap.controls = allControlIds(rows.length).filter(function (id) { return !!resolve(id); });
        return JSON.stringify(snap);
      } catch (e) {
        return 'error: ' + String((e && e.message) || e).slice(0, 120);
      }
    })();
    """

    /// One action on one named control (the actor's only way to touch Zoom's page). Resolves the ID with the same finder the
    /// reader uses, checks the deny-list on the element's own text at this moment (it always wins), then acts. Answers
    /// 'ok', 'none' (not on the page) or 'denied'. Never runs on credential VALUES: it only presses and types what a plan says.
    static func action(verb: String, id: String, text: String = "") -> String {
        func q(_ s: String) -> String {
            let d = try? JSONSerialization.data(withJSONObject: [s]); let j = d.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            return String(j.dropFirst().dropLast())
        }
        return """
        (function () {
          \(library)
          var verb = \(q(verb)), id = \(q(id)), text = \(q(text));
          var el = resolve(id);
          if (!el) return 'none';
          var said = ((el.textContent || '') + ' ' + (el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('title') || ''));
          // A scope checkbox's row carries the scope's own name ("...delete_..."): that text is ours, not a warning.
          if (id.indexOf('scopeCheckbox:') === 0) said = said.split(id.slice(14)).join('');
          if (new RegExp(\(q(ZoomActorRules.denyPattern)), 'i').test(said)) return 'denied';
          // A switched-off control is not there to act on (Zoom ignores it, and a script must not pretend otherwise).
          if (verb !== 'hover' && isDisabled(el)) return 'none';
          if (verb === 'hover') {
            var n = el; for (var i = 0; n && i < 4; i++, n = n.parentElement) { ['pointerover','mouseover','mouseenter','pointermove','mousemove'].forEach(function (t) { n.dispatchEvent(new MouseEvent(t, { bubbles: t !== 'mouseenter', cancelable: true, view: window })); }); }
            return 'ok';
          }
          if (verb === 'type') {
            var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            var setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
            el.focus(); setter.call(el, text);
            el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'ok';
          }
          el.scrollIntoView({ block: 'center' });
          if (verb === 'pressdeep') {
            var inner = el.querySelector('svg path, svg, i, img') || el;
            ['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function (t) { inner.dispatchEvent(new MouseEvent(t, { bubbles: true, cancelable: true, view: window })); });
            return 'ok';
          }
          // An app row opens through its own link; any other control is clicked itself.
          var target = el;
          if (id.indexOf('appRow.') === 0) target = el.querySelector('a[href],[role=link]') || el;
          target.click();
          return 'ok';
        })();
        """
    }
}
