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
    @Environment(\.openWindow) private var openWindow
    @State private var showSavePreset = false
    @State private var presetNameDraft = ""
    /// Hidden by default: the log is diagnostic detail, opened when something
    /// needs explaining. Not persisted - each launch starts compact.
    @State private var statusShown = false

    /// Start is for starting: disabled while a start is in flight AND
    /// while the session is live (Stop first, then Start - pressing Start
    /// mid-session used to happily build a second meeting on top).
    /// Centralized on the coordinator so the menu bar shares the SAME
    /// rules (it used to skip the credential/ID checks).
    private var startDisabled: Bool { coordinator.startActionDisabled }

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

    /// Names the session's folder, so a term of classes is not a wall of
    /// identical timestamps.
    ///
    /// Pre-filled from last time rather than asked for on every Start: the same
    /// class runs five mornings a week, and a dialog would spend a click a day
    /// on yesterday's answer. Shown BEFORE Start rather than after, so a wrong
    /// name is something you notice rather than something you discover in the
    /// folder afterwards.
    /// Two things, neither of which repeats the other.
    ///
    /// It was three: an eyebrow reading CLASS NAME, a placeholder reading
    /// "Class", and a preview reading "Class - 2026-09-19 08-53". The word
    /// "class" three times in one row, and a reader has to check all three to
    /// find the one that carries information.
    ///
    /// Now the placeholder says what to DO and the preview says what you will
    /// GET. The eyebrow went: a field that says "Name this class" does not
    /// also need a label saying CLASS NAME.
    @ViewBuilder private var classNameField: some View {
        HStack(spacing: 10) {
            TextField("Name this class", text: $coordinator.className)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .disabled(coordinator.isRunning || coordinator.virtualCamActive)
                .help("Names this session's folder in Documents/Greenroom. Leave it empty and the folder is named by date and time instead.")
            Text(folderPreview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("The folder this session will be saved in.")
        }
    }

    /// The folder the next Start will create, shown as you type. Cheaper than
    /// explaining the naming rule in prose, and it makes the timestamp fallback
    /// obvious the moment the field is empty.
    private var folderPreview: String {
        if let live = coordinator.sessionFolder { return live.lastPathComponent }
        return GreenroomScene.sessionFolderName(className: coordinator.className, started: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            meetingSection

            classNameField

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
                    openWindow(id: "sessions")
                } label: {
                    Label("Sessions", systemImage: "film.stack")
                }
                .controlSize(.large)
                .help("Every past class: its recordings and clips with a player, its YouTube links, and a name you can change.")

                // Screenroom lives beside Sessions rather than beside Start: it is
                // not a step in the session cascade, it is a second thing this
                // app does. Held out of the build entirely until it is ready
                // (see ScreenroomAvailability).
                if ScreenroomAvailability.isReleased {
                    Button {
                        openWindow(id: "screenroom")
                    } label: {
                        Label("Screenroom", systemImage: "text.badge.star")
                    }
                    .controlSize(.large)
                    .help("Evaluate a presentation: record the speaker and take notes timed to the recording.")
                }
            }

            Divider()

            bottomBar

            if statusShown {
                statusLog
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: Self.minimumWindowWidth, minHeight: preferredWindowHeight)
        // The window OPENS at the preferred size every time, regardless
        // of the size it was closed at (explicit request) - SwiftUI
        // persists scene geometry across launches and defaultSize only
        // covers the first-ever open, so the size is asserted on appear.
        .onAppear {
            DispatchQueue.main.async { resizeWindow(animated: false) }
        }
        // The two things that change the window's height. Both grow it
        // DOWNWARD from an anchored top edge, so nothing above the divider
        // moves - see resizeWindow.
        .onChange(of: statusShown) { _, _ in resizeWindow(animated: true) }
        .onChange(of: coordinator.meetingMode) { _, _ in resizeWindow(animated: true) }
        .sheet(isPresented: $coordinator.showOnboarding) {
            OnboardingView()
                .environmentObject(coordinator)
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
                .frame(height: 88)
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

    /// The window's height for the current state: the controls, plus Join's
    /// two extra rows, plus the log when it is shown. Measured from the
    /// accessibility tree rather than guessed, on the 4px scale.
    private var preferredWindowHeight: CGFloat {
        // 356, not 372: the class-name row lost its eyebrow and the 4pt above
        // it, which is ~19pt of content. A height measured for a layout that
        // changed is 19pt of dead space at the bottom of the window.
        var height: CGFloat = 356
        if coordinator.meetingMode == .join { height += 64 }
        if statusShown { height += Self.statusLogHeight + 12 }
        return height
    }

    /// The width the button row needs, and therefore the window's.
    ///
    /// Worked out from the row rather than chosen. Five bordered `.large`
    /// buttons at their LONGEST labels - "Stop Recording", not "Record", and
    /// Start's 130pt floor - plus four 10pt gaps, 20pt padding each side, and
    /// enough left for the Spacer to still read as a gap. That comes to
    /// 720pt; the row was clipping "Screenroom" at 620.
    ///
    /// Longest labels on purpose: a window sized for the idle state reflows
    /// the moment a recording starts, which is the one moment nothing on
    /// screen should move.
    ///
    /// Two values because the last button is not always there. Screenroom is
    /// held out of releases, and a shipping window should not carry 100pt of
    /// margin for a button nobody can see - so the released width is the one
    /// that has always been there.
    static var minimumWindowWidth: CGFloat { ScreenroomAvailability.isReleased ? 720 : 580 }

    /// What the window opens at: the minimum plus the 40pt of breathing room
    /// the original pair (580/620) already used.
    static var defaultWindowWidth: CGFloat { ScreenroomAvailability.isReleased ? 760 : 620 }

    /// Height of the open log. Eight lines.
    private static let statusLogHeight: CGFloat = 180

    /// Resizes from an anchored TOP edge. AppKit's `setContentSize` keeps the
    /// bottom-left corner, so every expansion used to send the whole window
    /// climbing the screen while the rows above reflowed (reported live:
    /// "that animation where everything moves up"). Holding the top edge means
    /// the controls stay exactly where the cursor left them and only the
    /// bottom edge travels - down when the log opens, up when it closes.
    /// Width is the user's.
    private func resizeWindow(animated: Bool) {
        guard let window = NSApp.windows.first(where: { $0.title == "Greenroom" }) else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let width = animated ? content.width : Self.defaultWindowWidth
        let target = NSRect(x: content.minX, y: content.maxY - preferredWindowHeight,
                            width: width, height: preferredWindowHeight)
        window.setFrame(window.frameRect(forContentRect: target), display: true, animate: animated)
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
                    Text("Needs the Server-to-Server credentials \u{2014} add them in Settings (\u{2318},) \u{2192} Zoom.")
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
                    // Visible labels, not placeholder-as-label: once
                    // filled, two bare fields were indistinguishable
                    // (Codex design audit #2).
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Meeting ID").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: $coordinator.meetingNumber, prompt: Text("e.g. 465 230 8563"))
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 170)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Passcode").font(.caption).foregroundStyle(.secondary)
                            TextField("", text: $coordinator.meetingPassword, prompt: Text("optional"))
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 130)
                        }
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
                    Button(preset.menuLabel) {
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
                        Button(preset.menuLabel, role: .destructive) {
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
    /// but there when one piece needs re-running without the rest. A
    /// pull-down, not a disclosure: three buttons that are used a few times a
    /// term do not deserve a row of the window, and a menu opens over the
    /// content instead of pushing it around.
    private var manualControlsMenu: some View {
        Menu {
            Button("Open Chat Window") { coordinator.joinChatOnly() }
                .disabled(coordinator.isConnectingChat || coordinator.meetingNumber.isEmpty)
            Button("Open \(coordinator.mainAppDisplayName) Window") { coordinator.openMainAppWindow() }
            Button("Just open Zoom") { coordinator.launchZoom() }
        } label: {
            Text("Manual controls")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("Each piece of the session on its own: the chat, the main app window, or Zoom.")
    }

    /// The row under the divider: the log's toggle on the left, the manual
    /// pull-down on the right. One fixed-height row in both states, so the
    /// only thing that changes when the log opens is what is below it.
    private var bottomBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                statusShown.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: statusShown ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Status")
                    // The count is a machine fact, so mono - and it is what says
                    // "something happened" while the log is closed.
                    if !coordinator.statusLines.isEmpty {
                        Text("\(coordinator.statusLines.count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.callout)
            .help(statusShown ? "Hide the status log" : "Show what each step did and why")
            .accessibilityLabel(statusShown ? "Hide status" : "Show status")

            Spacer()
            manualControlsMenu
        }
    }

    /// The log, when shown: a fixed 180pt box under the bar. Fixed, not
    /// flexible, so the window's growth is exactly the box - and the newest
    /// line is always the one in view.
    private var statusLog: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if coordinator.statusLines.isEmpty {
                    // An empty state, not dead space.
                    Text("Nothing yet. Start a session and each step shows up here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(coordinator.statusLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.callout)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.statusLogHeight)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)) // DESIGN.md radius-sm
            // Opening lands on the NEWEST line; while open, follow the tail.
            .onAppear { scrollToNewestStatus(proxy) }
            .onChange(of: coordinator.statusLines.count) { _, _ in
                scrollToNewestStatus(proxy)
            }
        }
    }

    private func scrollToNewestStatus(_ proxy: ScrollViewProxy) {
        guard let newest = coordinator.statusLines.indices.last else { return }
        // Next runloop pass, not this one: on expand the rows are created in
        // the same layout pass that runs this, and scrollTo cannot target a
        // row that does not exist yet.
        DispatchQueue.main.async {
            proxy.scrollTo(newest, anchor: .bottom)
        }
    }
}
