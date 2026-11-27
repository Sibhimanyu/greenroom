//
//  ZoomKeyReaderScript.swift
//  Greenroom
//
//  The page script that reads the key inputs (spec R5), a constant. It runs
//  only on the two credential pages (the Swift caller checks the page kind and
//  the exact host first), only reads (no click, no typing, no focus, no
//  network, no storage) and returns the values to Swift as one JSON string.
//  Each field is found by its label (Account ID, Client ID, Client Secret);
//  if that fails, the probe's input order is the fallback (text, text,
//  password). Swift then keeps only values that look like keys. The values are
//  never logged, never put in a title, never sent anywhere but the guide's
//  own fields.
//
import Foundation

enum ZoomKeyReaderScript {
    /// The script for these fields; its result is a JSON string of the fields it found.
    static func call(fields: [ZoomKeyField]) -> String {
        let names = fields.map { name in
            switch name {
            case .accountID: return "'accountID'"
            case .clientID: return "'clientID'"
            case .clientSecret: return "'clientSecret'"
            }
        }.joined(separator: ",")
        return "(\(source))([\(names)]);"
    }

    static let source = """
    function (want) {
      var LABEL = { accountID: 'Account ID', clientID: 'Client ID', clientSecret: 'Client Secret' };
      function norm(s) { return (s || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
      function ownText(el) {
        var t = '';
        for (var i = 0; i < el.childNodes.length; i++) if (el.childNodes[i].nodeType === 3) t += el.childNodes[i].nodeValue;
        return norm(t);
      }
      function fieldInputs(scope) {
        return Array.prototype.slice.call(scope.querySelectorAll('input')).filter(function (i) {
          var t = (i.getAttribute('type') || 'text').toLowerCase();
          return t === 'text' || t === 'password';
        });
      }
      var labels = document.body ? document.body.getElementsByTagName('*') : [];
      // The probe's order (text, text, password) is only trusted inside the "App Credentials" card: the smallest
      // ancestor of that heading that holds as many fields as we want; else the whole page.
      var scope = document;
      for (var h = 0; h < labels.length; h++) {
        if (ownText(labels[h]) !== 'app credentials') continue;
        var q = labels[h];
        for (var up = 0; up < 8 && q && q !== document.body; up++, q = q.parentElement) {
          if (fieldInputs(q).length >= want.length) { scope = q; break; }
        }
        break;
      }
      var all = fieldInputs(scope);
      var texts = all.filter(function (i) { return (i.getAttribute('type') || 'text').toLowerCase() === 'text'; });
      var passwords = all.filter(function (i) { return (i.getAttribute('type') || '').toLowerCase() === 'password'; });

      function byLabel(text) {
        for (var i = 0; i < labels.length; i++) {
          var el = labels[i];
          if (ownText(el) !== text && ownText(el) !== text + ':') continue;
          var p = el;
          for (var hops = 0; p && p !== document.body && hops < 5; hops++, p = p.parentElement) {
            var inputs = fieldInputs(p);
            for (var j = 0; j < inputs.length; j++) {
              if (el.compareDocumentPosition(inputs[j]) & Node.DOCUMENT_POSITION_FOLLOWING) return inputs[j];
            }
          }
        }
        return null;
      }
      // Zoom also shows some keys as plain text beside the label (a Draft app's Client ID): the sibling whose
      // whole text is key-shaped. Anything else (dots, "Show") is not a key and is ignored.
      function textSibling(text) {
        for (var i = 0; i < labels.length; i++) {
          var el = labels[i];
          if (ownText(el) !== text) continue;
          var p = el;
          for (var hops = 0; p && p !== document.body && hops < 3; hops++, p = p.parentElement) {
            var kids = p.children;
            for (var j = 0; j < kids.length; j++) {
              if (kids[j] === el || kids[j].contains(el) || el.contains(kids[j])) continue;
              if (!(el.compareDocumentPosition(kids[j]) & Node.DOCUMENT_POSITION_FOLLOWING)) continue;
              var t = norm2(kids[j].textContent);
              if (/^[A-Za-z0-9_-]{10,64}$/.test(t) && !kids[j].querySelector('input') && !/(\\u2026|\\.\\.\\.)$/.test(t)) return t;
            }
          }
        }
        return null;
      }
      function norm2(s) { return (s || '').replace(/\\s+/g, ' ').trim(); }
      function byOrder(name) {
        var hasAccount = want.indexOf('accountID') >= 0;
        if (name === 'accountID') return texts[0] || null;
        if (name === 'clientID') return (hasAccount ? texts[1] : texts[0]) || null;
        return passwords[0] || null;
      }

      var out = {}, diag = [];
      for (var k = 0; k < want.length; k++) {
        var name = want[k];
        var input = byLabel(LABEL[name].toLowerCase());
        var v = input ? String(input.value || '').trim() : '';
        if (!v) { var text = textSibling(LABEL[name].toLowerCase()); if (text) v = text; }
        var how = v ? (input ? 'input' : 'text') : '';
        if (!v) { var guess = byOrder(name); v = guess ? String(guess.value || '').trim() : ''; if (v) how = 'order'; }
        // Lengths only: how each field was found, never what it holds.
        diag.push(name + '=' + (v ? how + v.length : 'missing'));
        if (v) out[name] = v;
      }
      out._diag = diag.join(';');
      return JSON.stringify(out);
    }
    """
}
