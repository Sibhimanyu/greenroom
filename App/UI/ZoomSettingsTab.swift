//
//  ZoomSettingsTab.swift
//  Greenroom
//
//  Settings -> Zoom: Sign in with Zoom, the two Marketplace apps (advanced,
//  folded away) and how the meeting appears.
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
            hideSelfView: $coordinator.hideSelfView,
            signIn: ZoomSignInSection.live(coordinator),
            route: ZoomRouteRow.live(coordinator),
            showGuide: { coordinator.presentOnboarding() })
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
    @Binding var hideSelfView: Bool
    let signIn: ZoomSignInSection
    /// "Start uses: ...": which of the two ways Start takes right now.
    let route: ZoomRouteRow
    /// Opens the setup guide. Nil in the off-screen render, which hides the button.
    var showGuide: (() -> Void)? = nil
    /// Starts with "Use your own Zoom apps" open; for the off-screen render only.
    var ownAppsOpen = false
    /// Starts with the scope list open; for the off-screen render only.
    var scopesOpen = false

    // "During the meeting" (moved from the Layout tab; keys unchanged).
    @AppStorage(SessionNotes.enabledKey) private var notesOnStart = false
    @AppStorage(CoordinatorController.copyInviteOnStartKey) private var copyInviteOnStart = true

    static let scopes = ZoomScopes.names

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
                route
            }

            Section {
                signIn
            } header: {
                Text("Zoom account")
                    .help("Signs in with your own Zoom account. Greenroom starts, lists and ends meetings as you.")
            }

            Section {
                AdvancedDisclosure("Use your own Zoom apps (advanced)", open: ownAppsOpen) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Meeting SDK").font(.headline)
                                Spacer()
                                sdkState.badge
                            }
                            .help("A General App in the Zoom Marketplace \u{2192} Features \u{2192} Embed \u{2192} Meeting SDK. Powers the built-in meeting client and the chat window. Works only in meetings hosted under this Zoom account.")
                            TextField("Client ID", text: $sdkClientID)
                            SecureField("Client Secret", text: $sdkClientSecret)
                            MarketplaceGuideBlock(steps: ZoomMarketplaceGuide.sdkSteps, showGuide: showGuide)
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Server-to-Server").font(.headline)
                                Spacer()
                                s2sState.badge
                            }
                            .help("A Server-to-Server OAuth app on the same Zoom account. Powers New Meeting and the scheduled list. The setup guide (?) walks through it and tests the result. Used when Start uses your own Zoom apps (see the line at the top).")
                            TextField("Account ID", text: $s2sAccountID)
                            TextField("Client ID", text: $s2sClientID)
                            SecureField("Client Secret", text: $s2sClientSecret)
                            ScopeList(scopes: Self.scopes, open: scopesOpen)
                            MarketplaceGuideBlock(steps: ZoomMarketplaceGuide.s2sSteps, showGuide: showGuide)
                        }
                    }
                }
            }

            Section("Meeting") {
                TextField("Display name", text: $displayName)
                    .help("The name everyone sees for you in the meeting.")
            }

            Section("During the meeting") {
                Toggle("Copy the invite link when a meeting starts", isOn: $copyInviteOnStart)
                    .help("The link goes on the clipboard as the meeting goes live, ready to paste into a message.")
                Toggle("Open notes when a session starts", isOn: $notesOnStart)
                    .help("Notes are timed to the recording and saved with the session. You can still open or close them during a session.")
                Toggle("Hide my own tile", isOn: $hideSelfView)
                    .help("Your own video is left out of the meeting you see. Everyone still sees you.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Pieces

/// The page's first line: the route Start will use (`ZoomRouteRules`), and,
/// when both ways are set up, which one wins with a one-click switch.
struct ZoomRouteRow: View {
    let route: ZoomRoute
    let bothSetUp: Bool
    let onSwitch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                StatusBadge(text: ZoomRouteWords.line(route), tone: route.isUsable ? .good : .waiting)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if bothSetUp, let title = ZoomRouteWords.switchTitle(route) {
                    Button(title, action: onSwitch)
                        .help("Start takes the meeting and the video from the same place. This switches both.")
                }
            }
            if bothSetUp, let note = ZoomRouteWords.bothNote(route) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension ZoomRouteRow {
    @MainActor
    static func live(_ coordinator: CoordinatorController) -> ZoomRouteRow {
        ZoomRouteRow(route: coordinator.zoomRoute, bothSetUp: coordinator.zoomRoutesBothSetUp,
                     onSwitch: { coordinator.zoomPrefersOwnApps.toggle() })
    }
}

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

/// The "where do I get these" help under a block: the Marketplace link,
/// numbered steps, and a button that opens the setup guide.
private struct MarketplaceGuideBlock: View {
    let steps: [String]
    let showGuide: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Link(destination: ZoomMarketplaceGuide.builderURL) {
                Label(ZoomMarketplaceGuide.linkTitle, systemImage: "arrow.up.right")
            }
            .foregroundStyle(Brand.green)
            .help(ZoomMarketplaceGuide.builderURL.absoluteString)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").monospacedDigit()
                        Text(step)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let showGuide {
                Button(ZoomMarketplaceGuide.guideButtonTitle, action: showGuide)
                    .buttonStyle(.link)
                    .foregroundStyle(Brand.green)
                    .font(.caption)
            }
        }
        .padding(.top, 4)
    }
}

/// The scopes the Server-to-Server app needs: folded away, one click to
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
                    Label(copied ? "Copied" : "Copy scopes", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Brand.text)
                .help("Copy all \(scopes.count) scopes, one per line")
            }
        }
        .help(scopes.joined(separator: "\n"))
    }
}
