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
    /// `window.__grCoachSet(cfg, ring)`; cfg null clears the coach.
    static func call(_ json: String?, ring: String) -> String {
        "window.__grCoachSet && window.__grCoachSet(\(json ?? "null"), '\(ring)');"
    }

    static let source = """
    (function () {
      if (window.__grCoachSet) return;
      var host = null, root = null, ui = null, cfg = null, ring = '#5FA83C';
      var target = null, resizeObs = null, mutObs = null, timer = 0, pending = 0, dismissed = false;
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
      function textElement(label) {
        var want = norm(label), best = null, bestArea = 1e12;
        var all = document.body ? document.body.getElementsByTagName('*') : [];
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
      function findRow(label) {
        var el = textElement(label);
        if (!el) return null;
        var hops = 0;
        while (el.parentElement && el.parentElement !== document.body && hops < 6) {
          var p = el.parentElement;
          if (radiosIn(p) > 1) break;
          el = p; hops++;
        }
        return shown(el) ? el : null;
      }
      function findControl(label) {
        var el = textElement(label);
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
          '.count{font-size:11px;font-weight:600;letter-spacing:.02em;color:#6e6e73;margin-bottom:4px;}',
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
        var count = document.createElement('div'); count.className = 'count';
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
        card.appendChild(count); card.appendChild(text); card.appendChild(hide);
        root.appendChild(spot); root.appendChild(card);
        ui = { spot: spot, ring: ringEl, card: card, count: count, text: text, placed: false };
        (document.documentElement || document.body).appendChild(host);
      }

      function resolve() {
        if (!cfg || !cfg.label) return null;
        if (cfg.kind === 'row') return findRow(cfg.label);
        if (cfg.kind === 'toggle') return findToggle(cfg.label);
        if (cfg.searchText) { var s = findSearch(); if (s) return s; }
        return findControl(cfg.label);
      }

      function place() {
        pending = 0;
        if (!cfg || dismissed) return;
        if (!target || !target.isConnected || !shown(target)) target = resolve();
        if (!host) build();
        if (!host.isConnected) (document.documentElement || document.body).appendChild(host);
        var useSearch = cfg.searchText && target && target.tagName === 'INPUT';
        ui.count.textContent = cfg.counter || '';
        ui.text.textContent = useSearch ? cfg.searchText : cfg.text;
        var animate = !reduce && ui.placed;
        ui.spot.className = 'spot' + (animate ? ' move' : '');
        ui.card.className = 'card' + (animate ? ' move' : '');
        var vw = window.innerWidth, vh = window.innerHeight, cw = 280, ch = ui.card.offsetHeight || 90;
        var left, top;
        if (target) {
          var r = rectOf(target), pad = 6;
          ui.spot.style.display = 'block';
          ui.spot.style.left = (r.left - pad) + 'px'; ui.spot.style.top = (r.top - pad) + 'px';
          ui.spot.style.width = (r.width + pad * 2) + 'px'; ui.spot.style.height = (r.height + pad * 2) + 'px';
          ui.ring.style.boxShadow = '0 0 0 2px ' + ring;
          if (r.right + 16 + cw <= vw - 8) { left = r.right + 16 + pad; top = r.top; }
          else if (r.left - 16 - cw >= 8) { left = r.left - 16 - cw - pad; top = r.top; }
          else if (r.bottom + 16 + ch <= vh - 8) { left = r.left; top = r.bottom + 16 + pad; }
          else { left = r.left; top = Math.max(8, r.top - 16 - ch - pad); }
        } else {
          ui.spot.style.display = 'none';
          left = vw - cw - 16; top = vh - ch - 16;
          if (cfg.label) { ui.card.style.display = 'none'; ui.placed = false; return; }
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

      window.__grCoachSet = function (next, color) {
        if (color) ring = color;
        if (!next) { dismissed = false; clear(); return; }
        dismissed = false;
        cfg = next; target = null;
        if (ui) ui.placed = false;
        watch();
        place();
        schedule();
      };
    })();
    """
}
