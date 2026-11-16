//
//  SessionsSidebar.swift
//
//  The Sessions sidebar as the window's own sidebar column. ContentView's root
//  is a NavigationSplitView, so on macOS 26 the system draws this column as the
//  full-height floating glass panel with the traffic lights inside it, as in
//  Finder, and the toolbar sits over the detail column only.
//
//  The column exists for the Sessions pages (grid, a session, its report). On
//  Home it is collapsed to detail-only and its toggle is
//  removed, so Home looks as it always did.
//
import SwiftUI
import AppKit

// MARK: - What the sidebar shows

/// What the page hands the sidebar: the sessions' kinds (for the badges) and
/// the storage line. RecordingsView owns the data and writes it here; the
/// sidebar only reads, so it never needs the folder scan.
@MainActor
final class SessionsSidebarModel: ObservableObject {
    struct Snapshot: Equatable {
        var cards: [SessionCardModel] = []
        var storage = ""
        /// Set when the disk is getting full; true when critically low.
        var warningIsCritical: Bool?
    }
    @Published var snapshot = Snapshot()
}

// MARK: - The column

struct SessionsSidebar: View {
    @ObservedObject var model: SessionsSidebarModel
    @EnvironmentObject private var coordinator: CoordinatorController
    @AppStorage("sessionsShow") private var show: SessionsShow = .everything
    /// The NEEDS YOU choice ("" for none), read by the list (SessionsLayout).
    @AppStorage("sessionsNeed") private var needRaw = ""
    @ObservedObject private var index = SessionsIndex.shared

    private enum Item: Hashable { case show(SessionsShow), need(SessionsNeed) }

    var body: some View {
        let query = SessionsQuery(cards: index.enrich(model.snapshot.cards))
        let selected: Item = SessionsNeed(rawValue: needRaw).map(Item.need) ?? .show(show)
        List(selection: Binding<Item?>(get: { selected }, set: choose)) {
            Section("Library") {
                ForEach(SessionsShow.allCases) { option in
                    Label(option.rawValue, systemImage: option.symbol)
                        .badge(query.count(for: option))
                        .tag(Item.show(option))
                }
            }
            Section("Needs you") {
                ForEach(SessionsNeed.allCases) { option in
                    Label(option.rawValue, systemImage: option.symbol)
                        .badge(query.count(for: option))
                        .tag(Item.need(option))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                AccountChip()
                storageFooter
            }
        }
        .navigationSplitViewColumnWidth(min: SidebarRules.widthRange.lowerBound,
                                        ideal: SidebarRules.idealWidth,
                                        max: SidebarRules.widthRange.upperBound)
    }

    /// Picking a kind while a session or its report is up goes to the grid,
    /// as picking a folder in Finder shows that folder.
    private func choose(_ value: Item?) {
        guard let value else { return }
        switch value {
        case .show(let option): show = option; needRaw = ""
        case .need(let option): show = .everything; needRaw = option.rawValue
        }
        if case .sessions = coordinator.mainPage { return }
        if !coordinator.mainPage.isHome { coordinator.mainPage = .sessions }
    }

    private var storageFooter: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([SessionFolders.recordingsDirectory])
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if critical {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Text(model.snapshot.storage)
                    .foregroundStyle(critical ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .help("Show the folder in Finder.")
    }

    /// Amber means "leaves your Mac" (DESIGN.md), so a disk that is merely
    /// getting full stays secondary. Only the critical case is drawn in a
    /// warning colour, with an icon so it does not rest on colour alone.
    private var critical: Bool { model.snapshot.warningIsCritical == true }
}

// MARK: - Command

/// View menu: the one sidebar item, "Hide Sidebar" / "Show Sidebar" on
/// Command-B, in place of the system's (which would be a second item). It
/// writes the same saved choice ContentView's column visibility reads. Disabled
/// on Home, where there is no sidebar. Control-Command-S
/// is kept by a hidden key equivalent in ContentView.
struct SidebarCommands: Commands {
    @ObservedObject var coordinator: CoordinatorController
    @AppStorage(SidebarRules.hiddenKey) private var hidden = false

    /// Only the Sessions grid has a sidebar to toggle.
    static func canToggle(_ page: CoordinatorController.MainPage) -> Bool {
        if case .sessions = page { return true }
        return false
    }

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(hidden ? "Show Sidebar" : "Hide Sidebar") { hidden.toggle() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!SidebarCommands.canToggle(coordinator.mainPage))
        }
    }
}
