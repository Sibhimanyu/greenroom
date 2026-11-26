//
//  ZoomSignInSection.swift
//  Greenroom
//
//  The "Sign in with Zoom" block shared by Settings -> Zoom and the setup
//  guide's Zoom step, and the folding "Use your own Zoom apps (advanced)" row.
//  Plain values and closures only, so it renders off screen with sample data;
//  `ZoomSignInSection.live` feeds it from the coordinator.
//
import SwiftUI

struct ZoomSignInInfo: Equatable {
    var name: String
    var email: String

    /// "Name · email", or whichever half exists.
    var line: String { [name, email].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ") }
}

struct ZoomSignInSection: View {
    let signedIn: ZoomSignInInfo?
    let signingIn: Bool
    /// Plain-words reason the last attempt did not finish.
    let error: String?
    /// "Sign in with Zoom isn't finished setting up", when that is the state.
    let setupNote: String?
    /// Signed in, but a newly required Zoom permission is missing.
    var needsMorePermission = false
    var attentionTitle = ZoomScopeCheck.promptTitle
    var attentionDetail = ZoomScopeCheck.promptDetail
    /// "Check sign-in" under Signed in as (nil hides it, e.g. in an off-screen render).
    var check: ZoomSignInCheckRow? = nil
    let onSignIn: () -> Void
    let onCancel: () -> Void
    /// Returns true when Zoom confirmed the revoke, false when only the local copy was removed.
    let onSignOut: () async -> Bool

    @State private var signOutNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let signedIn {
                HStack(spacing: 12) {
                    Label("Signed in as \(signedIn.line)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Brand.text)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Sign out") {
                        Task {
                            let revoked = await onSignOut()
                            signOutNote = revoked ? nil : "Signed out here. Zoom did not confirm the revoke, so the app is still listed in your Zoom account\u{2019}s connected apps."
                        }
                    }
                }
                if let check { check }
                if let setupNote { StatusBadge(text: setupNote, tone: .problem) }
                if needsMorePermission {
                    VStack(alignment: .leading, spacing: 6) {
                        StatusBadge(text: attentionTitle, tone: .waiting)
                        Text(attentionDetail).font(.caption).foregroundStyle(.secondary)
                        Button("Sign in again", action: onSignIn)
                    }
                }
            } else if signingIn {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Zoom in your browser\u{2026}")
                    Spacer(minLength: 8)
                    Button("Cancel", action: onCancel)
                }
            } else {
                HStack(spacing: 12) {
                    Button(action: onSignIn) {
                        Label("Sign in with Zoom", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.buttonFill)
                    Text("Opens your browser. Greenroom never sees your Zoom password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error, signedIn == nil || !signingIn { StatusBadge(text: error, tone: .problem) }
            if let signOutNote, signedIn == nil {
                Text(signOutNote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension ZoomSignInSection {
    /// Fed from the coordinator.
    @MainActor
    static func live(_ coordinator: CoordinatorController) -> ZoomSignInSection {
        ZoomSignInSection(
            signedIn: coordinator.zoomSignedInAs.map { ZoomSignInInfo(name: $0.name, email: $0.email) },
            signingIn: coordinator.zoomSigningIn,
            error: coordinator.zoomSignInError,
            setupNote: coordinator.zoomSDKAuthChoice == .notFinished ? "Sign in with Zoom isn\u{2019}t finished setting up yet." : nil,
            needsMorePermission: coordinator.zoomNeedsMorePermission,
            attentionTitle: coordinator.zoomAttentionTitle,
            attentionDetail: coordinator.zoomAttentionDetail,
            check: ZoomSignInCheckRow(checker: coordinator.zoomSignInChecker, onRun: { coordinator.checkZoomSignIn() }),
            onSignIn: { coordinator.signInWithZoom() },
            onCancel: { coordinator.cancelZoomSignIn() },
            onSignOut: { await coordinator.signOutOfZoom() })
    }
}

/// A row that folds its content away with the settings animation (250 ms
/// snappy, instant under Reduce Motion).
struct AdvancedDisclosure<Content: View>: View {
    let title: String
    /// Set to true from outside (the failure card's Open Settings) to unfold it; reset once done.
    var openRequest: Binding<Bool>?
    @State private var open: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let content: Content

    init(_ title: String, open: Bool = false, openRequest: Binding<Bool>? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.openRequest = openRequest
        _open = State(initialValue: open)
        self.content = content()
    }

    private var anim: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(anim) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(title)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .clipped()
        .onAppear { honourRequest() }
        .onChange(of: openRequest?.wrappedValue ?? false) { _, _ in honourRequest() }
    }

    private func honourRequest() {
        guard let openRequest, openRequest.wrappedValue else { return }
        withAnimation(anim) { open = true }
        openRequest.wrappedValue = false
    }
}
