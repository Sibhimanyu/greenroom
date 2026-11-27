//
//  ForThisMeetingLine.swift
//  Greenroom
//
//  Settings -> Layouts: the one line under a saved row while the running meeting has its own value
//  for that setting ("For this meeting: Only me"), with Keep (save it into the layout) and Reset
//  (the meeting goes back to the saved value). Folds away, animated, when there is no change
//  (DESIGN.md "Settings: collapse when off"). docs/specs/meeting-setup.md R4.4.
//  Plain values and closures, so it renders off screen.
//
import SwiftUI

/// The lines for the active layout's three settings and what Keep and Reset do. `.none`: no meeting, no lines.
struct ForThisMeetingNotes {
    var cameraState: String?
    var cameraPiece: String?
    var share: String?
    var keep: (MeetingSetup.Setting) -> Void = { _ in }
    var reset: (MeetingSetup.Setting) -> Void = { _ in }

    static let none = ForThisMeetingNotes()

    func line(for setting: MeetingSetup.Setting) -> String? {
        switch setting {
        case .cameraState: return cameraState
        case .cameraPiece: return cameraPiece
        case .share: return share
        }
    }

    /// A row's line, bound to its setting.
    func view(_ setting: MeetingSetup.Setting) -> some View {
        ForThisMeetingLine(text: line(for: setting),
                           keep: { keep(setting) }, reset: { reset(setting) })
    }
}

struct ForThisMeetingLine: View {
    /// nil folds the line away.
    let text: String?
    let keep: () -> Void
    let reset: () -> Void
    /// The last text, so the words stay while the line folds instead of blanking first.
    @State private var shown = ""

    var body: some View {
        Collapsible(hidden: text == nil) {
            HStack(spacing: 8) {
                Text(text ?? shown)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Button(MeetingSetupLine.keepTitle, action: keep)
                    .help("Save this into the layout, so every meeting starts with it.")
                Button(MeetingSetupLine.resetTitle, action: reset)
                    .help("Give the meeting the saved value again.")
            }
            .controlSize(.small)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
        }
        .onChange(of: text, initial: true) { _, new in if let new { shown = new } }
    }
}
