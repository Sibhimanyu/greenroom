//
//  SharePopout.swift
//
//  The one share pop-out (R32): a picture of what everyone sees behind you, four tiles (Whole screen,
//  A window, Whiteboard, Just me), the window picker, and Follow the slide show. Home opens it for the
//  meeting that runs (`.thisMeeting`, HomeScreenPanel); Layouts opens it for what the layout starts with
//  (`.atStart`, the "Everyone sees this" popover). It owns no state of the share: the host passes the share
//  and what each pick does, so a Layouts pick is one change to the saved layout (one undo step). What shows
//  is decided by SharePopoutRules. Built in HomeTileMetrics like every Home pop-out.
//
import AppKit
import SwiftUI

/// One row of the window list: a live window (Home) or an app (Layouts, where a saved share names an app).
struct SharePopoutWindow: Identifiable, Hashable {
    var id: String
    var bundleID: String
    var appName: String
    var title: String
    /// " (full screen)" and the like, for a live window.
    var suffix = ""
}

struct SharePopout: View {
    let context: SharePopoutContext
    let share: ShareTarget
    /// Trailing on the header line.
    let value: String
    var art: AnyView?
    let windows: [SharePopoutWindow]
    /// Home: the displays a whole-screen share can come from, and the saved choice ("" = automatic).
    var displays: [DisplayInfo] = []
    var captureDisplayID = ""
    var gone = false
    /// The saved app's name, for "isn't open".
    var goneName = "The app"
    var permissionMissing = false
    var cameraState: CameraTileRules.State = .on
    /// Layouts, two displays: which display everyone sees (nil: not offered).
    var sharedDisplay: Binding<LayoutSlot>?
    var moreTitle: String?
    var more: (() -> Void)?
    /// Home: where the share lives ("Saved to ...", "For this meeting"). Layouts shows its own row instead.
    var setupLine: String?
    /// Whole screen, Whiteboard or Just me was picked (A window opens the list instead).
    let pickTile: (ScreenPanelRules.Tile) -> Void
    let pickWindow: (SharePopoutWindow) -> Void
    var pickDisplay: (String) -> Void = { _ in }
    let setFollows: (Bool) -> Void

    @State private var browsing = false

    private var effective: ShareTarget { SharePopoutRules.readBack(share) }

    private var sections: [SharePopoutRules.Section] {
        SharePopoutRules.sections(context: context, kind: share.kind, displayCount: displays.count,
                                  hasTwoDisplays: sharedDisplay != nil, browsingWindows: browsing,
                                  gone: gone, permissionMissing: permissionMissing)
    }

    private struct DisplayRow: Identifiable { var id: String; var title: String }

    private var displayRows: [DisplayRow] {
        [DisplayRow(id: "", title: "Automatic (your main display)")] + displays.map { DisplayRow(id: $0.id, title: $0.label) }
    }

    private func symbol(_ tile: ScreenPanelRules.Tile) -> String {
        switch tile {
        case .screen: return VisibilitySymbol.share.name
        case .window: return "macwindow"
        case .whiteboard: return "scribble"
        case .camera: return VisibilitySymbol.shareNothing.name
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
        let selectedTile = ScreenPanelRules.tile(for: SharePopoutRules.shareKind(effective.kind))
        HomeTilePanel(
            title: SharePopoutRules.title(context), summary: "What everyone sees behind you.", value: value,
            setupLine: setupLine, art: art, moreTitle: moreTitle, onMore: more
        ) {
            ForEach(sections, id: \.self) { section in
                switch section {
                case .share:
                    HomeTileSection(title: "Share") {
                        HomeTileChoiceRow(
                            choices: tiles.map {
                                HomeTileChoice(id: $0.rawValue, title: title($0), symbol: symbol($0),
                                               selected: $0 == selectedTile,
                                               enabled: ScreenPanelRules.tileEnabled($0, camera: cameraState))
                            },
                            autofocus: true
                        ) { tap(tiles[$0]) }
                        if cameraState == .noDevice {
                            Text(CameraTileRules.justMeNoDeviceHint)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                case .gone:
                    note("\(goneName) isn\u{2019}t open, so everyone would see your whole screen.",
                         action: ("Pick another window", { browsing = true }))
                case .permission:
                    note("Greenroom needs Screen Recording permission to share your screen. The line under the dock opens it.")
                case .sharedDisplay:
                    if let sharedDisplay {
                        HomeTileSection(title: "Shared display") { sharedDisplayRows(sharedDisplay) }
                    }
                case .displays:
                    HomeTileSection(title: "Displays") {
                        HomeTileList(rows: displayRows, selected: { share.kind == .display && captureDisplayID == $0.id },
                                     pick: { pickDisplay(displayRows[$0].id) }) { row, keyed in
                            HomeTileListRow(symbol: "display", title: row.title,
                                            selected: share.kind == .display && captureDisplayID == row.id,
                                            keyFocused: keyed) { pickDisplay(row.id) }
                        }
                    }
                case .windows:
                    HomeTileSection(title: context == .atStart ? "App" : "Windows") { windowList }
                case .follow:
                    HomeTileToggleRow(
                        title: "Follow slide shows",
                        isOn: Binding(get: { share.followsSlideShow }, set: setFollows),
                        help: "When the window goes full screen for a slide show, everyone sees that, and back when it ends.")
                }
            }
        }
    }

    private func tap(_ tile: ScreenPanelRules.Tile) {
        guard ScreenPanelRules.tileEnabled(tile, camera: cameraState) else { return }
        if tile == .window { Collapse.animate { browsing = true }; return }
        // The rows that depend on the pick (shared display, windows, slide shows) fold with the same animation.
        Collapse.animate {
            browsing = false
            pickTile(tile)
        }
    }

    private func sharedDisplayRows(_ slot: Binding<LayoutSlot>) -> some View {
        let rows = [(LayoutSlot.main, "Main display"), (.second, "Second display")]
        return HomeTileList(rows: rows.map { DisplayRow(id: "\($0.0)", title: $0.1) },
                            selected: { $0.id == "\(slot.wrappedValue)" },
                            pick: { slot.wrappedValue = rows[$0].0 }) { row, keyed in
            HomeTileListRow(symbol: row.id == "\(LayoutSlot.second)" ? VisibilitySymbol.twoDisplays.name : "display",
                            title: row.title, selected: row.id == "\(slot.wrappedValue)", keyFocused: keyed) {
                slot.wrappedValue = rows.first { "\($0.0)" == row.id }?.0 ?? .main
            }
        }
    }

    // MARK: Windows

    @ViewBuilder private var windowList: some View {
        if windows.isEmpty {
            Text(context == .atStart ? "No app to choose." : "No window to share. Open one, then come back.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            let groups = SharePopoutRules.groupsByApp(context)
            let grouped = ScreenPanelRules.grouped(bundleIDs: windows.map(\.bundleID))
            let ordered = groups ? grouped.order.map { windows[$0] } : windows
            let firsts = Dictionary(uniqueKeysWithValues: zip(grouped.order.map { windows[$0].id }, grouped.firstOfApp))
            let list = HomeTileList(rows: ordered, selected: chosen, pick: { choose(ordered[$0]) }) { window, keyed in
                VStack(alignment: .leading, spacing: 2) {
                    if groups, firsts[window.id] == true {
                        Text(window.appName)
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.top, 4)
                    }
                    ShareWindowRow(window: window, selected: chosen(window), keyFocused: keyed) { choose(window) }
                }
            }
            // A long list of apps scrolls on its own; the rest of the panel stays in view.
            if !groups, ordered.count > 6 {
                ScrollView(.vertical) { list }.frame(height: 6 * 32)
            } else {
                list
            }
        }
    }

    private func chosen(_ window: SharePopoutWindow) -> Bool {
        SharePopoutRules.isChosen(context, bundleID: window.bundleID, title: window.title, in: share)
    }

    private func choose(_ window: SharePopoutWindow) {
        Collapse.animate { browsing = false }
        pickWindow(window)
    }

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
}

/// A window row: the app's icon, the window's title (or the app's name), a check when shared.
private struct ShareWindowRow: View {
    let window: SharePopoutWindow
    let selected: Bool
    let keyFocused: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: Self.icon(window.bundleID))
                    .resizable().frame(width: 20, height: 20)
                Text((window.title.isEmpty ? window.appName : window.title) + window.suffix)
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
        .accessibilityLabel(window.title.isEmpty ? window.appName : "\(window.appName), \(window.title)")
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
