//
//  RecordingsView.swift
//  Greenroom
//
//  In-app review of session recordings: everything under ~/Documents/Greenroom,
//  grouped by the session that produced it, with an AVKit player and the clips
//  marked during that class laid out along the recording they came from.
//
//  Three things this view used to get wrong, all fixed here:
//   - It scanned only the top level, so once recordings moved into a folder per
//     session it would have shown nothing new ever again.
//   - Delete existed but only in a right-click menu, with no button, no key and
//     nothing on screen to suggest it. Present but undiscoverable is the same as
//     missing for anyone who does not try right-clicking.
//   - A recording was an opaque blob. The marks made during the class had
//     nowhere to appear, so the one thing a teacher wanted to find again was the
//     one thing they had to scrub for.
//
import SwiftUI
import AVKit

struct RecordingsView: View {
    @Environment(\.dismiss) private var dismiss

    /// One recording file, plus whatever was marked during it.
    struct Recording: Identifiable, Hashable {
        let url: URL
        let date: Date
        let sizeBytes: Int64
        var clips: [SessionClip]
        var id: URL { url }

        var title: String {
            date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .hour().minute().second())
        }
        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
        static func == (a: Recording, b: Recording) -> Bool { a.url == b.url }
        func hash(into hasher: inout Hasher) { hasher.combine(url) }
    }

    /// A class. One folder, usually one recording, sometimes more when the tape
    /// was stopped and restarted. Legacy loose files are gathered into a single
    /// unfoldered session so nothing recorded before this change disappears.
    struct Session: Identifiable, Hashable {
        let folder: URL?
        let title: String
        let date: Date
        var recordings: [Recording]
        var id: String { folder?.path ?? "__loose__" }

        var clipCount: Int { recordings.reduce(0) { $0 + $1.clips.count } }
        var sizeBytes: Int64 { recordings.reduce(0) { $0 + $1.sizeBytes } }
        static func == (a: Session, b: Session) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    static let playableExtensions = ["mov", "mp4", "mkv", "m4v"]

    @State private var sessions: [Session] = []
    @State private var freeBytes: Int64?
    @State private var usedBytes: Int64 = 0
    @State private var selection: Recording?
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var playhead: Double = 0
    @State private var timeObserver: Any?
    @State private var trashError: String?
    @State private var exporting: (done: Int, total: Int)?
    @State private var confirmingDelete: Recording?

    private var allRecordings: [Recording] { sessions.flatMap(\.recordings) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if spaceLevel != .ok, let freeBytes { spaceBanner(freeBytes) }
            Divider()
            if sessions.isEmpty { emptyState } else { browser }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear(perform: reload)
        .onChange(of: selection) { newSelection in load(newSelection) }
        .onDisappear(perform: teardownPlayer)
        .alert("Couldn't move that to the Trash",
               isPresented: Binding(get: { trashError != nil },
                                    set: { if !$0 { trashError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(trashError ?? "")
        }
        .confirmationDialog("Move this recording to the Trash?",
                            isPresented: Binding(get: { confirmingDelete != nil },
                                                 set: { if !$0 { confirmingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let target = confirmingDelete { trash(target) }
                confirmingDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmingDelete = nil }
        } message: {
            Text(confirmingDelete.map {
                $0.clips.isEmpty
                    ? "\($0.title) goes to the Trash. You can put it back from there."
                    : "\($0.title) and its \($0.clips.count) marked clip\($0.clips.count == 1 ? "" : "s") go to the Trash. You can put them back from there."
            } ?? "")
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Text("Recordings").font(.title3.bold())
            VStack(alignment: .leading, spacing: 1) {
                Text(GreenroomScene.recordingsDirectory.path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
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
    }

    private func spaceBanner(_ free: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: spaceLevel == .critical
                  ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
            Text(spaceLevel == .critical
                 ? "Only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) left \u{2014} that may not fit a full class. Move or delete a few recordings before your next session."
                 : "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) left \u{2014} room for about two more classes.")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(spaceColor.opacity(0.12))
        .foregroundStyle(spaceColor)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No recordings yet").font(.headline)
            Text("Press Record during a session \u{2014} the file lands here the moment you stop. Mark a moment mid-class with \u{2325}\u{2318}5 and it shows up on the recording below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Browser

    private var browser: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(sessions) { session in
                    Section {
                        ForEach(session.recordings) { recording in
                            recordingRow(recording).tag(recording)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(session.title).lineLimit(1).truncationMode(.middle)
                            if session.clipCount > 0 {
                                Text("\(session.clipCount)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
            // The key everyone reaches for first. The context menu still works,
            // but nobody should have to discover it.
            .onDeleteCommand { if let target = selection { confirmingDelete = target } }

            detail
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func recordingRow(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(recording.sizeLabel)
                if !recording.clips.isEmpty {
                    Text("\u{2022} \(recording.clips.count) clip\(recording.clips.count == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }
            Button("Move to Trash", role: .destructive) { confirmingDelete = recording }
        }
    }

    @ViewBuilder private var detail: some View {
        if let player, let selection {
            VStack(spacing: 0) {
                PlayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ClipTimeline(duration: duration,
                             playhead: playhead,
                             clips: selection.clips,
                             onSeek: seek)
                    .frame(height: 54)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                clipList(for: selection)
            }
        } else {
            Text("Select a recording to play it")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func clipList(for recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(recording.clips.isEmpty ? "NO CLIPS MARKED" : "CLIPS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let exporting {
                    ProgressView(value: Double(exporting.done), total: Double(max(1, exporting.total)))
                        .frame(width: 90)
                    Text("\(exporting.done)/\(exporting.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if !recording.clips.isEmpty {
                    Button("Export all clips") { exportAll(for: recording) }
                        .controlSize(.small)
                }
                Button(role: .destructive) {
                    confirmingDelete = recording
                } label: {
                    Label("Delete recording", systemImage: "trash")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if recording.clips.isEmpty {
                Text("Press \u{2325}\u{2318}1, \u{2325}\u{2318}2 or \u{2325}\u{2318}5 during a class to mark the last 1, 2 or 5 minutes. Marks appear here afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(recording.clips) { clip in
                            clipRow(clip, in: recording)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 132)
            }
        }
    }

    private func clipRow(_ clip: SessionClip, in recording: Recording) -> some View {
        let exported = SessionClipExporter.isExported(clip, from: recording.url)
        return HStack(spacing: 10) {
            Image(systemName: exported ? "checkmark.circle.fill" : "scissors")
                .foregroundStyle(exported ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Self.offsetLabel(clip.startMs)) \u{2013} \(Self.offsetLabel(clip.endMs))")
                    .font(.system(size: 12, design: .monospaced))
                Text("\(clip.durationLabel) \u{2022} marked at \(clip.markedAtLabel.replacingOccurrences(of: "-", with: ":"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Play") { seek(to: clip.startSeconds) }
                .controlSize(.small)
            if exported {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [SessionClipExporter.exportURL(for: clip, from: recording.url)])
                }
                .controlSize(.small)
            }
            Button(role: .destructive) {
                removeClip(clip, from: recording)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Removes the mark, and the exported clip if there is one. The recording is untouched.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Player

    private func load(_ recording: Recording?) {
        teardownPlayer()
        playhead = 0
        duration = 0
        guard let recording else { return }
        let item = AVPlayer(url: recording.url)
        player = item
        timeObserver = item.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { time in
                playhead = time.seconds
            }
        item.play()
        Task {
            let asset = AVURLAsset(url: recording.url)
            duration = (try? await asset.load(.duration))?.seconds ?? 0
        }
    }

    private func teardownPlayer() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }

    // MARK: Actions

    private func exportAll(for recording: Recording) {
        exporting = (0, recording.clips.count)
        Task {
            let outcome = await SessionClipExporter.exportAll(
                recording.clips, from: recording.url,
                onProgress: { done, total in exporting = (done, total) })
            exporting = nil
            if let first = outcome.failed.first {
                trashError = first.1.localizedDescription
            }
            reload()
        }
    }

    /// Removes a mark, and the file it produced if it has one. The recording it
    /// was cut from is deliberately untouched.
    private func removeClip(_ clip: SessionClip, from recording: Recording) {
        let remaining = recording.clips.filter { $0.id != clip.id }
        SessionClipStore.save(remaining, for: recording.url)
        let exported = SessionClipExporter.exportURL(for: clip, from: recording.url)
        if FileManager.default.fileExists(atPath: exported.path) {
            try? FileManager.default.trashItem(at: exported, resultingItemURL: nil)
        }
        reload()
    }

    /// Trashes a recording, its sidecar and its exported clips. When that empties
    /// the session folder, the folder goes too - an empty dated folder left
    /// behind is just litter.
    private func trash(_ recording: Recording) {
        if selection == recording { teardownPlayer(); selection = nil }
        let folder = recording.url.deletingLastPathComponent()
        do {
            try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
            let sidecar = SessionClipStore.sidecarURL(for: recording.url)
            try? FileManager.default.trashItem(at: sidecar, resultingItemURL: nil)
            for clip in recording.clips {
                let exported = SessionClipExporter.exportURL(for: clip, from: recording.url)
                try? FileManager.default.trashItem(at: exported, resultingItemURL: nil)
            }
            trashEmptySessionFolder(folder)
        } catch {
            // Never silent: a failed trash looked identical to success
            // (Codex design audit #15).
            trashError = error.localizedDescription
        }
        reload()
    }

    private func trashEmptySessionFolder(_ folder: URL) {
        guard folder != GreenroomScene.recordingsDirectory else { return }
        let remaining = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        // An empty clips/ subfolder does not count as content.
        let meaningful = remaining.filter { url in
            if url.lastPathComponent == "clips" {
                let inner = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                return !inner.isEmpty
            }
            return true
        }
        if meaningful.isEmpty {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }

    // MARK: Scanning

    private func reload() {
        freeBytes = GreenroomScene.recordingsFreeBytes
        usedBytes = GreenroomScene.recordingsUsedBytes
        let root = GreenroomScene.recordingsDirectory
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let entries = contents(of: root)
        let folders = entries.filter { isDirectory($0) && $0.lastPathComponent != "clips" }
        var found: [Session] = folders.compactMap { folder in
            let recordings = self.recordings(in: folder)
            guard !recordings.isEmpty else { return nil }
            return Session(folder: folder,
                           title: folder.lastPathComponent,
                           date: recordings.map(\.date).max() ?? .distantPast,
                           recordings: recordings)
        }

        // Everything recorded before sessions had folders.
        let loose = self.recordings(from: entries.filter { !isDirectory($0) })
        if !loose.isEmpty {
            found.append(Session(folder: nil,
                                 title: "Earlier recordings",
                                 date: loose.map(\.date).max() ?? .distantPast,
                                 recordings: loose))
        }

        sessions = found.sorted { $0.date > $1.date }
        // A selection whose file just went to the Trash must not linger.
        if let current = selection, !allRecordings.contains(where: { $0.url == current.url }) {
            teardownPlayer()
            selection = nil
        } else if let current = selection,
                  let refreshed = allRecordings.first(where: { $0.url == current.url }) {
            selection = refreshed   // pick up clip changes without reloading the player
        }
    }

    private func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func recordings(in folder: URL) -> [Recording] {
        recordings(from: contents(of: folder))
    }

    private func recordings(from urls: [URL]) -> [Recording] {
        urls
            .filter { Self.playableExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return Recording(url: url,
                                 date: values?.contentModificationDate ?? .distantPast,
                                 sizeBytes: Int64(values?.fileSize ?? 0),
                                 clips: SessionClipStore.load(for: url).sorted { $0.startMs < $1.startMs })
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: Bits

    private var spaceLevel: GreenroomScene.SpaceLevel {
        freeBytes.map(GreenroomScene.spaceLevel(freeBytes:)) ?? .ok
    }

    /// Amber for "plan ahead", red for "this class may not fit". Semantic system
    /// colours, not brand tokens - these adapt to light and dark, and DESIGN.md's
    /// amber/danger values are site CSS, not app colours.
    private var spaceColor: Color { spaceLevel == .critical ? .red : .orange }

    private var storageSummary: String {
        let used = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        guard let freeBytes else { return "\(used) in recordings" }
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return "\(used) in recordings \u{2022} \(free) free"
    }

    static func offsetLabel(_ milliseconds: Int) -> String {
        let total = milliseconds / 1000
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// AppKit's AVPlayerView wrapped for SwiftUI - deliberately NOT the SwiftUI
    /// VideoPlayer. That type (the _AVKit_SwiftUI overlay) crashed this app at
    /// generic-metadata instantiation the moment a recording was selected (swift
    /// getSuperclassMetadata fatalError, confirmed in three crash reports) - most
    /// plausibly one of the ~80 embedded Zoom SDK libraries shadowing something
    /// the overlay's metadata resolution needs. AVPlayerView is a plain ObjC
    /// class and sidesteps that machinery entirely.
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
}

/// The marked moments, drawn against the whole class.
///
/// This is the answer to "where was that bit?". A recording is otherwise an
/// hour-long bar with nothing to aim at, and the marks made during the class -
/// the one record of what was worth keeping - had nowhere to appear. Here they
/// are blocks on the timeline, positioned by where they actually are, and
/// clicking one jumps the player to it.
private struct ClipTimeline: View {
    let duration: Double
    let playhead: Double
    let clips: [SessionClip]
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 22)

                    if duration > 0 {
                        ForEach(clips) { clip in
                            let start = clip.startSeconds / duration
                            let span = max(0.004, Double(clip.durationMs) / 1000 / duration)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(width: max(3, width * span), height: 22)
                                .offset(x: width * start)
                                .onTapGesture { onSeek(clip.startSeconds) }
                                .help("\(clip.durationLabel), marked at \(clip.markedAtLabel.replacingOccurrences(of: "-", with: ":"))")
                        }

                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2, height: 30)
                            .offset(x: width * min(1, max(0, playhead / duration)) - 1)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 30)
                // Click anywhere on the track to scrub there. The player has its
                // own scrubber, but this one is the one with the marks on it.
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard duration > 0, width > 0 else { return }
                    onSeek(min(duration, max(0, duration * value.location.x / width)))
                })
            }
            .frame(height: 30)

            HStack {
                Text(RecordingsView.offsetLabel(Int(playhead * 1000)))
                Spacer()
                Text(duration > 0 ? RecordingsView.offsetLabel(Int(duration * 1000)) : "\u{2014}")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }
}
