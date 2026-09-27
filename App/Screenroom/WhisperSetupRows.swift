//
//  WhisperSetupRows.swift
//  Greenroom
//
//  One row that gets whisper working, for any Form that needs it: the setup
//  guide's Cues and Screenroom pages, Settings → Cues and Settings →
//  Screenroom. One line, one button, one progress bar - whatever is missing
//  is done in order behind it. Nothing shows once whisper works. See
//  WhisperInstaller.
//
//  It was two rows (the program, then a model) over a list of every model with
//  a paragraph and a curl command each. The teacher's question is only "can
//  this listen properly?", so that is the only question the row answers.
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
            if !installer.isReady {
                LabeledContent {
                    control
                } label: {
                    SettingLabel(title: "Whisper", subtitle: subtitle)
                }
            }
        }
        .onChange(of: installer.revision) { _ in onChange() }
    }

    @ViewBuilder private var control: some View {
        switch installer.phase {
        case .installingProgram:
            ProgressView().controlSize(.small)
        case .downloading(_, let fraction, _):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 110)
                Button("Cancel") { installer.cancel() }.controlSize(.small)
            }
        default:
            if !installer.hasProgram, WhisperInstaller.homebrew == nil {
                Link("Get Homebrew first", destination: URL(string: "https://brew.sh")!)
            } else {
                Button(installer.phase == .idle ? "Set up whisper" : "Try again") { installer.setUp() }
            }
        }
    }

    private var subtitle: String {
        switch installer.phase {
        case .installingProgram(let line): return "Installing\u{2026} \(line)"
        case .downloading(_, _, let detail): return "Downloading the model \u{00B7} \(detail)"
        case .failed(let why): return why
        default:
            if !installer.hasProgram, WhisperInstaller.homebrew == nil {
                return "Hears names properly and counts filler words, on this Mac. It installs with Homebrew, which this Mac doesn\u{2019}t have yet; come back after."
            }
            return "Hears names properly and counts filler words, on this Mac. One press: about 465 MB, once."
        }
    }
}
