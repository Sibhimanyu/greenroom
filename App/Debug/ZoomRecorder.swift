#if DEBUG
//
//  ZoomRecorder.swift
//  Greenroom
//
//  DEBUG-only: with the launch argument `-zoomRecord YES`, the Zoom window reads a
//  `ZoomPageSnapshot` after every page change, route change and DOM settle (throttled to
//  about 700ms, and only when it differs from the last) and appends one JSON line
//  `{snapshot, ts}` to ~/Library/Logs/Greenroom/zoom-snapshots.jsonl. Key values are
//  replaced by their length and a short fingerprint before they are written
//  (`ZoomRecordingLine`). Every user click in the page is recorded too, as
//  `{event:"click", control, ts}` (the clicked element's resolved `ZoomControl` ID, else
//  its role and a short scrubbed text), so a recording shows what was pressed between
//  snapshots. The click listener is passive and only reports; it never changes the page.
//
//  `-zoomCoachOff YES` turns off the coach drawing and the automatic key fill (page read
//  and clipboard pickup), so a recording run sees Zoom's pages untouched.
//
//  Debug UI never ships: this whole file, and every call to it, is inside #if DEBUG.
//
import Foundation

enum ZoomRecorder {
    private static func flag(_ name: String) -> Bool {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return false }
        return ["YES", "yes", "1", "true"].contains(a[i + 1])
    }
    static var enabled: Bool { flag("-zoomRecord") }
    static var coachOff: Bool { flag("-zoomCoachOff") }

    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Greenroom/zoom-snapshots.jsonl")

    static func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    /// Installed at document start in the client world (Zoom's own scripts cannot see it). Reports clicks (capture phase,
    /// passive: before Zoom's handlers run, so the DOM is as the person saw it) and, throttled, "the DOM changed".
    static let clickScript: String = """
    (function () {
      if (window.__grRecord) return; window.__grRecord = true;
      \(ZoomPageScript.library)
      function post(o) { try { window.webkit.messageHandlers.zoomRecord.postMessage(o); } catch (e) {} }
      function related(el, t) {
        if (el === t || el.contains(t)) return true;
        var box = t.closest ? t.closest('label,[role=button],li') : null;
        return !!(box && box.contains(el) && box.querySelectorAll('input,button,a').length <= 2);
      }
      document.addEventListener('click', function (e) {
        var out = { click: true };
        try {
          var t = e.target;
          if (t && t.nodeType === 1 && onMarketplace()) {
            var rows = path().indexOf('/user/build') === 0 ? scanAppRows().length : 0, best = null, bestArea = 1e12;
            allControlIds(rows).forEach(function (id) {
              var el = resolve(id);
              if (!el || !related(el, t)) return;
              var r = el.getBoundingClientRect(), a = r.width * r.height;
              if (a < bestArea) { best = id; bestArea = a; }
            });
            if (best) out.control = best;
          }
          if (!out.control && t && t.nodeType === 1) {
            var holder = t.closest('[role],button,a,input,li,label') || t;
            out.role = (holder.getAttribute('role') || holder.tagName || '').toLowerCase().slice(0, 30);
            if (holder.matches('button,a,[role=button],[role=menuitem],[role=tab],label')) out.text = scrub(clip(holder.textContent, 40));
          }
        } catch (err) {}
        post(out);
      }, { capture: true, passive: true });
      var pending = false;
      function nudge() { if (pending) return; pending = true; setTimeout(function () { pending = false; post({ nudge: true }); }, 300); }
      function watch() {
        if (!document.documentElement) return;
        new MutationObserver(nudge).observe(document.documentElement, { childList: true, subtree: true, characterData: true,
          attributes: true, attributeFilter: ['class', 'aria-checked', 'aria-expanded', 'disabled', 'hidden', 'style'] });
      }
      if (document.documentElement) watch(); else document.addEventListener('DOMContentLoaded', watch);
    })();
    """
}
#endif
