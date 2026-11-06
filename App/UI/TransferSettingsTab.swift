//
//  TransferSettingsTab.swift
//  Greenroom
//
//  Settings -> Transfer: every setting as one file.
//
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Export/import all of the above as one JSON file - the whole point is
/// setting up a teammate's machine without them ever touching the Zoom
/// Marketplace: send them the app + this file, they import it, done.
struct TransferSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var statusMessage = ""
    @State private var confirmingExport = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    // Confirmation before writing secrets in plaintext - the
                    // risk shouldn't live only in small caption text below
                    // (Codex design audit #6).
                    Button("Export\u{2026}") { confirmingExport = true }
                        .confirmationDialog("This file will contain your Zoom secrets in plain text.",
                                            isPresented: $confirmingExport, titleVisibility: .visible) {
                            Button("Export Plaintext File") { exportSettings() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Hand it over directly (e.g. AirDrop) and delete it after importing.")
                        }
                } label: {
                    SettingLabel(title: "Export settings", subtitle: "One file with every setting, credentials included, in plain text.")
                }
                LabeledContent {
                    Button("Import\u{2026}") { importSettings() }
                } label: {
                    SettingLabel(title: "Import settings", subtitle: "Sets up this Mac from a file a colleague exported.")
                }
            } header: { Text("Transfer") } footer: {
                Text(statusMessage.isEmpty ? "Hand the file over directly (AirDrop) and delete it once imported." : statusMessage)
            }
        }
        .formStyle(.grouped)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Greenroom Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.exportSettingsData().write(to: url, options: .atomic)
            statusMessage = "Exported to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.importSettings(from: Data(contentsOf: url))
            statusMessage = "Imported from \(url.lastPathComponent). You can delete that file now."
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

