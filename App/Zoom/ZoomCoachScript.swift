//
//  ZoomCoachScript.swift
//  Greenroom
//
//  The coach's page script (spec R6), a constant. It draws a dim layer with a
//  clear, ringed spotlight over one control and a callout card, inside a
//  CLOSED shadow root on one fixed host element, so Zoom's CSS cannot break
//  it and it cannot break Zoom's. It never clicks, never takes focus and never
//  blocks: everything has pointer-events none except the card's "Hide tips".
//  Targets are found by visible label text only. The card's words arrive from
//  Swift as JSON (`ZoomCoach.json`); nothing on the page is ever copied into
//  it. If the target is not there, the spotlight simply is not drawn.
//
//  Use: evaluate `source` once per page load, then `ZoomCoachScript.call(json, ring)`
//  on every route change (`call(nil, ring)` clears it). The ring colour is
//  Brand.green, passed in from Swift. The script runs in WKContentWorld.defaultClient.
//
import Foundation

enum ZoomCoachScript {
    /// The mark may only be a small PNG data URI (never an address).
    static func safeMark(_ s: String) -> String? {
        let prefix = "data:image/png;base64,"
        guard s.hasPrefix(prefix), s.count > prefix.count,
              s.dropFirst(prefix.count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }) else { return nil }
        return s
    }

    /// `window.__grCoachSet(cfg, ring, mark)`; cfg null clears the coach.
    static func call(_ json: String?, ring: String, mark: String? = nil) -> String {
        let m = mark.flatMap(safeMark).map { "'\($0)'" } ?? "null"
        return "window.__grCoachSet && window.__grCoachSet(\(json ?? "null"), '\(ring)', \(m));"
    }

    static let source = """
    (function () {
      if (window.__grCoachSet) return;
      \(ZoomAppListScript.scanFunction)
      var host = null, root = null, ui = null, cfg = null, ring = 'currentColor', mark = null;
      var status = 'cleared', target = null, resizeObs = null, mutObs = null, timer = 0, pending = 0, dismissed = false;
      var reduce = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

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
      function findAppRow(index) {
        var rows = scanAppRows();
        return rows[index] ? rows[index].el : null;
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
      function findSearch() {
        var dialogs = document.querySelectorAll('[role=dialog],[aria-modal="true"]');
        for (var i = 0; i < dialogs.length; i++) {
          var inputs = dialogs[i].querySelectorAll('input');
          for (var j = 0; j < inputs.length; j++) {
            var hint = norm((inputs[j].getAttribute('placeholder') || '') + ' ' + (inputs[j].getAttribute('aria-label') || ''));
            if (hint.indexOf('search') >= 0 && shown(inputs[j])) return inputs[j];
          }
        }
        return null;
      }

      function build() {
        host = document.createElement('div');
        host.setAttribute('data-greenroom-coach', '');
        host.style.cssText = 'position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events: none;';
        root = host.attachShadow({ mode: 'closed' });
        var style = document.createElement('style');
        style.textContent = [
          ':host{all:initial}',
          '.spot{position:fixed;pointer-events: none;border-radius:10px;box-shadow:0 0 0 9999px rgba(0,0,0,.45);}',
          '.spot.move{transition:left .2s ease,top .2s ease,width .2s ease,height .2s ease;}',
          '.ring{position:absolute;inset:0;border-radius:10px;pointer-events: none;}',
          '.card{position:fixed;width:280px;box-sizing:border-box;padding:12px 14px;border-radius:12px;pointer-events: none;',
          ' font:13px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;',
          ' background:#fff;color:#1d1d1f;box-shadow:0 6px 24px rgba(0,0,0,.28),0 0 0 .5px rgba(0,0,0,.18);}',
          '.card.move{transition:left .2s ease,top .2s ease;}',
          '.head{display:flex;align-items:center;gap:6px;margin-bottom:6px;}',
          '.mark{width:16px;height:16px;border-radius:4px;flex:none;}',
          '.name{font-weight:600;font-size:13px;}',
          '.count{font-size:12px;font-weight:400;color:#6e6e73;}',
          '.text{font-weight:500;}',
          '.hide{display:inline-block;margin-top:8px;font-size:12px;color:#6e6e73;text-decoration:underline;cursor:pointer;pointer-events:auto;}',
          '@media (prefers-color-scheme: dark){.card{background:#2c2c2e;color:#f5f5f7;box-shadow:0 6px 24px rgba(0,0,0,.6),0 0 0 .5px rgba(255,255,255,.18);}',
          ' .count,.hide{color:#a1a1a6;}}',
          '@media (prefers-reduced-motion: reduce){.spot.move,.card.move{transition:none}}'
        ].join('');
        root.appendChild(style);
        var spot = document.createElement('div'); spot.className = 'spot';
        var ringEl = document.createElement('div'); ringEl.className = 'ring';
        spot.appendChild(ringEl);
        var card = document.createElement('div'); card.className = 'card';
        var head = document.createElement('div'); head.className = 'head';
        var markEl = document.createElement('img'); markEl.className = 'mark'; markEl.alt = ''; markEl.style.display = 'none';
        markEl.addEventListener('error', function () { markEl.style.display = 'none'; mark = null; });
        var name = document.createElement('span'); name.className = 'name'; name.textContent = 'Greenroom';
        var count = document.createElement('span'); count.className = 'count';
        head.appendChild(markEl); head.appendChild(name); head.appendChild(count);
        var text = document.createElement('div'); text.className = 'text';
        var hide = document.createElement('a'); hide.className = 'hide'; hide.textContent = 'Hide tips';
        hide.setAttribute('role', 'button'); hide.setAttribute('tabindex', '-1');
        hide.addEventListener('mousedown', function (e) { e.preventDefault(); });
        hide.addEventListener('click', function (e) {
          e.preventDefault();
          dismissed = true;
          clear();
          try { window.webkit.messageHandlers.coach.postMessage('hide'); } catch (err) {}
        });
        card.appendChild(head); card.appendChild(text); card.appendChild(hide);
        root.appendChild(spot); root.appendChild(card);
        ui = { spot: spot, ring: ringEl, card: card, count: count, markEl: markEl, text: text, placed: false };
        (document.documentElement || document.body).appendChild(host);
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
      function stageTarget(st) {
        if (st.kind === 'menuItem') return findMenuItem(st.label);
        var root = chooserRoot();
        if (!root) return null;
        var row = findRow(st.label, root);
        if (st.kind === 'chooseRow') return row;
        if (st.kind === 'createAfter') return isChosen(row) ? findControl('Create', root) : null;
        return null;
      }
      var stageText = null, lostAt = 0;

      function resolve() {
        if (!cfg) return null;
        stageText = null;
        if (cfg.then) {
          // The furthest later stage the page shows wins; else the first spotlight.
          for (var si = cfg.then.length - 1; si >= 0; si--) {
            var t = stageTarget(cfg.then[si]);
            if (t) { stageText = cfg.then[si].text; return t; }
          }
        }
        if (cfg.kind === 'appRow') return findAppRow(cfg.rowIndex);
        if (cfg.kind === 'build') return findBuildButton();
        if (!cfg.label) return null;
        if (cfg.kind === 'row') return findRow(cfg.label);
        if (cfg.kind === 'toggle') return findToggle(cfg.label);
        if (cfg.searchText) { var s = findSearch(); if (s) return s; }
        return findControl(cfg.label);
      }

      function place() {
        pending = 0;
        if (!cfg || dismissed) { status = 'cleared'; return; }
        status = 'drawn';
        // A flow with later stages looks again every time; others keep their target while it lasts.
        if (cfg.then || !target || !target.isConnected || !shown(target)) target = resolve();
        if (!host) build();
        if (!host.isConnected) (document.documentElement || document.body).appendChild(host);
        var useSearch = cfg.searchText && target && target.tagName === 'INPUT';
        ui.count.textContent = cfg.counter ? ' \\u00B7 ' + cfg.counter : '';
        if (mark) { ui.markEl.src = mark; ui.markEl.style.display = 'block'; }
        ui.text.textContent = useSearch ? cfg.searchText : (stageText || cfg.text);
        var animate = !reduce && ui.placed;
        ui.spot.className = 'spot' + (animate ? ' move' : '');
        ui.card.className = 'card' + (animate ? ' move' : '');
        var vw = window.innerWidth, vh = window.innerHeight, cw = 280, ch = ui.card.offsetHeight || 90;
        var left, top;
        if (target) {
          lostAt = 0;
          var r = rectOf(target), pad = 6;
          ui.spot.style.display = 'block';
          ui.spot.style.left = (r.left - pad) + 'px'; ui.spot.style.top = (r.top - pad) + 'px';
          ui.spot.style.width = (r.width + pad * 2) + 'px'; ui.spot.style.height = (r.height + pad * 2) + 'px';
          ui.ring.style.boxShadow = '0 0 0 2px ' + ring;
          if (r.right + 16 + cw <= vw - 8) { left = r.right + 16 + pad; top = r.top; }
          else if (r.left - 16 - cw >= 8) { left = r.left - 16 - cw - pad; top = r.top; }
          // No room beside it (a full-width row): sit under or over its RIGHT end, so
          // the card covers the empty side of the next row, never its label or the
          // Create button, which Zoom puts on the left.
          else if (r.bottom + 16 + ch <= vh - 8) { left = r.right - cw; top = r.bottom + 16 + pad; }
          else { left = r.right - cw; top = Math.max(8, r.top - 16 - ch - pad); }
        } else {
          ui.spot.style.display = 'none';
          left = vw - cw - 16; top = vh - ch - 16;
          // Zoom redraws often: a target that is briefly gone keeps the card where it
          // was for 1.5s (no flicker). After that a card that needs a target hides,
          // and one that may stand alone moves to the corner.
          if (!lostAt) lostAt = Date.now();
          if (ui.placed && Date.now() - lostAt < 1500) { status = 'held'; return; }
          if (cfg.kind && cfg.kind !== 'none' && !cfg.optional && !cfg.then) { ui.card.style.display = 'none'; ui.placed = false; status = 'no-target'; return; }
        }
        ui.card.style.display = 'block';
        ui.card.style.left = Math.min(Math.max(8, left), vw - cw - 8) + 'px';
        ui.card.style.top = Math.min(Math.max(8, top), vh - ch - 8) + 'px';
        ui.placed = true;
      }
      function schedule() { if (!pending) pending = window.requestAnimationFrame(place); }

      function watch() {
        stop();
        window.addEventListener('scroll', schedule, true);
        window.addEventListener('resize', schedule, true);
        if (window.ResizeObserver && document.body) { resizeObs = new ResizeObserver(schedule); resizeObs.observe(document.body); }
        if (window.MutationObserver) { mutObs = new MutationObserver(schedule); mutObs.observe(document.documentElement, { childList: true, subtree: true, attributes: true }); }
        timer = window.setInterval(schedule, 500);
      }
      function stop() {
        window.removeEventListener('scroll', schedule, true);
        window.removeEventListener('resize', schedule, true);
        if (resizeObs) { resizeObs.disconnect(); resizeObs = null; }
        if (mutObs) { mutObs.disconnect(); mutObs = null; }
        if (timer) { window.clearInterval(timer); timer = 0; }
        if (pending) { window.cancelAnimationFrame(pending); pending = 0; }
      }
      function clear() {
        stop();
        cfg = null; target = null;
        if (host && host.parentNode) host.parentNode.removeChild(host);
        host = null; root = null; ui = null;
      }

      window.__grCoachSet = function (next, color, markUri) {
        if (color) ring = color;
        if (markUri) mark = markUri;
        if (!next) { dismissed = false; clear(); return 'cleared'; }
        dismissed = false;
        cfg = next; target = null;
        if (ui) ui.placed = false;
        watch();
        place();
        schedule();
        return status;
      };
    })();
    """
}
