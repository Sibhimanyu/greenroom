//
//  SessionsContent.swift
//  Greenroom
//
//  The Sessions window as a drawing: a timeline of sessions grouped by day,
//  each row saying what is still left to do (SessionChips), searchable by
//  title and by what was said (SessionsIndex, TranscriptSearch).
//
//  Nothing in this file knows about the coordinator, the disk, AVKit or
//  Screenroom. RecordingsView scans the folders, owns the player and runs the
//  actions, and hands this file plain values and closures. The split is what
//  lets the window be drawn off screen with staged data (.context/sr/) - and it
//  keeps the layout honest, since a layout that can only be checked by opening
//  the real window with real recordings in it is one nobody checks.
//
//  Why a list by day again: the owner chose "One Timeline" (redesign r01).
//  A row carries its frame, its time and its state, so a teacher can tell
//  from the list alone what still needs doing, without opening anything.
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
    /// Set when the disk is getting full: amber for "plan ahead", red for
    /// "the next class may not fit". Said above the grid, in that colour.
    var spaceWarning: (text: String, color: Color)?
    var now = Date()
    var onDeleteKey: () -> Void = {}
    /// The cards picked in the grid (click, Command-click, Shift-click).
    @Binding var marked: SessionSelection
    /// Move the picked sessions (in display order) to the Trash; the host asks
    /// once and does it.
    var onTrashMany: ([String]) -> Void = { _ in }
    var onRevealMany: ([String]) -> Void = { _ in }
    @ViewBuilder let cardMenu: (SessionCardModel) -> CardMenu
    /// A card was double-clicked, or Return pressed on the focused one: open
    /// its page. A single click only selects. The grid itself never shows a session's detail.
    var onOpen: (String) -> Void = { _ in }
    /// A transcript result was clicked: open the session at that second.
    /// The time is also left in SessionsPendingSeek.shared for the page to
    /// take; a host that does not pass this still opens the session.
    var onOpenAt: (String, Double) -> Void = { _, _ in }
    /// The way back to Home; nil where the grid is drawn on its own.
    var onBack: (() -> Void)?
    /// False while a session's page is up over this grid (the grid stays in
    /// the tree to keep its place). Its toolbar items and Back then step
    /// aside, so the window has one toolbar, the page's.
    var isActive = true
    /// The window subtitle to hold while another page is up.
    var subtitleOverride: String?

    @FocusState private var focusedID: String?
    @ObservedObject private var index = SessionsIndex.shared
    /// The sidebar's NEEDS YOU choice ("" for none).
    @AppStorage("sessionsNeed") private var needRaw = ""

    private var query: SessionsQuery {
        SessionsQuery(cards: index.enrich(cards), show: show, status: status,
                      need: SessionsNeed(rawValue: needRaw), search: search,
                      transcriptHits: index.hits(for: search), sort: sort, now: now)
    }

    /// The detail column's content. The sidebar is the window's own column
    /// (SessionsSidebar.swift), and the toolbar items below land over this
    /// column because that is where this view sits.
    var body: some View {
        timeline
            .frame(minWidth: 480, maxHeight: .infinity)
            .task(id: cards) { await index.refresh(cards) }
            .searchable(text: $search, placement: .toolbar, prompt: "Search titles and what was said")
            .toolbar { gridToolbar }
            // Subtitle only. Back is ContentView's one page-wide item; a second
            // one here drew two side by side.
            .navigationSubtitle(subtitleOverride ?? query.subtitle)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var gridToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { sortMenu }
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
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

    // MARK: Timeline

    private var timeline: some View {
        let q = query
        let groups = q.dayGroups
        // Every row on screen in the order drawn.
        let order = groups.flatMap { $0.cards.map(\.id) }
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
                    .padding(.bottom, 12)
                }

                if groups.isEmpty {
                    empty(q)
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    ForEach(Array(groups.enumerated()), id: \.element.day) { index, group in
                        if index > 0 { Divider().padding(.vertical, 10) }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(group.title).font(.system(size: 15, weight: .bold))
                            Text(group.subtitle).font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 8)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(group.cards) { card in
                            row(card, order: order, hits: q.transcriptHits[card.id] ?? [])
                        }
                    }
                    if q.isSearching, let note = untranscribedNote(q) {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 14)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            // Empty space clears the selection.
            .background {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { marked.clear() }
            }
        }
        .onChange(of: focusedID) { _, id in if let id { selection = id } }
        // Delete trashes the picked rows, as in Finder; with none picked it
        // trashes the focused one, as it did before.
        .onDeleteCommand {
            if marked.isEmpty { onDeleteKey() } else { onTrashMany(marked.ordered(order)) }
        }
        .onKeyPress(.escape) {
            guard !marked.isEmpty else { return .ignored }
            marked.clear()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "a")) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            marked.selectAll(order)
            return .handled
        }
        .pageScrollEdge()
        // A filter or search that hides a picked row un-picks it.
        .onChange(of: order) { _, now in marked.keep(only: now) }
        .overlay(alignment: .bottom) {
            if !marked.isEmpty { selectionBar(order) }
        }
        // The list is unmounted while a session's page is up (its search field
        // would otherwise stay in the toolbar), so Back finds the place again.
        .onAppear { if let selection { proxy.scrollTo(selection, anchor: .center) } }
        }
    }

    /// Under the results: classes that could not be searched by what was said.
    private func untranscribedNote(_ q: SessionsQuery) -> String? {
        let n = q.ofKind.filter { !$0.hasTranscript && $0.kind != .recording }.count
        guard n > 0 else { return nil }
        return n == 1 ? "1 meeting has no transcript, so only its title was searched."
                      : "\(n) meetings have no transcript, so only their titles were searched."
    }

    private func row(_ card: SessionCardModel, order: [String], hits: [TranscriptHit]) -> some View {
        SessionRow(card: card, image: thumbnail(card), now: now,
                   selected: marked.contains(card.id), hits: hits, term: search,
                   onSelect: { clicked(card.id, order: order) },
                   onOpen: {
                       marked.click(card.id, order: order, command: false, shift: false)
                       selection = card.id
                       onOpen(card.id)
                   },
                   onOpenAt: { seconds in
                       selection = card.id
                       SessionsPendingSeek.shared.set(card.id, seconds: seconds)
                       onOpenAt(card.id, seconds)
                   },
                   menu: {
                       if marked.count > 1, marked.contains(card.id) {
                           let ids = marked.ordered(order)
                           Button("Move \(ids.count) to Trash\u{2026}", role: .destructive) { onTrashMany(ids) }
                           Button("Show in Finder") { onRevealMany(ids) }
                       } else {
                           cardMenu(card)
                       }
                   })
        .focused($focusedID, equals: card.id)
        .id(card.id)
    }

    private func clicked(_ id: String, order: [String]) {
        let flags = NSEvent.modifierFlags
        marked.click(id, order: order,
                     command: flags.contains(.command), shift: flags.contains(.shift))
        selection = id
    }

    /// "N selected", Move to Trash, Deselect, floating over the grid.
    private func selectionBar(_ order: [String]) -> some View {
        HStack(spacing: 12) {
            Text("\(marked.count) selected")
                .font(.callout.weight(.semibold))
            Button("Move to Trash\u{2026}", role: .destructive) {
                onTrashMany(marked.ordered(order))
            }
            Button("Deselect") { marked.clear() }
        }
        .greenroomGlassButton()
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .greenroomGlass(in: Capsule())
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private func empty(_ q: SessionsQuery) -> some View {
        if q.isSearching {
            ContentUnavailableView.search(text: search)
        } else if status != nil || needRaw != "" {
            ContentUnavailableView("Nothing matches",
                                   systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Choose All sessions in the sidebar to see more."))
        } else {
            ContentUnavailableView(show.emptyLine,
                                   systemImage: show.symbol,
                                   description: Text("Start a meeting or a recording from the main window. It lands here when it stops."))
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
    /// Picked in the grid: a ring in the brand colour (Brand.green).
    var selected = false

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
                            .help("Report ready")
                    }
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 4)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Brand.green.opacity(0.10) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Brand.green, lineWidth: 2).opacity(selected ? 1 : 0))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
        /// The whole name, for a tooltip.
        let label: String
        /// What the page's small take switch says: "Take 1", "Clip 2".
        var short: String = ""
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

    /// The line under the page's title: "Today 2:05 PM \u{00B7} 48 min \u{00B7} Class".
    var headerMeta: String {
        var parts = ["\(SessionsFormat.day(date, now: Date())) \(SessionsFormat.time(date))"]
        if let duration { parts.append(SessionsFormat.length(duration)) }
        parts.append(kind.label)
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
    /// Opens the Ready popover (Get feedback, Run again). Runs nothing.
    var analyse: () -> Void = {}
    /// The popover's Start: runs what it was opened for.
    var start: () -> Void = {}
    /// Transcribe only: opens the same Ready popover with its one step.
    var transcribe: () -> Void = {}
    var openAnalysisSetup: () -> Void = {}
    var stopAnalysis: () -> Void = {}
    var openReport: () -> Void = {}
    var rename: () -> Void = {}
    var showInFinder: () -> Void = {}
    var trash: () -> Void = {}
    var edit: () -> Void = {}
    /// Opens Settings on the YouTube tab.
    var connectYouTube: () -> Void = {}
}
