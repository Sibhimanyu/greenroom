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
        /// Where this file went, if it was uploaded (from the folder's session.json).
        var upload: SessionMetadata.Upload?
        var id: URL { url }

        /// Without the seconds.
        ///
        /// "Fri, 18 Sep at 9:16:17 PM" measures 149pt and was what held the
        /// sidebar open at 240pt minimum. The seconds disambiguated two
        /// recordings inside one minute, which the file size already does,
        /// and they cost fifty points of a column the video wants.
        var title: String {
            date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .hour().minute())
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
        /// The folder's own name - the date and class it was created for.
        let title: String
        /// The name the teacher gave it, if any (session.json).
        var customTitle: String?
        let date: Date
        var recordings: [Recording]
        var displayTitle: String { customTitle ?? title }
        var uploadCount: Int { recordings.filter { $0.upload != nil }.count }
        /// Finished clip files in the session's clips/ folder.
        ///
        /// These are not always cut from a recording in this folder. A clip
        /// taken from the rolling buffer while nothing was recording has no
        /// master at all, so a session can legitimately hold clips and no
        /// recording - and dropping those was why a clip taken without pressing
        /// Record appeared nowhere despite being on disk.
        var clipFiles: [Recording]
        /// Cues cards the teacher opened or sent during this class
        /// (session.json). Never the ones merely shown.
        var links: [SessionMetadata.Link] = []
        /// What the folder says it is (session.json), when it says anything.
        var kind: String?
        var id: String { folder?.path ?? "__loose__" }

        /// Nothing here at all. A folder that says what it is is not empty
        /// even with no tape in it - its notes and its report are the part a
        /// student gets sent.
        var isEmpty: Bool {
            recordings.isEmpty && clipFiles.isEmpty && links.isEmpty && kind == nil
        }

        /// Which half of the app made this.
        ///
        /// What the folder SAYS first, what its files suggest second.
        ///
        /// The files alone were the whole rule, and they are still the rule
        /// for every folder made before session.json carried a kind - which
        /// is why nothing had to be migrated or moved. But a rule read off
        /// the files says a Screen stops being a Screen the moment somebody
        /// deletes its 290MB video to get the space back, keeping the notes
        /// and the report. What a session WAS is not something a deleted file
        /// gets to decide, so Screenroom now writes it down at the start.
        var source: Source {
            switch kind {
            case SessionMetadata.Kind.screen.rawValue: return .screen
            case SessionMetadata.Kind.green.rawValue: return .green
            default:
                return recordings.contains {
                    $0.url.lastPathComponent == ScreenroomRecorder.recordingFileName
                } ? .screen : .green
            }
        }

        /// One recording, nothing else. The overwhelmingly common shape.
        ///
        /// A Section header naming the class above a single row naming the
        /// same class at a different time is two headings for one thing, and
        /// that is what the sidebar looked like: "Test1", then under it "Fri,
        /// 18 Sep at 9:16 PM". The header exists for the session that really
        /// does hold several things; for the one that does not, it is
        /// furniture around a single row.
        var isSingle: Bool {
            recordings.count == 1 && clipFiles.isEmpty && links.isEmpty
        }
        var clipCount: Int { recordings.reduce(0) { $0 + $1.clips.count } + clipFiles.count }
        var sizeBytes: Int64 {
            recordings.reduce(0) { $0 + $1.sizeBytes } + clipFiles.reduce(0) { $0 + $1.sizeBytes }
        }
        static func == (a: Session, b: Session) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    static let playableExtensions = ["mov", "mp4", "mkv", "m4v"]

    @State private var sessions: [Session] = []
    /// Which half is being looked at. Persisted, because a teacher who marks
    /// presentations all term should not pick the same tab every morning.
    @AppStorage("sessionsFilter") private var filter: Filter = .all
    @State private var freeBytes: Int64?
    @State private var usedBytes: Int64 = 0
    @State private var selection: Recording?
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    /// Set while the recording is playing with its fillers cut out: the
    /// observer that jumps over them, so it can be taken away again.
    @State private var skipObserver: Any?
    @ObservedObject private var review = ScreenroomReviewController.shared
    @State private var playhead: Double = 0
    @State private var timeObserver: Any?
    @State private var trashError: String?
    @State private var exporting: (done: Int, total: Int)?
    @State private var confirmingDelete: Recording?
    @State private var renaming: Session?
    @State private var renameDraft = ""
    @State private var renamingVideo: (upload: SessionMetadata.Upload, folder: URL)?
    @State private var videoTitleDraft = ""
    @State private var renameError: String?
    /// Which half of the detail pane is showing. The recording is what the
    /// window was built for; the transcript is what a teacher wants the day
    /// after, and it had no home in the app at all.
    @State private var detailTab: DetailTab = .analysis

    /// Which half of the app made a session.
    ///
    /// Greenroom makes Greens, Screenroom makes Screens. Named from the two
    /// halves rather than from what they contain, because "Classes" and
    /// "Presentations" are words this app does not otherwise use and they
    /// throw away the vocabulary everything else is built on.
    enum Source {
        case green, screen

        /// Singular, for a folder name: "Green - 2026-09-19 08-30".
        var defaultName: String { self == .green ? "Green" : "Screen" }
    }

    /// What the sidebar is showing.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case greens = "Greens"
        case screens = "Screens"
        var id: String { rawValue }

        var source: Source? {
            switch self {
            case .all: return nil
            case .greens: return .green
            case .screens: return .screen
            }
        }

        var symbol: String {
            switch self {
            case .all: return "tray.full"
            case .greens: return "person.3"
            case .screens: return "person.wave.2"
            }
        }

        var emptyLine: String {
            switch self {
            case .all: return "Nothing recorded yet."
            case .greens: return "No Greens yet."
            case .screens: return "No Screens yet."
            }
        }

        var emptyDetail: String {
            switch self {
            case .all: return "Run a class, or record someone presenting."
            case .greens: return "A Green is a class. Press Start on the main window to run one."
            case .screens: return "A Screen is a presentation. Open Screenroom to record one."
            }
        }
    }

    enum DetailTab: String, CaseIterable, Identifiable {
        /// What used to be "Recording" minus the player, which now sits above
        /// the tabs permanently. Clips, the upload line, the YouTube links.
        case clips = "Clips"
        case transcript = "Transcript"
        /// Screenroom's three, flat rather than nested.
        ///
        /// They were one "Analysis" tab holding a second segmented control of
        /// Analysis / Notes / Rubric, which put two pickers one under the
        /// other with the word "Analysis" in both. That reads as a bug, not a
        /// hierarchy. Five flat tabs is one decision instead of two, and the
        /// word appears once.
        case analysis = "Analysis"
        case notes = "Notes"
        var id: String { rawValue }

        var isAvailable: Bool {
            switch self {
            case .clips: return true
            // No longer Cues-only: Screenroom's Analyse writes transcript.txt
            // too, so a build with Screenroom in it can fill this tab even
            // when Cues is held back.
            case .transcript: return CuesAvailability.isReleased || ScreenroomAvailability.isReleased
            case .analysis, .notes: return ScreenroomAvailability.isReleased
            }
        }
    }
    /// Presented as a sheet from ContentView, so the environment object
    /// arrives with it; used for the YouTube upload button and state.
    @EnvironmentObject private var coordinator: CoordinatorController

    private var allRecordings: [Recording] {
        sessions.flatMap { $0.recordings + $0.clipFiles }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if spaceLevel != .ok, let freeBytes { spaceBanner(freeBytes) }
            Divider()
            if sessions.isEmpty { emptyState } else { browser }
        }
        // The video, its scrubber and the work under it all want height, and
        // the sidebar gives back 85pt of width.
        .frame(minWidth: 1_180, minHeight: 720)
        .onAppear(perform: reload)
        .onChange(of: selection) { newSelection in load(newSelection) }
        // An upload finishing while the window is open should show up here.
        .onChange(of: coordinator.isUploadingToYouTube) { _ in reload() }
        .onDisappear(perform: teardownPlayer)
        .alert("Rename this class",
               isPresented: Binding(get: { renaming != nil },
                                    set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Rename") {
                if let session = renaming, let folder = session.folder {
                    SessionMetadata.rename(folder: folder, to: renameDraft)
                }
                renaming = nil
                reload()
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Shown in this window. The folder in Documents/Greenroom keeps its date name; clear the field to go back to it. Videos already on YouTube keep their titles \u{2014} rename those under the recording.")
        }
        .alert("Rename on YouTube",
               isPresented: Binding(get: { renamingVideo != nil },
                                    set: { if !$0 { renamingVideo = nil } })) {
            TextField("Title", text: $videoTitleDraft)
            Button("Rename") {
                guard let target = renamingVideo else { return }
                renamingVideo = nil
                Task {
                    if let failure = await coordinator.renameYouTubeVideo(target.upload, in: target.folder, to: videoTitleDraft) {
                        renameError = failure
                    } else {
                        ToastController.show("Renamed on YouTube", detail: videoTitleDraft)
                    }
                    reload()
                }
            }
            Button("Cancel", role: .cancel) { renamingVideo = nil }
        } message: {
            Text("Changes the title on the channel. The file on this Mac is untouched.")
        }
        .alert("Couldn't rename on YouTube",
               isPresented: Binding(get: { renameError != nil },
                                    set: { if !$0 { renameError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameError ?? "")
        }
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
            Text("Sessions").font(.title3.bold())
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
            Text("No sessions yet").font(.headline)
            Text("Press Record during a class \u{2014} the file lands here the moment you stop, under the class it belongs to. Mark a moment mid-class with \u{2325}\u{2318}5 and it shows up on the recording; upload to YouTube and the link stays here too.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Browser

    /// The sessions of the kind being looked at.
    ///
    /// Loose legacy recordings have no folder and no presentation.mov, so
    /// they classify as classes, which is what they were.
    private var shown: [Session] {
        guard let wanted = filter.source else { return sessions }
        return sessions.filter { $0.source == wanted }
    }

    private var browser: some View {
        HSplitView {
            VStack(spacing: 0) {
                // Two halves of one app, told apart rather than mixed.
                //
                // No counts on the tabs. They were there to explain an empty
                // list, but the empty state under this control already says
                // so in a sentence - and a number beside every tab is read
                // on every glance, forever, to answer a question asked once.
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)

                if shown.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: filter.symbol)
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text(filter.emptyLine).font(.callout).foregroundStyle(.secondary)
                        Text(filter.emptyDetail)
                            .font(.caption).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
            List(selection: $selection) {
                ForEach(shown) { session in
                    if session.isSingle, let only = session.recordings.first {
                        singleRow(session, only).tag(only)
                    } else {
                    Section {
                        ForEach(session.recordings) { recording in
                            recordingRow(recording).tag(recording)
                        }
                        ForEach(session.clipFiles) { clip in
                            clipFileRow(clip).tag(clip)
                        }
                        if !session.links.isEmpty {
                            linksRow(session.links)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Text(session.displayTitle).lineLimit(1).truncationMode(.middle)
                            if session.clipCount > 0 {
                                Text("\(session.clipCount)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                                    .help("\(session.clipCount) clip\(session.clipCount == 1 ? "" : "s")")
                            }
                            if session.uploadCount > 0 {
                                Image(systemName: "play.rectangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.accentColor)
                                    .help("\(session.uploadCount) on YouTube")
                            }
                            Spacer()
                            if session.folder != nil {
                                Button {
                                    renameDraft = session.customTitle ?? ""
                                    renaming = session
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Rename this class")
                            }
                        }
                        .contextMenu {
                            if let folder = session.folder {
                                Button("Rename\u{2026}") {
                                    renameDraft = session.customTitle ?? ""
                                    renaming = session
                                }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                                }
                            }
                        }
                    }
                    }
                }
                }
            }
            }
            // Sized to the row label plus padding, rather than to a number
            // chosen before the label was. Measured: "Fri, 18 Sep at 9:16 PM"
            // is 132pt, so 172 is the floor and 180 is the floor with room to
            // be wrong in. The weekday stays - a teacher looks for Friday's
            // class - and only the seconds went.
            .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
            // The key everyone reaches for first. The context menu still works,
            // but nobody should have to discover it.
            .onDeleteCommand { if let target = selection { confirmingDelete = target } }

            detail
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One session, one row: its name, and underneath it when and how big.
    ///
    /// The name leads because that is what a teacher is looking for. The date
    /// is the subtitle rather than the title, which is the other way round
    /// from how this list used to read.
    private func singleRow(_ session: Session, _ recording: Recording) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(recording.title)
                    Text("\u{00B7}")
                    Text(recording.sizeLabel)
                    if let upload = recording.upload {
                        Text("\u{00B7} YouTube \u{00B7} \(upload.privacy)")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if session.folder != nil {
                Button {
                    renameDraft = session.customTitle ?? ""
                    renaming = session
                } label: {
                    Image(systemName: "pencil").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rename this session")
            }
        }
        .contextMenu {
            if let folder = session.folder {
                Button("Rename\u{2026}") {
                    renameDraft = session.customTitle ?? ""
                    renaming = session
                }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                Divider()
            }
            if let upload = recording.upload, let url = URL(string: upload.url) {
                Button("Open on YouTube") { NSWorkspace.shared.open(url) }
                Button("Copy YouTube link") { copy(upload.url) }
                Divider()
            }
            Button("Move to Trash", role: .destructive) { confirmingDelete = recording }
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
                if let upload = recording.upload {
                    Text("\u{2022} YouTube \u{00B7} \(upload.privacy)")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contextMenu {
            if let upload = recording.upload, let url = URL(string: upload.url) {
                Button("Open on YouTube") { NSWorkspace.shared.open(url) }
                Button("Copy YouTube link") { copy(upload.url) }
                Divider()
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([recording.url])
            }
            Button("Move to Trash", role: .destructive) { confirmingDelete = recording }
        }
    }

    /// "Links from class": what Cues offered and the teacher opened or
    /// sent. Collapsed by default so a class with twelve links does not push
    /// its recording off the list.
    private func linksRow(_ links: [SessionMetadata.Link]) -> some View {
        DisclosureGroup {
            ForEach(links) { link in
                HStack(spacing: 6) {
                    Text(link.kind.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .leading)
                    Text(link.title).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    if link.action == "sent" {
                        Image(systemName: "paperplane").font(.system(size: 9)).foregroundStyle(.secondary)
                            .help("Sent to the class chat")
                    }
                }
                .font(.caption)
                .contextMenu {
                    if let url = URL(string: link.url) {
                        Button("Open") { NSWorkspace.shared.open(url) }
                    }
                    Button("Copy link") { copy(link.url) }
                }
                .onTapGesture(count: 2) {
                    if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Links from class").font(.caption)
                Text("\(links.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastController.show("Link copied", detail: text)
    }

    /// The upload record under the player: where it went, when, and the link.
    @ViewBuilder private func uploadLine(for recording: Recording) -> some View {
        if let upload = recording.upload {
            HStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\u{201C}\(upload.title)\u{201D} \u{00B7} \(upload.privacy) \u{00B7} uploaded \(upload.uploadedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .lineLimit(1)
                    Text(upload.url)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if let url = URL(string: upload.url) {
                    Button("Open") { NSWorkspace.shared.open(url) }
                        .controlSize(.small)
                }
                Button("Copy link") { copy(upload.url) }
                    .controlSize(.small)
                Button("Rename\u{2026}") {
                    videoTitleDraft = upload.title
                    renamingVideo = (upload, recording.url.deletingLastPathComponent())
                }
                .controlSize(.small)
                .help("Change the title on YouTube.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
        }
    }

    /// A finished clip file. Distinct from a recording on purpose: it has no
    /// marks of its own and is usually a fragment of something longer.
    private func clipFileRow(_ clip: Recording) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.url.deletingPathExtension().lastPathComponent)
                    .lineLimit(1)
                Text(clip.sizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([clip.url])
            }
            Button("Move to Trash", role: .destructive) { confirmingDelete = clip }
        }
    }

    /// Which of Screenroom's panes the current tab wants, or nil when the
    /// tab belongs to something else.
    private var screenroomPane: ScreenroomAnalysisPane.Pane? {
        switch detailTab {
        case .analysis: return .analysis
        case .notes: return .notes
        case .clips, .transcript: return nil
        }
    }

    /// The class folder a recording belongs to, for the transcript pane.
    private func folder(for recording: Recording) -> URL? {
        sessions.first {
            $0.recordings.contains(recording) || $0.clipFiles.contains(recording)
        }?.folder
    }

    @ViewBuilder private var detail: some View {
        if let selection {
            VStack(spacing: 0) {
                // THE PICTURE IS NOT A TAB.
                //
                // It used to be: the player lived inside a "Recording" tab and
                // the notes inside a "Notes" tab, so writing a note about
                // something at 3:12 meant leaving the video to do it. Reported
                // as "I am having to add notes without even being able to
                // watch the video live" - and it was worse than awkward, since
                // the playhead kept running while you hunted for the tab, so
                // the note landed wherever the video got to rather than where
                // the thing happened.
                //
                // The material is always on screen. The tabs below switch only
                // the WORK done on it.
                stage(for: selection)
                Divider()
                work(for: selection)
            }
        } else {
            Text("Select a recording to play it")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The recording and its scrubber, permanently.
    @ViewBuilder private func stage(for selection: Recording) -> some View {
        VStack(spacing: 0) {
            if let player {
                PlayerView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ClipTimeline(duration: duration,
                         playhead: playhead,
                         clips: selection.clips,
                         marks: marks(for: selection),
                         skipping: skipObserver != nil,
                         onStopSkipping: stopSkipping,
                         onSeek: seek)
                .frame(height: 54)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        // Both halves flex, with a floor each: the video must stay big enough
        // to read a face, and the work must stay tall enough to type into.
        .frame(minHeight: 220, maxHeight: .infinity)
    }

    /// Everything you do to the recording, under it.
    @ViewBuilder private func work(for selection: Recording) -> some View {
        VStack(spacing: 0) {
            let tabs = DetailTab.allCases.filter(\.isAvailable)
            if tabs.count > 1 {
                // Leading-aligned, sharing the left edge of everything under
                // it, and sized to its own labels rather than to a number that
                // goes stale the moment a tab is renamed.
                Picker("", selection: $detailTab) {
                    ForEach(tabs) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }

            if let pane = screenroomPane, DetailTab.analysis.isAvailable {
                ScreenroomAnalysisPane(
                    folder: folder(for: selection),
                    recording: selection.url,
                    showing: pane,
                    seek: { ms in seek(to: Double(ms) / 1000) },
                    position: { Int(playhead * 1000) },
                    rate: { player?.rate = $0 },
                    skip: { playSkipping($0) })
            } else if detailTab == .transcript, DetailTab.transcript.isAvailable {
                if let folder = folder(for: selection) {
                    SessionTranscriptView(folder: folder)
                } else {
                    Text("This recording is not in a class folder, so it has no transcript.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                clipsDetail(for: selection)
            }
        }
        .frame(minHeight: 260, maxHeight: .infinity)
    }

    /// The clips, the upload line, the YouTube links. What the old Recording
    /// tab held once the player moved out of it.
    @ViewBuilder private func clipsDetail(for selection: Recording) -> some View {
        VStack(spacing: 0) {
            uploadLine(for: selection)
            clipList(for: selection)
            Spacer(minLength: 0)
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
                // The retry path for a declined or failed upload - and the
                // manual one for teachers who keep "After a recording" off.
                if coordinator.youtubeConnected {
                    Button {
                        coordinator.uploadRecordingToYouTube(recording.url)
                    } label: {
                        Label(coordinator.isUploadingToYouTube ? "Uploading\u{2026}"
                              : recording.upload == nil ? "Upload to YouTube" : "Upload again",
                              systemImage: "play.rectangle")
                    }
                    .controlSize(.small)
                    .disabled(coordinator.isUploadingToYouTube)
                    .help(recording.upload == nil
                          ? "Upload this recording to the connected channel (\(coordinator.youtubePrivacy))."
                          : "Uploads a second copy; the existing video stays on the channel.")
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
        stopSkipping()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    /// Plays from the start and jumps over each span as the playhead
    /// reaches it. A boundary observer rather than the quarter-second
    /// playhead tick: a filler lasts about that long, so polling would hear
    /// half of every one.
    private func playSkipping(_ spans: [ClosedRange<Double>]) {
        guard let player, !spans.isEmpty else { return }
        stopSkipping()
        let starts = spans.map { NSValue(time: CMTime(seconds: $0.lowerBound, preferredTimescale: 600)) }
        skipObserver = player.addBoundaryTimeObserver(forTimes: starts, queue: .main) { [player] in
            let now = player.currentTime().seconds
            guard let span = spans.first(where: { $0.contains(now + 0.02) }) else { return }
            player.seek(to: CMTime(seconds: span.upperBound, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.rate = 1
        seek(to: 0)
    }

    private func stopSkipping() {
        if let skipObserver { player?.removeTimeObserver(skipObserver) }
        skipObserver = nil
    }

    /// Fillers and notes for the recording on screen, when Screenroom has
    /// analysed THIS take. Nothing otherwise - a mark measured against a
    /// different take points at the wrong moment.
    private func marks(for selection: Recording) -> ClipTimeline.Marks {
        guard ScreenroomAvailability.isReleased,
              let folder = folder(for: selection),
              review.selected?.folder == folder else { return .init() }
        let found = review.scrubberMarks
        return .init(fillers: found.fillers.map { Double($0) / 1000 },
                     notes: found.notes.map { Double($0) / 1000 })
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
            // Only clips cut FROM this recording. Now that clips share the
            // session folder, a blanket sweep would take clips belonging to
            // another take, or to no recording at all.
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
        // An empty legacy clips/ subfolder does not count as content. Clips
        // themselves DO count: a session whose recording was deleted but whose
        // clips were kept is still a session worth having.
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
            let all = self.recordings(in: folder)
            let recordings = all.filter { !SessionClipExporter.isClip($0.url) }
            // Clips sit in the session folder now, told apart by the `Clip `
            // prefix. The legacy clips/ subfolder is still read so anything
            // taken before that change does not vanish.
            let clips = all.filter { SessionClipExporter.isClip($0.url) }
                + self.recordings(in: folder.appendingPathComponent("clips"))
            // Not `recordings.isEmpty`: a session where the teacher clipped from
            // the buffer without ever pressing Record has clips and no master,
            // and dropping it here is what made those clips invisible.
            let metadata = SessionMetadata.load(in: folder)
            // A class with no tape but with links it looked at is still a
            // class worth listing.
            // A presentation whose video has been deleted is still a
            // presentation: its notes, its marks and its report are all
            // still here, and they are the half a teacher actually sends to
            // a student. Dropping it made a folder full of work vanish from
            // the one window built to find it.
            let isMarked = metadata.kind != nil
            guard !recordings.isEmpty || !clips.isEmpty || !metadata.links.isEmpty || isMarked else { return nil }
            let withUploads = recordings.map { recording in
                var copy = recording
                copy.upload = metadata.upload(for: recording.url)
                return copy
            }
            return Session(folder: folder,
                           title: folder.lastPathComponent,
                           customTitle: metadata.title,
                           // The folder name last, not nothing: a session
                           // whose video was deleted has no file to date it
                           // by, and .distantPast would bury it at the end of
                           // a list sorted by when things happened.
                           date: (recordings + clips).map(\.date).max()
                               ?? metadata.links.map(\.at).max()
                               ?? ScreenroomLibrary.date(of: folder),
                           recordings: withUploads,
                           clipFiles: clips,
                           links: metadata.links.sorted { $0.at < $1.at },
                           kind: metadata.kind)
        }

        // Everything recorded before sessions had folders.
        let allLoose = self.recordings(from: entries.filter { !isDirectory($0) })
        let loose = allLoose.filter { !SessionClipExporter.isClip($0.url) }
        // Clips at the ROOT rather than in a session folder: everything taken
        // before buffer clips were routed into their session.
        let looseClips = allLoose.filter { SessionClipExporter.isClip($0.url) }
            + self.recordings(in: root.appendingPathComponent("clips"))
        if !loose.isEmpty || !looseClips.isEmpty {
            found.append(Session(folder: nil,
                                 title: "Earlier recordings",
                                 customTitle: nil,
                                 date: (loose + looseClips).map(\.date).max() ?? .distantPast,
                                 recordings: loose,
                                 clipFiles: looseClips))
        }

        sessions = found.sorted { $0.date > $1.date }
        // A selection that belongs to the other half would leave the detail
        // pane showing a recording the sidebar does not list.
        if let current = selection,
           !shown.contains(where: { session in
               session.recordings.contains(current) || session.clipFiles.contains(current)
           }) {
            selection = nil
            teardownPlayer()
        }
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
    /// Screenroom's moments, in seconds, drawn as ticks over the track so
    /// the player itself shows where the fillers and notes fell.
    struct Marks {
        var fillers: [Double] = []
        var notes: [Double] = []
        var isEmpty: Bool { fillers.isEmpty && notes.isEmpty }
    }

    let duration: Double
    let playhead: Double
    let clips: [SessionClip]
    var marks = Marks()
    var skipping = false
    var onStopSkipping: () -> Void = {}
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

                        // Fillers as short ticks in the lower half, notes as
                        // taller ones - two kinds of moment, told apart by
                        // shape rather than by a second colour.
                        ForEach(Array(marks.fillers.enumerated()), id: \.offset) { _, at in
                            Capsule()
                                .fill(Brand.fill)
                                .frame(width: 2, height: 9)
                                .offset(x: width * min(1, at / duration) - 1, y: 6)
                                .allowsHitTesting(false)
                        }
                        ForEach(Array(marks.notes.enumerated()), id: \.offset) { _, at in
                            Capsule()
                                .fill(Color.primary.opacity(0.75))
                                .frame(width: 3, height: 22)
                                .offset(x: width * min(1, at / duration) - 1.5)
                                .onTapGesture { onSeek(max(0, at - 4)) }
                                .help("A note")
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

            HStack(spacing: 12) {
                Text(RecordingsView.offsetLabel(Int(playhead * 1000)))
                if skipping {
                    // Said on the player, because the player is what is
                    // behaving differently: every filler is being jumped.
                    HStack(spacing: 6) {
                        Text("Playing without fillers")
                        Button("Stop", action: onStopSkipping)
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                } else if !marks.isEmpty {
                    Text(markLegend)
                        .font(.system(size: 11))
                }
                Spacer()
                Text(duration > 0 ? RecordingsView.offsetLabel(Int(duration * 1000)) : "\u{2014}")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private var markLegend: String {
        var parts: [String] = []
        if !marks.fillers.isEmpty { parts.append("short ticks: \(marks.fillers.count) filler\(marks.fillers.count == 1 ? "" : "s")") }
        if !marks.notes.isEmpty { parts.append("tall: \(marks.notes.count) note\(marks.notes.count == 1 ? "" : "s")") }
        return parts.joined(separator: " \u{00B7} ")
    }
}
