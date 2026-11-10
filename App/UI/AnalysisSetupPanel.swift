//
//  AnalysisSetupPanel.swift
//  Greenroom
//
//  "How to analyse": the two choices that used to live in Settings, moved to
//  the step they belong to.
//
//  Whisper (does this Mac hear properly, and which model) and who writes the
//  feedback (this Mac, or an agent you already run) are decisions about this
//  Mac, made once. They are asked at the first press of Analyse, because that
//  is the first moment they mean anything, and are one small control away
//  after that. Nothing here is a new setting: every key keeps its name and
//  value, so a choice made on the old Settings tab is already in place.
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
    /// First time: the button runs the analysis. After that the panel is a
    /// place to change a choice, and the button just closes it.
    let runsOnConfirm: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("How to analyse")
                    .font(.title3.weight(.semibold))
                Text(runsOnConfirm
                     ? "Asked once. You can change it later from the link next to Analyse."
                     : "Applies to the next analysis. Nothing already analysed changes.")
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
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .opacity(runsOnConfirm ? 1 : 0)
                    .disabled(!runsOnConfirm)
                Button(runsOnConfirm ? "Analyse" : "Done", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 560, height: 700)
    }
}
