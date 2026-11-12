//
//  RecordingsView.swift
//  Greenroom
//
//  The Sessions window: everything under ~/Documents/Greenroom, one card per
//  session, and for the selected one its player, its clips, where it went and
//  what the analysis made of it.
//
//  This half reads the disk and runs the actions; SessionsContent.swift draws.
//  The drawing takes values and closures and nothing else, so it can be
//  rendered off screen with staged sessions - see that file's note.
//
//  Three things this view used to get wrong, all still fixed here:
//   - It scanned only the top level, so once recordings moved into a folder per
//     session it would have shown nothing new ever again.
//   - Delete existed but only in a right-click menu, with no button, no key and
//     nothing on screen to suggest it. Present but undiscoverable is the same as
//     missing for anyone who does not try right-clicking. It is now in the
//     inspector's menu, on every card's menu, and on the Delete key.
//   - A recording was an opaque blob. The marks made during the class had
//     nowhere to appear, so the one thing a teacher wanted to find again was the
//     one thing they had to scrub for.
//
//  And one it got wrong by design: the analysis was a tab, only reached by
//  opening a session and then finding the tab, and Screenroom's presentations
//  were a different kind of thing from a class. Any session with a recording
//  can now be analysed from the inspector, in place, and "Analysed" is a
//  status the grid can filter on.
//
import SwiftUI
import AVKit

struct RecordingsView: View {

    /// One recording file, plus whatever was marked during it.
    struct Recording: Identifiable, Hashable {
        let url: URL
        let date: Date
        let sizeBytes: Int64
        var clips: [SessionClip]
        /// Where this file went, if it was uploaded (from the folder's session.json).
        var upload: SessionMetadata.Upload?
        var id: URL { url }

        /// Without the seconds - two recordings inside one minute are told
        /// apart by their size.
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

    /// A session. One folder, usually one recording, sometimes more when the
    /// tape was stopped and restarted. Legacy loose files are gathered into a
    /// single unfoldered session so nothing recorded before folders existed
    /// disappears.
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
        /// Finished clip files in the session folder.
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
        /// The analysis has run here: analysis.json or an exported report.
        var isAnalysed = false
        var id: String { folder?.path ?? "__loose__" }

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
        /// gets to decide, so the makers write it down at the start.
        var source: Source {
            switch kind {
            case SessionMetadata.Kind.screen.rawValue: return .screen
            case SessionMetadata.Kind.recording.rawValue: return .recording
            case SessionMetadata.Kind.green.rawValue: return .green
            default:
                return recordings.contains {
                    $0.url.lastPathComponent == ScreenroomLibrary.presentationFileName
                } ? .screen : .green
            }
        }

        /// The take that plays when the session is opened, and the one the
        /// analysis describes: Screenroom's own file, else the biggest -
        /// the same rule as ScreenroomLibrary.recording(in:), so the picture
        /// and the analysis agree on which take they mean. A clip when there
        /// is no recording at all.
        var primaryTake: Recording? {
            recordings.first { $0.url.lastPathComponent == ScreenroomLibrary.presentationFileName }
                ?? recordings.filter { $0.url.lastPathComponent != ScreenroomVideoExport.annotatedFileName }
                    .max { $0.sizeBytes < $1.sizeBytes }
                ?? recordings.first
                ?? clipFiles.first
        }

        var takes: [Recording] { recordings + clipFiles }
        var clipCount: Int { recordings.reduce(0) { $0 + $1.clips.count } + clipFiles.count }
        static func == (a: Session, b: Session) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Which part of the app made a session. Shown as Class, Recording and
    /// Review (SessionKind); named here for the code that made them.
    enum Source {
        case green, screen, recording

        var kind: SessionKind {
            switch self {
            case .green: return .classSession
            case .screen: return .review
            case .recording: return .recording
            }
        }
    }

    static let playableExtensions = ["mov", "mp4", "mkv", "m4v"]

    @State private var sessions: [Session] = []
    @State private var freeBytes: Int64?
    @State private var usedBytes: Int64 = 0
    /// The card selected in the grid.
    @State private var selectedID: String?
    /// The take playing in the inspector - one of the selected session's.
    @State private var selection: Recording?
    @State private var search = ""
    /// What the sidebar shows. Persisted, because a teacher who marks
    /// presentations all term should not pick Reviews every morning.
    @AppStorage("sessionsShow") private var show: SessionsShow = .everything
    @AppStorage("sessionsSort") private var sort: SessionsSort = .newest
    @State private var status: SessionsStatus?
    @State private var tab = Tab.clips.rawValue
    /// The folder whose analysis this window started, so the report opens
    /// when it finishes - and only then, not for a run begun elsewhere.
    @State private var analysingFolder: URL?

    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    /// Set while the recording is playing with its fillers cut out: the
    /// observer that jumps over them, so it can be taken away again.
    @State private var skipObserver: Any?
    @ObservedObject private var review = ScreenroomReviewController.shared
    @ObservedObject private var thumbnails = SessionThumbnails.shared
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
    @State private var deletingVideo: (upload: SessionMetadata.Upload, folder: URL)?
    @State private var deleteVideoError: String?

    /// Used for the YouTube upload button and state.
    @EnvironmentObject private var coordinator: CoordinatorController

    /// The work under the inspector's picture.
    ///
    /// The analysis is not one of them any more: it is a tile above, with its
    /// verdict under it and the full report a click away. What is left is the
    /// work done ON the recording, which wants the room under the player.
    enum Tab: String, CaseIterable {
        case clips = "Clips"
        case notes = "Notes"
        case transcript = "Transcript"
        /// What Cues offered in the class and the teacher opened or sent.
        case links = "Links"

        var isAvailable: Bool {
            switch self {
            case .clips: return true
            case .notes: return true
            // Analyse writes transcript.txt too, so this tab can be filled
            // even when Cues is held back.
            case .transcript: return true
            case .links: return CuesAvailability.isReleased
            }
        }
    }

    private var allRecordings: [Recording] {
        sessions.flatMap(\.takes)
    }

    private var selectedSession: Session? {
        sessions.first { $0.id == selectedID }
    }

    /// Two levels in the main window: the grid, and a session's page over it.
    /// The grid stays in the tree under the page, hidden, so Back lands on
    /// the same filter, search, sort and scroll position; the report is a
    /// third layer over the page for the same reason. Which layer is up lives
    /// on the coordinator (mainPage), the one place the window's page is kept.
    private var detailSession: Session? {
        switch coordinator.mainPage {
        case .detail(let id), .report(let id): return sessions.first { $0.id == id }
        default: return nil
        }
    }

    private var layers: some View {
        ZStack {
            grid
                .opacity(detailSession == nil ? 1 : 0)
                .allowsHitTesting(detailSession == nil)
                .accessibilityHidden(detailSession != nil)
            if let session = detailSession {
                detailPage(session)
                    .opacity(isReport ? 0 : 1)
                    .allowsHitTesting(!isReport)
                    .accessibilityHidden(isReport)
            }
            if isReport {
                ScreenroomReportView(onBack: { coordinator.goBack() })
            }
        }
        // Grid, session, report: a short crossfade, not a hard swap. These
        // layers share the window's size, so nothing resizes.
        .animation(.easeInOut(duration: 0.15), value: coordinator.mainPage)
        .onAppear(perform: reload)
        .onChange(of: selectedID) { didSelect() }
        .onChange(of: selection) { _, newSelection in
            load(newSelection)
            review.selectedRecording = newSelection?.url
        }
        .onChange(of: coordinator.mainPage) { _, page in
            switch page {
            // Back on the grid: nothing is playing there.
            case .sessions: teardownPlayer()
            // Nobody listens to a recording under a report.
            case .report: player?.pause()
            default: break
            }
        }
        // A session finished while this page was open only appeared after
        // closing and reopening it. Coming back to the app is when a teacher
        // expects to see it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload() }
        // An upload finishing while the page is open should show up here.
        .onChange(of: coordinator.isUploadingToYouTube) { reload() }
        // An analysis finishing: the card gets its sparkles, and when this
        // page started the run, the report opens - that is what was asked for.
        .onChange(of: review.analysisRuns) {
            reload()
            if let folder = analysingFolder, review.selected?.folder == folder,
               coordinator.mainPage == .detail(folder.path) {
                coordinator.mainPage = .report(folder.path)
            }
            analysingFolder = nil
        }
        .onDisappear(perform: teardownPlayer)
    }

    private var isReport: Bool {
        if case .report = coordinator.mainPage { return true }
        return false
    }

    /// A card was clicked: a session's page replaces the grid. The player is
    /// loaded here, because picking the card that is already selected changes
    /// neither selectedID nor selection, which is what load hangs off.
    private func open(_ id: String) {
        let unchanged = selectedID == id
        selectedID = id
        coordinator.mainPage = .detail(id)
        if unchanged {
            DispatchQueue.main.async { if player == nil { load(selection) } }
        }
    }

    private var grid: some View {
        SessionsLayout(
            cards: cards,
            search: $search,
            show: $show,
            status: $status,
            sort: $sort,
            selection: $selectedID,
            thumbnail: { card in
                sessions.first { $0.id == card.id }?.primaryTake.flatMap { thumbnails.image(for: $0.url) }
            },
            storage: storageSummary,
            spaceWarning: spaceWarning,
            revealRoot: {
                NSWorkspace.shared.activateFileViewerSelecting([SessionFolders.recordingsDirectory])
            },
            onDeleteKey: { if let selection { confirmingDelete = selection } },
            cardMenu: { card in cardMenu(card) },
            onOpen: open,
            onBack: { coordinator.goBack() })
    }

    /// A session as one page: what the side inspector used to hold, with the
    /// room a page has. Same views, moved - the picture, the title and its
    /// menu, the two action cards and the work tabs.
    private func detailPage(_: Session) -> some View {
        VStack(spacing: 0) {
            HStack {
                BackButton(action: { coordinator.goBack() })
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            inspector
        }
    }

    var body: some View {
        layers
        .sheet(isPresented: $review.showingSetup) {
            AnalysisSetupPanel(
                runsOnConfirm: review.setupRunsAnalysis,
                confirm: {
                    if review.setupRunsAnalysis { review.confirmSetupAndAnalyse() }
                    else { review.showingSetup = false }
                },
                cancel: {
                    // A first press that was backed out of runs nothing, so
                    // the report does not open for a run that never was.
                    analysingFolder = nil
                    review.showingSetup = false
                })
        }
        .alert("Rename this session",
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
            Text("Shown in this window. The folder in Documents/Greenroom keeps its date name; clear the field to go back to it. Videos already on YouTube keep their titles \u{2014} rename those under the upload.")
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
        // Its own question, not a side effect of Move to Trash: YouTube has
        // no bin, so this is the one delete in the window that is final.
        .confirmationDialog("Delete this video from YouTube?",
                            isPresented: Binding(get: { deletingVideo != nil },
                                                 set: { if !$0 { deletingVideo = nil } }),
                            titleVisibility: .visible) {
            Button("Delete from YouTube", role: .destructive) {
                guard let target = deletingVideo else { return }
                deletingVideo = nil
                Task {
                    if let failure = await coordinator.deleteYouTubeVideo(target.upload, in: target.folder) {
                        deleteVideoError = failure
                    } else {
                        ToastController.show("Deleted from YouTube", detail: "The recording is still on this Mac.")
                    }
                    reload()
                }
            }
            Button("Cancel", role: .cancel) { deletingVideo = nil }
        } message: {
            Text(deletingVideo.map {
                "\u{201C}\($0.upload.title)\u{201D} is removed from the channel for good, and its link stops working. YouTube can\u{2019}t restore it. The recording on this Mac stays, and can be uploaded again."
            } ?? "")
        }
        .alert("Couldn't delete from YouTube",
               isPresented: Binding(get: { deleteVideoError != nil },
                                    set: { if !$0 { deleteVideoError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteVideoError ?? "")
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
                ($0.clips.isEmpty
                    ? "\($0.title) goes to the Trash. You can put it back from there."
                    : "\($0.title) and its \($0.clips.count) marked clip\($0.clips.count == 1 ? "" : "s") go to the Trash. You can put them back from there.")
                + ($0.upload == nil ? "" : " Its video on YouTube stays up. To take that down too, press Delete under its YouTube link first.")
            } ?? "")
        }
    }

    // MARK: Cards

    private var cards: [SessionCardModel] {
        sessions.map { session in
            SessionCardModel(id: session.id,
                             title: session.displayTitle,
                             kind: session.source.kind,
                             date: session.date,
                             duration: session.primaryTake.flatMap { take in
                                 thumbnails.duration(for: take.url).flatMap { $0 > 0 ? $0 : nil }
                             },
                             isUploaded: session.uploadCount > 0,
                             isAnalysed: session.isAnalysed)
        }
    }

    @ViewBuilder private func cardMenu(_ card: SessionCardModel) -> some View {
        if let session = sessions.first(where: { $0.id == card.id }) {
            if session.folder != nil {
                Button("Rename\u{2026}") {
                    renameDraft = session.customTitle ?? ""
                    renaming = session
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [session.folder ?? session.primaryTake?.url ?? SessionFolders.recordingsDirectory])
            }
            if let take = session.primaryTake, let upload = take.upload, let url = URL(string: upload.url) {
                Divider()
                Button("Open on YouTube") { NSWorkspace.shared.open(url) }
                Button("Copy YouTube link") { copy(upload.url) }
                if coordinator.youtubeConnected {
                    Button("Delete from YouTube\u{2026}", role: .destructive) {
                        deletingVideo = (upload, take.url.deletingLastPathComponent())
                    }
                }
            }
            if let take = session.primaryTake {
                Divider()
                Button("Move to Trash\u{2026}", role: .destructive) { confirmingDelete = take }
            }
        }
    }

    // MARK: Inspector

    @ViewBuilder private var inspector: some View {
        if let session = selectedSession {
            SessionInspector(
                model: inspectorModel(session),
                columnWidth: 800,
                actions: inspectorActions(session),
                take: Binding(get: { selection?.url },
                              set: { url in selection = session.takes.first { $0.url == url } }),
                tabs: Tab.allCases.filter(\.isAvailable).map(\.rawValue),
                tab: $tab,
                player: { stage(for: session) },
                detail: { work(for: session) })
            // A different session is a different inspector: nothing typed in
            // one session's notes field should survive into the next.
            .id(session.id)
        } else {
            Text(sessions.isEmpty ? "No sessions yet" : "Select a session")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func inspectorModel(_ session: Session) -> SessionInspectorModel {
        let take = selection
        var model = SessionInspectorModel(
            title: session.displayTitle,
            kind: session.source.kind,
            date: session.date,
            duration: take.flatMap { thumbnails.durations[$0.url] }.flatMap { $0 > 0 ? $0 : nil },
            clipCount: session.clipCount,
            youtube: youtubeState(take),
            analyse: analyseState(session),
            youtubeConnected: coordinator.youtubeConnected)
        if let upload = take?.upload {
            model.upload = .init(title: upload.title, url: upload.url,
                                 privacy: upload.privacy, uploadedAt: upload.uploadedAt)
        }
        if let folder = session.folder, review.selected?.folder == folder, let analysis = review.analysis {
            model.summary = analysis.headline ?? analysis.summary
            if review.selectionMismatch {
                model.summaryCaveat = "About \(review.analysisTarget?.lastPathComponent ?? "the longest take"), not the take playing."
            }
        }
        model.takes = session.takes.map { take in
            .init(id: take.url,
                  label: SessionClipExporter.isClip(take.url) || session.clipFiles.contains(take)
                    ? "Clip \u{00B7} \(take.url.deletingPathExtension().lastPathComponent)"
                    : "\(take.title) \u{00B7} \(take.sizeLabel)")
        }
        model.canRename = session.folder != nil
        model.canTrash = take != nil
        return model
    }

    private func youtubeState(_ take: Recording?) -> SessionInspectorModel.YouTube {
        guard let take else { return .noVideo }
        if let upload = take.upload { return .uploaded(privacy: upload.privacy, when: upload.uploadedAt) }
        if coordinator.isUploadingToYouTube { return .uploading }
        guard coordinator.youtubeConnected else { return .notConnected }
        return .ready(privacy: coordinator.youtubePrivacy)
    }

    /// Who would do the work, said before it is done. Screenroom's agent is
    /// off until someone turns it on in Settings, and when it is on the
    /// transcript and notes leave this Mac - so the tile says so, in amber.
    private func analyseState(_ session: Session) -> SessionInspectorModel.Analyse {
        guard let folder = session.folder else { return .unavailable("Not in a session folder") }
        let agent = ScreenroomAgentSettings.load()
        let leaves = agent.enabled && !agent.command.trimmingCharacters(in: .whitespaces).isEmpty
        let engine = leaves ? "\(agent.kind.label) \u{00B7} leaves this Mac" : "On this Mac"
        let isThis = review.selected?.folder == folder
        if review.isAnalysing {
            guard isThis else { return .busy }
            var detail: [String] = []
            if review.stepCount > 0 { detail.append("Step \(review.stepIndex) of \(review.stepCount)") }
            detail.append(ScreenroomAnalysisPane.clock(review.elapsed))
            if let eta = review.eta { detail.append(ScreenroomETA.label(eta)) }
            return .running(step: review.step.isEmpty ? "Working\u{2026}" : review.step,
                            detail: detail.joined(separator: " \u{00B7} "),
                            log: review.log)
        }
        if isThis, let analysis = review.analysis {
            return .analysed(engine: analysis.engine, when: analysis.generatedAt, leavesMac: false)
        }
        let hasNotes = FileManager.default.fileExists(atPath: ScreenroomNotesFile.url(in: folder).path)
        guard session.primaryTake != nil || hasNotes else { return .unavailable("Nothing to analyse") }
        return .ready(engine: engine, leavesMac: leaves)
    }

    private func inspectorActions(_ session: Session) -> SessionInspectorActions {
        let take = selection
        let upload = take?.upload
        var actions = SessionInspectorActions()
        actions.upload = { if let take { coordinator.uploadRecordingToYouTube(take.url) } }
        actions.copyLink = { if let upload { copy(upload.url) } }
        actions.openOnYouTube = {
            if let upload, let url = URL(string: upload.url) { NSWorkspace.shared.open(url) }
        }
        actions.renameOnYouTube = {
            guard let upload, let take else { return }
            videoTitleDraft = upload.title
            renamingVideo = (upload, take.url.deletingLastPathComponent())
        }
        actions.deleteFromYouTube = {
            guard let upload, let take else { return }
            deletingVideo = (upload, take.url.deletingLastPathComponent())
        }
        actions.analyse = {
            guard let folder = session.folder else { return }
            review.select(folder: folder)
            review.selectedRecording = selection?.url
            analysingFolder = folder
            review.requestAnalyse()
        }
        actions.openAnalysisSetup = { review.openSetup() }
        actions.stopAnalysis = {
            analysingFolder = nil
            review.cancel()
        }
        actions.openReport = {
            review.select(folder: session.folder)
            coordinator.mainPage = .report(session.id)
        }
        actions.rename = {
            renameDraft = session.customTitle ?? ""
            renaming = session
        }
        actions.showInFinder = {
            NSWorkspace.shared.activateFileViewerSelecting(
                [take?.url ?? session.folder ?? SessionFolders.recordingsDirectory])
        }
        actions.trash = { if let take { confirmingDelete = take } }
        return actions
    }

    /// The picture and its scrubber, or what is left when the tape is gone.
    @ViewBuilder private func stage(for session: Session) -> some View {
        if let selection {
            VStack(spacing: 8) {
                Group {
                    if let player {
                        PlayerView(player: player)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                ClipTimeline(duration: duration,
                             playhead: playhead,
                             clips: selection.clips,
                             marks: marks(for: selection),
                             skipping: skipObserver != nil,
                             onStopSkipping: stopSkipping,
                             onSeek: seek)
                    .frame(height: 46)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                SessionThumbnail(image: nil, kind: session.source.kind)
                Text("No recording here any more. The notes, transcript and report still are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Everything done on the recording, under it.
    @ViewBuilder private func work(for session: Session) -> some View {
        switch Tab(rawValue: tab) ?? .clips {
        case .notes where Tab.notes.isAvailable:
            if session.folder != nil {
                ScreenroomAnalysisPane(
                    folder: session.folder,
                    recording: selection?.url,
                    showing: .notes,
                    seek: { ms in seek(to: Double(ms) / 1000) },
                    position: { Int(playhead * 1000) },
                    rate: { player?.rate = $0 },
                    skip: { playSkipping($0) },
                    openReport: { coordinator.openReport() })
            } else {
                notInFolder("notes")
            }
        case .transcript where Tab.transcript.isAvailable:
            if let folder = session.folder {
                SessionTranscriptView(folder: folder)
            } else {
                notInFolder("transcript")
            }
        case .links where Tab.links.isAvailable:
            linksDetail(for: session)
        default:
            clipsDetail()
        }
    }

    private func notInFolder(_ what: String) -> some View {
        Text("These recordings are not in a session folder, so they have no \(what).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func clipsDetail() -> some View {
        let clips = selection?.clips ?? []
        return SessionClipsList(
            lines: clips.map { clip in
                SessionClipLine(
                    id: clip.id,
                    start: Self.offsetLabel(clip.startMs),
                    detail: "\(clip.durationLabel) \u{00B7} marked at \(clip.markedAtLabel.replacingOccurrences(of: "-", with: ":"))",
                    exported: selection.map { SessionClipExporter.isExported(clip, from: $0.url) } ?? false)
            },
            exporting: exporting,
            play: { id in
                if let clip = clips.first(where: { $0.id == id }) { seek(to: clip.startSeconds) }
            },
            reveal: { id in
                guard let selection, let clip = clips.first(where: { $0.id == id }) else { return }
                NSWorkspace.shared.activateFileViewerSelecting(
                    [SessionClipExporter.exportURL(for: clip, from: selection.url)])
            },
            remove: { id in
                guard let selection, let clip = clips.first(where: { $0.id == id }) else { return }
                removeClip(clip, from: selection)
            },
            exportAll: { if let selection { exportAll(for: selection) } })
    }

    /// The class's links: what it was, where it goes, whether it went to the
    /// chat, and Open and Copy on every row.
    @ViewBuilder private func linksDetail(for session: Session) -> some View {
        if session.links.isEmpty {
            Text("With Cues on, the cards you open or send in a class are kept here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.links) { link in
                        HStack(spacing: 8) {
                            Image(systemName: link.action == "sent" ? "paperplane" : "arrow.up.forward.square")
                                .foregroundStyle(.secondary)
                                .help(link.action == "sent" ? "Sent to chat" : "Opened")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.title).font(.callout).lineLimit(1)
                                Text("\(link.kind) \u{00B7} \(URL(string: link.url)?.host ?? link.url) \u{00B7} \(link.at.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if let url = URL(string: link.url) {
                                Button("Open") { NSWorkspace.shared.open(url) }.controlSize(.small)
                            }
                            Button("Copy") { copy(link.url) }.controlSize(.small)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        ToastController.show("Link copied", detail: text)
    }

    /// A card was picked: play its main take, and point Screenroom's state at
    /// its folder so the analysis tile, the notes and the scrubber's marks
    /// all describe this session.
    private func didSelect() {
        let session = selectedSession
        if selection == nil || !(session?.takes.contains(where: { $0.url == selection?.url }) ?? false) {
            selection = session?.primaryTake
        }
        review.externalSeek = { ms in seek(to: Double(ms) / 1000) }
        review.externalRate = { player?.rate = $0 }
        review.externalSkip = { playSkipping($0) }
        review.currentPosition = { Int(playhead * 1000) }
        review.select(folder: session?.folder)
        review.selectedRecording = selection?.url
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
        // Loaded, not played. Opening a class to read its transcript or copy
        // its link started the recording with sound, on a Mac that is often
        // in a staffroom.
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
        guard let folder = sessions.first(where: { $0.takes.contains(selection) })?.folder,
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
        // reload() below moves the inspector to what is left of the session,
        // or to the next session when this was its only take.
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
        guard folder != SessionFolders.recordingsDirectory else { return }
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
        freeBytes = SessionFolders.recordingsFreeBytes
        usedBytes = SessionFolders.recordingsUsedBytes
        let root = SessionFolders.recordingsDirectory
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
            // The same goes for a class whose only record is the notes typed
            // during it, or an analysis kept after the video was deleted.
            let manager = FileManager.default
            let hasNotes = manager.fileExists(atPath: ScreenroomNotesFile.url(in: folder).path)
            let isAnalysed = manager.fileExists(atPath: ScreenroomAnalysis.url(in: folder).path)
                || manager.fileExists(atPath: ScreenroomReport.url(in: folder).path)
            guard !recordings.isEmpty || !clips.isEmpty || !metadata.links.isEmpty
                    || isMarked || hasNotes || isAnalysed else { return nil }
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
                           kind: metadata.kind,
                           isAnalysed: isAnalysed)
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
        // The selected card must still exist; when it went to the Trash,
        // the newest session takes its place rather than an empty inspector.
        if selectedID == nil || !sessions.contains(where: { $0.id == selectedID }) {
            selectedID = sessions.first?.id
        }
        // A take whose file just went to the Trash must not linger.
        if let current = selection, !allRecordings.contains(where: { $0.url == current.url }) {
            teardownPlayer()
            selection = nil
        } else if let current = selection,
                  let refreshed = allRecordings.first(where: { $0.url == current.url }) {
            selection = refreshed   // pick up clip changes without reloading the player
        }
        didSelect()
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

    private var spaceLevel: SessionFolders.SpaceLevel {
        freeBytes.map(SessionFolders.spaceLevel(freeBytes:)) ?? .ok
    }

    /// Amber for "plan ahead", red for "this class may not fit". Semantic system
    /// colours rather than Brand.net: this is about the disk, not about
    /// anything leaving the Mac, and amber here would claim that it was.
    private var spaceColor: Color { spaceLevel == .critical ? .red : .orange }

    private var spaceWarning: (text: String, color: Color)? {
        guard spaceLevel != .ok, let freeBytes else { return nil }
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return (spaceLevel == .critical
                    ? "Only \(free) left \u{2014} that may not fit a full class. Move or delete a few recordings before your next session."
                    : "\(free) left \u{2014} room for about two more classes.",
                spaceColor)
    }

    /// "~/Documents/Greenroom · 12 GB used · 38 GB free".
    private var storageSummary: String {
        let path = SessionFolders.recordingsDirectory.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let used = ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
        guard let freeBytes else { return "\(path) \u{00B7} \(used) used" }
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return "\(path) \u{00B7} \(used) used \u{00B7} \(free) free"
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
