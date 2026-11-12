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

    @State private var hovered: String?
    @State private var noted: String?
    @FocusState private var focus: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let columns = 4
    private static let tileWidth: CGFloat = 84
    private static let tileHeight: CGFloat = 84
    private static let gap: CGFloat = 8
    private static let visibleAppRows = 3
    /// Four tiles, three gaps and the 14pt padding either side.
    private static let panelWidth: CGFloat = 4 * 84 + 3 * 8 + 28

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

    private var meetingItems: [Item] {
        let meeting = LayoutPiece.Kind.meeting(fillsDisplay: false, startsHidden: false)
        return [item("meeting", customUIMode ? "Meeting window" : "Zoom window", meeting, symbol: "video.fill")]
            + MeetingView.allCases.map { view in
                item("view:\(view.rawValue)", view.title, .view(view, startsHidden: false),
                     symbol: view.symbol, view: view)
            }
    }

    private var chatItems: [Item] {
        [item("chat", "Chat", .chat, symbol: "bubble.left.and.bubble.right.fill")]
    }

    private var appItems: [Item] {
        apps.map { app in
            item("app:\(app.bundleID)", app.name, .app(AppPiece(bundleID: app.bundleID)),
                 symbol: "app.dashed", icon: LayoutIcons.icon(app.bundleID))
        }
    }

    private var groups: [(title: String, items: [Item])] {
        [("Meeting", meetingItems), ("Chat", chatItems), ("Apps", appItems)]
    }

    private var allItems: [Item] { groups.flatMap(\.items) }

    /// The tiles as rows of four per group, for the arrow keys.
    private var rows: [[String]] {
        groups.flatMap { group in
            stride(from: 0, to: group.items.count, by: Self.columns).map { start in
                group.items[start..<min(start + Self.columns, group.items.count)].map(\.id)
            }
        }
    }

    // MARK: Body

    var body: some View {
        let all = allItems
        VStack(alignment: .leading, spacing: 10) {
            section("Meeting", meetingItems)
            section("Chat", chatItems)
            appsSection()
            Divider()
            captionLine(all)
        }
        .padding(14)
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
        VStack(alignment: .leading, spacing: 6) {
            heading(title)
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Self.gap) {
                ForEach(items) { tile($0) }
            }
        }
    }

    /// The app list can be long: it scrolls after three rows.
    private func appsSection() -> some View {
        let items = appItems
        let rowCount = (items.count + Self.columns - 1) / Self.columns
        let shown = min(max(rowCount, 1), Self.visibleAppRows)
        let height = CGFloat(shown) * Self.tileHeight + CGFloat(shown - 1) * Self.gap
        return VStack(alignment: .leading, spacing: 6) {
            heading("Apps")
            if items.isEmpty {
                Text("No apps found on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: rowCount > Self.visibleAppRows) {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Self.gap) {
                        ForEach(items) { tile($0) }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
                .frame(height: height + 4)
            }
        }
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
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
            .accessibilityHidden(true)   // each tile speaks its own state
    }

    // MARK: A tile

    @ViewBuilder
    private func tile(_ item: Item) -> some View {
        let isHovered = hovered == item.id
        let isFocused = focus == item.id
        let face = VStack(spacing: 4) {
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
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(item.placed ? Brand.green.opacity(0.12)
                  : (isHovered && item.available ? Color.secondary.opacity(0.14) : Color(nsColor: .controlBackgroundColor))))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isFocused ? Brand.green : (item.placed ? Brand.green.opacity(0.6) : Color.secondary.opacity(0.25)),
                          lineWidth: isFocused ? 2 : 1))
        .overlay(alignment: .topTrailing) {
            if item.placed {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Brand.text)
                    .padding(6)
            }
        }
        .opacity(item.available ? 1 : 0.45)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)

        let interactive = face
            .focusable()
            .focused($focus, equals: item.id)
            .focusEffectDisabled()
            .onKeyPress(keys: [.return, .space, .leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                key(press, on: item)
            }
            .onTapGesture { activate(item) }
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
        let grid = rows
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
