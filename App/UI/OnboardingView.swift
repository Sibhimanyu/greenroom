//
//  OnboardingView.swift
//  Greenroom
//
//  First-launch setup wizard - walks a fresh user through everything the
//  READMEs know the hard way: the two external installs, credentials (via
//  the settings-file import fast path), and the permission prompts macOS
//  will throw at them. Detects live state wherever possible (OBS/Zoom
//  installed, credentials present, Accessibility granted) instead of just
//  instructing. Reopenable anytime from the main window's ? button.
//
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var step = 0
    @State private var refreshTick = 0 // bumped by a timer so detected state stays live

    private let stepCount = 5
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(28)

            Divider()

            footer
                .padding(16)
        }
        .frame(width: 560, height: 540)
        .onReceive(timer) { _ in refreshTick += 1 }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0: welcomeStep
        case 1: essentialsStep
        case 2: credentialsStep
        case 3: permissionsStep
        default: readyStep
        }
    }

    // MARK: Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.top, 12)
            Text("Welcome to Greenroom").font(.largeTitle.bold())
            Text("Your whole meeting setup, one click.")
                .font(.title3)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Label("A virtual camera showing your screen with you keyed into a bubble", systemImage: "web.camera")
                Label("Starts a fresh Zoom meeting as host, or joins one from a link", systemImage: "video.badge.plus")
                Label("Chrome and the meeting chat tiled neatly side by side", systemImage: "rectangle.split.2x1")
                Label("Stop tears the whole thing down again", systemImage: "stop.circle")
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private var essentialsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("The essentials", "Two free apps do the heavy lifting. Both are one-time installs.")

            StatusRow(
                ok: OBSProcessManager.obsAppURL != nil,
                title: "OBS Studio",
                detail: OBSProcessManager.obsAppURL != nil
                    ? "Installed \u{2014} Greenroom configures it automatically, nothing to set up."
                    : "Not found. Install it, then come back \u{2014} this row updates by itself.",
                actionTitle: OBSProcessManager.obsAppURL == nil ? "Download OBS" : nil
            ) {
                NSWorkspace.shared.open(URL(string: "https://obsproject.com")!)
            }

            StatusRow(
                ok: ZoomLauncher.isInstalled,
                title: "Zoom",
                detail: ZoomLauncher.isInstalled
                    ? "Installed."
                    : "Not found. Install the Zoom desktop app.",
                actionTitle: ZoomLauncher.isInstalled ? nil : "Download Zoom"
            ) {
                NSWorkspace.shared.open(URL(string: "https://zoom.us/download")!)
            }

            Text("A fresh OBS install may show its own setup wizard on first launch \u{2014} it can simply be cancelled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Zoom credentials", "Greenroom's meeting features run on Zoom Marketplace app credentials.")

            HStack {
                Button {
                    importSettingsFile()
                } label: {
                    Label("Import Settings File\u{2026}", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)

                Text("Got a file from a teammate? This fills in everything at once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            StatusRow(
                ok: !coordinator.sdkClientID.isEmpty,
                title: "Meeting chat credentials",
                detail: coordinator.sdkClientID.isEmpty
                    ? "Missing \u{2014} powers the side-by-side chat window."
                    : "Configured.",
                actionTitle: nil, action: {}
            )

            StatusRow(
                ok: !coordinator.s2sAccountID.isEmpty && !coordinator.s2sClientID.isEmpty,
                title: "Start-meeting credentials (optional)",
                detail: coordinator.s2sAccountID.isEmpty
                    ? "Missing \u{2014} powers one-click \u{201C}New Meeting\u{201D}. Joining existing meetings works without it."
                    : "Configured.",
                actionTitle: nil, action: {}
            )

            Divider()

            Text("Setting up from scratch instead? Create the apps at marketplace.zoom.us \u{2014} the exact steps live under each field in Settings (\u{2318},), Meeting Chat and Start Meeting tabs.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Zoom Marketplace") {
                NSWorkspace.shared.open(URL(string: "https://marketplace.zoom.us")!)
            }
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepHeader("Permissions", "macOS will ask a few one-time questions. Here's what to expect and why.")

            StatusRow(
                ok: ZoomWindowManager.hasAccessibilityPermission,
                title: "Accessibility",
                detail: ZoomWindowManager.hasAccessibilityPermission
                    ? "Granted \u{2014} Zoom's window gets tiled automatically."
                    : "Needed to tile Zoom's window into the layout. Grant it now to avoid a mid-meeting prompt.",
                actionTitle: ZoomWindowManager.hasAccessibilityPermission ? nil : "Grant\u{2026}"
            ) {
                ZoomWindowManager.promptForAccessibilityPermission()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Screen Recording \u{2014} OBS asks on the first Start (it captures your screen)", systemImage: "rectangle.dashed.badge.record")
                Label("Camera & Microphone \u{2014} asked on the first chat connection", systemImage: "camera")
                Label("Google Chrome automation \u{2014} asked when the Chrome window is first tiled", systemImage: "globe")
                Label("Keychain \u{2014} if asked, always click \u{201C}Always Allow\u{201D}, never plain \u{201C}Allow\u{201D}", systemImage: "key")
            }
            .font(.callout)

            Text("Each appears exactly once if approved \u{2014} approving them all makes every later Start silent.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .padding(.top, 12)
            Text("One last thing").font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 12) {
                Text("The first time you're in a Zoom meeting, open Zoom's **Settings \u{2192} Video** and pick **\u{201C}OBS Virtual Camera\u{201D}**. Zoom remembers it for every call after that \u{2014} it's the only manual step this app can't do for you.")
                Text("Then it's: pick **New Meeting** or **Join Existing**, hit **Start**, and everything falls into place.")
                Text("Reopen this guide anytime with the **?** button on the main window.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Shared pieces

    private func stepHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") { step -= 1 }
                .disabled(step == 0)

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            if step < stepCount - 1 {
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Get Started") { coordinator.completeOnboarding() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func importSettingsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? coordinator.importSettings(from: Data(contentsOf: url))
    }
}

/// One detected-state row: a live check/warning icon, what it means, and
/// (when something's missing) the button that fixes it.
private struct StatusRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle, action: action)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
