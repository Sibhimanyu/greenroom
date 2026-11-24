//
//  HomeScreenPanel.swift
//
//  The Screen tile's popover: what everyone sees behind you. Four choice tiles
//  (whole screen, a window, whiteboard, just my camera), the displays when
//  there are two or more, the open windows grouped by app, the slide-show
//  switch, and a plain note when the picked window has gone. Built only from
//  what exists (ShareTarget, DisplayResolver, screenCaptureDisplayUUID); what
//  shows is decided by ScreenPanelRules. Shell: HomeTilePanels.swift.
//
//  Not built, would need new code: live window thumbnails (a capture per
//  window, with Screen Recording permission), "share one app" (the picker
//  dropped it on purpose), and a display preview.
//
import AppKit
import SwiftUI

struct HomeScreenPanel: View {
    @ObservedObject var coordinator: CoordinatorController
    let displays: [DisplayInfo]
    let windows: [ShareTarget.Window]
    let gone: Bool
    let permissionMissing: Bool
    let value: String
    let more: () -> Void
    let close: () -> Void

    /// The Window tile was tapped but nothing is picked yet.
    @State private var browsing = false

    private var share: ShareTarget { coordinator.shareTarget }
    private var kind: SetupSummary.ShareKind {
        switch share.kind {
        case .display: return .display
        case .app: return .app
        case .window: return .window
        case .whiteboard: return .whiteboard
        case .nothing: return .nothing
        }
    }

    private var sections: [ScreenPanelRules.Section] {
        ScreenPanelRules.sections(kind: kind, displayCount: displays.count, browsingWindows: browsing,
                                  gone: gone, permissionMissing: permissionMissing)
    }

    private struct DisplayRow: Identifiable { var id: String; var title: String }

    private var displayRows: [DisplayRow] {
        [DisplayRow(id: "", title: "Automatic (your main display)")]
            + displays.map { DisplayRow(id: $0.id, title: $0.label) }
    }

    private func symbol(_ tile: ScreenPanelRules.Tile) -> String {
        switch tile {
        case .screen: return "display"
        case .window: return "macwindow"
        case .whiteboard: return "scribble"
        case .camera: return "person.crop.rectangle"
        }
    }

    private func title(_ tile: ScreenPanelRules.Tile) -> String {
        switch tile {
        case .screen: return "Whole screen"
        case .window: return "A window"
        case .whiteboard: return "Whiteboard"
        case .camera: return "Just me"
        }
    }

    var body: some View {
        let tiles = ScreenPanelRules.Tile.allCases
        let selectedTile = ScreenPanelRules.tile(for: kind)
        HomeTilePanel(
            title: "Screen", summary: "What everyone sees behind you.", value: value,
            art: DockHintVisual.share(share.kind, shape: coordinator.webcamShape, cameraOff: coordinator.cameraIsOff),
            moreTitle: "More screen settings\u{2026}", onMore: more
        ) {
            ForEach(sections, id: \.self) { section in
                switch section {
                case .share:
                    HomeTileSection(title: "Share") {
                        HomeTileChoiceRow(
                            choices: tiles.map {
                                HomeTileChoice(id: $0.rawValue, title: title($0), symbol: symbol($0),
                                               selected: $0 == selectedTile)
                            },
                            autofocus: true
                        ) { pickTile(tiles[$0]) }
                        if coordinator.cameraIsOff {
                            Text("Just me needs a camera. Pick one in Camera.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                case .gone:
                    note("\(share.displayName) isn\u{2019}t open, so everyone would see your whole screen.",
                         action: ("Pick another window", { browsing = true }))
                case .permission:
                    note("Greenroom needs Screen Recording permission to share your screen. The line under the dock opens it.")
                case .displays:
                    HomeTileSection(title: "Displays") {
                        HomeTileList(rows: displayRows, selected: displaySelected, pick: pickDisplayRow) { row, keyed in
                            HomeTileListRow(symbol: "display", title: row.title, selected: displaySelected(row),
                                            keyFocused: keyed) { pickDisplayRow(displayRows.firstIndex { $0.id == row.id } ?? 0) }
                        }
                    }
                case .windows:
                    HomeTileSection(title: "Windows") { windowList }
                case .follow:
                    HomeTileToggleRow(
                        title: "Follow slide shows",
                        isOn: Binding(get: { coordinator.shareTarget.followsSlideShow },
                                      set: { coordinator.shareTarget.followsSlideShow = $0 }),
                        help: "When the window goes full screen for a slide show, everyone sees that, and back when it ends.")
                }
            }
        }
        .frame(width: 330)
    }

    // MARK: Windows

    @ViewBuilder private var windowList: some View {
        if windows.isEmpty {
            Text("No window to share. Open one, then come back.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            let grouped = ScreenPanelRules.grouped(bundleIDs: windows.map(\.bundleID))
            let ordered = grouped.order.map { windows[$0] }
            let firsts = Dictionary(uniqueKeysWithValues: zip(grouped.order.map { windows[$0].id }, grouped.firstOfApp))
            ScrollView {
                HomeTileList(rows: ordered, selected: windowSelected, pick: { pickWindow(ordered[$0]) }) { window, keyed in
                    VStack(alignment: .leading, spacing: 2) {
                        if firsts[window.id] == true {
                            Text(window.appName)
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 4)
                        }
                        ScreenWindowRow(window: window, selected: windowSelected(window), keyFocused: keyed) {
                            pickWindow(window)
                        }
                    }
                }
            }
            // A ScrollView with only a maximum collapses to zero height in a
            // popover: "Windows" showed with nothing under it (owner,
            // 2026-11-24). Ask for the rows' own height, capped.
            .frame(height: min(190, CGFloat(ordered.count) * 34
                               + CGFloat(grouped.firstOfApp.filter { $0 }.count) * 18))
        }
    }

    private func windowSelected(_ window: ShareTarget.Window) -> Bool {
        share.kind == .window && share.appBundleID == window.bundleID && share.windowTitle == window.title
    }

    private func pickWindow(_ window: ShareTarget.Window) {
        coordinator.shareTarget.kind = .window
        coordinator.shareTarget.appBundleID = window.bundleID
        coordinator.shareTarget.appName = window.appName
        coordinator.shareTarget.windowTitle = window.title
        coordinator.requestShapeApply(rebuild: true)
        coordinator.bringSharedWindowForward(window)
        browsing = false
        close()
    }

    // MARK: Picks

    private func note(_ text: String, action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Brand.text)
            }
        }
    }

    private func pickTile(_ tile: ScreenPanelRules.Tile) {
        guard ScreenPanelRules.tileEnabled(tile, cameraOff: coordinator.cameraIsOff) else { return }
        switch tile {
        case .window:
            browsing = true
            return
        case .screen:
            browsing = false
            guard share.kind != .display else { return }
            coordinator.shareTarget.kind = .display
        case .whiteboard:
            browsing = false
            coordinator.shareTarget.kind = .whiteboard
        case .camera:
            browsing = false
            coordinator.shareTarget.kind = .nothing
        }
        coordinator.requestShapeApply(rebuild: true)
    }

    private func displaySelected(_ row: DisplayRow) -> Bool {
        share.kind == .display && coordinator.screenCaptureDisplayUUID == row.id
    }

    private func pickDisplayRow(_ index: Int) {
        guard displayRows.indices.contains(index) else { return }
        coordinator.screenCaptureDisplayUUID = displayRows[index].id
        coordinator.shareTarget.kind = .display
        coordinator.requestShapeApply(rebuild: true)
    }
}

/// A window row: the app's icon, the window's title, a check when shared.
private struct ScreenWindowRow: View {
    let window: ShareTarget.Window
    let selected: Bool
    let keyFocused: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: Self.icon(window.bundleID))
                    .resizable().frame(width: 20, height: 20)
                Text((window.title.isEmpty ? window.appName : window.title) + window.placement.menuSuffix)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.text)
                    .opacity(selected ? 1 : 0).frame(width: 14)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(hovering ? 0.7 : 0)))
        .overlay { HomeTileKeyRing(show: keyFocused, radius: 8) }
        .onHover { hovering = $0 }
        .accessibilityLabel("\(window.appName), \(window.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static var icons: [String: NSImage] = [:]
    private static func icon(_ bundleID: String) -> NSImage {
        if let cached = icons[bundleID] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[bundleID] = image
        return image
    }
}
