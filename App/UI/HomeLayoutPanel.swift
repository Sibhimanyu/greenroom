//
//  HomeLayoutPanel.swift
//
//  The Layout tile's popover: every layout as a tile with its own small
//  diagram (None first), the two actions that belong to a layout (show it on
//  screen, open its apps), and a quiet note with the choices disabled while a
//  meeting runs the layout it started with. Footer opens Settings -> Layout.
//  Built only from the layout library; what shows is decided by
//  LayoutPanelRules. Shell: HomeTilePanels.swift.
//
//  Not built, would need new code: duplicating or renaming a layout from here,
//  and a picture of a layout on a second display (the diagram shows one
//  display, as the hover card did).
//
import SwiftUI

struct HomeLayoutPanel: View {
    @ObservedObject var coordinator: CoordinatorController
    let more: () -> Void
    let close: () -> Void

    @State private var index = 0
    @State private var keyed = false

    private struct Choice: Identifiable {
        var id: String
        var template: LayoutTemplate?
        var name: String
    }

    private var library: LayoutLibrary { coordinator.layoutLibrary }
    private var locked: Bool { coordinator.layoutChoiceLocked }
    private var choices: [Choice] {
        [Choice(id: "none", template: nil, name: "None")]
            + library.templates.map { Choice(id: $0.id.uuidString, template: $0, name: $0.name) }
    }

    private func isSelected(_ choice: Choice) -> Bool { choice.template?.id == library.activeID }

    var body: some View {
        let active = library.active
        let sections = LayoutPanelRules.sections(
            locked: locked, activePieceCount: active?.pieceCount, hasApps: coordinator.layoutHasApps)
        HomeTilePanel(
            title: "Layout", summary: "Where Start puts the meeting, the chat and your apps.",
            value: LayoutPanelRules.headerValue(name: coordinator.layoutChoiceName),
            note: LayoutPanelRules.twoDisplayNote(
                hasTwoDisplays: active?.twoDisplays != nil,
                secondConnected: active?.twoDisplays.map { LayoutScreenPreview.secondScreen(uuid: $0.secondUUID) != nil } ?? false
            ).map { (symbol: "rectangle.on.rectangle", text: $0) },
            art: DockHintVisual.layout(active?.oneDisplay) { [coordinator] piece in
                LayoutPageContent.look(piece, customUIMode: coordinator.customUIMode,
                                       canMoveApps: AppWindowManager.hasAccessibilityPermission)
            },
            moreTitle: "Edit layouts\u{2026}", onMore: more
        ) {
            ForEach(sections, id: \.self) { section in
                switch section {
                case .layouts:
                    HomeTileSection(title: "Layouts") { grid }
                case .locked:
                    Text(LayoutPanelRules.lockedNote)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .actions:
                    HomeTileSection(title: "Actions") {
                        if let active, LayoutPanelRules.showsShowOnScreen(activePieceCount: active.pieceCount) {
                            actionRow("Show on screen", symbol: "rectangle.on.rectangle",
                                      help: "Preview this layout on your screen") {
                                LayoutPageContent.showOnScreen(active, customUIMode: coordinator.customUIMode,
                                                               canMoveApps: AppWindowManager.hasAccessibilityPermission)
                                close()
                            }
                        }
                        if coordinator.layoutHasApps {
                            actionRow("Open this layout\u{2019}s apps", symbol: "macwindow.on.rectangle",
                                      help: "Opens the layout\u{2019}s apps in their places now, without starting a meeting.") {
                                coordinator.openMainAppWindow()
                                close()
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 330)
    }

    // MARK: Tiles

    private var grid: some View {
        let rows = choices
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { offset, choice in
                    Button { pick(offset) } label: { tile(choice) }
                        .greenroomTile(role: .choice(selected: isSelected(choice)), radius: 10)
                        .overlay { HomeTileKeyRing(show: keyed && index == offset, radius: 10) }
                        .disabled(locked)
                        .help(choice.template?.twoDisplays != nil ? "\(choice.name). \(LayoutPanelRules.twoDisplayBadgeHelp)" : choice.name)
                        .accessibilityLabel(choice.name)
                        .accessibilityAddTraits(isSelected(choice) ? .isSelected : [])
                }
            }
        .padding(1)
        .opacity(locked ? 0.6 : 1)
        .homeTileKeys(axis: .horizontal, count: rows.count, index: $index, keyed: $keyed,
                      selected: rows.firstIndex(where: isSelected), autofocus: true) { if !locked { pick($0) } }
    }

    private func tile(_ choice: Choice) -> some View {
        let selected = isSelected(choice)
        return VStack(spacing: 5) {
            Group {
                if let template = choice.template, !template.oneDisplay.isEmpty {
                    LayoutThumbnail(pieces: template.oneDisplay, aspect: 1.6) { [coordinator] piece in
                        LayoutPageContent.look(piece, customUIMode: coordinator.customUIMode,
                                               canMoveApps: AppWindowManager.hasAccessibilityPermission)
                    }
                } else {
                    Image(systemName: choice.template == nil ? "rectangle.dashed" : "rectangle.split.2x1")
                        .font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 40)
            Text(choice.name)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if choice.template?.twoDisplays != nil {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .padding(4)
                    .help(LayoutPanelRules.twoDisplayBadgeHelp)
            }
        }
    }

    private func pick(_ offset: Int) {
        guard !locked, choices.indices.contains(offset) else { return }
        coordinator.layoutLibrary.select(choices[offset].template?.id)
    }

    private func actionRow(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Brand.text)
        .help(help)
    }
}
