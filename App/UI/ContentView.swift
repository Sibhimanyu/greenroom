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
    @State private var showRecordings = false
    @State private var showSavePreset = false
    @State private var presetNameDraft = ""

    /// Start is for starting: disabled while a start is in flight AND
    /// while the session is live (Stop first, then Start - pressing Start
    /// mid-session used to happily build a second meeting on top).
    private var startDisabled: Bool {
        if coordinator.isRunning || coordinator.virtualCamActive || coordinator.isStopping { return true }
        switch coordinator.meetingMode {
        case .create: return coordinator.s2sAccountID.isEmpty || coordinator.s2sClientID.isEmpty
        case .join: return coordinator.meetingNumberDigits.isEmpty
        }
    }

    /// Says what it does: which meeting action Start performs depends on
    /// the mode picker right above it.
    private var startLabel: String {
        if coordinator.isRunning { return "Starting\u{2026}" }
        if coordinator.virtualCamActive { return "In Session" }
        return coordinator.meetingMode == .create ? "Start Meeting" : "Join Meeting"
    }

    private var startHelp: String {
        coordinator.meetingMode == .create
            ? "Turns on the virtual camera, creates a fresh meeting under your Zoom account with you as host, and tiles your windows \u{2014} the whole session in one click."
            : "Turns on the virtual camera, joins the meeting above (starting it as host if it's yours), and tiles your windows."
    }

    /// Stop needs something to stop: a live session, or a start in
    /// flight (which it cancels at the next checkpoint).
    private var stopDisabled: Bool {
        coordinator.isStopping || (!coordinator.isRunning && !coordinator.virtualCamActive)
    }

    /// Recording needs a live OBS session - except when already
    /// recording, where the button must stay pressable to stop it.
    private var recordDisabled: Bool {
        !coordinator.virtualCamActive && !coordinator.isRecording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            meetingSection

            HStack(spacing: 10) {
                Button {
                    coordinator.start()
                } label: {
                    Label(startLabel, systemImage: "play.fill")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(startDisabled)
                .help(startHelp)

                Button(coordinator.isStopping ? "Ending\u{2026}" : "End Session") {
                    coordinator.confirmAndStop()
                }
                .controlSize(.large)
                .disabled(stopDisabled)
                .help("Ends the meeting for everyone when you're hosting (leaves it otherwise), closes the chat window, and stops the camera and OBS. Ending the meeting from the Zoom window does the same \u{2014} both roads end the whole session.")

                Spacer()

                Button {
                    coordinator.toggleRecording()
                } label: {
                    Label(coordinator.isRecording ? "Stop Recording" : "Record",
                          systemImage: coordinator.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .controlSize(.large)
                .tint(coordinator.isRecording ? .red : nil)
                .disabled(recordDisabled)
                .help("Records exactly what participants see \u{2014} your shared screen with you in it. Saved to Documents/Greenroom when stopped.")

                Button {
                    showRecordings = true
                } label: {
                    Label("Recordings", systemImage: "film.stack")
                }
                .controlSize(.large)
                .help("Review past recordings \u{2014} play them right here, or jump to the file in Finder.")
            }

            Divider()

            manualControls

            statusSection

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 580, minHeight: 460)
        .sheet(isPresented: $coordinator.showOnboarding) {
            OnboardingView()
                .environmentObject(coordinator)
        }
        .sheet(isPresented: $showRecordings) {
            RecordingsView()
        }
    }

    /// The brand's leaf green (#5FA83C) - matches the "Control Flow"
    /// lockup in Branding/greenroom-logo.png and the generated app icon.
    private static let brandGreen = Color(red: 0.373, green: 0.659, blue: 0.235)

    /// One compact row: logo + two-tone wordmark with the tagline
    /// UNDER the wordmark (not under the logo), so everything shares one
    /// leading edge; window controls vertically centered on the row.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("LogoMark")
                .resizable()
                .scaledToFit()
                .frame(height: 46)
            VStack(alignment: .leading, spacing: 2) {
                // Two-tone wordmark, as in the logo: "Green" bright,
                // "room" in the label color so it works on both themes.
                (Text("Green").foregroundColor(Self.brandGreen) + Text("room"))
                    .font(.system(size: 27, weight: .bold))
                Text("One click: camera on, Zoom in the meeting, your windows tiled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            HStack(spacing: 12) {
                Button {
                    coordinator.presentOnboarding()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Setup guide")

                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(.secondary)
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
                // Two aligned rows instead of one crammed line: the
                // fields get room to breathe, the fill-from sources sit
                // together beneath them.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Meeting ID", text: $coordinator.meetingNumber)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 170)
                        TextField("Passcode (optional)", text: $coordinator.meetingPassword)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 130)
                    }
                    HStack(spacing: 8) {
                        presetsMenu
                        scheduledMeetingsMenu
                        Button {
                            coordinator.fillMeetingFromClipboard()
                        } label: {
                            Label("Paste Link", systemImage: "doc.on.clipboard")
                        }
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                }
                .onAppear {
                    // Pre-fetch so the menu is ready by the time it's
                    // opened - skipped silently when credentials or a
                    // read scope are missing (refresh logs the reason).
                    if coordinator.scheduledMeetings.isEmpty && !coordinator.s2sAccountID.isEmpty {
                        coordinator.refreshScheduledMeetings()
                    }
                }
            }
        }
    }

    /// The account's scheduled/recurring meetings, one click to fill the
    /// Join fields - the daily-class flow: schedule a recurring meeting
    /// once at zoom.us, then it's always right here.
    /// Saved meeting shortcuts: click one to fill the ID + passcode, or
    /// save the current fields as a new preset. Delete via each preset's
    /// context menu (right-click). Mirrors the Scheduled menu's pattern.
    private var presetsMenu: some View {
        Menu {
            if coordinator.meetingPresets.isEmpty {
                Text("No saved presets")
            } else {
                ForEach(coordinator.meetingPresets) { preset in
                    Button("\(preset.name) \u{2014} \(preset.number)") {
                        coordinator.applyPreset(preset)
                    }
                }
            }
            Divider()
            Button("Save current as preset\u{2026}") { showSavePreset = true }
                .disabled(coordinator.meetingNumberDigits.isEmpty)
            if !coordinator.meetingPresets.isEmpty {
                Menu("Delete preset") {
                    ForEach(coordinator.meetingPresets) { preset in
                        Button("\(preset.name) \u{2014} \(preset.number)", role: .destructive) {
                            coordinator.deletePreset(preset)
                        }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "bookmark")
        }
        .fixedSize()
        .alert("Save meeting preset", isPresented: $showSavePreset) {
            TextField("Name (e.g. Morning class)", text: $presetNameDraft)
            Button("Save") {
                coordinator.saveCurrentAsPreset(name: presetNameDraft)
                presetNameDraft = ""
            }
            Button("Cancel", role: .cancel) { presetNameDraft = "" }
        } message: {
            Text("Saves the meeting ID \(coordinator.meetingNumberDigits) and its passcode for one-click filling later.")
        }
    }

    private var scheduledMeetingsMenu: some View {
        Menu {
            if coordinator.scheduledMeetings.isEmpty {
                Text(coordinator.isLoadingScheduled ? "Loading\u{2026}" : "No scheduled meetings found")
            } else {
                ForEach(coordinator.scheduledMeetings) { meeting in
                    Button(scheduledMeetingLabel(meeting)) {
                        coordinator.selectScheduledMeeting(meeting)
                    }
                }
            }
            Divider()
            Button("Refresh") { coordinator.refreshScheduledMeetings() }
        } label: {
            Label("Scheduled", systemImage: "calendar")
        }
        .fixedSize()
    }

    /// Recurring meetings' times come from the per-meeting details call
    /// (their real next occurrence) - never from the list endpoint, whose
    /// recurring timestamps are the series' original anchor (confirmed
    /// live: a daily 4 PM class listed a months-old date). No time means
    /// "no fixed time", no upcoming occurrence, or a missing details
    /// scope (the status log explains that one).
    private func scheduledMeetingLabel(_ meeting: ZoomServerToServerClient.ScheduledMeeting) -> String {
        let when = meeting.startTime?.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        switch (meeting.isRecurring, when) {
        case (true, let when?): return "\(meeting.topic) \u{2014} recurring, next \(when)"
        case (true, nil): return "\(meeting.topic) \u{2014} recurring"
        case (false, let when?): return "\(meeting.topic) \u{2014} \(when)"
        case (false, nil): return meeting.topic
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

    /// Collapsed by default, like Manual controls: the log is diagnostic
    /// detail, not something to read every session - open it when
    /// something needs explaining.
    private var statusSection: some View {
        DisclosureGroup("Status") {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(coordinator.statusLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .padding(.top, 6)
        }
        .font(.callout)
    }
}
