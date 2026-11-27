//
//  ZoomAppListScript.swift
//  Greenroom
//
//  The read-only scan of Marketplace's "Created apps" table (spec R15). It
//  finds the table's Type column by its header text and lists each row's TYPE
//  text only (lowercase, at most 80 characters): app names are never read. The
//  coach script embeds the same `scanAppRows` so a row's index means the same
//  thing in both. Never clicks, types, focuses or sends anything. Constants.
//
import Foundation

enum ZoomAppListScript {
    /// `scanAppRows()` returns [{el, typeText}] for the visible data rows; shared with `ZoomCoachScript`.
    static let scanFunction = """
    function scanAppRows() {
      function nn(s) { return (s || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
      function vis(el) {
        var r = el.getBoundingClientRect();
        if (r.width < 4 || r.height < 4) return false;
        var cs = window.getComputedStyle(el);
        return cs.visibility !== 'hidden' && cs.display !== 'none';
      }
      var typeCol = -1, headerRow = null;
      var heads = document.querySelectorAll('th, [role=columnheader]');
      for (var i = 0; i < heads.length; i++) {
        if (nn(heads[i].textContent) !== 'type') continue;
        var hr = heads[i].closest('tr,[role=row]');
        if (hr) { headerRow = hr; typeCol = Array.prototype.indexOf.call(hr.querySelectorAll('th,[role=columnheader]'), heads[i]); }
        break;
      }
      var KNOWN = ['server-to-server oauth', 'server to server oauth', 'general app', 'webhook only app'];
      var out = [];
      var rows = document.querySelectorAll('tr, [role=row]');
      for (var j = 0; j < rows.length; j++) {
        var row = rows[j];
        if (row === headerRow || row.querySelector('th,[role=columnheader]') || !vis(row)) continue;
        var cells = row.querySelectorAll('td,[role=cell],[role=gridcell]');
        if (cells.length < 2) continue;
        var type = typeCol >= 0 && cells[typeCol] ? nn(cells[typeCol].textContent) : '';
        if (!type) {
          var all = nn(row.textContent);
          for (var k = 0; k < KNOWN.length; k++) if (all.indexOf(KNOWN[k]) >= 0) { type = KNOWN[k]; break; }
        }
        out.push({ el: row, typeText: type.slice(0, 80) });
      }
      if (out.length) return out;
      // No table: Zoom's real list (2026-11-27) is plain divs. Find each Type label by
      // its own text, then climb to the smallest ancestor that is wide (most of the
      // list) and holds exactly one Type label: that is the row.
      var labels = [];
      var all = document.querySelectorAll('body *');
      for (var a = 0; a < all.length; a++) {
        var el = all[a];
        if (el.children.length > 2 || !vis(el)) continue;
        var t = nn(el.textContent);
        for (var b = 0; b < KNOWN.length; b++) {
          if (t.indexOf(KNOWN[b]) === 0 && t.length < KNOWN[b].length + 60) {
            if (!labels.some(function (l) { return l.el.contains(el) || el.contains(l.el); })) labels.push({ el: el, type: t });
            break;
          }
        }
      }
      function typeCount(node) {
        var n = 0;
        for (var c = 0; c < labels.length; c++) if (node.contains(labels[c].el)) n++;
        return n;
      }
      var main = document.querySelector('main') || document.body;
      var wide = main.getBoundingClientRect().width * 0.5;
      labels.forEach(function (l) {
        var node = l.el, row = null;
        while (node && node !== document.body) {
          if (typeCount(node) > 1) break;
          if (node.getBoundingClientRect().width >= wide) row = node;
          node = node.parentElement;
        }
        if (row && !out.some(function (o) { return o.el === row; })) out.push({ el: row, typeText: l.type.slice(0, 80) });
      });
      out.sort(function (x, y) { return x.el.getBoundingClientRect().top - y.el.getBoundingClientRect().top; });
      return out;
    }
    """

    /// Returns a JSON string: [{"index":0,"typeText":"general app \u{00B7} user managed"}, ...].
    static let source = """
    (function () {
      \(scanFunction)
      var rows = scanAppRows();
      return JSON.stringify(rows.map(function (r, i) { return { index: i, typeText: r.typeText }; }));
    })();
    """
}
