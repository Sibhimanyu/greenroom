//
//  SessionFinishedCard.swift
//  Greenroom
//
//  The card over the main window once a class or a take has ended and its
//  recording is saved: what you can do with it next. Watch, Edit, Upload to
//  YouTube, Finder, Done. Styled as the editor's "Saved" card (owner,
//  2026-11-16), it replaces the island's upload question (the island shows
//  status only, with no buttons) and Home's "Last session" line.
//
import SwiftUI
import AppKit

struct SessionFinishedCard: View {
    @ObservedObject var coordinator: CoordinatorController
    let session: CoordinatorController.FinishedSession

    private func close() { coordinator.finishedSession = nil }

    /// Automatic mode is already uploading (signed in, Made for Kids
    /// answered), so it says so instead.
    private var uploadsOnItsOwn: Bool {
        coordinator.youtubeUploadMode == .automatic && coordinator.youtubeConnected && coordinator.youtubeMadeForKids != nil
    }

    /// Upload is always offered otherwise: the sheet has Upload in YouTube
    /// Studio, which needs no sign-in.
    private var offersUpload: Bool { !uploadsOnItsOwn }

    private var line: String {
        if uploadsOnItsOwn {
            return coordinator.youtubeUploadProgress != nil
                ? "It's in Sessions, and uploading to YouTube."
                : "It's in Sessions, and goes to YouTube on its own."
        }
        return "It's in Sessions, ready to watch, edit or share."
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Brand.green.opacity(0.15)).frame(width: 72, height: 72)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Brand.green)
                }
                Text("Saved \u{201C}\(session.title)\u{201D}")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        coordinator.mainPage = .detail(session.folder.path)
                        close()
                    } label: {
                        Label("Watch", systemImage: "play.fill")
                    }
                    Button {
                        coordinator.mainPage = .editor(session.folder.path)
                        close()
                    } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                    }
                    if offersUpload {
                        // Leaves this Mac: amber, not green (DESIGN.md).
                        Button {
                            close()
                            coordinator.presentYouTubeUpload(session.file, title: session.title)
                        } label: {
                            Label("Upload to YouTube\u{2026}", systemImage: "arrow.up.circle")
                                .foregroundStyle(Brand.netText)
                        }
                        .disabled(coordinator.youtubeUploadProgress != nil)
                        .help("Choose the title, visibility and audience, then upload. The file stays on this Mac either way.")
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([session.file])
                        close()
                    } label: {
                        Label("Finder", systemImage: "folder")
                    }
                    Button("Done") { close() }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.green)
                        .keyboardShortcut(.defaultAction)
                }
                // Esc closes it, like Done.
                Button("") { close() }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .padding(30)
            .frame(maxWidth: 560)
            .greenroomGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Saved \(session.title)")
        }
        .transition(.opacity)
    }
}
