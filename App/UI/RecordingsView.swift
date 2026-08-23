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
    @State private var freeBytes: Int64?
    @State private var usedBytes: Int64 = 0
    @State private var selection: Recording?
    @State private var player: AVPlayer?
    @State private var trashError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recordings").font(.title3.bold())
                VStack(alignment: .leading, spacing: 1) {
                    Text(GreenroomScene.recordingsDirectory.path.replacingOccurrences(
                        of: NSHomeDirectory(), with: "~"))
                    Text(storageSummary)
                        .foregroundStyle(spaceLevel == .ok ? AnyShapeStyle(.secondary)
                                                           : AnyShapeStyle(spaceColor))
                }
                .font(.caption)
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

            if spaceLevel != .ok, let freeBytes {
                HStack(spacing: 8) {
                    Image(systemName: spaceLevel == .critical
                          ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                    Text(spaceLevel == .critical
                         ? "Only \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) left \u{2014} that may not fit a full class. Move or delete a few recordings before your next session."
                         : "\(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) left \u{2014} room for about two more classes.")
                    Spacer()
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(spaceColor.opacity(0.12))
                .foregroundStyle(spaceColor)
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

    private var spaceLevel: GreenroomScene.SpaceLevel {
        freeBytes.map(GreenroomScene.spaceLevel(freeBytes:)) ?? .ok
    }

    /// Amber for "plan ahead", red for "this class may not fit". Semantic
    /// system colours, not brand tokens - these adapt to light and dark, and
    /// DESIGN.md's amber/danger values are site CSS, not app colours.
    private var spaceColor: Color {
        spaceLevel == .critical ? .red : .orange
    }

    private var storageSummary: String {
        let used = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        guard let freeBytes else { return "\(used) in recordings" }
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return "\(used) in recordings \u{2022} \(free) free"
    }

    static let playableExtensions = ["mov", "mp4", "mkv", "m4v"]

    /// Finds recordings one level down as well as loose in the root.
    ///
    /// Sessions record into a folder of their own now. A top-level-only scan
    /// found nothing in them, so every new recording would simply have stopped
    /// appearing here. Loose files are still listed because every recording made
    /// before that change is one.
    private func reload() {
        freeBytes = GreenroomScene.recordingsFreeBytes
        usedBytes = GreenroomScene.recordingsUsedBytes
        let root = GreenroomScene.recordingsDirectory
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]

        func media(in directory: URL) -> [URL] {
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }

        let top = media(in: root)
        // The session folder's own clips/ subfolder is deliberately not walked:
        // clips get their own presentation, and listing them beside their parent
        // recording would read as duplicates of it.
        let nested = top
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .flatMap { media(in: $0) }

        recordings = (top + nested)
            .filter { Self.playableExtensions.contains($0.pathExtension.lowercased()) }
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
