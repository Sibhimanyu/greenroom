//
//  SessionsSidebar.swift
//
//  The Sessions sidebar as the window's own sidebar column. ContentView's root
//  is a NavigationSplitView, so on macOS 26 the system draws this column as the
//  full-height floating glass panel with the traffic lights inside it, as in
//  Finder, and the toolbar sits over the detail column only.
//
//  The column exists for the Sessions pages (grid, a session, its report). On
//  Home and the Record studio it is collapsed to detail-only and its toggle is
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
        /// Set when the disk is getting full; critical is red, otherwise amber.
        var warningIsCritical: Bool?
    }
    @Published var snapshot = Snapshot()
}

// MARK: - The column

struct SessionsSidebar: View {
    @ObservedObject var model: SessionsSidebarModel
    @EnvironmentObject private var coordinator: CoordinatorController
    @AppStorage("sessionsShow") private var show: SessionsShow = .everything

    var body: some View {
        let query = SessionsQuery(cards: model.snapshot.cards)
        List(selection: Binding<SessionsShow?>(get: { show }, set: choose)) {
            Section("Show") {
                ForEach(SessionsShow.allCases) { option in
                    Label(option.rawValue, systemImage: option.symbol)
                        .badge(query.count(for: option))
                        .tag(option)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { storageFooter }
        .navigationSplitViewColumnWidth(min: SidebarRules.widthRange.lowerBound,
                                        ideal: SidebarRules.idealWidth,
                                        max: SidebarRules.widthRange.upperBound)
    }

    /// Picking a kind while a session or its report is up goes to the grid,
    /// as picking a folder in Finder shows that folder.
    private func choose(_ value: SessionsShow?) {
        guard let value else { return }
        show = value
        if case .sessions = coordinator.mainPage { return }
        if !coordinator.mainPage.isHome { coordinator.mainPage = .sessions }
    }

    private var storageFooter: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([SessionFolders.recordingsDirectory])
        } label: {
            Text(model.snapshot.storage)
                .font(.footnote)
                .foregroundStyle(warningColor ?? .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .help("Show the folder in Finder.")
    }

    /// Semantic system colours: this is about the disk, not about anything
    /// leaving the Mac, so not Brand.net.
    private var warningColor: Color? {
        model.snapshot.warningIsCritical.map { $0 ? .red : .orange }
    }
}

// MARK: - Command

/// View menu: the one sidebar item, "Hide Sidebar" / "Show Sidebar" on
/// Command-B, in place of the system's (which would be a second item). It
/// writes the same saved choice ContentView's column visibility reads. Disabled
/// on Home and the Record studio, where there is no sidebar. Control-Command-S
/// is kept by a hidden key equivalent in ContentView.
struct SidebarCommands: Commands {
    @ObservedObject var coordinator: CoordinatorController
    @AppStorage(SidebarRules.hiddenKey) private var hidden = false

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(hidden ? "Show Sidebar" : "Hide Sidebar") { hidden.toggle() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(coordinator.mainPage.isHome || coordinator.recordStudioShown)
        }
    }
}
