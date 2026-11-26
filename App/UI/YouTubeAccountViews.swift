//
//  YouTubeAccountViews.swift
//  Greenroom
//
//  The YouTube account pieces Settings -> YouTube and the setup guide's
//  YouTube step share, so both say the same thing the same way:
//
//  - `YouTubeAppChoiceRow`: "Greenroom's Google app | Your own Google app",
//    one segmented control bound to the stored choice, and the chosen
//    option's one grey line.
//  - `YouTubeAccountLine`: the chosen option's account (channel picture and
//    name, or a status), and its Sign in / Use another account / Sign out.
//
//  Words and states come from `YouTubeAccountRules`. Plain values and
//  closures only, so both render off screen (scripts/render/youtube.sh,
//  youtube-guide.sh).
//
import SwiftUI

/// The choice: which Google app signing in and uploading use.
struct YouTubeAppChoiceRow: View {
    /// The stored choice (`youtubeUsesOwnApp`); a pick animates the sections' fold.
    @Binding var usesOwnApp: Bool

    private var option: Binding<YouTubeAppOption> {
        Binding(get: { YouTubeAppOption(prefersOwnApp: usesOwnApp) },
                set: { picked in Collapse.animate { usesOwnApp = picked.prefersOwnApp } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GreenroomSegmented("How Greenroom connects to YouTube", selection: option,
                               options: YouTubeAppOption.allCases) { option in
                Text(option.title)
            }
            .segmentHelp { $0.note }
            Text(option.wrappedValue.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The chosen option's account: who is signed in (or a status) and its buttons.
struct YouTubeAccountLine: View {
    let choice: YouTubeAccountChoice
    var avatarURL: String? = nil
    var uploading = false
    /// A failed sign-in's or a missing channel's words, under the line.
    var problem: String? = nil
    var signIn: () -> Void = {}
    var signOut: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if choice.signedInHere {
                    YouTubeChannelAvatar(url: avatarURL, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.account).font(.body.weight(.medium))
                        Text(choice.selected == .greenroom ? "Through Greenroom\u{2019}s Google app"
                                                           : "Through your own Google app")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    StatusBadge(text: choice.account, tone: StatusBadge.Tone(choice.accountTone))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if uploading { ProgressView().controlSize(.small) }
                buttons
            }
            if let note = problem ?? choice.hint {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var buttons: some View {
        ForEach(choice.buttons, id: \.self) { button in
            switch button {
            case .signIn:
                if choice.waiting {
                    ProgressView().controlSize(.small)
                }
                Button(action: signIn) {
                    Label("Sign in with Google", systemImage: "person.crop.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.buttonFill)
                .disabled(!choice.signInEnabled)
                .help("Opens Google in your browser to choose an account. Greenroom can upload and edit your own videos, nothing else.")
            case .useAnotherAccount:
                Button("Use another account", action: signIn)
                    .disabled(!choice.signInEnabled)
                    .help("Google shows its account chooser. The current sign-in is removed once the new one is in.")
            case .signOut:
                Button("Sign out", action: signOut)
                    .help("Signs out here and tells Google to remove Greenroom\u{2019}s access.")
            }
        }
    }
}

/// A `YouTubeStatusTone` as the shared badge's tone.
extension StatusBadge.Tone {
    init(_ tone: YouTubeStatusTone) {
        switch tone {
        case .good: self = .good
        case .waiting: self = .waiting
        case .problem: self = .problem
        }
    }
}
