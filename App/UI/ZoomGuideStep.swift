//
//  ZoomGuideStep.swift
//  Greenroom
//
//  The setup guide's Zoom step, "Connect Zoom" (spec R14, owner 2026-11-27):
//  one main button. Top to bottom: title and a one-line intro; ONE large green
//  button, "Set up for me" (Greenroom builds both apps and copies the keys;
//  docs/specs/zoom-setup-flow.md), with "Guide me instead" beside it, which opens
//  the Zoom window on the first unfinished part; a calm status list, one line per part (mark, name,
//  state words; when done a quiet "Use a different app" and a "..." menu of
//  shortcuts to that app's pages); the Check row once both parts are done;
//  a folded "Enter the keys yourself" holding the manual route (steps, key
//  fields, the scope checklist, "Show me each click"), which deep links
//  (`ZoomGuideSpot`) unfold and scroll to; and a quiet footer (Import,
//  Start over, Sign in with Zoom Coming soon). "Filled in from Zoom", the offer
//  to use the page's keys and "Keys removed" show on the part's status line.
//
//  Every key field, the scopes and Check Zoom setup live here and only here;
//  Settings -> Zoom shows the status and one button into this step. Which part
//  the button opens, the wording and when the check row shows come from
//  `ZoomConnect` and `ZoomGuideFlowRules`.
//
//  Plain values, bindings and closures only, so it renders off screen with
//  sample values (scripts/render/zoom-guide.sh). OnboardingView feeds it.
//
import SwiftUI

struct ZoomGuideStep: View {
    @Binding var sdkClientID: String
    @Binding var sdkClientSecret: String
    @Binding var s2sAccountID: String
    @Binding var s2sClientID: String
    @Binding var s2sClientSecret: String
    /// The last Check Zoom setup's lines, and whether it is running.
    let checkLines: [ZoomCheckLine]
    let isChecking: Bool
    /// True while a meeting is on: the check waits until it ends.
    var checkDisabled = false
    /// Sign in with Zoom shows as Coming soon (the switch). Off: `signIn` shows instead.
    var signInComingSoon = true
    /// The open sign-in's block (only with the switch off, e.g. the DEBUG override).
    var signIn: AnyView? = nil
    /// The import's last result, and whether it failed.
    var importStatus = ""
    var importFailed = false
    /// Where a deep link asked the step to open ("Show me where"); cleared once used.
    @Binding var jump: ZoomGuideSpot?
    /// The Zoom window: its page, the app IDs it has seen, and the fill-in notices (R3 to R5).
    var assist = ZoomGuideAssistState()
    /// Opens the Zoom window at an address, for the part being worked on.
    var onOpenZoom: (URL, ZoomGuidePart) -> Void = { _, _ in }
    /// "Start over" (confirmed), "Use a different app" and its Undo.
    var onStartOver: () -> Void = {}
    var onUseDifferentApp: (ZoomGuidePart) -> Void = { _ in }
    var onUndoRemoved: (ZoomGuidePart) -> Void = { _ in }
    /// Returns true when the import filled things in.
    var onImport: () -> Bool = { false }
    var onCheck: () -> Void = {}
    var onViewResults: () -> Void = {}
    /// Set up for me: its state, the button, the form's Start / Cancel, and Stop.
    var setUp: ZoomSetUpForMeState = .idle
    var infoDefaults = InfoValues()
    var onSetUpForMe: () -> Void = {}
    var onStartSetUp: (InfoValues, Set<ZoomApp>) -> Void = { _, _ in }
    var onCancelSetUp: () -> Void = {}
    var onStopSetUp: () -> Void = {}
    /// Starts with the manual route unfolded; for the off-screen render only.
    var manualOpen = false

    @State private var manualRequest = false
    @State private var scrollTarget: AnyHashable?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let topID = "zoomStepTop"
    private static let checkID = "zoomStepCheck"

    private var facts: ZoomGuideFlowFacts {
        ZoomGuideFlowRules.facts(sdkFields: [sdkClientID, sdkClientSecret],
                                 s2sFields: [s2sAccountID, s2sClientID, s2sClientSecret],
                                 lines: checkLines, running: isChecking)
    }
    private var flow: ZoomGuideFlow { ZoomGuideFlowRules.flow(facts) }
    private var missingScopes: [String] { ZoomCheckSummary.missingScopes(checkLines) }
    private var anim: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }
    private func filledCount(_ part: ZoomGuidePart) -> Int { part == .meetingApp ? facts.sdkFilled : facts.s2sFilled }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header.id(Self.topID)
                    if let part = ZoomConnect.nextPart(facts) { setUpArea(part) }
                    statusList
                    if ZoomConnect.showsCheckRow(facts) { check.id(Self.checkID) }
                    manualRoute
                    footer
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(anim) { reader.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
            .onAppear { useJump() }
            .onChange(of: jump) { _, _ in useJump() }
        }
    }

    /// A deep link: the keys, scopes and activation unfold the manual route and scroll to the spot;
    /// the step's top just scrolls up.
    private func useJump() {
        guard let spot = jump else { return }
        jump = nil
        if ZoomConnect.opensManual(spot) { manualRequest = true }
        // After the route unfolds, so the anchor exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            scrollTarget = spot == .zoomStep ? AnyHashable(Self.topID) : AnyHashable(spot)
        }
    }

    // MARK: Header and the one button

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connect Zoom").font(.title.bold())
            Text(ZoomConnect.intro)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Set up for me is the main button; the guided steps are "Guide me instead" and what Set up for me hands over to.
    @ViewBuilder
    private func setUpArea(_ part: ZoomGuidePart) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch setUp {
            case .preparing:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Looking at your Zoom apps\u{2026}").foregroundStyle(.secondary) }
            case .running(let line):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(line).foregroundStyle(.secondary)
                    Button("Stop", action: onStopSetUp)
                }
            default:
                if case .handedOver(let note) = setUp {
                    Label(note, systemImage: "hand.raised")
                        .font(.callout).foregroundStyle(Brand.netText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button(action: onSetUpForMe) {
                        Text("Set up for me").font(.headline).frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Brand.buttonFill)
                    .help("Greenroom builds both apps in your Zoom account and copies the keys. You can stop at any time.")
                    guideButton(part)
                }
            }
        }
        .sheet(isPresented: Binding(get: { if case .asking = setUp { return true } else { return false } },
                                    set: { if !$0, case .asking = setUp { onCancelSetUp() } })) {
            if case .asking(let existing) = setUp {
                ZoomSetUpForMeForm(info: infoDefaults, existing: existing, onStart: onStartSetUp, onCancel: onCancelSetUp)
            }
        }
    }

    /// "Guide me instead": the Zoom window opens at the first unfinished part and its bar and tips take you step by step.
    private func guideButton(_ part: ZoomGuidePart) -> some View {
        let page = ZoomConnect.entryPage(part, ids: assist.ids, filled: filledCount(part))
        let url = ZoomMarketplacePages.url(for: page) ?? ZoomMarketplaceGuide.builderURL
        return Button { onOpenZoom(url, part) } label: {
            Text("Guide me instead").font(.body)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help("Opens Zoom App Marketplace in its own window, at \(part.title)")
    }

    // MARK: The status list

    private var statusList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([ZoomGuidePart.meetingApp, .hostingApp], id: \.self) { part in statusLine(part) }
        }
    }

    private func statusLine(_ part: ZoomGuidePart) -> some View {
        let state = flow.state(part)
        let label = ZoomGuideFlowRules.label(part, facts)
        // Where setup stands now, when it is in this part (the one step ZoomSetupFlow returned).
        let app: ZoomApp = part == .meetingApp ? .meeting : .hosting
        let current = state == .done ? nil : assist.step.flatMap { $0.number != nil && $0.app == app ? $0 : nil }
        let words = current.map { $0.barTitle } ?? label
        let shortcuts = ZoomConnect.shortcuts(part, ids: assist.ids)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                marker(part, state, needsFix: label == "Needs a fix")
                Text(part.title).font(.headline)
                Text(words)
                    .font(.callout)
                    .foregroundStyle(label == "Needs a fix" && current == nil ? AnyShapeStyle(Brand.netText) : AnyShapeStyle(.secondary))
                Spacer(minLength: 8)
                if ZoomStartOverRules.showsUseDifferentApp(state) {
                    Button(ZoomStartOverRules.useDifferentAppTitle) { onUseDifferentApp(part) }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Clears this app\u{2019}s keys and opens Zoom\u{2019}s list of your apps")
                }
                if !shortcuts.isEmpty {
                    Menu {
                        ForEach(shortcuts, id: \.title) { link in
                            Button(link.title) {
                                if let url = ZoomMarketplacePages.url(for: link.page) { onOpenZoom(url, part) }
                            }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Open this app\u{2019}s pages in the Zoom window")
                    .accessibilityLabel("\(part.title) pages")
                }
            }
            notice(part)
        }
        .accessibilityElement(children: .contain)
    }

    /// "Keys removed" with Undo.
    @ViewBuilder
    private func notice(_ part: ZoomGuidePart) -> some View {
        Group {
            if assist.removed.contains(part) {
                HStack(spacing: 6) {
                    Text("\(ZoomStartOverRules.removedNotice) \u{00B7}").foregroundStyle(.secondary)
                    Button("Undo") { onUndoRemoved(part) }.buttonStyle(.link).foregroundStyle(Brand.text)
                }
            }
        }
        .font(.callout)
        .padding(.leading, 36)
    }

    /// The number, a check once the part is done, or amber when the check found something to fix.
    @ViewBuilder
    private func marker(_ part: ZoomGuidePart, _ state: ZoomGuidePartState, needsFix: Bool) -> some View {
        if needsFix {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3).foregroundStyle(Brand.netText)
                .frame(width: 24, height: 24).accessibilityHidden(true)
        } else if state == .done {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3).foregroundStyle(Brand.text)
                .frame(width: 24, height: 24).accessibilityHidden(true)
        } else {
            Text("\(part.number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(state == .notStarted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.text))
                .frame(width: 24, height: 24)
                .background(Circle().strokeBorder(state == .notStarted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.text), lineWidth: 1.5))
                .accessibilityHidden(true)
        }
    }

    // MARK: The check row

    private var check: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZoomCheckButtonRow(title: ZoomRouteCheck.setup.title, lines: checkLines, isRunning: isChecking,
                               disabled: checkDisabled,
                               onCheck: { if isChecking { onViewResults() } else { onCheck() } },
                               onView: onViewResults)
            Text(checkDisabled
                 ? "End the current session before checking Zoom."
                 : "Checks both apps, all \(ZoomScopes.countWord) hosting permissions, meeting lookup and the hosting token. No meeting is created or ended.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The manual route

    private var manualRoute: some View {
        AdvancedDisclosure(ZoomConnect.manualTitle, open: manualOpen, openRequest: $manualRequest) {
            VStack(alignment: .leading, spacing: 28) {
                manualPart(.meetingApp) {
                    fields([("Client ID", $sdkClientID, false), ("Client Secret", $sdkClientSecret, true)])
                        .id(ZoomGuideSpot.sdkCredentials)
                }
                manualPart(.hostingApp) {
                    ZoomScopeChecklist(missing: missingScopes)
                        .id(ZoomGuideSpot.s2sScopes)
                    Label("In Zoom, finish Information, then open Activation and activate the app.", systemImage: "power")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(ZoomGuideSpot.s2sActivation)
                    fields([("Account ID", $s2sAccountID, false), ("Client ID", $s2sClientID, false),
                            ("Client Secret", $s2sClientSecret, true)])
                        .id(ZoomGuideSpot.s2sCredentials)
                }
                detail {
                    Text("Use the same Zoom account for both apps. You need permission to build apps; ask your Zoom account admin if Build App is missing.")
                    Text("Meeting app: choose Build App \u{2192} General App. Under Features \u{2192} Embed, turn on Meeting SDK. Find the Client ID and Client Secret under Basic Information \u{2192} App Credentials.")
                    Text("Hosting app: choose Build App \u{2192} Server-to-Server OAuth and name it. Open Scopes \u{2192} Add Scopes: copy one name above, paste it into the search field and select the matching permission. Repeat for all \(ZoomScopes.countWord), then save. Finish Information, open Activation and activate the app. Then copy the three values from App Credentials.")
                }
            }
            .padding(.top, 4)
        }
    }

    /// A part's heading, its steps as plain text, and what goes under them.
    private func manualPart<C: View>(_ part: ZoomGuidePart, @ViewBuilder _ content: () -> C) -> some View {
        let steps = part == .meetingApp ? ZoomMarketplaceGuide.sdkSteps : ZoomMarketplaceGuide.s2sSteps
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(part.title).font(.headline)
                Text(part.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(step).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
            content()
        }
    }

    // MARK: The footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            importShortcut
            if ZoomStartOverRules.isShown(facts) {
                ZoomStartOverButton(disabled: checkDisabled, action: onStartOver)
            }
            signInRow
        }
    }

    private var importShortcut: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Have a settings file from a teammate?")
                    .foregroundStyle(.secondary)
                Button("Import it\u{2026}") {
                    if onImport() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { scrollTarget = AnyHashable(Self.checkID) }
                    }
                }
                .buttonStyle(.link)
                .foregroundStyle(Brand.text)
                .disabled(isChecking)
                .help("Fills in both apps from a Greenroom settings file, then takes you to the check.")
            }
            .font(.callout)
            if !importStatus.isEmpty {
                Label(importStatus, systemImage: importFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(importFailed ? AnyShapeStyle(Brand.netText) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Sign in with Zoom, low and quiet

    @ViewBuilder
    private var signInRow: some View {
        if signInComingSoon {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .accessibilityHidden(true)
                Text("Sign in with Zoom")
                Text("\u{00B7}")
                    .accessibilityHidden(true)
                Text(ZoomSignInAvailability.label)
            }
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .help(ZoomSignInAvailability.tooltip)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sign in with Zoom, coming soon")
            .accessibilityHint(ZoomSignInAvailability.tooltip)
        } else if let signIn {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("Or sign in with Zoom").font(.headline)
                signIn
            }
        }
    }

    // MARK: Pieces

    /// The key fields, labels in one column so the fields line up. Secrets are always dotted.
    /// The small "Use a different app" link under a Done part's fields.
    @ViewBuilder
    private func differentApp(_ part: ZoomGuidePart) -> some View {
        if ZoomStartOverRules.showsUseDifferentApp(flow.state(part)) {
            Button(ZoomStartOverRules.useDifferentAppTitle) { onUseDifferentApp(part) }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Clears this app\u{2019}s keys and opens Zoom\u{2019}s list of your apps")
        }
    }

    private func fields(_ rows: [(title: String, text: Binding<String>, secure: Bool)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(rows, id: \.title) { row in
                GridRow {
                    Text(row.title)
                        .gridColumnAlignment(.trailing)
                    Group {
                        if row.secure { SecureField(row.title, text: row.text) }
                        else { TextField(row.title, text: row.text) }
                    }
                    .labelsHidden()
                    .textFieldStyle(.greenroom)
                    .frame(maxWidth: 360)
                }
            }
        }
    }

    private func detail<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        AdvancedDisclosure(ZoomMarketplaceGuide.detailTitle) {
            VStack(alignment: .leading, spacing: 8) { content() }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
