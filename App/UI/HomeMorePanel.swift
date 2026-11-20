//
//  HomeMorePanel.swift
//
//  The More tile's popover: a grid of tiles that jump straight to each
//  Settings tab (the tabs and icons are SettingsView's, listed in
//  MorePanelRules.tabs), a Help row (the setup guide), and a footer that opens
//  Settings. Shell: HomeTilePanels.swift.
//
import SwiftUI

struct HomeMorePanel: View {
    /// Open Settings on this tab (SettingsView's tag).
    let openTab: (String) -> Void
    let setupGuide: () -> Void
    let allSettings: () -> Void

    @State private var index = 0
    @State private var keyed = false

    private let tabs = MorePanelRules.tabs
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        HomeTilePanel(
            title: "More",
            summary: "Every other setting, one click away.",
            value: "Settings",
            art: DockHintVisual.more,
            moreTitle: "All settings\u{2026}", onMore: allSettings
        ) {
            HomeTileSection(title: "Settings") {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { offset, tab in
                        Button { openTab(tab.id) } label: {
                            VStack(spacing: 5) {
                                Image(systemName: tab.symbol)
                                    .font(.system(size: 18))
                                    .frame(height: 24)
                                Text(tab.title).font(.system(size: 11))
                                if tab.beta { CuesBetaBadge().scaleEffect(0.8).frame(height: 12) }
                                else { Color.clear.frame(height: 12) }
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                        }
                        .greenroomTile(role: .browse, radius: 10)
                        .overlay { HomeTileKeyRing(show: keyed && index == offset, radius: 10) }
                        .help(tab.beta ? "\(tab.title) settings (beta)" : "\(tab.title) settings")
                        .accessibilityLabel(tab.beta ? "\(tab.title), beta" : tab.title)
                    }
                }
                .homeTileKeys(axis: .horizontal, count: tabs.count, index: $index, keyed: $keyed,
                              selected: nil, autofocus: true, pick: { openTab(tabs[$0].id) })
            }

            HomeTileSection(title: "Help") {
                HomeTileListRow(symbol: "questionmark.circle", title: "Setup guide", selected: false,
                                action: setupGuide)
            }
        }
        .frame(width: 330)
    }
}
