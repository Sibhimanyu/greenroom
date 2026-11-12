//
//  YouTubeSettingsTab.swift
//  Greenroom
//
//  Settings -> YouTube: uploading recordings.
//
//  The one feature that sends class content off the Mac, so the page opens on
//  a picture of exactly that: this Mac, an arrow, YouTube. The arrow is amber
//  (DESIGN.md `--net`) whenever a recording could cross it, and grey with
//  "Stays here" when it can't. The choices are pictures; where the file goes
//  and how the sign-in works are in hover help.
//
//  `YouTubePageContent` takes plain bindings, so it can be rendered off screen
//  with sample values. `YouTubeSettingsTab` feeds it from the coordinator.
//
import AppKit
import SwiftUI

// MARK: - The tab

struct YouTubeSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        YouTubePageContent(
            uploadMode: $coordinator.youtubeUploadMode,
            privacy: $coordinator.youtubePrivacy,
            clientID: $coordinator.youtubeClientID,
            clientSecret: $coordinator.youtubeClientSecret,
            connected: coordinator.youtubeConnected,
            uploading: coordinator.isUploadingToYouTube,
            status: coordinator.youtubeStatus,
            connect: { await coordinator.connectYouTube() },
            disconnect: { await coordinator.disconnectYouTube() })
    }
}

// MARK: - The page

struct YouTubePageContent: View {
    @Binding var uploadMode: YouTubeUploadMode
    @Binding var privacy: String
    @Binding var clientID: String
    @Binding var clientSecret: String
    let connected: Bool
    let uploading: Bool
    /// The coordinator's last word on the account, or empty.
    let status: String
    let connect: () async -> Void
    let disconnect: () async -> Void

    @State private var connecting = false

    private var hasClient: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
    private var failed: Bool { !connected && !connecting && status.hasPrefix("Not connected:") }

    var body: some View {
        Form {
            Section("Recordings") {
                UploadFlowPicture(mode: uploadMode, connected: connected, uploading: uploading)
                uploadChoices
                // Do nothing: no upload, so no visibility to choose.
                Collapsible(hidden: uploadMode == .off) { visibilityChoices }
            }

            Section("Account") {
                TextField("Client ID", text: $clientID)
                    .help(Self.clientHelp)
                SecureField("Client Secret", text: $clientSecret)
                    .help(Self.clientHelp)
                accountRow
                if failed {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var uploadChoices: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("After recording").font(.callout)
            ModePicker(selection: $uploadMode.animatedCollapse())
        }
        .accessibilityElement(children: .contain)
    }

    private var visibilityChoices: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Visibility").font(.callout)
            VisibilityPicker(selection: $privacy)
        }
        .accessibilityElement(children: .contain)
    }

    private static let clientHelp = "From a Google Cloud OAuth client of type \u{201C}Desktop app\u{201D} with the YouTube Data API v3 enabled. The setup guide (? on the main window) has the clicks. While the Google project is in Testing, the sign-in lasts seven days."

    private var accountRow: some View {
        LabeledContent {
            HStack(spacing: 12) {
                if uploading { ProgressView().controlSize(.small) }
                if connected {
                    Button("Disconnect") { Task { await disconnect() } }
                } else {
                    Button(connecting ? "Waiting\u{2026}" : "Connect\u{2026}") {
                        connecting = true
                        Task {
                            await connect()
                            connecting = false
                        }
                    }
                    .disabled(connecting || !hasClient)
                }
            }
        } label: {
            accountBadge
                .help(status.isEmpty
                      ? "Signs in once in your browser. Greenroom can upload and edit your own videos, nothing else."
                      : status)
        }
    }

    @ViewBuilder
    private var accountBadge: some View {
        if connected {
            StatusBadge(text: "Connected", tone: .good)
        } else if connecting {
            StatusBadge(text: "Waiting for Google", tone: .waiting)
        } else if failed {
            StatusBadge(text: "Couldn\u{2019}t connect", tone: .problem)
        } else if hasClient {
            StatusBadge(text: "Not connected", tone: .waiting)
        } else {
            StatusBadge(text: "Not set up", tone: .waiting)
        }
    }
}

// MARK: - Pieces


/// This Mac -> YouTube, with the arrow saying whether anything crosses it.
private struct UploadFlowPicture: View {
    let mode: YouTubeUploadMode
    let connected: Bool
    let uploading: Bool

    private var crosses: Bool { mode != .off }

    var body: some View {
        HStack(spacing: 16) {
            FlowNode(symbol: "laptopcomputer", title: "This Mac", tint: Brand.green)
            connector
            FlowNode(symbol: "play.rectangle.fill", title: "YouTube",
                     tint: crosses && connected ? Brand.net : Color.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if uploading { PictureChip(text: "UPLOADING", dot: Brand.net) }
        }
        .help("The one place class content leaves the Mac: the recording, over HTTPS, to the connected channel. Progress is in the menu bar; the link is copied when it finishes. The file stays in Documents/Greenroom either way.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(crosses ? "Recordings can be uploaded to YouTube" : "Recordings stay on this Mac")
    }

    private var connector: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(crosses ? Brand.netText : Brand.text)
            HStack(spacing: 0) {
                Line()
                    .stroke(crosses ? Brand.net : Color.secondary.opacity(0.4),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: crosses ? [] : [4, 5]))
                    .frame(height: 2)
                Image(systemName: crosses ? "arrowtriangle.right.fill" : "xmark")
                    .font(.system(size: crosses ? 10 : 9, weight: .bold))
                    .foregroundStyle(crosses ? Brand.net : Color.secondary.opacity(0.6))
            }
            // Same height as the label, so the line sits level with the icons.
            Text(" ").font(.caption)
        }
        .frame(maxWidth: 220)
    }

    private var label: String {
        switch mode {
        case .off: return "Stays here"
        case .ask: return "Asks, then uploads"
        case .automatic: return "Uploads"
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.midY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            }
        }
    }
}

/// A place in the picture: a glyph in a rounded square, its name below.
private struct FlowNode: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
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
        }
    }
}

/// Do nothing, Ask, Upload, as pictures. Anything that would send the file
/// draws its glyph amber.
private struct ModePicker: View {
    @Binding var selection: YouTubeUploadMode

    var body: some View {
        HStack(spacing: 8) {
            ForEach(YouTubeUploadMode.allCases) { mode in
                let selected = mode == selection
                ChoiceTile(title: title(mode), selected: selected, badge: nil) {
                    Image(systemName: symbol(mode))
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(selected ? tint(mode) : Color.secondary)
                        .frame(height: 32)
                } action: { selection = mode }
                .frame(minWidth: mode == .off ? 120 : 80)
                .help(help(mode))
            }
        }
        .padding(.vertical, 4)
    }

    private func title(_ mode: YouTubeUploadMode) -> String {
        switch mode {
        case .off: return "Do nothing"
        case .ask: return "Ask"
        case .automatic: return "Upload"
        }
    }

    private func symbol(_ mode: YouTubeUploadMode) -> String {
        switch mode {
        case .off: return "internaldrive"
        case .ask: return "questionmark.bubble"
        case .automatic: return "arrow.up.circle"
        }
    }

    private func tint(_ mode: YouTubeUploadMode) -> Color {
        mode == .off ? Brand.green : Brand.net
    }

    private func help(_ mode: YouTubeUploadMode) -> String {
        switch mode {
        case .off: return "Recordings stay in Documents/Greenroom. Nothing is uploaded."
        case .ask: return "After each recording, one Upload / Not now card. The file stays in Documents/Greenroom either way."
        case .automatic: return "Every recording goes to the connected channel as soon as it ends. The file stays in Documents/Greenroom too."
        }
    }
}

/// Unlisted or Private, as pictures.
private struct VisibilityPicker: View {
    @Binding var selection: String

    private static let options: [(tag: String, title: String, symbol: String, help: String)] = [
        ("unlisted", "Unlisted", "link", "Anyone with the link can watch."),
        ("private", "Private", "lock.fill", "Only the channel\u{2019}s account can watch."),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.options, id: \.tag) { option in
                let selected = option.tag == selection
                ChoiceTile(title: option.title, selected: selected, badge: nil) {
                    Image(systemName: option.symbol)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(selected ? Brand.green : Color.secondary)
                        .frame(height: 32)
                } action: { selection = option.tag }
                .help(option.help)
            }
        }
        .padding(.vertical, 4)
    }
}
