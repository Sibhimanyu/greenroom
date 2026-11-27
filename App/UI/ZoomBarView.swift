//
//  ZoomBarView.swift
//  Greenroom
//
//  The Greenroom bar at the top of the Zoom window (spec R13), the one bar
//  above the web view. Left: the part, step and what to do. Then the contextual
//  button (Copy scopes, "set up" with a check, Sign in) and the primary button
//  (Next: <part>, Back to Greenroom). Right: Back, Forward, Reload, the Tips
//  toggle and a "..." menu with Open in Safari and (only when signed in) Sign
//  out of Zoom. Plain values and closures, so it renders off screen
//  (scripts/render/zoom-bar.sh). It is a plain stack, not an NSToolbar, so
//  nothing can fold into an overflow chevron; at the 900pt minimum width the
//  fixed parts (about 520pt with every button showing) leave the title the rest,
//  and it truncates at its tail.
//
import SwiftUI

struct ZoomBarView: View {
    let bar: ZoomBar
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
    var onPrimary: () -> Void = {}
    var onOpenInSafari: () -> Void = {}
    var onSignOut: () -> Void = {}

    static let height: CGFloat = 44

    var body: some View {
        HStack(spacing: 10) {
            Text(bar.title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(address.isEmpty ? bar.title : address)
            if loadFailed {
                Text("Couldn\u{2019}t load this page.")
                    .font(.caption).foregroundStyle(Brand.netText).lineLimit(1).fixedSize()
            }
            context
            primary
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
                if bar.offersSignOut {
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
        switch bar.context {
        case .none:
            EmptyView()
        case .copyScopes:
            Button(action: onCopyScopes) {
                Label(copied ? "Copied" : "Copy scopes", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
            .fixedSize()
            .help("Copy all \(ZoomScopes.count) scopes, one per line, to paste into Zoom\u{2019}s scope search")
        case .setUp(let text):
            Label {
                Text(text).font(.callout)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
            }
            .lineLimit(1)
            .fixedSize()
        case .signIn:
            Button(bar.context.title, action: onSignIn)
                .controlSize(.small)
                .fixedSize()
                .help("Opens Zoom Marketplace, which asks you to sign in")
        }
    }

    @ViewBuilder
    private var primary: some View {
        if bar.primary != .none {
            Button(bar.primary.title, action: onPrimary)
                .buttonStyle(.borderedProminent)
                .tint(Brand.buttonFill)
                .controlSize(.regular)
                .fixedSize()
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
