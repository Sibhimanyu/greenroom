//
//  MeetingSetupLine.swift
//  Greenroom
//
//  The words that say where a camera, share or camera-piece value lives (docs/specs/meeting-setup.md
//  R3.2, R4.3, R4.4). Pure: Foundation only, compiled by the test target as it is.
//
//  Home (one quiet line under a control's summary):
//   - no meeting up:                 "Saved to <layout>"   (a change goes into that layout)
//   - meeting up, a change in effect: "For this meeting"
//   - meeting up, nothing changed:   "From <layout>"       (a change would be for this meeting only)
//  The last one is shown rather than nothing so the panel keeps one height when the first pick
//  arrives, and so the person is told, before they pick, that the pick will not be saved.
//  Settings -> Layouts (under the saved row, only while a change is in effect): "For this meeting: <value>".
//
import Foundation

enum MeetingSetupLine {

    static let keepTitle = "Keep"
    static let resetTitle = "Reset"

    /// Home's line. nil only when there is no layout to name and no change to report.
    static func home(layoutName: String?, sessionUp: Bool, forThisMeeting: Bool) -> String? {
        if sessionUp, forThisMeeting { return "For this meeting" }
        guard let name = layoutName, !name.isEmpty else { return nil }
        return sessionUp ? "From \(name)" : "Saved to \(name)"
    }

    /// The line under a Layouts row: nil (collapsed) when that setting has no change in effect.
    static func layouts(forThisMeeting: Bool, valueName: String) -> String? {
        forThisMeeting ? "For this meeting: \(valueName)" : nil
    }

    /// What a camera-piece change reads as: its shape when the shape changed, else that it was moved or resized.
    static func pieceName(saved: LayoutCamera, inUse: LayoutCamera) -> String {
        inUse.shape != saved.shape ? inUse.shape.label : "Moved or resized"
    }
}
