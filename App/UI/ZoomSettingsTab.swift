//
//  ZoomSettingsTab.swift
//  Greenroom
//
//  Settings -> Zoom: the two Marketplace apps and how the meeting appears.
//
//  Both Zoom Marketplace apps on one page.
//
//  They were two tabs, Meeting Chat and Start Meeting, named after what each
//  credential unlocks rather than after what it is. Both are Zoom tokens, both
//  come from the same account, and the second tab's own footer had to say "on
//  the same Zoom account as Meeting Chat" - a sentence that exists only
//  because the two were apart. Setting Greenroom up means pasting six values
//  from one place, and it should be one page.
//
//  Two sections, kept separate, because they really are two different
//  Marketplace apps and pretending otherwise would be the opposite mistake:
//  Zoom's headless token grant is exclusive to the Server-to-Server type and
//  the Meeting SDK embed is exclusive to the General App type, so nobody can
//  consolidate them into one set of credentials. Vendor/README.md records the
//  attempt.
//
//  The page opens on a picture of the two apps side by side: what each one
//  powers, drawn as small glyphs, and whether its keys are all in. Where to
//  find them in the Marketplace is hover help on each card; the scope list is
//  a copyable block under the second app's fields.
//
//  `ZoomPageContent` takes plain bindings, so it can be rendered off screen
//  with sample values. `ZoomSettingsTab` feeds it from the coordinator.
//
import AppKit
import SwiftUI

// MARK: - The tab

struct ZoomSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        ZoomPageContent(
            sdkClientID: $coordinator.sdkClientID,
            sdkClientSecret: $coordinator.sdkClientSecret,
            s2sAccountID: $coordinator.s2sAccountID,
            s2sClientID: $coordinator.s2sClientID,
            s2sClientSecret: $coordinator.s2sClientSecret,
            displayName: $coordinator.userDisplayName,
            customUI: $coordinator.customUIMode,
            customUINeedsRelaunch: coordinator.customUIModeNeedsRelaunch)
    }
}

// MARK: - The page

struct ZoomPageContent: View {
    @Binding var sdkClientID: String
    @Binding var sdkClientSecret: String
    @Binding var s2sAccountID: String
    @Binding var s2sClientID: String
    @Binding var s2sClientSecret: String
    @Binding var displayName: String
    @Binding var customUI: Bool
    let customUINeedsRelaunch: Bool
    /// Starts with the scope list open; for the off-screen render only.
    var scopesOpen = false

    static let scopes = [
        "meeting:write:meeting:admin",
        "meeting:read:list_meetings:admin",
        "meeting:read:meeting:admin",
        "user:read:token:admin",
        "meeting:update:status:admin",
    ]

    private var sdkState: CredentialState {
        CredentialState([("Client ID", sdkClientID), ("Client Secret", sdkClientSecret)])
    }

    private var s2sState: CredentialState {
        CredentialState([("Account ID", s2sAccountID), ("Client ID", s2sClientID),
                         ("Client Secret", s2sClientSecret)])
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AppCard(title: "Meeting SDK", symbol: "video.fill",
                            powers: [("video", "Meeting"), ("bubble.left", "Chat")],
                            state: sdkState)
                        .help("A General App in the Zoom Marketplace \u{2192} Features \u{2192} Embed \u{2192} Meeting SDK. Powers the built-in meeting client and the chat window. Works only in meetings hosted under this Zoom account.")
                    AppCard(title: "Server-to-Server", symbol: "server.rack",
                            powers: [("plus.circle", "New meeting"), ("calendar", "Scheduled")],
                            state: s2sState)
                        .help("A Server-to-Server OAuth app on the same Zoom account. Powers New Meeting and the scheduled list. The setup guide (?) walks through it and tests the result.")
                }
                .padding(.vertical, 4)
            }

            Section("Meeting SDK") {
                TextField("Client ID", text: $sdkClientID)
                SecureField("Client Secret", text: $sdkClientSecret)
            }

            Section("Server-to-Server") {
                TextField("Account ID", text: $s2sAccountID)
                TextField("Client ID", text: $s2sClientID)
                SecureField("Client Secret", text: $s2sClientSecret)
                ScopeList(scopes: Self.scopes, open: scopesOpen)
            }

            Section("Meeting") {
                TextField("Display name", text: $displayName)
                    .help("The name the class sees for you in the meeting.")
                Toggle(isOn: $customUI) {
                    HStack(spacing: 8) {
                        Text("Custom meeting UI")
                        Text("EXPERIMENTAL")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.secondary.opacity(0.4)))
                    }
                }
                .help("On: Zoom opens no windows; Greenroom shows the meeting in its own meeting window \u{2014} video, people, chat and controls. Takes effect after a relaunch.")
                Text("On: Zoom opens no windows. Greenroom shows the meeting in its own meeting window, with Gallery and Speaker views, people, chat and the meeting controls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if customUINeedsRelaunch {
                    StatusBadge(text: "Quit and reopen Greenroom to apply", tone: .problem)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Pieces

/// Whether a set of keys is all in, none in, or part way.
private struct CredentialState {
    let missing: [String]
    let total: Int

    init(_ fields: [(name: String, value: String)]) {
        missing = fields.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.name)
        total = fields.count
    }

    var badge: StatusBadge {
        if missing.isEmpty { return StatusBadge(text: "Ready", tone: .good) }
        if missing.count == total { return StatusBadge(text: "Not set up", tone: .waiting) }
        return StatusBadge(text: "Needs \(missing.joined(separator: ", "))", tone: .problem)
    }
}

/// One Marketplace app: its glyph and name, what it powers, whether it's ready.
private struct AppCard: View {
    let title: String
    let symbol: String
    let powers: [(symbol: String, name: String)]
    let state: CredentialState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(state.missing.isEmpty ? Brand.text : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Spacer(minLength: 4)
                    state.badge
                }
                Text(powers.map(\.name).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }
}

/// The five scopes the Server-to-Server app needs: folded away, one click to
/// copy, selectable when open.
private struct ScopeList: View {
    let scopes: [String]
    @State private var open: Bool
    @State private var copied = false

    init(scopes: [String], open: Bool) {
        self.scopes = scopes
        _open = State(initialValue: open)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Text(scopes.joined(separator: "\n"))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08)))
                .padding(.top, 4)
        } label: {
            HStack {
                Text("Scopes")
                Text("\(scopes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(scopes.joined(separator: "\n"), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy all \(scopes.count) scopes, one per line")
            }
        }
        .help(scopes.joined(separator: "\n"))
    }
}
