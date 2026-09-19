//
//  WhisperModelPicker.swift
//  Greenroom
//
//  One picker, shown wherever the choice applies.
//
//  The whisper model is a property of the MAC, not of a feature: Screenroom
//  transcribes recordings with it and Cues listens through it, and nobody
//  wants two. So there is one stored value and one control, and the control
//  appears in both tabs rather than living in one and being inherited
//  invisibly by the other - which is what happened, and the question it
//  produced was "why am I not able to select which model I want in the Cues
//  settings".
//
//  A view rather than a copied block, so the two places cannot drift.
//
import SwiftUI

struct WhisperModelPicker: View {
    /// Shown above the picker. Cues and Screenroom want different sentences
    /// for the same control.
    var subtitle: String

    @State private var models = ScreenroomWhisper.availableModels()
    @State private var chosen = ScreenroomTranscriberSettings.resolvedModel()?.path ?? ""

    var body: some View {
        Group {
            if models.count > 1 {
                Picker(selection: Binding(get: { chosen }, set: { path in
                    chosen = path
                    var settings = ScreenroomTranscriberSettings.load()
                    settings.modelPath = path
                    settings.save()
                })) {
                    ForEach(models) { model in
                        Text(model.label).tag(model.url.path)
                    }
                } label: {
                    SettingLabel(title: "Whisper model", subtitle: subtitle)
                }
            } else if let only = models.first {
                // One model is a fact, not a decision, and a picker with one
                // row in it is furniture.
                LabeledContent {
                    Text(only.label)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                } label: {
                    SettingLabel(title: "Whisper model",
                                 subtitle: "The only one on this Mac. Add another in Settings \u{2192} Screenroom.")
                }
            } else {
                LabeledContent {
                    Text("none")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                } label: {
                    SettingLabel(title: "Whisper model",
                                 subtitle: "No model on this Mac yet \u{2014} Settings \u{2192} Screenroom has the two commands that add one.")
                }
            }
        }
        .onAppear {
            models = ScreenroomWhisper.availableModels()
            chosen = ScreenroomTranscriberSettings.resolvedModel()?.path ?? ""
        }
    }
}
