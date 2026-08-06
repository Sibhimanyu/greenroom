//
//  ContentView.swift
//  Greenroom
//
//  One decision, one button: pick "New Meeting" or "Join Existing", hit
//  Start, and the whole session cascades - OBS virtual camera, Zoom into
//  the meeting, Chrome tiled to its side of the screen, chat window tiled
//  to the other. Individual pieces remain available under "Manual
//  controls" for debugging; configuration lives in Settings (⌘,).
//
import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @Environment(\.openSettings) private var openSettings

    private var startDisabled: Bool {
        if coordinator.isRunning { return true }
        switch coordinator.meetingMode {
        case .create: return coordinator.s2sAccountID.isEmpty || coordinator.s2sClientID.isEmpty
        case .join: return coordinator.meetingNumber.isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            meetingSection

            HStack(spacing: 10) {
                Button {
                    coordinator.start()
                } label: {
                    Label(coordinator.isRunning ? "Starting\u{2026}" : "Start", systemImage: "play.fill")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(startDisabled)

                Button("Stop") {
                    coordinator.stop()
                }
                .controlSize(.large)

                Spacer()

                Button {
                    coordinator.toggleRecording()
                } label: {
                    Label(coordinator.isRecording ? "Stop Recording" : "Record",
                          systemImage: coordinator.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .controlSize(.large)
                .tint(coordinator.isRecording ? .red : nil)
            }

            manualControls

            Divider()

            statusSection
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 480)
        .sheet(isPresented: $coordinator.showOnboarding) {
            OnboardingView()
                .environmentObject(coordinator)
        }
    }

    /// The brand's leaf green (#5FA83C) - matches the "Control Flow"
    /// lockup in Branding/greenroom-logo.png and the generated app icon.
    private static let brandGreen = Color(red: 0.373, green: 0.659, blue: 0.235)

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 14) {
                    Image("LogoMark")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 64)
                    // Two-tone wordmark, as in the logo: "Green" bright,
                    // "room" in the label color so it works on both themes.
                    (Text("Green").foregroundColor(Self.brandGreen) + Text("room"))
                        .font(.system(size: 40, weight: .bold))
                }
                Text("One click: virtual camera on, Zoom in the meeting, your main app and chat tiled side by side.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 14) {
                Button {
                    coordinator.presentOnboarding()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("Setup guide")

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
    }

    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $coordinator.meetingMode) {
                ForEach(MeetingMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch coordinator.meetingMode {
            case .create:
                if coordinator.s2sAccountID.isEmpty || coordinator.s2sClientID.isEmpty {
                    Text("Needs the Start Meeting credentials \u{2014} add them in Settings (\u{2318},).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Start creates a fresh meeting under your Zoom account and opens it as host.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .join:
                HStack {
                    Button {
                        coordinator.fillMeetingFromClipboard()
                    } label: {
                        Label("Paste Link", systemImage: "doc.on.clipboard")
                    }
                    TextField("Meeting ID", text: $coordinator.meetingNumber)
                    TextField("Passcode (optional)", text: $coordinator.meetingPassword)
                }
            }
        }
    }

    /// The pieces of the session as individual actions - out of the way,
    /// but there when one piece needs re-running without the rest.
    private var manualControls: some View {
        DisclosureGroup("Manual controls") {
            HStack(spacing: 10) {
                Button("Open Chat Window") { coordinator.joinChatOnly() }
                    .disabled(coordinator.isConnectingChat || coordinator.meetingNumber.isEmpty)
                Button("Open \(coordinator.mainAppDisplayName) Window") { coordinator.openMainAppWindow() }
                Button("Just open Zoom") { coordinator.launchZoom() }
            }
            .padding(.top, 8)
        }
        .font(.callout)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(coordinator.statusLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
