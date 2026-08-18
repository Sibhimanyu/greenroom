//
//  RecordingsView.swift
//  Greenroom
//
//  In-app review of session recordings: lists everything in
//  ~/Documents/Greenroom (where GreenroomScene points OBS's recording
//  output) newest-first, with an AVKit player right there - no hunting
//  through Finder to check whether this morning's class captured
//  properly.
//
import SwiftUI
import AVKit

struct RecordingsView: View {
    @Environment(\.dismiss) private var dismiss

    struct Recording: Identifiable, Hashable {
        let url: URL
        let date: Date
        let sizeBytes: Int64
        var id: URL { url }

        var title: String {
            // Seconds included: two takes in the same minute were
            // indistinguishable (Codex design audit #14).
            date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().second())
        }
        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    @State private var recordings: [Recording] = []
    @State private var selection: Recording?
    @State private var player: AVPlayer?
    @State private var trashError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recordings").font(.title3.bold())
                Text(GreenroomScene.recordingsDirectory.path.replacingOccurrences(
                    of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [selection?.url ?? GreenroomScene.recordingsDirectory])
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .alert("Couldn't move the recording to the Trash",
                   isPresented: Binding(get: { trashError != nil },
                                        set: { if !$0 { trashError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(trashError ?? "")
            }

            Divider()

            if recordings.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("No recordings yet")
                        .font(.headline)
                    Text("Press Record during a session \u{2014} the file lands here the moment you stop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    List(recordings, selection: $selection) { recording in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.title)
                            Text(recording.sizeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(recording)
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
                            }
                            Button("Move to Trash", role: .destructive) { trash(recording) }
                        }
                    }
                    .frame(minWidth: 220, maxWidth: 300)

                    Group {
                        if let player {
                            PlayerView(player: player)
                        } else {
                            Text("Select a recording to play it")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear(perform: reload)
        .onChange(of: selection) { newSelection in
            player?.pause()
            player = newSelection.map { AVPlayer(url: $0.url) }
            player?.play()
        }
        .onDisappear { player?.pause() }
    }

    private func reload() {
        let directory = GreenroomScene.recordingsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        recordings = urls
            .filter { ["mov", "mp4", "mkv", "m4v"].contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Recording(url: url,
                                 date: values?.contentModificationDate ?? .distantPast,
                                 sizeBytes: Int64(values?.fileSize ?? 0))
            }
            .sorted { $0.date > $1.date }
    }

    /// AppKit's AVPlayerView wrapped for SwiftUI - deliberately NOT the
    /// SwiftUI VideoPlayer. That type (the _AVKit_SwiftUI overlay)
    /// crashed this app at generic-metadata instantiation the moment a
    /// recording was selected (swift getSuperclassMetadata fatalError,
    /// confirmed in three crash reports) - most plausibly one of the ~80
    /// embedded Zoom SDK libraries shadowing something the overlay's
    /// metadata resolution needs. AVPlayerView is a plain ObjC class and
    /// sidesteps that machinery entirely.
    private struct PlayerView: NSViewRepresentable {
        let player: AVPlayer

        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.controlsStyle = .floating
            view.player = player
            return view
        }

        func updateNSView(_ view: AVPlayerView, context: Context) {
            view.player = player
        }
    }

    private func trash(_ recording: Recording) {
        if selection == recording {
            player?.pause()
            player = nil
            selection = nil
        }
        // Never silent: a failed trash looked identical to success
        // (Codex design audit #15).
        do {
            try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
        } catch {
            trashError = error.localizedDescription
        }
        reload()
    }
}
