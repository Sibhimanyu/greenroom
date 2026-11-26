//
//  YouTubeSettingsTab.swift
//  Greenroom
//
//  Settings -> YouTube: uploading recordings, and the YouTube account.
//
//  The account is one choice of two (owner, 2026-11-26), like Settings ->
//  Zoom: "Greenroom's Google app | Your own Google app", one segmented
//  control bound to `youtubeUsesOwnApp`. The pick IS what signing in and
//  uploading use, and only its section shows; the other folds away. Your own
//  app's section is a summary (setup status, the account, one "Set up… /
//  Edit setup…" button into the setup guide); the Client ID, Secret and the
//  Google Cloud steps live only in the guide's YouTube step. The words come
//  from `YouTubeAccountRules`; the choice row and the account line are shared
//  with the guide (YouTubeAccountViews.swift).
//
//  The one feature that sends meeting content off the Mac, so the page opens on
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
            account: coordinator.youtubeAccountFacts,
            channel: coordinator.youtubeChannel,
            uploading: coordinator.isUploadingToYouTube,
            status: coordinator.youtubeStatus,
            signIn: { await coordinator.signInToYouTube() },
            signOut: { await coordinator.signOutOfYouTube() },
            openSetup: { coordinator.openYouTubeSetupGuide(at: $0) })
            .onAppear { coordinator.loadSecretsIfNeeded() }
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
    /// The choice: true = your own Google app, false = Greenroom's. It is what signing in and uploading use.
    @Binding var usesOwnApp: Bool
    /// The sign-in, the stored token's app and the own app's fields, for `YouTubeAccountRules`.
    let account: YouTubeAccountFacts
    let channel: YouTubeChannel?
    let uploading: Bool
    /// The coordinator's last word on the account, or empty.
    let status: String
    let signIn: () async -> Void
    let signOut: () async -> Void
    /// Opens the setup guide's YouTube step at a spot (your own app's part).
    var openSetup: (YouTubeGuideSpot) -> Void = { _ in }

    /// What an option's section says. Each section reads its own option, so the
    /// one folding away keeps its words while it goes.
    private func choice(_ option: YouTubeAppOption) -> YouTubeAccountChoice {
        var f = account
        f.route.prefersOwnApp = option.prefersOwnApp
        return YouTubeAccountRules.choice(f)
    }

    private var current: YouTubeAccountChoice { choice(YouTubeAppOption(prefersOwnApp: usesOwnApp)) }

    /// A failed sign-in, or a signed-in account with no channel: in the chosen section.
    private var problem: String? {
        if !account.signedIn && !account.signingIn && status.hasPrefix("Not connected:") {
            return String(status.dropFirst("Not connected: ".count))
        }
        if account.signedIn && channel == nil && !status.isEmpty { return status }
        return nil
    }

    var body: some View {
        Form {
            #if DEBUG
            Section("Upload to") { SharedChannelRow(ownChannelConnected: current.readyToUpload) }
            #endif

            Section("Recordings") {
                UploadFlowPicture(mode: uploadMode, connected: current.readyToUpload, uploading: uploading)
                uploadChoices
                // Do nothing: no upload, so no visibility or audience to choose.
                Collapsible(hidden: uploadMode == .off) { uploadDefaults }
            }

            Section {
                YouTubeAppChoiceRow(usesOwnApp: $usesOwnApp)
                Collapsible(hidden: usesOwnApp) { greenroomSection }
                Collapsible(hidden: !usesOwnApp) { ownSection }
            } header: {
                Text("How Greenroom connects to YouTube")
            } footer: {
                Text("Upload in YouTube Studio needs no sign-in: it is on every upload sheet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Account

    /// Greenroom's Google app: the account line and its buttons.
    private var greenroomSection: some View {
        accountLine(choice(.greenroom))
            .padding(.vertical, 4)
    }

    /// Your own Google app: its setup status, the account line, and one button
    /// into the setup guide, where the Client ID, Secret and Google Cloud steps live.
    private var ownSection: some View {
        let c = choice(.own)
        return VStack(alignment: .leading, spacing: 10) {
            if let status = c.setupStatus, let tone = c.setupTone {
                HStack(spacing: 12) {
                    StatusBadge(text: status, tone: StatusBadge.Tone(tone))
                    Spacer(minLength: 8)
                    if let entry = c.setupEntry {
                        Button(entry.title) { openSetup(entry.spot) }
                            .help("Opens the setup guide\u{2019}s YouTube step, where the Client ID, Client Secret and the Google Cloud steps live.")
                    }
                }
            }
            Divider()
            accountLine(c)
        }
        .padding(.vertical, 4)
    }

    private func accountLine(_ c: YouTubeAccountChoice) -> some View {
        YouTubeAccountLine(choice: c, avatarURL: channel?.avatarURL, uploading: uploading,
                           problem: c.selected == current.selected ? problem : nil,
                           signIn: { Task { await signIn() } },
                           signOut: { Task { await signOut() } })
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
                        Label("Automatic uploads need this answer.", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
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
