//
//  YouTubeSettingsTab.swift
//  Greenroom
//
//  Settings -> YouTube: uploading recordings, and the YouTube account.
//
//  The account is Sign in with Google, through Greenroom's shared Google app;
//  the paste-your-own-client way is folded under "Use your own Google app"
//  (YouTubeRouteRules decides which one signs in).
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
            madeForKids: $coordinator.youtubeMadeForKids,
            usesOwnApp: $coordinator.youtubeUsesOwnApp,
            clientID: $coordinator.youtubeClientID,
            clientSecret: $coordinator.youtubeClientSecret,
            connected: coordinator.youtubeConnected,
            channel: coordinator.youtubeChannel,
            tokenApp: YouTubeAuth.tokenApp,
            route: coordinator.youtubeSignInRoute,
            signingIn: coordinator.youtubeSigningIn,
            uploading: coordinator.isUploadingToYouTube,
            status: coordinator.youtubeStatus,
            signIn: { await coordinator.signInToYouTube() },
            signOut: { await coordinator.signOutOfYouTube() })
            .task {
                // A sign-in from before the channel line existed: read it once.
                if coordinator.youtubeConnected, coordinator.youtubeChannel == nil {
                    await coordinator.refreshYouTubeChannel()
                }
            }
    }
}

// MARK: - The page

struct YouTubePageContent: View {
    @Binding var uploadMode: YouTubeUploadMode
    @Binding var privacy: String
    @Binding var madeForKids: Bool?
    @Binding var usesOwnApp: Bool
    @Binding var clientID: String
    @Binding var clientSecret: String
    let connected: Bool
    let channel: YouTubeChannel?
    /// Which Google app the current sign-in came through.
    let tokenApp: YouTubeGoogleApp
    /// What Sign in with Google would use now.
    let route: YouTubeRoute
    let signingIn: Bool
    let uploading: Bool
    /// The coordinator's last word on the account, or empty.
    let status: String
    let signIn: () async -> Void
    let signOut: () async -> Void

    private var failed: Bool { !connected && !signingIn && status.hasPrefix("Not connected:") }

    var body: some View {
        Form {
            #if DEBUG
            Section("Upload to") { SharedChannelRow(ownChannelConnected: connected) }
            #endif

            Section("Recordings") {
                UploadFlowPicture(mode: uploadMode, connected: connected, uploading: uploading)
                uploadChoices
                // Do nothing: no upload, so no visibility or audience to choose.
                Collapsible(hidden: uploadMode == .off) { uploadDefaults }
            }

            Section {
                accountRow
                if failed || (connected && channel == nil && !status.isEmpty) {
                    Text(failed ? String(status.dropFirst("Not connected: ".count)) : status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ownApp
            } header: {
                Text("YouTube account")
            } footer: {
                Text("No sign-in needed for Upload in YouTube Studio: every upload sheet has it. It opens YouTube, shows the recording in Finder and copies the title and description.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// Visibility beside the Made for Kids answer (DESIGN.md: upload behaviour
    /// beside visibility), then, for automatic uploads, the Terms line: the
    /// person never sees an Upload button, so choosing Upload here is the click.
    private var uploadDefaults: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Visibility").font(.callout)
                    VisibilityPicker(selection: $privacy)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Made for kids").font(.callout)
                    MadeForKidsChoice(selection: $madeForKids)
                    if uploadMode == .automatic && madeForKids == nil {
                        Text("Automatic uploads need this answer.")
                            .font(.caption)
                            .foregroundStyle(Brand.netText)
                    } else {
                        Link("What counts as made for kids?", destination: YouTubeUploadRules.madeForKidsHelpURL)
                            .font(.caption)
                    }
                }
            }
            Collapsible(hidden: uploadMode != .automatic) {
                Text(YouTubeSettingsWords.certifyAttributed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .tint(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Account

    private var accountRow: some View {
        HStack(spacing: 12) {
            if connected {
                YouTubeChannelAvatar(url: channel?.avatarURL, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel?.name ?? "Signed in").font(.body.weight(.medium))
                    Text(tokenApp == .shared ? "Signed in with Google" : "Signed in through your own Google app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if uploading { ProgressView().controlSize(.small) }
                Button("Use another account") { Task { await signIn() } }
                    .disabled(signingIn || route.app == nil)
                    .help("Google shows its account chooser. The current sign-in is removed once the new one is in.")
                Button("Sign out") { Task { await signOut() } }
                    .help("Signs out here and tells Google to remove Greenroom\u{2019}s access.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    accountBadge
                    Text(signInNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(signingIn ? "Waiting for Google\u{2026}" : "Sign in with Google") {
                    Task { await signIn() }
                }
                .disabled(signingIn || route.app == nil)
                .help("Opens Google in your browser to choose an account. Greenroom can upload and edit your own videos, nothing else.")
            }
        }
    }

    private var signInNote: String {
        switch route {
        case .none(let gap): return gap.message
        case .shared: return YouTubeSettingsWords.unverifiedNote
        case .own: return "Signs in through your own Google app."
        }
    }

    @ViewBuilder
    private var accountBadge: some View {
        if signingIn {
            StatusBadge(text: "Waiting for Google", tone: .waiting)
        } else if failed {
            StatusBadge(text: "Couldn\u{2019}t sign in", tone: .problem)
        } else if route.app == nil {
            StatusBadge(text: "Not available yet", tone: .waiting)
        } else {
            StatusBadge(text: "Not signed in", tone: .waiting)
        }
    }

    // MARK: Your own Google app

    private var ownApp: some View {
        AdvancedDisclosure("Use your own Google app", open: usesOwnApp) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Sign in through my own Google app", isOn: $usesOwnApp.animatedCollapse())
                Text("For when Greenroom\u{2019}s Google app has reached Google\u{2019}s limit of 100 people, or to have your own daily upload limit. You need a Google Cloud OAuth client of type Desktop app with YouTube Data API v3 turned on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Collapsible(hidden: !usesOwnApp) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Client ID", text: $clientID)
                            .help(Self.clientHelp)
                        SecureField("Client Secret", text: $clientSecret)
                            .help(Self.clientHelp)
                        Link("Open Google Cloud", destination: URL(string: "https://console.cloud.google.com/apis/credentials")!)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private static let clientHelp = "From a Google Cloud OAuth client of type \u{201C}Desktop app\u{201D} with the YouTube Data API v3 enabled. While the Google project is in Testing, the sign-in lasts seven days."
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
        .help("The one place meeting content leaves the Mac: the recording, over HTTPS, to the connected channel. Progress is in the menu bar; the link is copied when it finishes. The file stays in Documents/Greenroom either way.")
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
        case .off: return "hand.raised"
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
                        .foregroundStyle(selected ? Brand.text : Color.secondary)
                        .frame(height: 32)
                } action: { selection = option.tag }
                .help(option.help)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shared channel (through Thriveni)

private struct SharedChannelRow: View {
    @ObservedObject private var account = AccountStore.shared
    /// The Google sign-in below. Only used to say where uploads go.
    let ownChannelConnected: Bool

    var body: some View {
        // One status, one action: where uploads go right now. The Thriveni
        // sign-in wins when present; otherwise the channel connected below;
        // otherwise nothing, and the one action is to sign in.
        if account.has(.youtubeUpload) {
            StatusBadge(text: "Zoho Schools channel (through your Thriveni account)", tone: .good)
        } else if ownChannelConnected {
            StatusBadge(text: "Your own YouTube channel", tone: .good)
        } else {
            HStack {
                StatusBadge(text: "Not set up", tone: .waiting)
                Spacer()
                Button("Open Account") {
                    NotificationCenter.default.post(name: .showSettingsTab, object: "account")
                }
                .foregroundStyle(Brand.text)
                .help("Sign in with a Thriveni account that has YouTube access to upload to the Zoho Schools channel, or connect your own channel below.")
            }
        }
    }
}
