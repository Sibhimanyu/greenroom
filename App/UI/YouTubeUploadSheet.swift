//
//  YouTubeUploadSheet.swift
//  Greenroom
//
//  The upload sheet, over the main window: the one screen where a recording
//  is sent to YouTube from Greenroom. Title and description start from the
//  session; visibility starts at Settings' choice (Unlisted unless changed);
//  the Made for Kids answer is required (YouTube API Services Terms §9.1(4));
//  and the §9.1(1) line sits right above the Upload button, linked to
//  YouTube's Terms.
//
//  "Upload in YouTube Studio" is always there, signed in or not: it opens
//  YouTube's upload page, shows the file in Finder and copies the title and
//  description (YouTubeStudioHandoff).
//
//  `YouTubeUploadSheetContent` takes plain values so it renders off screen
//  (scripts/render/youtube.sh); `YouTubeUploadSheet` feeds it from the
//  coordinator.
//
import AppKit
import SwiftUI

// MARK: - The sheet

struct YouTubeUploadSheet: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    let draft: YouTubeUploadDraft

    var body: some View {
        YouTubeUploadSheetContent(
            draft: draft,
            privacy: coordinator.youtubePrivacy,
            madeForKids: coordinator.youtubeMadeForKids,
            signedIn: coordinator.youtubeConnected,
            channel: coordinator.youtubeChannel,
            signingIn: coordinator.youtubeSigningIn,
            route: coordinator.youtubeSignInRoute,
            uploading: coordinator.isUploadingToYouTube,
            signIn: { Task { await coordinator.signInToYouTube() } },
            upload: { details in coordinator.startYouTubeUpload(draft.file, details: details) },
            openStudio: { title, description in
                coordinator.uploadInYouTubeStudio(draft.file, title: title, description: description)
            },
            cancel: { coordinator.youtubeUploadDraft = nil })
    }
}

// MARK: - The content

struct YouTubeUploadSheetContent: View {
    let signedIn: Bool
    let channel: YouTubeChannel?
    let signingIn: Bool
    let route: YouTubeRoute
    let uploading: Bool
    let signIn: () -> Void
    let upload: (YouTubeUploadDetails) -> Void
    let openStudio: (_ title: String, _ description: String) -> Void
    let cancel: () -> Void

    @State private var title: String
    @State private var description: String
    @State private var privacy: String
    @State private var madeForKids: Bool?

    init(draft: YouTubeUploadDraft, privacy: String, madeForKids: Bool?, signedIn: Bool,
         channel: YouTubeChannel?, signingIn: Bool, route: YouTubeRoute, uploading: Bool,
         signIn: @escaping () -> Void, upload: @escaping (YouTubeUploadDetails) -> Void,
         openStudio: @escaping (String, String) -> Void, cancel: @escaping () -> Void) {
        self.signedIn = signedIn
        self.channel = channel
        self.signingIn = signingIn
        self.route = route
        self.uploading = uploading
        self.signIn = signIn
        self.upload = upload
        self.openStudio = openStudio
        self.cancel = cancel
        _title = State(initialValue: draft.title)
        _description = State(initialValue: draft.description)
        _privacy = State(initialValue: privacy == "private" ? "private" : YouTubeUploadRules.defaultPrivacy)
        _madeForKids = State(initialValue: madeForKids)
    }

    private var canUpload: Bool {
        !uploading && YouTubeUploadRules.canUpload(title: title, madeForKids: madeForKids, signedIn: signedIn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            account
            Divider()
            fields
            Divider()
            certify
            buttons
        }
        .padding(24)
        .frame(width: 540)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Brand.net)
            Text("Upload to YouTube")
                .font(.title3.weight(.semibold))
            Spacer()
            Text("Leaves this Mac")
                .font(.caption)
                .foregroundStyle(Brand.netText)
        }
    }

    // MARK: Account

    @ViewBuilder
    private var account: some View {
        if signedIn {
            HStack(spacing: 10) {
                YouTubeChannelAvatar(url: channel?.avatarURL, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(channel?.name ?? "Your YouTube channel").font(.callout.weight(.medium))
                    Text("Uploads go to this channel").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(route.app == nil
                         ? "Uploading from Greenroom isn\u{2019}t set up."
                         : "Sign in with Google to upload from Greenroom.")
                        .font(.callout)
                    Spacer()
                    if route.app != nil {
                        Button(signingIn ? "Waiting for Google\u{2026}" : "Sign in with Google", action: signIn)
                            .disabled(signingIn)
                    }
                }
                Text(accountNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountNote: String {
        switch route {
        case .none(let gap): return gap.message
        case .shared: return YouTubeSettingsWords.unverifiedNote
        case .own: return "Signs in through your own Google app."
        }
    }

    // MARK: Fields

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
            GridRow {
                Text("Title").gridColumnAlignment(.trailing)
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            GridRow {
                Text("Description")
                TextEditor(text: $description)
                    .font(.body)
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }
            GridRow {
                Text("Visibility")
                GreenroomSegmented("Visibility", selection: $privacy, options: ["unlisted", "private"]) { option in
                    Text(option == "private" ? "Private" : "Unlisted")
                }
                .segmentHelp { $0 == "private" ? "Only the channel\u{2019}s account can watch." : "Anyone with the link can watch." }
            }
            GridRow {
                Text("Made for kids")
                VStack(alignment: .leading, spacing: 6) {
                    MadeForKidsChoice(selection: $madeForKids)
                    Link("What counts as made for kids?", destination: YouTubeUploadRules.madeForKidsHelpURL)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: Terms and buttons

    private var certify: some View {
        Text(YouTubeSettingsWords.certifyAttributed)
            .font(.caption)
            .foregroundStyle(.secondary)
            .tint(Brand.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Upload in YouTube Studio") { openStudio(title, description) }
                .help("No sign-in needed: opens YouTube\u{2019}s upload page, shows the recording in Finder to drag in, and copies the title and description.")
            Spacer()
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button("Upload") {
                guard let madeForKids else { return }
                upload(YouTubeUploadDetails(title: title, description: description,
                                            privacy: privacy, madeForKids: madeForKids))
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.net)
            .keyboardShortcut(.defaultAction)
            .disabled(!canUpload)
            .help(madeForKids == nil ? "Answer Made for kids first." : "Sends the recording to YouTube. The file stays on this Mac too.")
        }
    }
}

// MARK: - Shared pieces (the sheet and Settings → YouTube)

/// Made for kids: No / Yes, nothing chosen until the person answers.
struct MadeForKidsChoice: View {
    @Binding var selection: Bool?

    var body: some View {
        GreenroomSegmented("Made for kids", selection: $selection, options: [false, true]) { option in
            Text(option == true ? "Yes, it\u{2019}s made for kids" : "No, it\u{2019}s not made for kids")
        }
    }
}

/// The channel's picture, or a neutral glyph while it loads or when there is none.
struct YouTubeChannelAvatar: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let url, let link = URL(string: url) {
                AsyncImage(url: link) { image in
                    image.resizable().scaledToFill()
                } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .foregroundStyle(.secondary)
    }
}

/// Words the sheet and Settings share.
enum YouTubeSettingsWords {
    /// Shown wherever Sign in with Google is offered through the shared app.
    static let unverifiedNote = "Google may show \u{201C}Google hasn\u{2019}t verified this app\u{201D}. Click Advanced, then Go to Greenroom."

    /// The §9.1 line with its address as a link, and the guidelines linked too.
    static var certifyAttributed: AttributedString {
        var text = AttributedString(YouTubeUploadRules.certifyLine)
        if let range = text.range(of: YouTubeUploadRules.termsURL.absoluteString) {
            text[range].link = YouTubeUploadRules.termsURL
        }
        if let range = text.range(of: "YouTube Terms of Service") {
            text[range].link = YouTubeUploadRules.termsURL
        }
        if let range = text.range(of: "YouTube Community Guidelines") {
            text[range].link = YouTubeUploadRules.guidelinesURL
        }
        return text
    }
}
