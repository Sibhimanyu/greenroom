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
    /// False while a session's page is up over this grid (the grid stays in
    /// the tree to keep its place). Its toolbar items and Back then step
    /// aside, so the window has one toolbar, the page's.
    var isActive = true
    /// The window subtitle to hold while another page is up.
    var subtitleOverride: String?

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
        .toolbar { if isActive { gridToolbar } }
        .pageToolbar(back: isActive ? onBack.map { PageBack(label: "Home", action: $0) } : nil,
                     subtitle: subtitleOverride ?? query.subtitle)
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
        if lines.isEmpty {
            ContentUnavailableView {
                Label("No clips marked", systemImage: "scissors")
            } description: {
                Text("Use the clip shortcuts (Settings \u{2192} Shortcuts) during a class to mark the last 1, 2 or 5 minutes. Marks appear here afterwards.")
            }
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(lines) { line in
                            row(line)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Divider()
                footer
            }
        }
    }

    /// Export all lives at the foot of the list, where the clips end.
    private var footer: some View {
        HStack {
            if let exporting {
                ProgressView(value: Double(exporting.done), total: Double(max(1, exporting.total)))
                    .frame(maxWidth: 120)
                Text("\(exporting.done)/\(exporting.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Export all", action: exportAll)
                .disabled(exporting != nil)
                .help("Cuts every marked clip into its own file, next to the recording.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func row(_ line: SessionClipLine) -> some View {
        HStack(spacing: 10) {
            Button { play(line.id) } label: {
                HStack(spacing: 10) {
                    Text(line.start)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
