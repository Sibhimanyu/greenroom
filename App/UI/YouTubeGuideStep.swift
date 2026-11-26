//
//  YouTubeGuideStep.swift
//  Greenroom
//
//  The setup guide's YouTube step, "Share recordings on YouTube", as a
//  guided step in the Zoom step's language (owner, 2026-11-26): two cards,
//  one open at a time, each with its state in its header.
//
//  1. Your YouTube account: the same choice as Settings -> YouTube (the
//     shared `YouTubeAppChoiceRow`, not a copy). Greenroom's Google app: Sign
//     in with Google or the signed-in account. Your own Google app: Open
//     Google Cloud and its numbered steps, the Client ID and Secret, then Sign
//     in. These fields live here and only here; Settings opens this card at
//     the own-app part (`YouTubeGuideSpot.ownApp`).
//  2. After each recording: Ask / Upload automatically / Do nothing, one
//     plain line, and for Upload automatically the Made for Kids answer and
//     the §9.1 line.
//
//  Then one quiet footnote about Upload in YouTube Studio. A sign-out's
//  result is a toast, never a line here. States and words come from
//  `YouTubeGuideFlowRules` and `YouTubeAccountRules`. Plain values, bindings
//  and closures only, so it renders off screen (scripts/render/youtube-guide.sh).
//  OnboardingView feeds it.
//
import SwiftUI

struct YouTubeGuideStep: View {
    @Binding var usesOwnApp: Bool
    @Binding var clientID: String
    @Binding var clientSecret: String
    @Binding var uploadMode: YouTubeUploadMode
    @Binding var madeForKids: Bool?
    /// The sign-in, the stored token's app and the fields, for `YouTubeAccountRules`.
    let account: YouTubeAccountFacts
    var channel: YouTubeChannel? = nil
    /// A failed sign-in's words, or nil.
    var problem: String? = nil
    var signIn: () -> Void = {}
    var signOut: () -> Void = {}
    /// Where a deep link asked the step to open; cleared once used.
    @Binding var jump: YouTubeGuideSpot?
    /// Starts with this card open; for the off-screen render only.
    var initiallyOpen: YouTubeGuideCard? = nil

    @State private var chosen: YouTubeGuideCard?
    @State private var chosenSet = false
    @State private var scrollTarget: AnyHashable?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let topID = "youtubeStepTop"

    private func choice(_ option: YouTubeAppOption) -> YouTubeAccountChoice {
        var f = account
        f.route.prefersOwnApp = option.prefersOwnApp
        return YouTubeAccountRules.choice(f)
    }
    private var current: YouTubeAccountChoice { choice(YouTubeAppOption(prefersOwnApp: usesOwnApp)) }
    private var flow: YouTubeGuideFlow {
        YouTubeGuideFlowRules.flow(account: current, mode: uploadMode, madeForKids: madeForKids)
    }
    private var openCard: YouTubeGuideCard? { chosenSet ? chosen : (initiallyOpen ?? flow.open) }
    private var anim: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header.id(Self.topID)
                    VStack(spacing: 12) {
                        ForEach(YouTubeGuideCard.allCases, id: \.self) { card in
                            self.card(card).id(card)
                        }
                    }
                    Text(YouTubeGuideFlowRules.footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
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
                if !chosenSet { chosen = initiallyOpen ?? flow.open; chosenSet = true }
                useJump()
            }
            .onChange(of: jump) { _, _ in useJump() }
            // Signed in: move on to what happens after each recording.
            .onChange(of: flow.account) { _, now in if now == .done { open(.afterRecording) } }
        }
    }

    private func useJump() {
        guard let spot = jump else { return }
        jump = nil
        withAnimation(anim) {
            chosen = YouTubeGuideFlowRules.card(for: spot) ?? flow.open
            chosenSet = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            scrollTarget = spot == .step ? AnyHashable(Self.topID) : AnyHashable(spot)
        }
    }

    private func open(_ card: YouTubeGuideCard?) {
        withAnimation(anim) { chosen = card; chosenSet = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(YouTubeGuideFlowRules.title).font(.title.bold())
            Text(YouTubeGuideFlowRules.subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The cards

    private func card(_ card: YouTubeGuideCard) -> some View {
        let isOpen = openCard == card
        let state = flow.state(card)
        return VStack(alignment: .leading, spacing: 0) {
            Button { open(isOpen ? nil : card) } label: {
                HStack(spacing: 12) {
                    marker(card, success: card == .account && state == .done, started: state != .notStarted)
                    Text(card.title).font(.headline)
                    Spacer(minLength: 8)
                    Text(flow.label(card))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(labelStyle(card, state))
                        .lineLimit(1)
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
            .help(isOpen ? "Fold \(card.title)" : "Open \(card.title)")
            .accessibilityLabel("\(card.number). \(card.title)")
            .accessibilityValue(flow.label(card))
            .accessibilityHint(isOpen ? "Folds this part" : "Opens this part")

            Collapsible(hidden: !isOpen) {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    switch card {
                    case .account: accountCard
                    case .afterRecording: afterRecordingCard
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

    /// The number, or a green check for real success only (a sign-in through
    /// the chosen app). A choice that is simply made, like Ask, stays neutral.
    @ViewBuilder
    private func marker(_ card: YouTubeGuideCard, success: Bool, started: Bool) -> some View {
        if success {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(Brand.text)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        } else {
            Text("\(card.number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(started ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 24)
                .background(Circle().strokeBorder(started ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary),
                                                  lineWidth: 1.5))
                .accessibilityHidden(true)
        }
    }

    private func labelStyle(_ card: YouTubeGuideCard, _ state: YouTubeGuideCardState) -> AnyShapeStyle {
        switch state {
        case .needsAnswer: return AnyShapeStyle(Brand.netText)
        case .done: return card == .account ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary)
        case .notStarted, .inProgress: return AnyShapeStyle(.secondary)
        }
    }

    // MARK: 1 · Your YouTube account

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            YouTubeAppChoiceRow(usesOwnApp: $usesOwnApp)
            Collapsible(hidden: usesOwnApp) {
                accountLine(choice(.greenroom))
            }
            Collapsible(hidden: !usesOwnApp) {
                ownApp
            }
        }
    }

    private var ownApp: some View {
        let c = choice(.own)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Link(destination: YouTubeCloudGuide.url) {
                    Label(YouTubeCloudGuide.linkTitle, systemImage: "arrow.up.right")
                }
                .foregroundStyle(Brand.green)
                .help(YouTubeCloudGuide.url.absoluteString)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(YouTubeCloudGuide.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
            }
            .id(YouTubeGuideSpot.ownApp)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Client ID").gridColumnAlignment(.trailing)
                    TextField("Client ID", text: $clientID)
                        .labelsHidden().textFieldStyle(.greenroom).frame(maxWidth: 360)
                        .help(YouTubeCloudGuide.clientHelp)
                }
                GridRow {
                    Text("Client Secret")
                    SecureField("Client Secret", text: $clientSecret)
                        .labelsHidden().textFieldStyle(.greenroom).frame(maxWidth: 360)
                        .help(YouTubeCloudGuide.clientHelp)
                }
            }
            Text(YouTubeCloudGuide.testingNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            accountLine(c)
        }
    }

    private func accountLine(_ c: YouTubeAccountChoice) -> some View {
        YouTubeAccountLine(choice: c, avatarURL: channel?.avatarURL,
                           problem: c.selected == current.selected ? problem : nil,
                           signIn: signIn, signOut: signOut)
    }

    // MARK: 2 · After each recording

    private static let modes: [YouTubeUploadMode] = [.ask, .automatic, .off]

    private var afterRecordingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            GreenroomSegmented("After each recording", selection: $uploadMode.animatedCollapse(),
                               options: Self.modes) { mode in
                Text(mode.label)
            }
            Text(YouTubeGuideFlowRules.modeLine(uploadMode))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Collapsible(hidden: !flow.showsMadeForKids) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Made for kids").font(.callout)
                    MadeForKidsChoice(selection: $madeForKids)
                    if madeForKids == nil {
                        Label("Upload automatically needs this answer.", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(Brand.netText)
                    }
                    Text(YouTubeSettingsWords.certifyAttributed)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
    }
}
