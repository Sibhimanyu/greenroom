//
//  ZoomCheckPanel.swift
//  Greenroom
//
//  The one look for a Zoom check's results, shared by "Check Zoom setup"
//  (your own Zoom apps, the setup guide) and "Check sign-in" (Sign in with
//  Zoom, Settings and the setup guide): a headline, "N of M checks passed",
//  one line per step with its icon, and Check again / Done. Plain values
//  (`ZoomCheckLine`, words in ZoomSetupCheckRules), so it renders off screen.
//
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
    let onAgain: () -> Void
    let onDone: () -> Void

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
                                }
                            }
                            Spacer(minLength: 0)
                            if let word = ZoomCheckSummary.trailing(line.status) {
                                Text(word).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .help(line.detail)
                        .accessibilityElement(children: .combine)
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

    static let footnote = "Tries what Start needs from your sign-in, in Start\u{2019}s order. No meeting is created or started."

    var body: some View {
        ZoomCheckButtonRow(title: "Check sign-in", lines: checker.lines, isRunning: checker.isRunning,
                           onCheck: { checker.showing = true; if !checker.isRunning { onRun() } },
                           onView: { checker.showing = true })
            .sheet(isPresented: $checker.showing) {
                ZoomCheckPanel(subject: "Zoom sign-in", lines: checker.lines, isRunning: checker.isRunning,
                               footnote: Self.footnote, onAgain: onRun, onDone: { checker.showing = false })
            }
    }
}
