//
//  MarksWindow.swift
//  Greenroom
//
//  Marks' one surface: the person presenting on the left, the notes being
//  taken about them on the right.
//
//  The shape is the Classroom Console's, deliberately. That window settled on
//  media as the primary region with a fixed 320pt column of exceptions beside
//  it (docs/participant-window-redesign-plan.md), and the same argument holds
//  here for the same reason: the picture is what the evaluator is actually
//  watching, and a column that changes width as content arrives makes the
//  thing you are watching move. The column is fixed at the same 320pt so the
//  two windows read as one app.
//
//  The composer sits at the FOOT of the notes column rather than under the
//  video, because a note is written into the run of notes, not onto the
//  picture - and because that is the shape every person typing next to a
//  video already has in their hands.
//
import AVFoundation
import SwiftUI

struct MarksWindow: View {
    @StateObject private var marks = MarksController()
    @Environment(\.openWindow) private var openWindow

    /// Focus goes here and stays here. The evaluator's hands should never
    /// have to find the box again once the presentation has started.
    @FocusState private var composerFocused: Bool

    /// Matches LiveQueueLayout.width. Not imported from it: the two windows
    /// agree on a number, they do not share a layout.
    private static let notesWidth: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                stage
                Divider()
                notesColumn
                    .frame(width: Self.notesWidth)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .tint(Brand.green)
        .onAppear { marks.windowAppeared() }
        .onDisappear { marks.windowDisappeared() }
        .onChange(of: marks.recorder.isRecording) { _, recording in
            // The box takes focus the instant the tape rolls, so the first
            // note costs no click.
            if recording { composerFocused = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Marks")
                    .font(.system(size: 17, weight: .bold))
                Text("Notes while they present, timed to the tape.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 28)

            VStack(alignment: .leading, spacing: 4) {
                eyebrow("PRESENTER")
                TextField("Who is presenting", text: $marks.presenter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .disabled(marks.recorder.isRecording)
                    .help("Names this presentation's folder in Documents/Greenroom, next to the classes.")
            }

            Spacer(minLength: 16)

            if marks.recorder.isRecording {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    Text(marks.elapsedLabel)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                }
                .help("How long the recording has been running.")
            }

            if marks.recorder.isRecording {
                Button("Finish") { marks.finish() }
                    .controlSize(.large)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stops the recording and closes the file. Your notes stay on screen.")
            } else {
                Button {
                    marks.start()
                } label: {
                    Label("Start Presentation", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!marks.canStart)
                .help(marks.canStart
                      ? "Starts recording and opens the note box."
                      : "Name the presenter first, and wait for the camera.")
            }

            // The way through to the other half. Quiet, because during a
            // presentation it is the last thing the evaluator should be
            // looking at, and the presentation they just finished will be at
            // the top of that window's list anyway.
            Button {
                openWindow(id: "marks-review")
            } label: {
                Image(systemName: "list.bullet.rectangle")
            }
            .controlSize(.large)
            .help("Past presentations: the recording, the notes, the rubric and the report.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Stage - the person presenting

    private var stage: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black)
                CameraPreview(session: marks.recorder.session)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if !marks.recorder.isPreviewing {
                    // A control that is not ready says so (DESIGN.md).
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Opening the camera\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                if marks.cameras.count > 1 {
                    Picker("Camera", selection: $marks.cameraUID) {
                        ForEach(marks.cameras) { camera in
                            Text(camera.name).tag(camera.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .disabled(marks.recorder.isRecording)
                    .help(marks.recorder.isRecording
                          ? "The camera cannot change while the tape is rolling."
                          : "Which camera is pointed at the presenter.")
                }

                if let failure = marks.recorder.failure {
                    // The failure lands on the surface the evaluator was
                    // already watching, named where it happened.
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if let folder = marks.folder {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    } label: {
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("Show this presentation's folder in the Finder.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Notes

    private var notesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                eyebrow("NOTES")
                Spacer()
                if !marks.notes.isEmpty {
                    Text("\(marks.notes.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            notesList

            Divider()

            composer
        }
        .frame(maxHeight: .infinity)
    }

    private var notesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(marks.notes) { note in
                        noteRow(note).id(note.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            // Allowed motion: scroll-to-latest, as the chat window does.
            .onChange(of: marks.notes.count) { _, _ in
                guard let last = marks.notes.last else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .overlay {
                if marks.notes.isEmpty { emptyNotes }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func noteRow(_ note: MarksNote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.offsetLabel)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Brand.green)
            Text(note.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyNotes: some View {
        VStack(spacing: 6) {
            Text(marks.canTakeNotes ? "Nothing noted yet." : "No presentation running.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(marks.canTakeNotes
                 ? "Type what you see. Return files it."
                 : "Name the presenter and press Start Presentation.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The stamp the next note will carry, live. The evaluator can
                // see where it lands rather than having to trust it.
                Text(marks.canTakeNotes ? marks.draftOffsetLabel : "\u{2013}\u{2013}:\u{2013}\u{2013}")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(marks.draft.isEmpty
                                     ? AnyShapeStyle(.tertiary)
                                     : AnyShapeStyle(Brand.green))
                    .frame(width: 38, alignment: .leading)

                TextField(marks.canTakeNotes ? "What did you see?" : "Not recording",
                          text: $marks.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .disabled(!marks.canTakeNotes)
                    .onSubmit { marks.commitDraft() }
            }

            Text(marks.canTakeNotes
                 ? "Return files the note. It is stamped from your first keystroke."
                 : "Notes need a running presentation to point into.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(marks.canTakeNotes ? 1 : 0.55)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - The camera picture

/// AVFoundation's own preview layer, wrapped for SwiftUI.
///
/// A layer rather than sampling frames into an Image: the preview is the one
/// thing on this window that must not stutter while the evaluator types, and
/// AVCaptureVideoPreviewLayer renders on the window server's side of the
/// fence without the app touching a single frame.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewHost {
        let host = PreviewHost()
        host.session = session
        return host
    }

    func updateNSView(_ host: PreviewHost, context: Context) {
        host.session = session
    }

    final class PreviewHost: NSView {
        private let preview = AVCaptureVideoPreviewLayer()

        var session: AVCaptureSession? {
            didSet { preview.session = session }
        }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            // resizeAspect, never resizeAspectFill: this is a person standing
            // up and using their hands, and a fill crop takes the hands off
            // the sides of the frame - which is a thing the evaluator is
            // there to watch.
            preview.videoGravity = .resizeAspect
            layer?.addSublayer(preview)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            // A CALayer animates its own frame by default, so every live
            // resize would drag the picture a quarter-second behind the
            // window edge.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            preview.frame = bounds
            CATransaction.commit()
        }
    }
}
