//
//  ZoomSettingsTab.swift
//  Greenroom
//
//  Settings -> Zoom: how Greenroom connects to Zoom, as one choice of two,
//  then how the meeting appears.
//
//  The choice (owner, 2026-11-26: "it should be visible by what we use"):
//  "Your own Zoom apps" or "Sign in with Zoom", one segmented control at the
//  top, bound to `zoomPrefersSignIn`. What is chosen IS what Start uses, and
//  only the chosen way's section shows; the other folds away. The words
//  (status line, check, button, what Start does) come from
//  `ZoomRouteChoiceRules`; Home, the menu bar and the log say the same thing
//  through `ZoomRouteWords`.
//
//  Your own Zoom apps are two Marketplace apps, kept as two blocks because
//  they really are two: Zoom's headless token grant is exclusive to the
//  Server-to-Server type and the Meeting SDK embed to the General App type,
//  so nobody can consolidate them (Vendor/README.md records the attempt).
//
//  `ZoomPageContent` takes plain values and bindings, so it can be rendered
//  off screen with sample values. `ZoomSettingsTab` feeds it from the coordinator.
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
            prefersSignIn: $coordinator.zoomPrefersSignIn,
            choice: coordinator.zoomRouteChoice,
            signIn: ZoomSignInSection.live(coordinator, compact: true),
            setupCheck: ZoomSetupCheckRow(checker: coordinator.zoomSetupChecker,
                                          disabled: coordinator.phase.isInMeeting,
                                          ids: coordinator.zoomCheckIDs,
                                          onRun: { coordinator.checkZoomSetup() },
                                          onAction: { coordinator.performZoomCheckAction($0, kind: .ownApps) }),
            missingScopes: ZoomCheckSummary.missingScopes(coordinator.zoomSetupChecker.lines),
            refusedNote: coordinator.zoomRouteNote,
            onSignIn: { coordinator.signInWithZoom() },
            onCancelSignIn: { coordinator.cancelZoomSignIn() },
            showGuide: { coordinator.presentOnboarding() },
            debugRows: debugRows)
            .onAppear { coordinator.loadSecretsIfNeeded() }
            .onChange(of: coordinator.zoomSetupCredentials) { _, _ in coordinator.zoomSetupChecker.credentialsChanged() }
    }

    /// DEBUG builds only: the owner turns Sign in with Zoom back on for testing. Never ships.
    private var debugRows: AnyView? {
        #if DEBUG
        return AnyView(Toggle("Sign in with Zoom on for testing (Debug)", isOn: Binding(
            get: { coordinator.zoomSignInOnForTesting },
            set: { coordinator.zoomSignInOnForTesting = $0 }))
            .help("Debug builds only. Lifts Coming soon so the sign-in can be chosen and tested. A Release build ignores it."))
        #else
        return nil
        #endif
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
    /// The choice: true = Sign in with Zoom, false = your own Zoom apps. It is what Start uses.
    @Binding var prefersSignIn: Bool
    /// What the chosen way's section says (`ZoomRouteChoiceRules`).
    let choice: ZoomRouteChoice
    /// The sign-in's own controls (compact): Check sign-in, Sign out, errors.
    let signIn: ZoomSignInSection
    /// "Check Zoom setup" for your own Zoom apps. Nil hides it.
    var setupCheck: ZoomSetupCheckRow? = nil
    /// The scopes the last Check Zoom setup found missing; the scope list marks them.
    var missingScopes: [String] = []
    /// Zoom refused this account before (error 63): why, and what to do.
    var refusedNote: String? = nil
    var onSignIn: () -> Void = {}
    var onCancelSignIn: () -> Void = {}
    /// Opens the setup guide. Nil in the off-screen render, which hides the button.
    var showGuide: (() -> Void)? = nil
    /// Starts with the scope list open; for the off-screen render only.
    var scopesOpen = false
    /// A DEBUG build's extra rows (the sign-in override); nil in Release and in renders.
    var debugRows: AnyView? = nil

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

    /// The segmented control's value: what the rules say is shown (always your
    /// own Zoom apps while the sign-in is coming soon, whatever was saved). A
    /// pick animates the sections' fold; an option that can't be picked is ignored.
    private var option: Binding<ZoomRouteOption> {
        Binding(get: { choice.selected },
                set: { picked in
                    guard choice.isSelectable(picked) else { return }
                    Collapse.animate { prefersSignIn = (picked == .signIn) }
                })
    }

    private var showsSignIn: Bool { choice.selected == .signIn }

    var body: some View {
        Form {
            Section {
                ZoomRouteChoiceRow(option: option, choice: choice)
                Collapsible(hidden: showsSignIn) { ownAppsSection }
                Collapsible(hidden: !showsSignIn) { signInSection }
            } header: {
                Text("How Greenroom connects to Zoom")
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

            if let debugRows {
                Section("Debug") { debugRows }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Your own Zoom apps: one status line and the check first, then both apps' keys and guides.
    private var ownAppsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ZoomRouteStatusLine(choice: choice)
                if choice.check == .setup, let setupCheck { setupCheck }
                ZoomRouteStartNote(choice: choice)
            }
            Divider()
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
                .help("A Server-to-Server OAuth app on the same Zoom account. Powers New Meeting and the scheduled list. The setup guide (?) walks through it and tests the result.")
                TextField("Account ID", text: $s2sAccountID)
                TextField("Client ID", text: $s2sClientID)
                SecureField("Client Secret", text: $s2sClientSecret)
                ScopeList(scopes: Self.scopes, missing: missingScopes, open: scopesOpen)
                MarketplaceGuideBlock(steps: ZoomMarketplaceGuide.s2sSteps, showGuide: showGuide)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// Sign in with Zoom: who is signed in (or Sign in), the check and Sign out.
    private var signInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ZoomRouteStatusLine(choice: choice)
                Spacer(minLength: 8)
                switch choice.action {
                case .signIn:
                    Button(action: onSignIn) {
                        Label("Sign in with Zoom", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.buttonFill)
                case .cancelSignIn:
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: onCancelSignIn)
                case nil:
                    EmptyView()
                }
            }
            signIn
            if let refusedNote {
                StatusBadge(text: refusedNote, tone: .problem)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ZoomRouteStartNote(choice: choice)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

// MARK: - Pieces

/// The choice at the top: the two ways as one segmented control, and the
/// chosen one's line on who it is for. Its tooltip and accessibility value are
/// the "Start uses: ..." sentence, the same words Home and the log use. While
/// Sign in with Zoom is coming soon its segment is dimmed with a small
/// "Coming soon" label, can't be picked, and its tooltip says why.
struct ZoomRouteChoiceRow: View {
    @Binding var option: ZoomRouteOption
    let choice: ZoomRouteChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GreenroomSegmented("How Greenroom connects to Zoom", selection: $option,
                               options: ZoomRouteOption.allCases) { option in
                HStack(spacing: 6) {
                    Text(option.title)
                    if let badge = choice.badge(option) {
                        Text(badge)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                .accessibilityElement(children: .combine)
            }
                .segmentHelp { choice.tip($0) }
                .segmentsEnabled { choice.isSelectable($0) }
            Text(option.note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(choice.startLine)
        .accessibilityElement(children: .contain)
        .accessibilityValue(choice.startLine)
    }
}

/// The chosen way's one status line: green only when it is ready.
struct ZoomRouteStatusLine: View {
    let choice: ZoomRouteChoice

    var body: some View {
        StatusBadge(text: choice.status, tone: tone)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(choice.startLine)
    }

    private var tone: StatusBadge.Tone {
        switch choice.tone {
        case .good: return .good
        case .waiting: return .waiting
        case .problem: return .problem
        }
    }
}

/// When the chosen way can't start a meeting yet but the other one could:
/// say so. (What is missing is the status line itself; Start's own words are
/// the status line's tooltip, so the page does not say it twice.)
struct ZoomRouteStartNote: View {
    let choice: ZoomRouteChoice

    var body: some View {
        if let hint = choice.otherHint {
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
/// copy, selectable when open. After a check, the missing ones are marked
/// (count in the label, "Missing" beside each) and can be copied on their own.
private struct ScopeList: View {
    let scopes: [String]
    /// From the last Check Zoom setup; empty when it found none (or has not run).
    let missing: [String]
    @State private var open: Bool
    @State private var copied: String?

    init(scopes: [String], missing: [String] = [], open: Bool) {
        self.scopes = scopes
        self.missing = missing
        _open = State(initialValue: open)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(scopes, id: \.self) { scope in
                    HStack(spacing: 8) {
                        Text(scope)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                        if missing.contains(scope) {
                            Label("Missing", systemImage: "exclamationmark.triangle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                                .accessibilityLabel("\(scope) is missing")
                        }
                    }
                }
            }
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
                if !missing.isEmpty {
                    Text("\(missing.count) missing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                Spacer()
                if !missing.isEmpty {
                    copyButton(missing, key: "missing", title: "Copy missing",
                               help: "Copy the \(missing.count) missing scope\(missing.count == 1 ? "" : "s"), one per line")
                }
                copyButton(scopes, key: "all", title: "Copy scopes",
                           help: missing.isEmpty ? "Copy all \(scopes.count) scopes, one per line"
                                 : "Copy all \(scopes.count) scopes, one per line. Missing after the last check: \(missing.joined(separator: ", "))")
            }
        }
        .help(scopes.map { missing.contains($0) ? "\($0) (missing)" : $0 }.joined(separator: "\n"))
    }

    private func copyButton(_ list: [String], key: String, title: String, help: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(list.joined(separator: "\n"), forType: .string)
            copied = key
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == key { copied = nil } }
        } label: {
            Label(copied == key ? "Copied" : title, systemImage: copied == key ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Brand.text)
        .help(help)
    }
}
