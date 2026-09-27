//
//  WhisperSetupRows.swift
//  Greenroom
//
//  The rows that get whisper working, for any Form that needs it: the setup
//  guide's Cues and Screenroom pages, Settings → Cues and Settings →
//  Screenroom. They show only what is missing - the program, then the model -
//  and nothing once both are there. See WhisperInstaller.
//
import SwiftUI

struct WhisperSetupRows: View {
    @ObservedObject private var installer = WhisperInstaller.shared
    /// Called after the program or a model lands, so the host can re-read
    /// whatever it caches.
    var onChange: () -> Void = {}

    var body: some View {
        // Read through the revision so a change on disk redraws this.
        let _ = installer.revision
        Group {
            if case .failed(let why) = installer.phase {
                LabeledContent {
                    Button("Try again") { retry() }
                } label: {
                    SettingLabel(title: "Whisper setup stopped", subtitle: why)
                }
            }
            if !installer.hasProgram {
                programRow
            } else if !installer.hasModel {
                modelRow
            }
        }
        .onChange(of: installer.revision) { _ in onChange() }
    }

    private var programRow: some View {
        LabeledContent {
            if case .installingProgram = installer.phase {
                ProgressView().controlSize(.small)
            } else if WhisperInstaller.homebrew != nil {
                Button("Install whisper") { installer.installProgram() }
            } else {
                HStack(spacing: 8) {
                    Link("Get Homebrew", destination: URL(string: "https://brew.sh")!)
                    Button("Look again") { installer.noteChange() }
                }
            }
        } label: {
            SettingLabel(title: "Whisper isn\u{2019}t installed",
                         subtitle: programSubtitle)
        }
    }

    private var programSubtitle: String {
        if case .installingProgram(let line) = installer.phase { return line }
        return WhisperInstaller.homebrew != nil
            ? "Hears names and counts filler words, on this Mac. Installed with Homebrew, one press."
            : "Hears names and counts filler words, on this Mac. It installs with Homebrew, which this Mac does not have yet."
    }

    private var modelRow: some View {
        LabeledContent {
            if case .downloading(_, let fraction, _) = installer.phase {
                HStack(spacing: 8) {
                    ProgressView(value: fraction).frame(width: 110)
                    Button("Cancel") { installer.cancel() }.controlSize(.small)
                }
            } else {
                Button("Download (465 MB)") { installer.download() }
            }
        } label: {
            SettingLabel(title: "Whisper needs a model",
                         subtitle: modelSubtitle)
        }
    }

    private var modelSubtitle: String {
        if case .downloading(_, _, let detail) = installer.phase { return "Downloading \u{00B7} \(detail)" }
        return "Multilingual small: the one tested best on accented English. Downloaded once, into Greenroom\u{2019}s folder."
    }

    private func retry() {
        if !installer.hasProgram { installer.installProgram() } else { installer.download() }
    }
}
