//
//  TransferSettingsTab.swift
//  Greenroom
//
//  Settings -> Transfer: every setting as one file.
//
//  Export/import all of the above as one JSON file - the whole point is
//  setting up a teammate's machine without them ever touching the Zoom
//  Marketplace: send them the app + this file, they import it, done. The page
//  draws that (this Mac, a file, their Mac) and offers the two moves as
//  pictures. Export still asks before it writes secrets in plain text.
//
//  `TransferPageContent` takes plain values and actions, so it can be rendered
//  off screen. `TransferSettingsTab` owns the panels and the coordinator.
//
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The tab

struct TransferSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var result: TransferResult?

    var body: some View {
        TransferPageContent(result: result, export: exportSettings, import: importSettings)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Greenroom Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.exportSettingsData().write(to: url, options: .atomic)
            result = .init(text: "Exported to \(url.lastPathComponent)", ok: true,
                           detail: "Hand it over directly (AirDrop) and delete it once imported.")
        } catch {
            result = .init(text: "Export failed", ok: false, detail: error.localizedDescription)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.importSettings(from: Data(contentsOf: url))
            result = .init(text: "Imported from \(url.lastPathComponent)", ok: true,
                           detail: "You can delete that file now.")
        } catch {
            result = .init(text: "Import failed", ok: false, detail: error.localizedDescription)
        }
    }
}

/// What the last export or import did.
struct TransferResult: Equatable {
    let text: String
    let ok: Bool
    /// The next step after a success, the reason after a failure.
    let detail: String
}

// MARK: - The page

struct TransferPageContent: View {
    let result: TransferResult?
    let export: () -> Void
    let `import`: () -> Void

    // Confirmation before writing secrets in plaintext - the risk shouldn't
    // live only in small caption text (Codex design audit #6).
    @State private var confirmingExport = false

    var body: some View {
        Form {
            Section {
                HandoverPicture()
            }

            Section("Settings file") {
                HStack(spacing: 8) {
                    ChoiceTile(title: "Export\u{2026}", selected: false, badge: "key.fill") {
                        glyph("square.and.arrow.up")
                    } action: { confirmingExport = true }
                    .help("One file with every setting, credentials included, in plain text. Hand it over directly (AirDrop) and delete it once imported.")
                    .confirmationDialog("This file will contain your Zoom secrets in plain text.",
                                        isPresented: $confirmingExport, titleVisibility: .visible) {
                        Button("Export Plaintext File") { export() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Hand it over directly (e.g. AirDrop) and delete it after importing.")
                    }

                    ChoiceTile(title: "Import\u{2026}", selected: false, badge: nil) {
                        glyph("square.and.arrow.down")
                    } action: { `import`() }
                    .help("Sets up this Mac from a file a colleague exported.")
                }
                .padding(.vertical, 4)

                if let result {
                    StatusBadge(text: result.text, tone: result.ok ? .good : .problem)
                        .help(result.detail)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(Color.secondary)
            .frame(height: 32)
    }
}

// MARK: - Pieces

/// This Mac -> a file -> their Mac: what the page is for.
private struct HandoverPicture: View {
    var body: some View {
        HStack(spacing: 12) {
            node(symbol: "laptopcomputer", title: "This Mac", tint: Brand.green)
            arrow
            node(symbol: "doc.text.fill", title: "Greenroom Settings.json", tint: Color.secondary)
            arrow
            node(symbol: "laptopcomputer", title: "Their Mac", tint: Color.secondary)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .help("Set up a colleague\u{2019}s Mac without the Zoom Marketplace: send them the app and this file, they import it, done.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Export a settings file from this Mac and import it on another")
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.secondary.opacity(0.6))
            .padding(.bottom, 24)
    }

    private func node(symbol: String, title: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 48, height: 36)
                .background(RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.secondary.opacity(0.25)))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 96)
    }
}
