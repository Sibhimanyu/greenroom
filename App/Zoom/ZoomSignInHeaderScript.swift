//
//  ZoomSignInHeaderScript.swift
//  Greenroom
//
//  A constant, read-only page script: is Marketplace's header showing a
//  "Sign In" link (signed out) or an account menu (signed in)? It answers with
//  one word (`ZoomHeaderReport`) and nothing from the page. It never clicks,
//  types or focuses; the Swift caller runs it only on the real Marketplace host.
//
import Foundation

enum ZoomSignInHeaderScript {
    static let source = """
    (function () {
      function norm(s) { return (s || '').replace(/\\s+/g, ' ').trim(); }
      function shown(el) {
        var r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4 || r.top > 120) return false;
        var cs = window.getComputedStyle(el);
        return cs.visibility !== 'hidden' && cs.display !== 'none';
      }
      var all = document.body ? document.body.getElementsByTagName('*') : [];
      var account = false;
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (!shown(el)) continue;
        var tag = el.tagName;
        if ((tag === 'A' || tag === 'BUTTON' || el.getAttribute('role') === 'button') && norm(el.textContent) === 'Sign In') return 'signInLink';
        var hint = ((el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('alt') || '')).toLowerCase();
        if (hint.indexOf('avatar') >= 0 || hint.indexOf('account') >= 0 || hint.indexOf('profile') >= 0) account = true;
      }
      return account ? 'account' : 'neither';
    })();
    """
}
