//
//  SessionsContent.swift
//  Greenroom
//
//  The Sessions window as a drawing: a sidebar of filters, a grid of sessions
//  grouped by week, and an inspector for the one selected.
//
//  Nothing in this file knows about the coordinator, the disk, AVKit or
//  Screenroom. RecordingsView scans the folders, owns the player and runs the
//  actions, and hands this file plain values and closures. The split is what
//  lets the window be drawn off screen with staged data (.context/sr/) - and it
//  keeps the layout honest, since a layout that can only be checked by opening
//  the real window with real recordings in it is one nobody checks.
//
//  Why a grid and not the list it replaced: a teacher looks for a class by
//  what was on the screen at least as often as by its date, and a frame of it
//  answers that at a glance. The list made every session one more line of
//  dates. Three kinds now share the window - classes, recordings and reviews -
//  and a badge on the picture tells them apart without a second column.
//
import AppKit
import SwiftUI

// MARK: - Look

extension SessionsStatus {
    /// Amber for YouTube, because it left the Mac. Green for an analysis,
    /// which is a file in the folder.
    var tint: Color {
        switch self {
        case .notUploaded: return .secondary
        case .onYouTube: return Brand.net
        case .analysed: return Brand.text
        }
    }
}

// MARK: - The window

struct SessionsLayout<CardMenu: View>: View {
    let cards: [SessionCardModel]
    @Binding var search: String
    @Binding var show: SessionsShow
    @Binding var status: SessionsStatus?
    @Binding var sort: SessionsSort
    /// The session last opened. Never drawn as a selection; it only keeps
    /// the scroll position and tells Delete which session is meant.
    @Binding var selection: String?
    let thumbnail: (SessionCardModel) -> NSImage?
    /// "~/Documents/Greenroom \u{00B7} 38 GB free".
    let storage: String
    /// Set when the disk is getting full: amber for "plan ahead", red for
    /// "the next class may not fit". Said above the grid, in that colour.
    var spaceWarning: (text: String, color: Color)?
    var now = Date()
    var revealRoot: () -> Void = {}
    var onDeleteKey: () -> Void = {}
    @ViewBuilder let cardMenu: (SessionCardModel) -> CardMenu
    /// A card was clicked, or Return pressed on the focused one: open its
    /// page. The grid itself never shows a session's detail.
    var onOpen: (String) -> Void = { _ in }
    /// The way back to Home; nil where the grid is drawn on its own.
    var onBack: (() -> Void)?

    @State private var columns = NavigationSplitViewVisibility.all
    @FocusState private var focusedID: String?

    private var query: SessionsQuery {
        SessionsQuery(cards: cards, show: show, status: status, search: search,
                      sort: sort, now: now)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            grid
                .frame(minWidth: 480, maxHeight: .infinity)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search sessions")
        .toolbar { gridToolbar }
        .pageToolbar(back: onBack.map { PageBack(label: "Home", action: $0) },
                     subtitle: query.subtitle)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var gridToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { statusMenu }
        ToolbarItem(placement: .primaryAction) { sortMenu }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }

    private var statusMenu: some View {
        let q = query
        return Menu {
            Picker("Status", selection: $status) {
                Text("All sessions").tag(SessionsStatus?.none)
                ForEach(SessionsStatus.allCases) { option in
                    Label("\(option.rawValue) \u{00B7} \(q.count(for: option))", systemImage: option.symbol)
                        .tag(SessionsStatus?.some(option))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Status",
                  systemImage: status == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
        }
        .help(status.map { "Showing: \($0.rawValue)" } ?? "Filter by status")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(SessionsSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .help("Sort sessions")
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let q = query
        return List(selection: Binding<SessionsShow?>(get: { show }, set: { value in if let value { show = value } })) {
            Section("Show") {
                ForEach(SessionsShow.allCases) { option in
                    Label(option.rawValue, systemImage: option.symbol)
                        .badge(q.count(for: option))
                        .tag(option)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: revealRoot) {
                Text(storage)
                    .font(.footnote)
                    .foregroundStyle(spaceWarning?.color ?? .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .help("Show the folder in Finder.")
        }
    }

    // MARK: Grid

    private var grid: some View {
        let q = query
        let groups = q.groups
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let spaceWarning {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                        Text(spaceWarning.text)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                    .foregroundStyle(spaceWarning.color)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(spaceWarning.color.opacity(0.12)))
                }

                if groups.isEmpty {
                    empty(q)
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(group.title)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 16)],
                                      alignment: .leading, spacing: 16) {
                                ForEach(group.cards) { card in
                                    Button {
                                        selection = card.id
                                        onOpen(card.id)
                                    } label: {
                                        SessionCard(card: card, image: thumbnail(card), now: now)
                                    }
                                    .greenroomTile(role: .browse, radius: 12)
                                    .focused($focusedID, equals: card.id)
                                    .contextMenu { cardMenu(card) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        // Delete trashes the focused card, as in Finder. Return opens it (the
        // button's own default action while it has focus).
        .onChange(of: focusedID) { _, id in if let id { selection = id } }
        .onDeleteCommand(perform: onDeleteKey)
    }

    @ViewBuilder
    private func empty(_ q: SessionsQuery) -> some View {
        if q.isSearching {
            ContentUnavailableView.search(text: search)
        } else if status != nil {
            ContentUnavailableView("Nothing matches",
                                   systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Choose All sessions in the Status menu to see more."))
        } else {
            ContentUnavailableView(show.emptyLine,
                                   systemImage: show.symbol,
                                   description: Text("Start a class or a recording from the main window. It lands here when it stops."))
        }
    }
}

/// One session: its picture, what it is, when, how long, and where it went.
/// No box at rest; the tile style adds the hover backdrop and lift, and the
/// system draws the focus ring while the card has keyboard focus.
struct SessionCard: View {
    let card: SessionCardModel
    let image: NSImage?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SessionThumbnail(image: image, kind: card.kind)
                .overlay(alignment: .bottomLeading) {
                    KindBadge(kind: card.kind).padding(8)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(card.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if card.isUploaded {
                        Image(systemName: "play.rectangle.fill")
                            .foregroundStyle(Brand.net)
                            .help("On YouTube")
                    }
                    if card.isAnalysed {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Brand.text)
                            .help("Analysed")
                    }
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 4)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        var parts = [SessionsFormat.day(card.date, now: now)]
        if let duration = card.duration { parts.append(SessionsFormat.length(duration)) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// A frame of the recording, or the kind's glyph when there is none.
struct SessionThumbnail: View {
    let image: NSImage?
    let kind: SessionKind
    var radius: CGFloat = 10

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// The kind, over the picture: glass on macOS 26, a black capsule before.
struct KindBadge: View {
    let kind: SessionKind

    var body: some View {
        let label = Label(kind.label.uppercased(), systemImage: kind.symbol)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        if #available(macOS 26, *) {
            label
                .foregroundStyle(.primary)
                .greenroomGlass(in: Capsule())
        } else {
            label
                .background(Capsule().fill(.black.opacity(0.72)))
                .foregroundStyle(.white)
        }
    }
}


// MARK: - Inspector

/// Everything the inspector says about the selected session.
struct SessionInspectorModel {

    enum YouTube {
        case noVideo
        case notConnected
        case ready(privacy: String)
        case uploading
        case uploaded(privacy: String, when: Date)
    }

    enum Analyse {
        /// Why it cannot run here at all.
        case unavailable(String)
        /// `engine` names who does the work: "On this Mac", or the agent.
        case ready(engine: String, leavesMac: Bool)
        case running(step: String, detail: String, log: String?)
        /// Another session is being analysed; one run at a time.
        case busy
        case analysed(engine: String, when: Date, leavesMac: Bool)
    }

    struct Take: Identifiable, Hashable {
        let id: URL
        let label: String
    }

    struct UploadLine {
        let title: String
        let url: String
        let privacy: String
        let uploadedAt: Date
    }

    var title: String
    var kind: SessionKind
    var date: Date
    var duration: Double?
    var clipCount: Int
    var youtube: YouTube
    var analyse: Analyse
    /// The analysis's verdict, when there is one.
    var summary: String?
    /// Said under the summary when it describes a different take.
    var summaryCaveat: String?
    var upload: UploadLine?
    var takes: [Take] = []
    var canRename: Bool = true
    var canTrash: Bool = true
    /// The selected take has a video the editor can open.
    var canEdit: Bool = false
    var youtubeConnected: Bool = false

    var meta: String {
        var parts = [kind.label,
                     "\(SessionsFormat.day(date, now: Date())) \(SessionsFormat.time(date))"]
        if let duration { parts.append(SessionsFormat.length(duration)) }
        if clipCount > 0 { parts.append("\(clipCount) clip\(clipCount == 1 ? "" : "s")") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// What the inspector's buttons do. All optional, so the off-screen render
/// can pass nothing.
struct SessionInspectorActions {
    var upload: () -> Void = {}
    var copyLink: () -> Void = {}
    var openOnYouTube: () -> Void = {}
    var renameOnYouTube: () -> Void = {}
    var deleteFromYouTube: () -> Void = {}
    var analyse: () -> Void = {}
    var openAnalysisSetup: () -> Void = {}
    var stopAnalysis: () -> Void = {}
    var openReport: () -> Void = {}
    var rename: () -> Void = {}
    var showInFinder: () -> Void = {}
    var trash: () -> Void = {}
    var edit: () -> Void = {}
}

/// "Back", top left of a page: the way out of a page of the main window.
/// ⌘[ (as in Safari and Finder) and Esc are bound once, by ContentView, not
/// here: the grid stays alive under a session's page, and two buttons holding
/// one shortcut would let the hidden one answer.
struct BackButton: View {
    var label = "Back"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.12 : 0.07)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(label == "Back" ? "Back" : "Back to \(label)") (\u{2318}[)")
        .accessibilityLabel(label == "Back" ? "Back" : "Back to \(label)")
    }
}

struct SessionInspector<Player: View, Detail: View>: View {
    let model: SessionInspectorModel
    /// The width the page is held to. As a 400pt column it filled its
    /// space; as a page it would run the player to the window's width, so
    /// the column is capped and centred and the scroller stays at the edge.
    var columnWidth: CGFloat?
    var actions = SessionInspectorActions()
    @Binding var take: URL?
    let tabs: [String]
    @Binding var tab: String
    @ViewBuilder let player: () -> Player
    @ViewBuilder let detail: () -> Detail

    /// One scroll for the whole column, with the work pane at a fixed height
    /// inside it. Two flexible halves split the height between them evenly,
    /// which on a laptop pushed the picture off the top; a fixed pane keeps
    /// the picture where the eye starts, and the Notes and Transcript panes
    /// scroll inside themselves as they always did.
    var body: some View {
        ScrollView {
            column
                .frame(maxWidth: columnWidth)
                .frame(maxWidth: .infinity)
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                player()

                header

                HStack(spacing: 12) {
                    youtubeTile
                    analyseTile
                    editTile
                }
                .fixedSize(horizontal: false, vertical: true)

                howToAnalyse

                if let upload = model.upload { uploadLine(upload) }

                if case .running(_, _, let log?) = model.analyse, !log.isEmpty {
                    Text(log)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.head)
                }

                summary
            }
            .padding(20)

            if tabs.count > 1 {
                Picker("", selection: $tab) {
                    ForEach(tabs, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            detail()
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(height: 300)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(model.meta)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if model.takes.count > 1 {
                    Picker("Playing", selection: $take) {
                        ForEach(model.takes) { Text($0.label).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    .help("This session holds more than one recording or clip. Pick which one plays.")
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Rename\u{2026}", action: actions.rename)
                    .disabled(!model.canRename)
                Button("Show in Finder", action: actions.showInFinder)
                Divider()
                Button("Move to Trash\u{2026}", role: .destructive, action: actions.trash)
                    .disabled(!model.canTrash)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Rename, show in Finder, or move to the Trash")
        }
    }

    // MARK: Tiles

    /// Opens the take in the video editor. Saving writes a new session
    /// folder; this recording is never modified.
    @ViewBuilder private var editTile: some View {
        if model.canEdit {
            StatusTile(symbol: "scissors", tint: Brand.text,
                       title: "Edit", subtitle: "Saved as a new recording",
                       action: actions.edit)
                .help("Opens this recording in the editor. Saving makes a new recording and leaves this one untouched.")
        } else {
            StatusTile(symbol: "scissors", tint: .secondary,
                       title: "Edit", subtitle: "No recording to edit", action: nil)
        }
    }

    @ViewBuilder private var youtubeTile: some View {
        switch model.youtube {
        case .noVideo:
            StatusTile(symbol: "play.rectangle", tint: .secondary,
                       title: "Upload to YouTube", subtitle: "No recording to upload",
                       action: nil)
                .help("This session has no recording.")
        case .notConnected:
            StatusTile(symbol: "play.rectangle", tint: Brand.net,
                       title: "Upload to YouTube", subtitle: "Connect in Settings",
                       action: nil)
                .help("Connect a YouTube channel in Settings \u{2192} YouTube first. Uploading sends the recording off this Mac.")
        case .ready(let privacy):
            StatusTile(symbol: "play.rectangle", tint: Brand.net,
                       title: "Upload to YouTube", subtitle: "\(privacy.capitalized) \u{00B7} leaves this Mac",
                       subtitleColor: Brand.netText,
                       action: actions.upload)
                .help("Uploads this recording to the connected channel as \(privacy). It leaves this Mac.")
        case .uploading:
            StatusTile(symbol: "play.rectangle", tint: Brand.net,
                       title: "Uploading\u{2026}", subtitle: "Leaves this Mac",
                       subtitleColor: Brand.netText,
                       mark: .spinner, action: nil)
        case .uploaded(let privacy, let when):
            StatusTile(symbol: "play.rectangle.fill", tint: Brand.net,
                       title: "On YouTube",
                       subtitle: "\(privacy.capitalized) \u{00B7} \(SessionsFormat.day(when, now: Date()))",
                       mark: .check(Brand.net), action: actions.copyLink)
                .help("Copies the link.")
        }
    }

    /// Small, under the Analyse tile and only where Analyse can be pressed:
    /// the way back to the two choices asked at the first press.
    @ViewBuilder private var howToAnalyse: some View {
        switch model.analyse {
        case .ready, .analysed:
            HStack {
                Spacer(minLength: 0)
                Button("How to analyse\u{2026}", action: actions.openAnalysisSetup)
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Whisper, and whether this Mac or an agent you run writes the feedback.")
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var analyseTile: some View {
        switch model.analyse {
        case .unavailable(let why):
            StatusTile(symbol: "sparkles", tint: .secondary,
                       title: "Analyse", subtitle: why, action: nil)
        case .busy:
            StatusTile(symbol: "sparkles", tint: .secondary,
                       title: "Analyse", subtitle: "Another session is running",
                       action: nil)
                .help("One analysis at a time. This one can start when that one finishes.")
        case .ready(let engine, let leavesMac):
            StatusTile(symbol: "sparkles", tint: leavesMac ? Brand.net : Brand.text,
                       title: "Analyse", subtitle: engine,
                       subtitleColor: leavesMac ? Brand.netText : .secondary,
                       action: actions.analyse)
                .help(leavesMac
                      ? "Transcribes on this Mac, then sends the transcript and notes to the agent chosen under How to analyse. That part leaves this Mac; the video does not."
                      : "Transcribes on this Mac, counts pace and filler words, and writes the report. Nothing leaves this Mac.")
        case .running(let step, let detail, _):
            StatusTile(symbol: "sparkles", tint: Brand.text,
                       title: step, subtitle: detail,
                       mark: .stop(actions.stopAnalysis), action: nil)
        case .analysed(let engine, let when, let leavesMac):
            StatusTile(symbol: "sparkles", tint: leavesMac ? Brand.net : Brand.text,
                       title: "Analysed",
                       subtitle: "\(engine) \u{00B7} \(when.formatted(.relative(presentation: .named)))",
                       mark: .check(Brand.text), action: actions.openReport)
                .help("Opens the full report.")
        }
    }

    // MARK: Under the tiles

    private func uploadLine(_ upload: SessionInspectorModel.UploadLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(upload.url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 12) {
                Button("Open", action: actions.openOnYouTube)
                Button("Copy link", action: actions.copyLink)
                Button("Rename\u{2026}", action: actions.renameOnYouTube)
                    .help("Change the title on YouTube.")
                Button("Upload again", action: actions.upload)
                    .disabled(!model.youtubeConnected)
                    .help("Uploads a second copy; the existing video stays on the channel.")
                if model.youtubeConnected {
                    Button("Delete\u{2026}", action: actions.deleteFromYouTube)
                        .help("Delete the video from YouTube. The recording on this Mac stays.")
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .help("\u{201C}\(upload.title)\u{201D}, uploaded \(upload.uploadedAt.formatted(date: .abbreviated, time: .shortened))")
    }

    @ViewBuilder private var summary: some View {
        if let text = model.summary {
            VStack(alignment: .leading, spacing: 8) {
                Text("SUMMARY")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let caveat = model.summaryCaveat {
                    Text(caveat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    Button(action: actions.openReport) {
                        Text("Open the full analysis \u{2192}")
                            .foregroundStyle(Brand.text)
                    }
                    Button("Analyse again", action: actions.analyse)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .font(.callout)
            }
        }
    }
}

/// A big square-ish button that is also a status: what it does, and whether
/// it has been done.
struct StatusTile: View {
    enum Mark {
        case none
        case check(Color)
        case spinner
        case stop(() -> Void)
    }

    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var subtitleColor: Color = .secondary
    var mark: Mark = .none
    let action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { face }
                .buttonStyle(.plain)
        } else {
            face
        }
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                switch mark {
                case .none: EmptyView()
                case .check(let color):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(color)
                case .spinner:
                    ProgressView().controlSize(.small)
                case .stop(let stop):
                    Button("Stop", role: .destructive, action: stop)
                        .controlSize(.small)
                        .help("Stops the run and closes whatever it started. Nothing is written until it finishes.")
                }
            }
            .frame(height: 20)
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(action == nil && isInert ? .secondary : .primary)
                .lineLimit(1)
                .padding(.top, 4)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Nothing to press and nothing happening: drawn dimmer, per DESIGN.md's
    /// "a control that is not ready says so".
    private var isInert: Bool {
        if case .none = mark { return true }
        return false
    }
}

// MARK: - Clips

/// A clip marked on the recording, as the inspector lists it.
struct SessionClipLine: Identifiable {
    let id: UUID
    /// Where it starts, mono: "18:40".
    let start: String
    /// "1 min · marked at 9:48".
    let detail: String
    let exported: Bool
}

struct SessionClipsList: View {
    let lines: [SessionClipLine]
    var exporting: (done: Int, total: Int)?
    var play: (UUID) -> Void = { _ in }
    var reveal: (UUID) -> Void = { _ in }
    var remove: (UUID) -> Void = { _ in }
    var exportAll: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lines.isEmpty ? "NO CLIPS MARKED" : "CLIPS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                if let exporting {
                    ProgressView(value: Double(exporting.done), total: Double(max(1, exporting.total)))
                        .frame(width: 90)
                    Text("\(exporting.done)/\(exporting.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if !lines.isEmpty {
                    Button("Export all", action: exportAll)
                        .controlSize(.small)
                        .help("Cuts every marked clip into its own file, next to the recording.")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            if lines.isEmpty {
                Text("Use the clip shortcuts (Settings \u{2192} Shortcuts) during a class to mark the last 1, 2 or 5 minutes. Marks appear here afterwards.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(lines) { line in
                            row(line)
                        }
                    }
                }
            }
        }
    }

    private func row(_ line: SessionClipLine) -> some View {
        HStack(spacing: 12) {
            Button { play(line.id) } label: {
                HStack(spacing: 12) {
                    Text(line.start)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text(line.detail)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play from here")

            if line.exported {
                Button { reveal(line.id) } label: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.text)
                }
                .buttonStyle(.plain)
                .help("Cut to a file. Show it in Finder.")
            } else {
                Image(systemName: "scissors")
                    .foregroundStyle(.secondary)
                    .help("Marked, not cut yet. Export all cuts it.")
            }
            Button { remove(line.id) } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Removes the mark, and the exported clip if there is one. The recording is untouched.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }
}
