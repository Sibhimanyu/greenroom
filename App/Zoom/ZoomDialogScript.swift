//
//  ZoomDialogScript.swift
//  Greenroom
//
//  A read-only look at an open dialog on Marketplace's page: its heading (only when
//  it is one of Zoom's own create dialogs, "Create a ..." or "What kind of app ...")
//  and, in the type chooser, the text of the chosen type's row. Swift's
//  `ZoomCoachRules.partFollowing` turns that into the part the coach follows.
//  Reads text only: no values, no clicks. A constant.
//
import Foundation

enum ZoomDialogScript {
    /// JSON: {"heading":"create a general app","chosen":"general app ..."} or "null".
    static let source = """
    (function () {
      var host = null;
      \(ZoomFinderScript.functions)
      var dlg = openDialog();
      if (!dlg) return 'null';
      var heading = dialogHeading(dlg);
      if (heading.indexOf('create a ') !== 0 && heading.indexOf('what kind of app') !== 0) return 'null';
      var chosen = null;
      if (heading.indexOf('what kind of app') === 0) {
        var boxes = dlg.querySelectorAll('input[type=radio]:checked,[role=radio][aria-checked="true"]');
        if (boxes.length) { var row = boxes[0].closest('label') || boxes[0].parentElement; chosen = nn2(row ? row.textContent : '').slice(0, 80); }
      }
      return JSON.stringify({ heading: heading.slice(0, 80), chosen: chosen });
    })();
    """
}
