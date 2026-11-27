//
//  ZoomActorScript.swift
//  Greenroom
//
//  The page script behind "Do this step" (spec R16), a constant run through
//  `callAsyncJavaScript` in WKContentWorld.defaultClient, only when the person
//  presses the coach card's button. Safety lives in ONE place: `rawClick` is the
//  only call that clicks, and every wrapper in front of it (`press`, `pressRadio`,
//  `pressScope`, `pressSwitch`, `pressFinder`) first checks the element's exact
//  label against the step's allow-list (arguments from `ZoomActorRules`) and
//  refuses anything matching the deny-list, even when allowed. It never touches
//  an input except the scopes panel's search field (set with the native setter and
//  an input event, so React sees it), never runs on credentials pages, waits for
//  each action's expected result (about 5s) and stops on any surprise. It returns
//  one JSON string: a code, counts and "click <allowed label> ok" lines, never page
//  text, values or app names. The words come from `ZoomActorRules.message`.
//
import Foundation

enum ZoomActorScript {
    /// The arguments for a step: Swift's lists, never the page's.
    static func arguments(_ step: ZoomActorStep, part: ZoomGuidePart) -> [String: Any] {
        let type = part == .hostingApp ? "Server to server OAuth app" : "General app"
        return ["step": step.rawValue,
                "scopes": ZoomScopes.names,
                "deny": ZoomActorRules.denyPattern,
                "allow": ZoomActorRules.allowList(for: step),
                "typeLabel": type]
    }

    /// Function body (top-level await allowed). Arguments: step, scopes, deny, allow, typeLabel.
    static let body = """
    var host = null;
    \(ZoomAppListScript.scanFunction)
    \(ZoomFinderScript.functions)
    var DENY = new RegExp(deny, 'i');
    var log = [];
    function nn(s) { return (s || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
    function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }
    async function until(fn, ms) {
      var t = Date.now();
      while (Date.now() - t < (ms || 5000)) { var v = fn(); if (v) return v; await wait(100); }
      return null;
    }
    function fin(code, extra) {
      var r = { code: code, log: log };
      if (extra) for (var k in extra) r[k] = extra[k];
      return JSON.stringify(r);
    }
    function denied(texts) {
      for (var i = 0; i < texts.length; i++) if (texts[i] && DENY.test(texts[i])) return true;
      return false;
    }
    // The ONLY place that clicks. Callers have already matched the element to the allow-list.
    function rawClick(el, label, names) {
      if (denied(names)) { log.push('refused ' + label); return false; }
      el.click();
      log.push('click ' + label + ' ok');
      return true;
    }
    // A control whose own exact label (visible text, else aria-label) is on the allow-list.
    function press(el) {
      if (!el) return false;
      var label = nn(el.textContent) || nn(el.getAttribute('aria-label'));
      if (allow.indexOf(label) < 0) { log.push('refused'); return false; }
      return rawClick(el, label, [nn(el.textContent), nn(el.getAttribute('aria-label')), nn(el.getAttribute('title'))]);
    }
    // The round + found by findBuildButton (an icon: no text to match, so allowed by its position and label).
    function pressFinder(el) {
      if (!el || allow.indexOf('+') < 0) return false;
      return rawClick(el, '+', [nn(el.textContent), nn(el.getAttribute('aria-label')), nn(el.getAttribute('title'))]);
    }
    function pressRadio(el, label) {
      if (!el || allow.indexOf(nn(label)) < 0) return false;
      return rawClick(el, nn(label), [nn(el.getAttribute('aria-label')), nn(el.getAttribute('title'))]);
    }
    function pressSwitch(el, label) {
      if (!el || allow.indexOf(nn(label)) < 0) return false;
      return rawClick(el, nn(label), [nn(el.getAttribute('aria-label')), nn(el.getAttribute('title'))]);
    }
    // A scope's checkbox: one of our scope names only; its own name is deny-checked with the scope string removed.
    function pressScope(el, scope) {
      if (!el || scopes.indexOf(scope) < 0) return false;
      var own = [el.getAttribute('aria-label') || '', el.getAttribute('title') || ''].map(function (t) { return nn(t.split(scope).join('')); });
      return rawClick(el, 'scope checkbox', own);
    }
    function setSearch(input, value) {
      var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      setter.call(input, value);
      input.dispatchEvent(new Event('input', { bubbles: true }));
    }
    function isSearch(el) {
      var hint = nn((el.getAttribute('placeholder') || '') + ' ' + (el.getAttribute('aria-label') || ''));
      return hint.indexOf('search') >= 0 && shown(el);
    }
    function findSearch() {
      var dialogs = document.querySelectorAll('[role=dialog],[aria-modal="true"],.MuiDrawer-root');
      for (var i = 0; i < dialogs.length; i++) {
        var inputs = dialogs[i].querySelectorAll('input');
        for (var j = 0; j < inputs.length; j++) if (isSearch(inputs[j])) return inputs[j];
      }
      var all = document.querySelectorAll('input');
      for (var k = 0; k < all.length; k++) if (isSearch(all[k])) return all[k];
      return null;
    }
    // The checkbox of the result row that holds exactly this scope string (one checkbox in the row).
    function scopeCheckbox(search, scope) {
      var root = search.closest('[role=dialog],[aria-modal="true"],.MuiDrawer-root') || document.body;
      var boxes = root.querySelectorAll('input[type=checkbox],[role=checkbox]');
      for (var i = 0; i < boxes.length; i++) {
        var p = boxes[i];
        for (var hops = 0; p && p !== root && hops < 6; hops++, p = p.parentElement) {
          if ((p.textContent || '').indexOf(scope) < 0) continue;
          if (p.querySelectorAll('input[type=checkbox],[role=checkbox]').length === 1) return boxes[i];
          break;
        }
      }
      return null;
    }
    function boxOn(b) { return b.checked === true || b.getAttribute('aria-checked') === 'true'; }
    function findConfirm(search, label) {
      var p = search.closest('[role=dialog],[aria-modal="true"],.MuiDrawer-root') || search;
      for (var hops = 0; p && p !== document.body && hops < 10; hops++, p = p.parentElement) {
        var btns = p.querySelectorAll('button,[role=button]');
        for (var i = 0; i < btns.length; i++) if (nn(btns[i].textContent) === label && shown(btns[i])) return btns[i];
      }
      return null;
    }

    async function createApp() {
      var chooser = chooserRoot();
      if (!chooser) {
        var item = findMenuItem('Build');
        if (!item) {
          var plus = findBuildButton();
          if (!plus || !pressFinder(plus)) return fin('no-plus');
          item = await until(function () { return findMenuItem('Build'); });
          if (!item) return fin('no-build');
        }
        if (!press(item)) return fin('no-build');
        chooser = await until(chooserRoot);
        if (!chooser) return fin('no-chooser');
      }
      var row = await until(function () { var c = chooserRoot(); return c && findRow(typeLabel, c); });
      if (!row) return fin('no-radio');
      if (!isChosen(row)) {
        var input = row.querySelector('input[type=radio],[role=radio]') || row;
        if (!pressRadio(input, typeLabel)) return fin('no-radio');
        var chosen = await until(function () { var c = chooserRoot(); return c && isChosen(findRow(typeLabel, c)); });
        if (!chosen) return fin('no-radio');
      }
      var create = await until(function () {
        var c = chooserRoot(); var el = c && findControl('Create', c);
        return el && el.matches('button,[role=button]') ? el : null;
      });
      if (!create || !press(create)) return fin('no-create');
      await wait(300);
      return fin('done');
    }

    async function addScopes() {
      var missing = scopes.filter(function (s) { return !textVisibleOutside(s); });
      if (!missing.length) return fin('already', { added: 0, total: 0 });
      var search = findSearch();
      if (!search) {
        var add = findControl('Add Scopes');
        if (!add || !add.matches('button,[role=button],a') || !press(add)) return fin('no-add-scopes');
        search = await until(findSearch);
        if (!search) return fin('no-panel');
      }
      var ticked = 0, notFound = [];
      for (var i = 0; i < missing.length; i++) {
        var scope = missing[i];
        setSearch(search, scope);
        var box = await until(function () { return scopeCheckbox(search, scope); });
        if (!box) { notFound.push(scope); continue; }
        if (!boxOn(box)) {
          if (!pressScope(box, scope)) { notFound.push(scope); continue; }
          var on = await until(function () { return boxOn(box); }, 2000);
          if (!on) { notFound.push(scope); continue; }
        }
        ticked++;
        setSearch(search, '');
        await wait(250);
      }
      var pressed = false, labels = ['done', 'save', 'continue'];
      for (var l = 0; l < labels.length && !pressed; l++) {
        var b = findConfirm(search, labels[l]);
        if (b && press(b)) pressed = true;
      }
      if (!pressed) return fin('no-confirm', { added: ticked, total: missing.length, notFound: notFound });
      await until(function () { return !findSearch(); });
      var added = 0, lost = [];
      for (var m = 0; m < missing.length; m++) {
        var s2 = missing[m];
        var seen = await until(function () { return textVisibleOutside(s2); }, 3000);
        if (seen) added++; else lost.push(s2);
      }
      return fin('done', { added: added, total: missing.length, notFound: lost });
    }

    async function activate() {
      var btn = findControl('Activate your app') || findControl('Activate');
      if (!btn || !btn.matches('button,[role=button],a')) return fin(pageActivated() ? 'already' : 'no-button');
      if (!press(btn)) return fin('no-button');
      var ok = await until(pageActivated);
      return fin(ok ? 'done' : 'not-verified');
    }

    async function enableSDK() {
      var sw = findToggle('Meeting SDK');
      if (!sw) return fin('no-switch');
      if (isOn(sw)) return fin('already');
      var input = sw.matches('input,[role=switch]') ? sw : (sw.querySelector('input,[role=switch]') || sw);
      if (!pressSwitch(input, 'Meeting SDK')) return fin('no-switch');
      var on = await until(function () { var t = findToggle('Meeting SDK'); return t && isOn(t); });
      return fin(on ? 'done' : 'not-verified');
    }

    var path = (location.pathname || '');
    if (path.indexOf('/credentials') >= 0 || path.indexOf('/information') >= 0) return fin('refused');
    if (step === 'createApp') return await createApp();
    if (step === 'addScopes') return await addScopes();
    if (step === 'activate') return await activate();
    if (step === 'enableSDK') return await enableSDK();
    return fin('refused');
    """
}
