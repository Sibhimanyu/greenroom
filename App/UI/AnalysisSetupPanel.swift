//
//  AnalysisSetupPanel.swift
//  Greenroom
//
//  "Feedback settings": the two choices that used to live in Settings, moved to
//  the step they belong to.
//
//  Whisper (does this Mac hear properly, and which model) and who writes the
//  feedback (this Mac, or an agent you already run) are decisions about this
//  Mac, made once. The Ready popover has the two as inline pickers; this
//  sheet (titled "Feedback settings") is where its "More settings..." link
//  goes. Nothing here is a new setting: every key keeps its name and value,
//  so a choice made on the old Settings tab is already in place.
//
//  The body is ScreenroomPageContent, the same picture and tiles the old tab
//  drew; ScreenroomSettingsTab feeds it from the stored settings.
//
import SwiftUI

enum AnalysisSetup {
    /// Set once the panel has been answered. A new key, not a settings value:
    /// it only records that the question was asked.
    static let seenKey = "analysisSetupSeen"

    static var seen: Bool { UserDefaults.standard.bool(forKey: seenKey) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: seenKey) }
}

struct AnalysisSetupPanel: View {
    /// A place to change a choice; Done closes it. It never runs anything:
    /// Start lives in the Ready popover.
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Feedback settings")
                    .font(.title3.weight(.semibold))
                Text("Applies to the next feedback. Feedback already written does not change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)

            ScreenroomSettingsTab()

            Divider()
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 560, height: 700)
    }
}
