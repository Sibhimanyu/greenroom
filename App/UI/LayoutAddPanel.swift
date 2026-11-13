//
//  LayoutAddPanel.swift
//  Greenroom
//
//  The "+ Add" popover in Settings -> Layout's editor: every piece a layout can
//  hold, as tiles in three groups (Meeting, Chat, Apps). Click a tile to add it
//  into the largest free space, or drag it onto the canvas (the same payload the
//  old chips carried). A tile that cannot be added right now is dimmed, not
//  hidden, and says why on hover, on click and in the line at the foot.
//
//  Plain values in, closures out, like `LayoutPageContent`, so the panel can be
//  rendered off screen (.context/lr/go.sh).
//
import SwiftUI
import AppKit

struct LayoutAddPanel: View {
    let customUIMode: Bool
    let apps: [AppInfo]
    /// Why this cannot be added right now; nil when it can.
    let reason: (LayoutPiece.Kind) -> String?
    /// Whether the layout already holds it (shown with a tick).
    let isPlaced: (LayoutPiece.Kind) -> Bool
    let add: (LayoutPiece.Kind) -> Void
    let close: () -> Void
    /// A tile to show as already pointed at, for the off-screen render.
    var initialNote: String?
    /// Whether the six meeting views are offered; injectable for tests and renders.
    var viewsEnabled = MeetingViewPieces.enabled

    /// Which apps count as running; injectable for tests and renders.
    var runningBundleIDs: Set<String> = LayoutAddPanel.currentlyRunning()

    @State private var hovered: String?
    @State private var noted: String?
    @State private var query = ""
    @FocusState private var focus: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let columns = 4
    private static let tileWidth: CGFloat = 84
    private static let tileHeight: CGFloat = 84
    private static let gap: CGFloat = 8
    private static let sidePad: CGFloat = 14
    private static let topPad: CGFloat = 12
    /// Room inside the scroller so a 2pt focus ring is never cut at its edges.
    private static let ringInset: CGFloat = 3
    private static let maxHeight: CGFloat = 520
    private static let captionHeight: CGFloat = 30
    /// Four tiles, three gaps and the 14pt padding either side.
    private static let panelWidth: CGFloat = 4 * 84 + 3 * 8 + 28

    static func currentlyRunning() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
    }

    // MARK: Items

    struct Item: Identifiable {
        let id: String
        let title: String
        let kind: LayoutPiece.Kind
        var symbol = ""
        var icon: NSImage?
        var view: MeetingView?
        var reason: String?
        var placed = false
        var available: Bool { reason == nil }
    }

    private func item(_ id: String, _ title: String, _ kind: LayoutPiece.Kind, symbol: String = "",
                      icon: NSImage? = nil, view: MeetingView? = nil) -> Item {
        Item(id: id, title: title, kind: kind, symbol: symbol, icon: icon, view: view,
             reason: reason(kind), placed: isPlaced(kind))
    }

    /// Everything on screen, grouped. Built once per body.
    private struct Visible {
        var top: [Item]      // Meeting window, any views, then Chat
        var suggested: [Item]
        var rest: [Item]
        var searching: Bool
        var appCount: Int
        var all: [Item] { top + suggested + rest }
        var scrolled: [Item] { suggested + rest }
    }

    private var visible: Visible {
        let meeting = MeetingViewPieces.addEntries(customUIMode: customUIMode, viewsEnabled: viewsEnabled).map { entry -> Item in
            let view = entry.kind.view
            return item(entry.id, entry.title, entry.kind, symbol: view?.symbol ?? "video.fill", view: view)
        }
        let chat = item("chat", "Chat", .chat, symbol: "bubble.left.and.bubble.right.fill")
        let byID = Dictionary(apps.map { ("app:\($0.bundleID)", $0) }, uniquingKeysWith: { first, _ in first })
        let arranged = LayoutAppOrdering.arrange(
            apps.map { LayoutAppCandidate(id: "app:\($0.bundleID)", name: $0.name,
                                          isBrowser: AppCatalog.isBrowser($0.bundleID),
                                          isRunning: runningBundleIDs.contains($0.bundleID)) },
            query: query)
        func tiles(_ ids: [String]) -> [Item] {
            ids.compactMap { id in
                byID[id].map { app in
                    item(id, app.name, .app(AppPiece(bundleID: app.bundleID)),
                         symbol: "app.dashed", icon: LayoutIcons.icon(app.bundleID))
                }
            }
        }
        return Visible(top: meeting + [chat], suggested: tiles(arranged.suggested),
                       rest: tiles(arranged.rest), searching: arranged.searching, appCount: apps.count)
    }

    /// The tiles as rows of four per group, for the arrow keys.
    private func rows(_ v: Visible) -> [[String]] {
        [v.top, v.suggested, v.rest].flatMap { group in
            stride(from: 0, to: group.count, by: Self.columns).map { start in
                group[start..<min(start + Self.columns, group.count)].map(\.id)
            }
        }
    }

    private static func rowCount(_ n: Int) -> Int { (n + columns - 1) / columns }
    private static func gridHeight(_ n: Int) -> CGFloat {
        let r = rowCount(n)
        return r == 0 ? 0 : CGFloat(r) * tileHeight + CGFloat(r - 1) * gap
    }

    // MARK: Body

    var body: some View {
        let v = visible
        let all = v.all
        VStack(alignment: .leading, spacing: 0) {
            // Pinned: the Meeting and Chat groups never scroll.
            section("Meeting and chat", v.top)
                .padding(.horizontal, Self.sidePad)
                .padding(.top, Self.topPad)

            appsSection(v)
                .padding(.horizontal, Self.sidePad)
                .padding(.top, 8)
                .padding(.bottom, 6)

            // Pinned footer: hairline, then the line, on the popover's own background.
            Divider()
            captionLine(all)
                .padding(.horizontal, Self.sidePad)
                .padding(.vertical, 6)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: Self.panelWidth)
        .onExitCommand(perform: close)
        .onAppear {
            noted = initialNote
            if initialNote == nil {
                // A tile is focused on open so the arrows and Return work straight away.
                DispatchQueue.main.async { focus = all.first(where: \.available)?.id ?? all.first?.id }
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(Self.tileWidth), spacing: Self.gap), count: Self.columns)
    }

    private func section(_ title: String, _ items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            heading(title)
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Self.gap) {
                ForEach(items) { tile($0) }
            }
        }
    }

    /// Height left for the app scroller under the 520pt ceiling, after everything pinned.
    private func scrollHeight(_ v: Visible) -> CGFloat {
        let pinnedTop = Self.topPad + 14 + 4 + Self.gridHeight(v.top.count)
        let appsChrome: CGFloat = 8 + 14 + 4 + 28 + 4 + 6       // gap, heading, gap, search, gap, bottom pad
        let footer: CGFloat = 1 + 6 + Self.captionHeight + 6
        // At the cap, at least three full tile rows stay visible.
        let threeRows = Self.gridHeight(3 * Self.columns) + 2 * Self.ringInset
        let room = max(threeRows, Self.maxHeight - pinnedTop - appsChrome - footer)
        var content: CGFloat = 2 * Self.ringInset
        if v.rest.isEmpty && v.suggested.isEmpty {
            content += 24
        } else {
            if !v.suggested.isEmpty { content += 14 + 4 + Self.gridHeight(v.suggested.count) }
            if !v.suggested.isEmpty && !v.rest.isEmpty { content += 8 }
            if !v.rest.isEmpty { content += (v.searching ? 0 : 14 + 4) + Self.gridHeight(v.rest.count) }
        }
        return min(content, room)
    }

    /// The only scrolling region: its own frame, clipped, so nothing draws outside it.
    private func appsSection(_ v: Visible) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            heading("Apps")
            if v.appCount == 0 {
                Text("No apps found on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                searchField(v)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) {
                            if v.scrolled.isEmpty {
                                Text("No app matches \u{2018}\(query.trimmingCharacters(in: .whitespaces))\u{2019}")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                            }
                            if !v.suggested.isEmpty {
                                appGroup("Suggested", v.suggested, labelled: !v.searching)
                            }
                            if !v.rest.isEmpty {
                                appGroup("All apps", v.rest, labelled: !v.searching)
                            }
                        }
                        .padding(Self.ringInset)
                    }
                    .frame(width: Self.panelWidth - 2 * Self.sidePad + 2 * Self.ringInset,
                           height: scrollHeight(v))
                    .clipped()
                    .padding(.horizontal, -Self.ringInset)
                    .onChange(of: focus) { _, id in
                        if let id, v.scrolled.contains(where: { $0.id == id }) { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    private func appGroup(_ title: String, _ items: [Item], labelled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if labelled { heading(title) }
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Self.gap) {
                ForEach(items) { tile($0).id($0.id) }
            }
        }
    }

    private func searchField(_ v: Visible) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search apps", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onKeyPress(.downArrow) {
                    if let first = v.scrolled.first { focus = first.id }
                    return .handled
                }
                .onExitCommand(perform: close)
                .accessibilityLabel("Search apps")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(searchFocused ? Brand.green : Color.secondary.opacity(0.25), lineWidth: searchFocused ? 2 : 1))
    }

    private func captionLine(_ all: [Item]) -> some View {
        let id = hovered ?? noted ?? focus
        let current = all.first { $0.id == id }
        let text = current.map { $0.reason ?? "Click to add, or drag onto the canvas." }
            ?? "Click to add, or drag onto the canvas."
        return Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            // Room for two lines always, so the popover does not jump as you hover.
            .frame(maxWidth: .infinity, minHeight: Self.captionHeight, alignment: .topLeading)
            .accessibilityHidden(true)   // each tile speaks its own state
    }

    // MARK: A tile

    @ViewBuilder
    private func tile(_ item: Item) -> some View {
        let face = Button { activate(item) } label: {
            VStack(spacing: 4) {
                glyph(item)
                    .frame(height: 34)
                Text(item.title)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .frame(width: Self.tileWidth, height: Self.tileHeight, alignment: .top)
        }
        .greenroomTile(role: .choice(selected: item.placed))
        .opacity(item.available ? 1 : 0.45)

        let interactive = face
            .focusable()
            .focused($focus, equals: item.id)
            .onKeyPress(keys: [.return, .space, .leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                key(press, on: item)
            }
            // Typing while a tile has focus starts a search.
            .onKeyPress(characters: .alphanumerics) { press in
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
                query += press.characters
                searchFocused = true
                return .handled
            }
            .onHover { inside in
                if inside { hovered = item.id } else if hovered == item.id { hovered = nil }
            }
            .help(item.reason ?? item.title)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.title)
            .accessibilityValue(item.placed ? "Already in this layout" : (item.reason ?? "Available"))
            .accessibilityHint(item.available ? "Adds it to the layout" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { activate(item) }
            .accessibilityAction(named: "Add to layout") { activate(item) }
        if item.available {
            interactive.draggable(LayoutPalettePayload.string(for: item.kind))
        } else {
            interactive
        }
    }

    @ViewBuilder
    private func glyph(_ item: Item) -> some View {
        if let view = item.view {
            MeetingViewDiagram(view: view)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                .frame(width: 42, height: 28)
        } else if let icon = item.icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: 32, height: 32)
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions and keys

    private func activate(_ item: Item) {
        noted = item.id
        if item.available { add(item.kind) }
    }

    private func key(_ press: KeyPress, on item: Item) -> KeyPress.Result {
        switch press.key {
        case .return, .space:
            activate(item)
            return .handled
        case .leftArrow: return move(from: item.id, columns: -1, rows: 0)
        case .rightArrow: return move(from: item.id, columns: 1, rows: 0)
        case .upArrow: return move(from: item.id, columns: 0, rows: -1)
        case .downArrow: return move(from: item.id, columns: 0, rows: 1)
        default: return .ignored
        }
    }

    /// Left and right walk the tiles in reading order (across rows and groups);
    /// up and down keep the column, clamped to a shorter row.
    private func move(from id: String, columns: Int, rows dy: Int) -> KeyPress.Result {
        let grid = rows(visible)
        guard let r = grid.firstIndex(where: { $0.contains(id) }),
              let c = grid[r].firstIndex(of: id) else { return .ignored }
        var target: String?
        if columns != 0 {
            let flat = grid.flatMap { $0 }
            if let i = flat.firstIndex(of: id), flat.indices.contains(i + columns) { target = flat[i + columns] }
        } else if grid.indices.contains(r + dy) {
            let row = grid[r + dy]
            target = row[min(c, row.count - 1)]
        }
        guard let target else { return .handled }   // at an edge: stay put, keep the key
        focus = target
        return .handled
    }
}
