//
//  RecordStudioView.swift
//  Greenroom
//
//  Home -> Record -> Get Ready: the room before the tape rolls.
//
//  Record used to start the tape the moment it was pressed, which left no
//  chance to look at the picture, fix the camera or name the take. Now the
//  main button only gets the picture ready and opens this view: the live
//  picture large, the few controls that change it, the name and notes, and a
//  big Record button for when you are.
//
//  Nothing here is new logic. The picture is the Webcam page's picture, fed
//  by the same compositor and the same preview feed, and each control is the
//  Webcam page's own piece (LookPicker, ShareKindPicker, the camera and
//  microphone sections) calling the same `requestShapeApply`. Settings ->
//  Webcam can be open at the same time and shows the same picture.
//
//  `RecordStudioContent` takes plain values and closures, not the coordinator,
//  so it can be rendered off screen with sample values. `RecordStudioView` is
//  the thin layer that feeds it.
//
import AppKit
import SwiftUI

// MARK: - Fed from the coordinator

struct RecordStudioView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @StateObject private var meter = MicLevelMonitor()
    @State private var displays: [DisplayInfo] = DisplayResolver.connectedDisplays()
    @State private var screenAllowed = StageCompositor.screenRecordingGranted

    /// The window is this tall while the view is up: the picture, a pane of
    /// controls that scrolls, and the pinned row of name and Record.
    static let windowHeight: CGFloat = 780

    var body: some View {
        RecordStudioContent(
            name: $coordinator.className,
            folderPreview: folderPreview,
            opening: coordinator.startingRecordOnly && !coordinator.recordOnlyActive,
            isRecording: coordinator.isRecording,
            recordingStartedAt: coordinator.recordingStartedAt,
            busy: coordinator.takeBusy || coordinator.isStopping,
            saving: coordinator.isSavingRecording,
            notice: screenNotice,
            previewAspect: coordinator.shapePreviewAspect,
            cameraSeesYou: coordinator.cameraSeesYou || !coordinator.webcamShape.usesChromaKey,
            cameraOff: coordinator.cameraIsOff,
            shape: Binding(get: { coordinator.webcamShape },
                           set: { coordinator.webcamShape = $0; coordinator.requestShapeApply() }),
            removal: coordinator.backgroundRemoval,
            shareKind: $coordinator.shareTarget.kind,
            // Only when the meter is reading the input the recording takes:
            // it listens to the system's, so a pinned microphone is not it.
            micLevel: coordinator.micDeviceUID.isEmpty && meter.isRunning ? meter.level : nil,
            record: { coordinator.isRecording ? coordinator.stopTake() : coordinator.startTake() },
            done: { coordinator.confirmAndCloseRecordStudio() },
            openScreenRecordingPane: Self.openScreenRecordingPane,
            livePicture: { LiveCompositePicture(feed: coordinator.shapePreview) },
            shareDetail: {
                ShareTargetSettings(displays: displays,
                                    onChange: { coordinator.requestShapeApply(rebuild: true) })
            },
            cameras: { CameraSwitchSection() },
            microphone: { MicrophoneSection() },
            notes: { SessionNotesToggle() })
        .onAppear {
            displays = DisplayResolver.connectedDisplays()
            screenAllowed = StageCompositor.screenRecordingGranted
            meter.start()
        }
        .onDisappear { meter.stop() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            screenAllowed = StageCompositor.screenRecordingGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayResolver.connectedDisplays()
        }
    }

    /// The folder this take will go into, shown as you type, as on Home.
    private var folderPreview: String {
        if let live = coordinator.sessionFolder { return live.lastPathComponent }
        return SessionFolders.sessionFolderName(className: coordinator.className, started: Date(),
                                                fallback: "Recording")
    }

    /// One plain line, only while the screen is wanted and macOS has not
    /// allowed it. The picture is the camera alone until it does.
    private var screenNotice: String? {
        guard coordinator.shareTarget.kind != .nothing, !screenAllowed else { return nil }
        return "Screen Recording is off, so the preview shows your camera only. Turn Greenroom on in System Settings \u{2192} Privacy & Security \u{2192} Screen Recording, then reopen it."
    }

    private static func openScreenRecordingPane() {
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(pane)
        }
    }
}

// MARK: - The view

struct RecordStudioContent<LivePicture: View, ShareDetail: View, Cameras: View, Microphone: View, Notes: View>: View {
    @Binding var name: String
    let folderPreview: String
    /// The picture is still opening: nothing to show yet.
    let opening: Bool
    let isRecording: Bool
    let recordingStartedAt: Date?
    /// A take is starting or finishing, or the view is closing.
    let busy: Bool
    /// The take has stopped and its file is still closing: the button reads
    /// "Saving\u{2026}" and cannot be pressed.
    var saving = false
    /// One line above the picture, or nil.
    let notice: String?
    /// The live picture's size, or nil before the first frame.
    let previewAspect: CGSize?
    var cameraSeesYou = true
    var cameraOff = false
    @Binding var shape: WebcamShape
    let removal: BackgroundRemoval
    @Binding var shareKind: ShareTarget.Kind
    /// 0...1, or nil when there is no meter to show.
    let micLevel: Double?
    let record: () -> Void
    let done: () -> Void
    let openScreenRecordingPane: () -> Void
    @ViewBuilder let livePicture: () -> LivePicture
    @ViewBuilder let shareDetail: () -> ShareDetail
    @ViewBuilder let cameras: () -> Cameras
    @ViewBuilder let microphone: () -> Microphone
    @ViewBuilder let notes: () -> Notes

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            topBar
            if let notice { noticeLine(notice) }
            stage
            controls
            Divider()
            bottomBar
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Record")
                .font(.title2.weight(.bold))
                .foregroundStyle(Brand.name)
            Text(folderPreview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("The folder this recording will be saved in.")
            Spacer(minLength: 16)
            Button(action: done) {
                Label("Done", systemImage: "xmark")
            }
            .controlSize(.large)
            .disabled(busy)
            .help(isRecording
                  ? "Asks first, then stops and saves the recording and turns the camera off."
                  : "Turns the camera off and goes back to Home.")
        }
    }

    private func noticeLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Open Settings", action: openScreenRecordingPane)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }

    // MARK: Picture

    private var canvasAspect: CGSize { previewAspect ?? CGSize(width: 16, height: 10) }

    /// Exactly what will be recorded. The red outline and the REC chip are the
    /// recording indicator; both sit on the picture's own rect, not the box.
    private var stage: some View {
        GeometryReader { box in
            let canvas = WebcamShapePreview.fittedCanvas(in: box.size, aspect: canvasAspect)
            ZStack(alignment: .topLeading) {
                Group {
                    if previewAspect == nil {
                        waiting
                    } else {
                        livePicture()
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .offset(x: canvas.minX, y: canvas.minY)

                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.red, lineWidth: 3)
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(x: canvas.minX, y: canvas.minY)
                    .opacity(isRecording ? 1 : 0)

                HStack(spacing: 6) {
                    chip
                    if previewAspect != nil, !cameraSeesYou { PictureChip(text: "Can\u{2019}t see you", symbol: "eye.slash") }
                }
                .offset(x: canvas.minX + 10, y: canvas.minY + 10)
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 300)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview of what will be recorded")
    }

    /// Names the step rather than just spinning (DESIGN.md, Waiting states).
    private var waiting: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.82))
            VStack(spacing: 10) {
                if opening {
                    ProgressView().controlSize(.small).colorScheme(.dark)
                } else {
                    Image(systemName: "video.slash").font(.title2)
                }
                Text(opening ? "Opening the camera\u{2026}" : "Waiting for a picture\u{2026}")
                    .font(.callout)
            }
            .foregroundStyle(Color.white.opacity(0.75))
        }
    }

    @ViewBuilder private var chip: some View {
        if isRecording {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PictureChip(text: "REC  \(Self.clock(from: recordingStartedAt, to: context.date))",
                            dot: Color.red)
            }
        } else {
            PictureChip(text: "READY", dot: Brand.green)
                .help("This is the picture that will be recorded. Nothing is being saved yet.")
        }
    }

    // MARK: Controls

    /// The Webcam page's own pieces, in its own form, so they look and behave
    /// as they do there. Scrolls when the window is short.
    private var controls: some View {
        Form {
            Section("Look") {
                LookPicker(selection: $shape, removal: removal)
            }
            Section("Behind you") {
                ShareKindPicker(selection: $shareKind, nothingAllowed: !cameraOff)
                shareDetail()
            }
            Section("Camera") { cameras() }
            Section("Microphone") {
                microphone()
                if let micLevel { MicMeter(level: micLevel) }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 160, maxHeight: .infinity)
    }

    // MARK: Bottom

    private var bottomBar: some View {
        HStack(spacing: 12) {
            TextField("Name this recording", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .disabled(isRecording || busy)
                .help("Names this recording\u{2019}s folder in Documents/Greenroom. Leave it empty and the folder is named by date and time instead.")
            notes()
            Spacer(minLength: 16)
            if isRecording {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.clock(from: recordingStartedAt, to: context.date))
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            Button(action: record) {
                Label(saving ? "Saving\u{2026}" : isRecording ? "Stop" : "Record",
                      systemImage: saving ? "hourglass" : isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 120, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .tint(isRecording && !saving ? Color.red : Brand.green)
            .disabled(busy || opening || saving)
            .help(isRecording ? "Stops and saves the recording. The picture stays on for another."
                              : "Starts recording the picture above.")
        }
    }

    /// m:ss, or h:mm:ss past the hour.
    static func clock(from start: Date?, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start ?? now)))
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Pieces

/// The microphone's level, as a thin bar. The same reading the participants
/// panel shows (MicLevelMonitor), already smoothed and scaled.
private struct MicMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { box in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Brand.green)
                        .frame(width: max(6, box.size.width * level))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
        .help("What the system\u{2019}s microphone is hearing right now.")
    }
}
