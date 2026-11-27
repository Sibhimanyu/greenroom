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
    static func call(_ json: String?, ring: String, mark: String? = nil, fill: String? = nil) -> String {
        let m = mark.flatMap(safeMark).map { "'\($0)'" } ?? "null"
        let f = fill.map { "'\($0)'" } ?? "null"
        return "window.__grCoachSet && window.__grCoachSet(\(json ?? "null"), '\(ring)', \(m), \(f));"
    }

    static let source = """
    (function () {
      if (window.__grCoachSet) return;
      \(ZoomAppListScript.scanFunction)
      var host = null;
      \(ZoomFinderScript.functions)
      var root = null, ui = null, cfg = null, ring = 'currentColor', fill = '#4E8C30', mark = null;
      var status = 'cleared', target = null, resizeObs = null, mutObs = null, timer = 0, pending = 0, dismissed = false;
      var reduce = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);

      function findAppRow(index) {
        var rows = scanAppRows();
        return rows[index] ? rows[index].el : null;
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
          '.plan,.note{font-size:12px;color:#6e6e73;margin-top:4px;}',
          '.row{display:flex;align-items:center;gap:14px;margin-top:8px;}',
          '.do{border:0;border-radius:8px;padding:5px 12px;font:600 12px -apple-system,system-ui,sans-serif;color:#fff;cursor:pointer;pointer-events:auto;}',
          '.do[disabled]{opacity:.6;cursor:default;}',
          '.hide{display:inline-block;font-size:12px;color:#6e6e73;text-decoration:underline;cursor:pointer;pointer-events:auto;}',
          '@media (prefers-color-scheme: dark){.card{background:#2c2c2e;color:#f5f5f7;box-shadow:0 6px 24px rgba(0,0,0,.6),0 0 0 .5px rgba(255,255,255,.18);}',
          ' .count,.hide,.plan,.note{color:#a1a1a6;}}',
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
        var plan = document.createElement('div'); plan.className = 'plan';
        var note = document.createElement('div'); note.className = 'note';
        var row = document.createElement('div'); row.className = 'row';
        var go = document.createElement('button'); go.className = 'do'; go.type = 'button'; go.textContent = 'Do this step';
        go.setAttribute('tabindex', '-1');
        go.addEventListener('mousedown', function (e) { e.preventDefault(); });
        go.addEventListener('click', function (e) {
          e.preventDefault();
          if (go.disabled) return;
          if (curActionNow) { try { window.webkit.messageHandlers.coach.postMessage('do:' + curActionNow); } catch (err) {} }
        });
        row.appendChild(go); row.appendChild(hide);
        card.appendChild(head); card.appendChild(text); card.appendChild(plan); card.appendChild(note); card.appendChild(row);
        root.appendChild(spot); root.appendChild(card);
        ui = { spot: spot, ring: ringEl, card: card, count: count, markEl: markEl, text: text, plan: plan, note: note, go: go, placed: false };
        (document.documentElement || document.body).appendChild(host);
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
      var stageText = null, stageCounter = null, stageDone = false, stageAction = null, stagePlan = null, stageIdx = -1, lostAt = 0;
      var noteKey = null, lastNote = null, curActionNow = null;

      // A later stage the page has reached: {target} (the target may be null), or null when not reached.
      function stageResult(st) {
        if (st.kind === 'afterSwitchOn') { var sw = findToggle(st.switchLabel); return sw && isOn(sw) ? { target: st.label ? findNavLink(st.label) : null, done: true } : null; }
        if (st.kind === 'afterTextsPresent') {
          var all = st.texts && st.texts.length;
          for (var i = 0; all && i < st.texts.length; i++) if (!textVisibleOutside(st.texts[i])) { all = false; }
          return all ? { target: st.label ? findNavLink(st.label) : null, done: true } : null;
        }
        if (st.kind === 'afterActivated') return pageActivated() ? { target: st.label ? findNavLink(st.label) : null, done: true } : null;
        if (st.kind === 'nameField' || st.kind === 'createNamed') {
          var d = openDialog();
          if (!d || dialogHeading(d).indexOf(nn2(st.label)) !== 0) return null;
          var field = null, ins = d.querySelectorAll('input[type=text],input:not([type])');
          for (var k = 0; k < ins.length; k++) if (shown(ins[k])) { field = ins[k]; break; }
          if (!field) return null;
          var hasText = (field.value || '').length > 0;   // only whether it is empty, never the text
          if (st.kind === 'nameField') return hasText ? null : { target: field, done: false };
          return hasText ? { target: findControl('Create', d), done: false } : null;
        }
        var t = stageTarget(st);
        return t ? { target: t, done: false } : null;
      }

      var dialogEl = null;
      function resolve() {
        if (!cfg) return null;
        stageText = null; stageCounter = null; stageDone = false; stageAction = null; stagePlan = null; stageIdx = -1;
        dialogEl = openDialog();
        var t = resolveInner();
        // With a dialog open the coach only ever points INSIDE it; nothing behind it.
        if (dialogEl && (!t || !dialogEl.contains(t))) { if (t) { stageText = null; stageCounter = null; stageDone = false; stageAction = null; stagePlan = null; stageIdx = -1; } return null; }
        return t;
      }
      function resolveInner() {
        if (cfg.then) {
          // The furthest later stage the page shows wins; else the first spotlight.
          for (var si = cfg.then.length - 1; si >= 0; si--) {
            var r = stageResult(cfg.then[si]);
            if (r) { stageText = cfg.then[si].text; stageCounter = cfg.then[si].counter || null; stageDone = r.done; stageAction = cfg.then[si].action || null; stagePlan = cfg.then[si].plan || null; stageIdx = si; return r.target; }
          }
        }
        if (cfg.kind === 'appRow') return findAppRow(cfg.rowIndex);
        if (cfg.kind === 'build') return findBuildButton();
        if (cfg.kind === 'credRow') { var lab = textElement(cfg.label); var par = lab && lab.parentElement; return par && par.children.length >= 2 && shown(par) ? par : lab; }
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
        dialogEl = openDialog();
        // A flow with later stages looks again every time; others keep their target while it lasts.
        if (cfg.then || !target || !target.isConnected || !shown(target) || openDialog()) target = resolve();
        if (!host) build();
        if (!host.isConnected) (document.documentElement || document.body).appendChild(host);
        var useSearch = cfg.searchText && target && target.tagName === 'INPUT';
        var counter = stageCounter || cfg.counter;
        ui.count.textContent = counter ? ' \\u00B7 ' + counter : '';
        if (mark) { ui.markEl.src = mark; ui.markEl.style.display = 'block'; }
        var behindDialog = !!dialogEl && !target && !stageText;
        ui.text.textContent = behindDialog ? cfg.dialogText : (useSearch ? cfg.searchText : (stageText || cfg.text));
        // The button, the plan line and the result line belong to the CURRENT stage only.
        var curAction = stageIdx >= 0 ? stageAction : cfg.action;
        var curPlan = stageIdx >= 0 ? stagePlan : cfg.plan;
        var key = behindDialog ? 'dlg' : String(stageIdx);
        if (cfg.note !== lastNote) { lastNote = cfg.note; noteKey = cfg.note ? key : null; }
        var canDo = !!curAction && !stageDone && !behindDialog;
        ui.go.style.display = canDo ? 'inline-block' : 'none';
        ui.go.style.background = fill;
        ui.go.disabled = !!cfg.busy;
        ui.go.textContent = cfg.busy ? 'Working\\u2026' : 'Do this step';
        ui.plan.textContent = canDo && !cfg.busy && curPlan ? curPlan : '';
        ui.plan.style.display = ui.plan.textContent ? 'block' : 'none';
        var showNote = !!cfg.note && noteKey === key;
        ui.note.textContent = showNote ? cfg.note : '';
        ui.note.style.display = showNote ? 'block' : 'none';
        curActionNow = canDo ? curAction : null;
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
        } else if (dialogEl) {
          // A dialog is open and nothing inside it is ours to point at: the card sits BESIDE it, never over it.
          ui.spot.style.display = 'none';
          lostAt = 0;
          var dr = rectOf(dialogEl);
          if (dr.right + 16 + cw <= vw - 8) { left = dr.right + 16; top = dr.top; }
          else if (dr.left - 16 - cw >= 8) { left = dr.left - 16 - cw; top = dr.top; }
          else if (dr.bottom + 16 + ch <= vh - 8) { left = dr.left; top = dr.bottom + 16; }
          else { left = dr.left; top = Math.max(8, dr.top - 16 - ch); }
        } else {
          ui.spot.style.display = 'none';
          left = vw - cw - 16; top = vh - ch - 16;
          // Zoom redraws often: a target that is briefly gone keeps the card where it
          // was for 1.5s (no flicker). After that a card that needs a target hides,
          // and one that may stand alone moves to the corner.
          if (!lostAt) lostAt = Date.now();
          if (ui.placed && Date.now() - lostAt < 1500) { status = 'held'; return; }
          if (cfg.kind && cfg.kind !== 'none' && !cfg.optional && !stageText && !(cfg.then && (cfg.kind === 'build' || cfg.kind === 'appRow'))) { ui.card.style.display = 'none'; ui.placed = false; status = 'no-target'; return; }
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

      window.__grCoachSet = function (next, color, markUri, fillColor) {
        if (color) ring = color;
        if (fillColor) fill = fillColor;
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
