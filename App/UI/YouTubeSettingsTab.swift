//
//  YouTubeSettingsTab.swift
//  Greenroom
//
//  Settings -> YouTube: uploading recordings.
//
import SwiftUI

/// Uploading recordings to YouTube - the one feature that sends class
/// content off the Mac, so it opens on "Do nothing" and every line of copy
/// says where the file goes.
struct YouTubeSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var connecting = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $coordinator.youtubeUploadMode) {
                    ForEach(YouTubeUploadMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    SettingLabel(title: "After a recording",
                                 subtitle: "\u{201C}Ask\u{201D} shows one Upload / Not now card. The file stays in Documents/Greenroom either way.")
                }
                Picker(selection: $coordinator.youtubePrivacy) {
                    Text("Unlisted").tag("unlisted")
                    Text("Private").tag("private")
                } label: {
                    SettingLabel(title: "Visibility",
                                 subtitle: coordinator.youtubePrivacy == "private" ? "Only the channel\u{2019}s account can watch." : "Anyone with the link can watch.")
                }
            } header: { Text("Upload") } footer: {
                Text("The one place class content leaves the Mac: the recording, over HTTPS, to the connected channel. Progress is in the menu bar; the link is copied when it finishes.")
            }

            Section {
                TextField("Client ID", text: $coordinator.youtubeClientID)
                SecureField("Client Secret", text: $coordinator.youtubeClientSecret)
                LabeledContent {
                    HStack(spacing: 12) {
                        if coordinator.youtubeConnected {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(Brand.green)
                            Button("Disconnect") { Task { await coordinator.disconnectYouTube() } }
                        } else {
                            Button(connecting ? "Waiting for Google\u{2026}" : "Connect\u{2026}") {
                                connecting = true
                                Task {
                                    await coordinator.connectYouTube()
                                    connecting = false
                                }
                            }
                            .disabled(connecting || coordinator.youtubeClientID.isEmpty || coordinator.youtubeClientSecret.isEmpty)
                        }
                        if coordinator.isUploadingToYouTube {
                            ProgressView().controlSize(.small)
                        }
                    }
                } label: {
                    SettingLabel(title: "Google account",
                                 subtitle: coordinator.youtubeStatus.isEmpty
                                     ? "Signs in once in your browser. Greenroom can upload and edit your own videos, nothing else."
                                     : coordinator.youtubeStatus)
                }
            } header: { Text("Account") } footer: {
                Text("From a Google Cloud OAuth client of type \u{201C}Desktop app\u{201D} with the YouTube Data API v3 enabled. The setup guide (? on the main window) has the clicks; while the Google project is in Testing, the sign-in lasts seven days.")
            }
        }
        .formStyle(.grouped)
    }
}

