//
//  ZoomBarView.swift
//  Greenroom
//
//  The Greenroom bar at the top of the Zoom window, the one bar above the web view.
//  It renders a `SetupStep` and nothing else (docs/specs/zoom-setup-flow.md): left, "Step n
//  of 8 \u{00B7} title"; then the step's ONE button (Do this step, Open Embed, Check again, Back
//  to Greenroom), or a spinner while a step is being done, or, while Set up for me runs, its
//  line with Stop. Sign in (when Zoom says signed out) and Copy scopes (on the scopes step)
//  sit beside it. Right: Back, Forward, Reload, the Tips
//  toggle and a "..." menu with Open in Safari and (only when signed in) Sign
//  out of Zoom. Plain values and closures, so it renders off screen
//  (scripts/render/zoom-bar.sh). It is a plain stack, not an NSToolbar, so
//  nothing can fold into an overflow chevron; at the 900pt minimum width the
//  fixed parts (about 520pt with every button showing) leave the title the rest,
//  and it truncates at its tail.
//
import SwiftUI

struct ZoomBarView: View {
    var step: SetupStep?
    /// What Marketplace's header says (nil: it says neither).
    var signedIn: Bool?
    /// A step is being done.
    var working = false
    var canGoBack = false
    var canGoForward = false
    @Binding var tipsOn: Bool
    var loadFailed = false
    /// "Copied" shows for a moment after Copy scopes.
    var copied = false
    /// The read-only address of the page, as the title's tooltip.
    var address = ""
    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    var onReload: () -> Void = {}
    var onCopyScopes: () -> Void = {}
    var onSignIn: () -> Void = {}
    var onAct: () -> Void = {}
    var onOpenInSafari: () -> Void = {}
    var onSignOut: () -> Void = {}
    /// "Step n of 8 \u{00B7} title\u{2026}" while Set up for me runs; the bar then shows it with Stop instead of the step's button.
    var autopilot: String? = nil
    var onStop: () -> Void = {}

    static let height: CGFloat = 44

    private var title: String { step?.barTitle ?? "Zoom setup" }

    var body: some View {
        HStack(spacing: 10) {
            if let autopilot {
                // Set up for me runs: its line takes the title's place (the step's own title would say the same twice).
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(autopilot).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(address.isEmpty ? title : address)
            }
            if loadFailed {
                Text("Couldn\u{2019}t load this page.")
                    .font(.caption).foregroundStyle(Brand.netText).lineLimit(1).fixedSize()
            }
            if autopilot != nil {
                // Plain, never the green call to action (owner, 2026-11-27): Stop is there, not suggested.
                Button("Stop", action: onStop)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .fixedSize()
                    .help("Ends Set up for me after the current action and hands over to the guided steps")
            } else {
                context
                primary
            }
            HStack(spacing: 2) {
                iconButton("chevron.left", "Back", enabled: canGoBack, onBack)
                iconButton("chevron.right", "Forward", enabled: canGoForward, onForward)
                iconButton("arrow.clockwise", "Reload", enabled: true, onReload)
            }
            Toggle("Tips", isOn: $tipsOn)
                .toggleStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("Show or hide Greenroom\u{2019}s tips on Zoom\u{2019}s page")
            Menu {
                Button("Open in Safari", action: onOpenInSafari)
                if signedIn == true {
                    Button("Sign out of Zoom", action: onSignOut)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background(.bar)
    }

    @ViewBuilder
    private var context: some View {
        if signedIn == false, step?.isSignIn == true {
            Button("Sign in", action: onSignIn)
                .controlSize(.small)
                .fixedSize()
                .help("Opens Zoom Marketplace, which asks you to sign in")
        } else if step?.number == 6 {
            Button(action: onCopyScopes) {
                Label(copied ? "Copied" : "Copy scopes", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .fixedSize()
            .help("Copy all \(ZoomScopes.count) scopes, one per line, to paste into Zoom\u{2019}s scope search")
        }
    }

    @ViewBuilder
    private var primary: some View {
        if working {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Working\u{2026}").font(.callout)
            }
            .fixedSize()
        } else if case .wait(let text)? = step?.cta {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize()
        } else if let label = step?.cta.buttonLabel {
            Button(label, action: onAct)
                .buttonStyle(.borderedProminent)
                .tint(Brand.buttonFill)
                .controlSize(.regular)
                .fixedSize()
        } else if let say = step?.cta.instruction {
            Text(say).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    private func iconButton(_ name: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).frame(width: 22, height: 22) }
            .buttonStyle(.borderless)
            .disabled(!enabled)
            .help(label)
            .accessibilityLabel(label)
    }
}
