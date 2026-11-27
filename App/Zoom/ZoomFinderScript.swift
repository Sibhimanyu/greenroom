//
//  ZoomFinderScript.swift
//  Greenroom
//
//  The read-only element finders the coach and the actor share (so a spotlight
//  and a press always mean the same element): found by visible label text, never
//  by class names, except to recognise an open dialog or a chosen radio. Pure
//  functions of the page; nothing here clicks, types or focuses. A constant.
//
import Foundation

enum ZoomFinderScript {
    /// Expects `var host = null;` (our own overlay element, skipped) to be defined first.
    static let functions = """
      function norm(s) { return (s || '').replace(/\\s+/g, ' ').replace(/\\+/g, '').trim().toLowerCase(); }
      function rectOf(el) { return el.getBoundingClientRect(); }
      function shown(el) {
        var r = rectOf(el);
        if (r.width < 4 || r.height < 4) return false;
        var cs = window.getComputedStyle(el);
        return cs.visibility !== 'hidden' && cs.display !== 'none';
      }
      function ownText(el) {
        var t = '';
        for (var i = 0; i < el.childNodes.length; i++) if (el.childNodes[i].nodeType === 3) t += el.childNodes[i].nodeValue;
        return norm(t);
      }
      // The smallest visible element whose own text is the label.
      function textElement(label, scope) {
        var want = norm(label), best = null, bestArea = 1e12;
        var all = (scope || document.body) ? (scope || document.body).getElementsByTagName('*') : [];
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (el === host) continue;
          var tag = el.tagName;
          if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') continue;
          if (ownText(el) !== want && !(el.children.length === 0 && norm(el.textContent) === want)) continue;
          if (!shown(el)) continue;
          var r = rectOf(el), a = r.width * r.height;
          if (a < bestArea) { best = el; bestArea = a; }
        }
        return best;
      }
      function radiosIn(el) { return el.querySelectorAll('input[type=radio],[role=radio]').length; }
      function findRow(label, scope) {
        var el = textElement(label, scope);
        if (!el) return null;
        var hops = 0;
        while (el.parentElement && el.parentElement !== document.body && hops < 6) {
          var p = el.parentElement;
          if (radiosIn(p) > 1) break;
          el = p; hops++;
        }
        return shown(el) ? el : null;
      }
      function findControl(label, scope) {
        var el = textElement(label, scope);
        if (!el) return null;
        var c = el.closest('button,[role=button],a');
        return c && shown(c) ? c : el;
      }
      function findToggle(label) {
        var el = textElement(label);
        if (!el) return null;
        var p = el;
        for (var hops = 0; p && p !== document.body && hops < 6; hops++, p = p.parentElement) {
          var sw = p.querySelector('[role=switch],input[type=checkbox]');
          if (sw) {
            var r = rectOf(sw);
            return r.width >= 4 && r.height >= 4 ? sw : (sw.parentElement || sw);
          }
        }
        return null;
      }
      // The round "+" (Build App) beside the "Developer" heading: by its label, else the button after the heading.
      function findBuildButton() {
        var btns = document.querySelectorAll('button,[role=button],a');
        for (var i = 0; i < btns.length; i++) {
          var hint = norm((btns[i].getAttribute('aria-label') || '') + ' ' + (btns[i].getAttribute('title') || '')).toLowerCase();
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
      // The "What kind of app are you creating" dialog (or page), if shown.
      function chooserRoot() {
        var all = document.body ? document.body.getElementsByTagName('*') : [];
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          if (el === host || el.children.length > 3) continue;
          if (norm(el.textContent).indexOf('what kind of app are you creating') !== 0 || !shown(el)) continue;
          var d = el.closest('[role=dialog],[aria-modal="true"]');
          if (d) return d;
          var p = el;
          for (var hops = 0; p.parentElement && p.parentElement !== document.body && hops < 8; hops++) {
            p = p.parentElement;
            if (radiosIn(p) >= 2) return p;
          }
          return document.body;
        }
        return null;
      }
      // A visible menu item whose whole text is the label (the + menu's "Build").
      function findMenuItem(label) {
        var want = norm(label), best = null, bestArea = 1e12;
        var els = document.querySelectorAll('[role=menuitem],[role=option],li,button,[role=button],a');
        for (var i = 0; i < els.length; i++) {
          if (norm(els[i].textContent) !== want || !shown(els[i])) continue;
          if (!els[i].closest('[role=menu],[role=listbox],[role=presentation],[role=tooltip],.MuiPopover-root,.MuiMenu-root,.MuiPopper-root')) continue;
          var r = rectOf(els[i]), a = r.width * r.height;
          if (a < bestArea) { best = els[i]; bestArea = a; }
        }
        return best;
      }
      function isChosen(row) {
        return !!(row && row.querySelector('input[type=radio]:checked,[role=radio][aria-checked="true"],.Mui-checked'));
      }
      // The visible modal, if any: a dialog or aria-modal element, or a MUI dialog root with a visible paper.
      // (A MUI menu popover is not a dialog.)
      function openDialog() {
        var els = document.querySelectorAll('[role=dialog],[aria-modal="true"],.MuiDialog-root');
        for (var i = els.length - 1; i >= 0; i--) {
          var el = els[i];
          if (el === host || (host && host.contains(el))) continue;
          var paper = el.matches('.MuiDialog-root') ? (el.querySelector('.MuiDialog-paper,[role=dialog]') || el) : el;
          if (shown(paper)) return paper;
        }
        return null;
      }
      function dialogHeading(dlg) {
        var h = dlg.querySelector('h1,h2,h3,h4,h5,h6,[role=heading]');
        return nn2(h ? h.textContent : (dlg.textContent || '').slice(0, 80));
      }
      function nn2(s) { return (s || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
      function isOn(el) {
        if (!el) return false;
        return el.getAttribute('aria-checked') === 'true' || el.checked === true || !!el.closest('.Mui-checked') ||
               !!el.querySelector('input:checked,[aria-checked="true"],.Mui-checked');
      }
      // Text visible on the page itself, not inside an open panel or dialog.
      function textVisibleOutside(str) {
        if (!document.body) return false;
        var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null), n;
        while ((n = w.nextNode())) {
          if (n.nodeValue.indexOf(str) < 0) continue;
          var p = n.parentElement;
          if (!p || p.closest('[role=dialog],[aria-modal="true"],.MuiDrawer-root,.MuiModal-root') || !shown(p)) continue;
          return true;
        }
        return false;
      }
      function pageActivated() {
        var t = ((document.body && document.body.innerText) || '').toLowerCase().replace(/not activated|deactivated|inactive/g, '');
        return t.indexOf('activated') >= 0;
      }
      // A left-nav link or tab by its exact text: inside the navigation first, else anywhere.
      function findNavLink(label) {
        var navs = document.querySelectorAll('nav,[role=navigation],aside,[role=tablist],.MuiDrawer-root');
        for (var i = 0; i < navs.length; i++) {
          var el = textElement(label, navs[i]);
          if (el) { var c = el.closest('a,[role=tab],[role=link],[role=menuitem],button,li'); return c && shown(c) ? c : el; }
        }
        return findControl(label);
      }
    """
}
