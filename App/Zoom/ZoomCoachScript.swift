//
//  ZoomCoachScript.swift
//  Greenroom
//
//  The coach's page script, a RENDERER (docs/specs/zoom-setup-flow.md). It is given what to show as a
//  `CoachDrawing`: one ZoomControl ID to ring (resolved by the reader's own finder, `ZoomPageScript.library`),
//  the card's words (counter, title, why, status) and the label of the one action button. It decides nothing about
//  steps. It draws a dim layer with a ringed spotlight and a callout card inside a CLOSED shadow root on one fixed
//  host element, so Zoom's CSS cannot break it and it cannot break Zoom's. It never clicks, never takes focus and
//  never blocks: everything has pointer-events none except the card's button ("act") and "Hide tips" ("hide").
//  The card's words come from Swift only; nothing on the page is ever copied into it. If the control is not there,
//  the spotlight is not drawn and the card sits in the corner (or beside an open dialog).
//
//  Use: evaluate `source` once per page load, then `call(json, ring, mark, fill)` on every change (`nil` clears it).
//  Runs in WKContentWorld.defaultClient.
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

    static func json(_ drawing: CoachDrawing) -> String {
        guard let data = try? JSONEncoder().encode(drawing), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    /// `window.__grCoachSet(cfg, ring, mark, fill)`; cfg null clears the coach.
    static func call(_ json: String?, ring: String, mark: String? = nil, fill: String? = nil) -> String {
        let m = mark.flatMap(safeMark).map { "'\($0)'" } ?? "null"
        let f = fill.map { "'\($0)'" } ?? "null"
        return "window.__grCoachSet && window.__grCoachSet(\(json ?? "null"), '\(ring)', \(m), \(f));"
    }

    static let source = """
    (function () {
      if (window.__grCoachSet) return;
      \(ZoomPageScript.library)
      var host = null, root = null, ui = null, cfg = null, ring = 'currentColor', fill = '#4E8C30', mark = null;
      var status = 'cleared', target = null, resizeObs = null, mutObs = null, timer = 0, pending = 0, dismissed = false, lostAt = 0;
      var reduce = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

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
          '.title{font-weight:600;}',
          '.why,.status{font-size:12px;color:#6e6e73;margin-top:4px;}',
          '.status{color:inherit;font-weight:500;font-size:13px;}',
          '.row{display:flex;align-items:center;gap:14px;margin-top:8px;}',
          '.do{border:0;border-radius:8px;padding:5px 12px;font:600 12px -apple-system,system-ui,sans-serif;color:#fff;cursor:pointer;pointer-events:auto;}',
          '.hide{display:inline-block;font-size:12px;color:#6e6e73;text-decoration:underline;cursor:pointer;pointer-events:auto;}',
          '@media (prefers-color-scheme: dark){.card{background:#2c2c2e;color:#f5f5f7;box-shadow:0 6px 24px rgba(0,0,0,.6),0 0 0 .5px rgba(255,255,255,.18);}',
          ' .count,.hide,.why{color:#a1a1a6;}}',
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
        var title = document.createElement('div'); title.className = 'title';
        var why = document.createElement('div'); why.className = 'why';
        var status = document.createElement('div'); status.className = 'status';
        var row = document.createElement('div'); row.className = 'row';
        var go = document.createElement('button'); go.className = 'do'; go.type = 'button'; go.setAttribute('tabindex', '-1');
        go.addEventListener('mousedown', function (e) { e.preventDefault(); });
        go.addEventListener('click', function (e) {
          e.preventDefault();
          try { window.webkit.messageHandlers.coach.postMessage('act'); } catch (err) {}
        });
        var hide = document.createElement('a'); hide.className = 'hide'; hide.textContent = 'Hide tips';
        hide.setAttribute('role', 'button'); hide.setAttribute('tabindex', '-1');
        hide.addEventListener('mousedown', function (e) { e.preventDefault(); });
        hide.addEventListener('click', function (e) {
          e.preventDefault();
          dismissed = true; clear();
          try { window.webkit.messageHandlers.coach.postMessage('hide'); } catch (err) {}
        });
        row.appendChild(go); row.appendChild(hide);
        card.appendChild(head); card.appendChild(title); card.appendChild(why); card.appendChild(status); card.appendChild(row);
        root.appendChild(spot); root.appendChild(card);
        ui = { spot: spot, ring: ringEl, card: card, count: count, markEl: markEl, title: title, why: why, status: status, go: go, placed: false };
        (document.documentElement || document.body).appendChild(host);
      }

      function rectOf(el) { var r = el.getBoundingClientRect(); return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; }

      function place() {
        pending = 0;
        if (!cfg || dismissed) { status = 'cleared'; return; }
        status = 'drawn';
        var dlg = openDialog();
        if (!target || !target.isConnected || !shown(target) || dlg) target = cfg.control ? resolve(cfg.control) : null;
        if (dlg && target && !dlg.contains(target)) target = null;   // behind an open dialog nothing is pointed at
        if (!host) build();
        if (!host.isConnected) (document.documentElement || document.body).appendChild(host);
        ui.count.textContent = cfg.counter ? ' \\u00B7 ' + cfg.counter : '';
        if (mark) { ui.markEl.src = mark; ui.markEl.style.display = 'block'; }
        ui.title.textContent = cfg.title || '';
        ui.why.textContent = cfg.why || '';
        ui.status.textContent = cfg.status || '';
        ui.status.style.display = cfg.status ? 'block' : 'none';
        ui.go.style.display = cfg.button ? 'inline-block' : 'none';
        ui.go.style.background = fill;
        ui.go.textContent = cfg.button || '';
        var animate = !reduce && ui.placed;
        ui.spot.className = 'spot' + (animate ? ' move' : '');
        ui.card.className = 'card' + (animate ? ' move' : '');
        var vw = window.innerWidth, vh = window.innerHeight, cw = 280, ch = ui.card.offsetHeight || 90, left, top;
        if (target) {
          lostAt = 0;
          var r = rectOf(target), pad = 6;
          ui.spot.style.display = 'block';
          ui.spot.style.left = (r.left - pad) + 'px'; ui.spot.style.top = (r.top - pad) + 'px';
          ui.spot.style.width = (r.width + pad * 2) + 'px'; ui.spot.style.height = (r.height + pad * 2) + 'px';
          ui.ring.style.boxShadow = '0 0 0 2px ' + ring;
          if (r.right + 16 + cw <= vw - 8) { left = r.right + 16 + pad; top = r.top; }
          else if (r.left - 16 - cw >= 8) { left = r.left - 16 - cw - pad; top = r.top; }
          else if (r.bottom + 16 + ch <= vh - 8) { left = r.right - cw; top = r.bottom + 16 + pad; }
          else { left = r.right - cw; top = Math.max(8, r.top - 16 - ch - pad); }
        } else if (dlg) {
          ui.spot.style.display = 'none'; lostAt = 0;
          var dr = rectOf(dlg);
          if (dr.right + 16 + cw <= vw - 8) { left = dr.right + 16; top = dr.top; }
          else if (dr.left - 16 - cw >= 8) { left = dr.left - 16 - cw; top = dr.top; }
          else if (dr.bottom + 16 + ch <= vh - 8) { left = dr.left; top = dr.bottom + 16; }
          else { left = dr.left; top = Math.max(8, dr.top - 16 - ch); }
        } else {
          ui.spot.style.display = 'none';
          left = vw - cw - 16; top = vh - ch - 16;
          // Zoom redraws often: a target that is briefly gone keeps the card where it was for 1.5s (no flicker).
          if (cfg.control) { if (!lostAt) lostAt = Date.now(); if (ui.placed && Date.now() - lostAt < 1500) { status = 'held'; return; } }
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
        stop(); cfg = null; target = null;
        if (host && host.parentNode) host.parentNode.removeChild(host);
        host = null; root = null; ui = null;
      }

      window.__grCoachSet = function (next, color, markUri, fillColor) {
        if (color) ring = color;
        if (fillColor) fill = fillColor;
        if (markUri) mark = markUri;
        if (!next) { dismissed = false; clear(); return 'cleared'; }
        cfg = next; target = null;
        if (ui) ui.placed = false;
        watch(); place(); schedule();
        return status;
      };
    })();
    """
}
