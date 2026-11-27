//
//  ZoomGuideStep.swift
//  Greenroom
//
//  The setup guide's Zoom step, "Connect Zoom", as a guided flow (owner,
//  2026-11-26): your own Zoom apps are THE path. A small import shortcut,
//  then three numbered parts (Meeting app, Hosting app, Check), each a card
//  with its own state. Only the current part is open; done parts fold to one
//  line; a click on a folded part opens it. Sign in with Zoom shows once, low
//  and quiet, as a disabled "Coming soon" row while it is coming soon.
//
//  Every key field, the scopes (Copy scopes, Copy missing, the missing marks)
//  and Check Zoom setup live here and only here; Settings -> Zoom shows the
//  status and one button into this step. Which part is open and every
//  state's words come from `ZoomGuideFlowRules`.
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
    /// Where a deep link asked the step to open ("Show me where", Settings' button); cleared once used.
    @Binding var jump: ZoomGuideSpot?
    /// The Zoom window: its page, the app IDs it has seen, and the fill-in notices (R3 to R5).
    var assist = ZoomGuideAssistState()
    /// Opens the Zoom window at an address, for the part being worked on.
    var onOpenZoom: (URL, ZoomGuidePart) -> Void = { _, _ in }
    /// "Use the keys from this page".
    var onUseKeys: (ZoomGuidePart) -> Void = { _ in }
    /// "Undo" on "Filled in from Zoom".
    var onUndoFill: (ZoomGuidePart) -> Void = { _ in }
    /// Returns true when the import filled things in.
    var onImport: () -> Bool = { false }
    var onCheck: () -> Void = {}
    var onViewResults: () -> Void = {}
    /// Starts with this part open; for the off-screen render only.
    var initiallyOpen: ZoomGuidePart? = nil

    /// A part the person (or a deep link) opened; nil follows the flow.
    @State private var chosen: ZoomGuidePart?
    @State private var chosenSet = false
    @State private var scrollTarget: AnyHashable?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let topID = "zoomStepTop"

    private var facts: ZoomGuideFlowFacts {
        ZoomGuideFlowRules.facts(sdkFields: [sdkClientID, sdkClientSecret],
                                 s2sFields: [s2sAccountID, s2sClientID, s2sClientSecret],
                                 lines: checkLines, running: isChecking)
    }
    private var flow: ZoomGuideFlow { ZoomGuideFlowRules.flow(facts) }
    private var openPart: ZoomGuidePart? { chosenSet ? chosen : (initiallyOpen ?? flow.open) }
    private var missingScopes: [String] { ZoomCheckSummary.missingScopes(checkLines) }
    private var anim: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header.id(Self.topID)
                    importShortcut
                    VStack(spacing: 12) {
                        ForEach(ZoomGuidePart.allCases, id: \.self) { part in
                            card(part).id(part)
                        }
                    }
                    signInRow
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(anim) { reader.scrollTo(target, anchor: .top) }
                scrollTarget = nil
            }
            .onAppear {
                // The open part is settled here, not on every keystroke: typing
                // the last key never folds the card under the cursor.
                if !chosenSet { chosen = initiallyOpen ?? flow.open; chosenSet = true }
                useJump()
            }
            .onChange(of: jump) { _, _ in useJump() }
            // The Zoom window moved to another page: open its part (unless the other one has typing in it).
            .onChange(of: assist.page) { _, page in
                guard let page else { return }
                let current = openPart
                let typing = current.map { partHasTyping($0) } ?? false
                if let part = ZoomGuideFollowRules.part(for: page, open: current, typing: typing), part != current { open(part) }
            }
            // A check result moves the flow on: to the part that needs a fix, or all folded.
            .onChange(of: facts.check) { _, now in
                if now == .passed || now == .failed { open(flow.open) }
            }
        }
    }

    /// A deep link: open its part (or follow the flow for the step's top) and scroll to the spot.
    private func useJump() {
        guard let spot = jump else { return }
        jump = nil
        withAnimation(anim) {
            chosen = ZoomGuideFlowRules.part(for: spot) ?? flow.open
            chosenSet = true
        }
        // After the card unfolds, so the anchor exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            scrollTarget = spot == .zoomStep ? AnyHashable(Self.topID) : AnyHashable(spot)
        }
    }

    /// Some keys typed but not all: the part is being worked on by hand.
    private func partHasTyping(_ part: ZoomGuidePart) -> Bool {
        switch part {
        case .meetingApp: return facts.sdkFilled > 0 && facts.sdkFilled < 2
        case .hostingApp: return facts.s2sFilled > 0 && facts.s2sFilled < 3
        case .check: return false
        }
    }

    private func open(_ part: ZoomGuidePart?) {
        withAnimation(anim) { chosen = part; chosenSet = true }
    }

    // MARK: Header and the import shortcut

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connect Zoom").font(.title.bold())
            Text("You\u{2019}ll make two small apps in your Zoom account, so Greenroom can start and host your meetings. It takes about 10 minutes.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var importShortcut: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Have a settings file from a teammate?")
                    .foregroundStyle(.secondary)
                Button("Import it\u{2026}") {
                    if onImport() {
                        open(.check)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { scrollTarget = AnyHashable(ZoomGuidePart.check) }
                    }
                }
                .buttonStyle(.link)
                .foregroundStyle(Brand.green)
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

    // MARK: The cards

    private func card(_ part: ZoomGuidePart) -> some View {
        let isOpen = openPart == part
        let state = flow.state(part)
        return VStack(alignment: .leading, spacing: 0) {
            Button { open(isOpen ? nil : part) } label: {
                HStack(spacing: 12) {
                    marker(part, state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.title).font(.headline)
                        if isOpen {
                            Text(part.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(ZoomGuideFlowRules.label(part, facts))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(labelColor(part, state))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Fold \(part.title)" : "Open \(part.title)")
            .accessibilityLabel("\(part.number). \(part.title)")
            .accessibilityValue(ZoomGuideFlowRules.label(part, facts))
            .accessibilityHint(isOpen ? "Folds this part" : "Opens this part")

            Collapsible(hidden: !isOpen) {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    content(part)
                    if state == .done, let next = ZoomGuidePart(rawValue: part.rawValue + 1) {
                        Button("Continue to \(next.title)") {
                            open(next)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { scrollTarget = AnyHashable(next) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.buttonFill)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quinary))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    /// The number, or a check once the part is done.
    @ViewBuilder
    private func marker(_ part: ZoomGuidePart, _ state: ZoomGuidePartState) -> some View {
        if state == .done {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Brand.text)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        } else {
            Text("\(part.number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(state == .notStarted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.text))
                .frame(width: 24, height: 24)
                .background(Circle().strokeBorder(state == .notStarted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.text),
                                                  lineWidth: 1.5))
                .accessibilityHidden(true)
        }
    }

    private func labelColor(_ part: ZoomGuidePart, _ state: ZoomGuidePartState) -> AnyShapeStyle {
        let label = ZoomGuideFlowRules.label(part, facts)
        if label == "Needs a fix" { return AnyShapeStyle(Brand.netText) }
        return state == .done ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary)
    }

    @ViewBuilder
    private func content(_ part: ZoomGuidePart) -> some View {
        switch part {
        case .meetingApp: meetingApp
        case .hostingApp: hostingApp
        case .check: check
        }
    }

    // MARK: 1 · Meeting app

    private var meetingApp: some View {
        VStack(alignment: .leading, spacing: 16) {
            steps(.meetingApp)
            fillNotice(.meetingApp)
            fields([("Client ID", $sdkClientID, false), ("Client Secret", $sdkClientSecret, true)])
                .id(ZoomGuideSpot.sdkCredentials)
            detail {
                Text("Use the same Zoom account for both apps. You need permission to build apps; ask your Zoom account admin if Build App is missing.")
                Text("In Zoom, choose Build App \u{2192} General App. Under Features \u{2192} Embed, turn on Meeting SDK. Find the Client ID and Client Secret under Basic Information \u{2192} App Credentials, and paste them above.")
            }
        }
    }

    // MARK: 2 · Hosting app

    private var hostingApp: some View {
        VStack(alignment: .leading, spacing: 16) {
            steps(.hostingApp)
            ZoomScopeChecklist(missing: missingScopes)
                .id(ZoomGuideSpot.s2sScopes)
            Label("In Zoom, finish Information, then open Activation and activate the app.",
                  systemImage: "power")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .id(ZoomGuideSpot.s2sActivation)
            fillNotice(.hostingApp)
            fields([("Account ID", $s2sAccountID, false), ("Client ID", $s2sClientID, false),
                    ("Client Secret", $s2sClientSecret, true)])
                .id(ZoomGuideSpot.s2sCredentials)
            detail {
                Text("Use the same Zoom account as the Meeting app. Adding admin scopes needs an admin role; ask your Zoom account admin if they are missing.")
                Text("In Zoom, choose Build App \u{2192} Server-to-Server OAuth and name it. Open Scopes \u{2192} Add Scopes: copy one name above, paste it into the search field and select the matching permission. Repeat for all \(ZoomScopes.countWord), then save.")
                Text("Finish Information, open Activation and activate the app. Then copy the three values from App Credentials and paste them above.")
            }
        }
    }

    // MARK: 3 · Check

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

    /// The Zoom window button and the part's steps; the step the window is on is marked, and each
    /// step with a known app has a button to its exact page.
    private func steps(_ part: ZoomGuidePart) -> some View {
        let rows = ZoomMarketplaceGuide.rows(part: part, ids: assist.ids)
        let current = ZoomGuideFollowRules.step(part: part, page: assist.page)
        return VStack(alignment: .leading, spacing: 8) {
            Button { onOpenZoom(ZoomMarketplaceGuide.builderURL, part) } label: {
                Label(ZoomMarketplaceGuide.linkTitle, systemImage: "arrow.up.right")
            }
            .buttonStyle(.link)
            .foregroundStyle(Brand.green)
            .help("Opens Zoom App Marketplace in the Zoom window beside this guide")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    let isCurrent = current == index + 1
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).").monospacedDigit()
                            .foregroundStyle(isCurrent ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary))
                            .fontWeight(isCurrent ? .semibold : .regular)
                        Text(row.text).fixedSize(horizontal: false, vertical: true)
                            .fontWeight(isCurrent ? .medium : .regular)
                        Spacer(minLength: 8)
                        if let link = row.link {
                            Button(link.title) {
                                if let url = ZoomMarketplacePages.url(for: link.page) { onOpenZoom(url, part) }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            .foregroundStyle(Brand.text)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isCurrent ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(isCurrent ? "You are on this step in the Zoom window" : "")
                }
            }
            .font(.callout)
        }
    }

    /// "Filled in from Zoom" with Undo, or the offer to use the page's keys.
    @ViewBuilder
    private func fillNotice(_ part: ZoomGuidePart) -> some View {
        if assist.filled.contains(part) {
            HStack(spacing: 8) {
                Label("Filled in from Zoom", systemImage: "checkmark.circle")
                    .foregroundStyle(Brand.text)
                Button("Undo") { onUndoFill(part) }.buttonStyle(.link).foregroundStyle(Brand.text)
            }
            .font(.callout)
        } else if assist.offers.contains(part) {
            VStack(alignment: .leading, spacing: 4) {
                Button("Use the keys from this page") { onUseKeys(part) }
                    .buttonStyle(.bordered)
                Text("The page shows different keys from the ones below. Nothing changes until you press this.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The key fields, labels in one column so the fields line up. Secrets are always dotted.
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
