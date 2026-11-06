//
//  ZoomSettingsTab.swift
//  Greenroom
//
//  Settings -> Zoom: the two Marketplace apps and how the meeting appears.
//
import SwiftUI

/// Both Zoom Marketplace apps on one page.
///
/// They were two tabs, Meeting Chat and Start Meeting, named after what each
/// credential unlocks rather than after what it is. Both are Zoom tokens, both
/// come from the same account, and the second tab's own footer had to say "on
/// the same Zoom account as Meeting Chat" - a sentence that exists only
/// because the two were apart. Setting Greenroom up means pasting six values
/// from one place, and it should be one page.
///
/// Two sections, kept separate, because they really are two different
/// Marketplace apps and pretending otherwise would be the opposite mistake:
/// Zoom's headless token grant is exclusive to the Server-to-Server type and
/// the Meeting SDK embed is exclusive to the General App type, so nobody can
/// consolidate them into one set of credentials. Vendor/README.md records the
/// attempt.
struct ZoomSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $coordinator.sdkClientID)
                SecureField("Client Secret", text: $coordinator.sdkClientSecret)
            } header: { Text("Meeting SDK app") } footer: {
                Text("Powers the built-in meeting client and the chat window. Zoom Marketplace \u{2192} General App \u{2192} Features \u{2192} Embed \u{2192} Meeting SDK. Works only in meetings hosted under this Zoom account.")
            }

            Section {
                TextField("Account ID", text: $coordinator.s2sAccountID)
                TextField("Client ID", text: $coordinator.s2sClientID)
                SecureField("Client Secret", text: $coordinator.s2sClientSecret)
            } header: { Text("Server-to-Server OAuth app") } footer: {
                Text("Powers New Meeting and the scheduled list. A second Marketplace app on the same Zoom account. Scopes: meeting:write:meeting:admin, meeting:read:list_meetings:admin, meeting:read:meeting:admin, user:read:token:admin, meeting:update:status:admin. The setup guide (?) walks through it and tests the result.")
            }

            Section {
                Toggle(isOn: $coordinator.useBuiltInClient) {
                    SettingLabel(title: "Use built-in meeting client",
                                 subtitle: "The whole meeting runs inside Greenroom. Off: the Zoom app, with a hidden chat participant.")
                }
                TextField("Your display name", text: $coordinator.userDisplayName)

                Toggle(isOn: $coordinator.customUIMode) {
                    SettingLabel(title: "Custom meeting UI (experimental)",
                                 subtitle: "Greenroom draws the speaker and the participant panel itself. Takes effect after a relaunch.")
                }
                if coordinator.customUIModeNeedsRelaunch {
                    Label("Not active yet \u{2014} quit and reopen Greenroom.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: { Text("In the meeting") } footer: {
                Text("How the meeting appears once it starts. Nothing here needs a credential.")
            }
        }
        .formStyle(.grouped)
    }
}

