//
//  ZoomCheckPanel.swift
//  Greenroom
//
//  The one look for a Zoom check's results, shared by "Check Zoom setup"
//  (your own Zoom apps, the setup guide) and "Check sign-in" (Sign in with
//  Zoom, Settings and the setup guide): a headline, "N of M checks passed",
//  a fix bar when anything failed ("2 things to fix", Copy all missing
//  scopes, Open Scopes page, Check again), one line per step with its icon
//  and its buttons (`ZoomCheckActionRules`), and Check again / Done. Plain values
//  (`ZoomCheckLine`, words in ZoomSetupCheckRules), so it renders off screen.
//
import AppKit
import SwiftUI

struct ZoomCheckIcon: View {
    let status: ZoomCheckStatus

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.text)
        case .warned: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.net)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .atStart: Image(systemName: "clock").foregroundStyle(.secondary)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}

struct ZoomCheckPanel: View {
    /// "Zoom setup", "Zoom sign-in": the headline's subject.
    let subject: String
    let lines: [ZoomCheckLine]
    let isRunning: Bool
    let footnote: String
    var againDisabled = false
    /// The client IDs the buttons' tooltips name the apps by.
    var ids = ZoomCheckActionContext()
    let onAgain: () -> Void
    let onDone: () -> Void
    /// The line buttons that leave the panel (open a page, the guide, sign in).
    /// Copying and Check again are the panel's own.
    var onAction: (ZoomCheckAction) -> Void = { _ in }

    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ZoomCheckSummary.headline(lines, subject: subject, running: isRunning))
                        .font(.title2.bold())
                    Text(ZoomCheckSummary.count(lines))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isRunning { ProgressView().controlSize(.small) }
            }
            if let bar = ZoomCheckSummary.fixBar(lines, running: isRunning) {
                fixBar(bar)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 12) {
                            ZoomCheckIcon(status: line.status).frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(line.title).font(.callout.weight(.semibold))
                                if line.status != .passed && line.status != .waiting {
                                    Text(line.detail).font(.caption).foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .help(line.detail)
                                }
                                if !line.actions.isEmpty && !isRunning {
                                    HStack(spacing: 8) {
                                        ForEach(line.actions, id: \.self) { button in
                                            actionButton(button)
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                            Spacer(minLength: 0)
                            if let word = ZoomCheckSummary.trailing(line.status) {
                                Text(word).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: line.actions.isEmpty ? .combine : .contain)
                    }
                }
                .padding(4)
            }
            Divider()
            Text(footnote).font(.caption).foregroundStyle(.secondary)
            HStack {
                if !isRunning {
                    Button("Check again", action: onAgain).disabled(againDisabled)
                }
                Spacer()
                Button(isRunning ? "Close checks" : "Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 580, height: 640)
    }

    /// "2 things to fix" and the fixes that cover every line at once.
    private func fixBar(_ bar: ZoomCheckFixBar) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(lines.contains { $0.status == .failed } ? AnyShapeStyle(.red) : AnyShapeStyle(Brand.net))
            Text(bar.title).font(.callout.weight(.semibold))
                .fixedSize()
            Spacer(minLength: 8)
            if bar.offersScopesPage {
                Button {
                    copy(bar.copyAllText, key: "all")
                } label: {
                    Text(copied == "all" ? "Copied" : "Copy all missing scopes")
                }
                .help("Copies \(bar.missingScopes.count == 1 ? "the missing scope" : "the \(bar.missingScopes.count) missing scopes"), one per line. Zoom\u{2019}s scope search takes one at a time: paste a line, pick the match, repeat.")
                Button {
                    onAction(.openScopesPage)
                } label: {
                    Text(ZoomCheckAction.openScopesPage.title)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.buttonFill)
                .help(ZoomCheckActionRules.help(.openScopesPage, ids: ids))
            }
            Button(ZoomCheckAction.checkAgain.title, action: onAgain)
                .disabled(againDisabled)
                .help(ZoomCheckActionRules.help(.checkAgain, ids: ids))
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionButton(_ button: ZoomCheckButton) -> some View {
        let action = button.action
        let key: String? = { if case .copyScope(let name) = action { return name } else { return nil } }()
        let isCopied = key != nil && copied == key
        let base = Button {
            switch action {
            case .copyScope(let name): copy(name, key: name)
            case .checkAgain: onAgain()
            default: onAction(action)
            }
        } label: {
            if isCopied { Label("Copied", systemImage: "checkmark") }
            else if action.url != nil { Label(action.title, systemImage: "arrow.up.right") }
            else { Text(action.title) }
        }
        .controlSize(.small)
        .disabled(action == .checkAgain && againDisabled)
        .help(ZoomCheckActionRules.help(action, ids: ids))
        if button.primary {
            base.buttonStyle(.borderedProminent).tint(Brand.buttonFill)
        } else {
            base.buttonStyle(.bordered)
        }
    }

    private func copy(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == key { copied = nil } }
    }
}

/// The check button with its summary ("N of M checks passed", View results).
struct ZoomCheckButtonRow: View {
    let title: String
    let lines: [ZoomCheckLine]
    let isRunning: Bool
    var disabled = false
    let onCheck: () -> Void
    let onView: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(isRunning ? "View checks in progress\u{2026}" : title, action: onCheck)
                .disabled(disabled)
            if isRunning { ProgressView().controlSize(.small) }
            if !lines.isEmpty && !isRunning {
                Text(ZoomCheckSummary.count(lines)).font(.callout).foregroundStyle(.secondary)
                Button("View results", action: onView)
            }
        }
    }
}

/// "Check sign-in" under Signed in as: the shared button, row and panel, fed by
/// a `ZoomSignInChecker`.
struct ZoomSignInCheckRow: View {
    @ObservedObject var checker: ZoomSignInChecker
    let onRun: () -> Void
    var onAction: (ZoomCheckAction) -> Void = { _ in }

    static let footnote = "Tries what Start needs from your sign-in, in Start\u{2019}s order. No meeting is created or started."

    var body: some View {
        ZoomCheckButtonRow(title: ZoomRouteCheck.signIn.title, lines: checker.lines, isRunning: checker.isRunning,
                           onCheck: { checker.showing = true; if !checker.isRunning { onRun() } },
                           onView: { checker.showing = true })
            .sheet(isPresented: $checker.showing) {
                ZoomCheckPanel(subject: "Zoom sign-in", lines: checker.lines, isRunning: checker.isRunning,
                               footnote: Self.footnote, onAgain: onRun, onDone: { checker.showing = false },
                               onAction: onAction)
            }
    }
}

/// "Check Zoom setup" in Settings -> Zoom: the same button, row and panel as
/// Check sign-in, fed by the coordinator's one `ZoomSetupChecker` (the setup
/// guide runs the same one).
struct ZoomSetupCheckRow: View {
    @ObservedObject var checker: ZoomSetupChecker
    var disabled = false
    var ids = ZoomCheckActionContext()
    let onRun: () -> Void
    var onAction: (ZoomCheckAction) -> Void = { _ in }

    var body: some View {
        ZoomCheckButtonRow(title: ZoomRouteCheck.setup.title, lines: checker.lines, isRunning: checker.isRunning,
                           disabled: disabled,
                           onCheck: { checker.showingIn = .settings; if !checker.isRunning { onRun() } },
                           onView: { checker.showingIn = .settings })
            .sheet(isPresented: Binding(get: { ZoomCheckSurface.settings.isShown(checker.showingIn) },
                                        set: { if !$0, checker.showingIn == .settings { checker.showingIn = nil } })) {
                ZoomCheckPanel(subject: "Zoom setup", lines: checker.lines, isRunning: checker.isRunning,
                               footnote: ZoomSetupChecker.footnote, againDisabled: disabled, ids: ids,
                               onAgain: onRun, onDone: { checker.showingIn = nil }, onAction: onAction)
            }
    }
}
