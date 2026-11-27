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
//  Your own Zoom apps are a compact summary here (owner, 2026-11-26: "no
//  setup stuff like copy scopes and all should be available in the settings;
//  a button should take us to the setup guide"): the status line, Check Zoom
//  setup and its results, and ONE button, "Set up…" or "Edit setup…", that
//  opens the setup guide's Zoom step at the first part that isn't done
//  (`ZoomGuideFlowRules.setupEntry`). Every key field, the scopes and the
//  Marketplace steps live only in the guide (`ZoomGuideStep`).
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
            setupEntry: coordinator.zoomSetupEntry,
            refusedNote: coordinator.zoomRouteNote,
            onSignIn: { coordinator.signInWithZoom() },
            onCancelSignIn: { coordinator.cancelZoomSignIn() },
            openGuide: { _ in coordinator.openZoomSetupGuide() },
            onStartOver: ZoomStartOverRules.isShown(coordinator.zoomGuideFacts) ? { coordinator.zoomAssist.startOver() } : nil,
            startOverDisabled: coordinator.phase.isInMeeting,
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
    /// The one button into the setup guide: its words and where it lands.
    var setupEntry = ZoomSetupEntry(title: "Set up Zoom\u{2026}", spot: .zoomStep)
    /// Zoom refused this account before (error 63): why, and what to do.
    var refusedNote: String? = nil
    var onSignIn: () -> Void = {}
    var onCancelSignIn: () -> Void = {}
    /// Opens the setup guide's Zoom step at a spot.
    var openGuide: (ZoomGuideSpot) -> Void = { _ in }
    /// "Start over\u{2026}", the same confirmation and action as the setup guide's; nil hides it (no keys filled).
    var onStartOver: (() -> Void)? = nil
    var startOverDisabled = false
    /// A DEBUG build's extra rows (the sign-in override); nil in Release and in renders.
    var debugRows: AnyView? = nil

    // "During the meeting" (moved from the Layout tab; keys unchanged).
    @AppStorage(SessionNotes.enabledKey) private var notesOnStart = false
    @AppStorage(CoordinatorController.copyInviteOnStartKey) private var copyInviteOnStart = true

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

    /// Your own Zoom apps, as a summary: the status line, the check and its
    /// results, and one button into the setup guide, where the keys live.
    private var ownAppsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZoomRouteStatusLine(choice: choice)
            if choice.check == .setup, let setupCheck { setupCheck }
            ZoomRouteStartNote(choice: choice)
            HStack(spacing: 16) {
                Button(setupEntry.title) { openGuide(setupEntry.spot) }
                    .help("Opens the setup guide\u{2019}s Zoom step, where the keys, scopes and the step-by-step setup live.")
                if let onStartOver {
                    ZoomStartOverButton(disabled: startOverDisabled, action: onStartOver)
                }
            }
            .padding(.top, 4)
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
