//
//  HomeRecordPanel.swift
//
//  The Auto-rec tile's popover: when recording starts (with the meeting, or
//  when you press it), the clip buffer switch with its length folded under it,
//  and where recordings are saved with Show in Finder. Only existing settings
//  (autoRecordOnStart, clipBufferEnabled); sections by RecordPanelRules. The
//  tile is disabled while live, so this is only ever opened when it is not.
//  Shell: HomeTilePanels.swift.
//
import AppKit
import SwiftUI

struct HomeRecordPanel: View {
    @ObservedObject var coordinator: CoordinatorController
    let isLive: Bool
    let more: () -> Void

    var body: some View {
        let on = coordinator.autoRecordOnStart
        let sections = RecordPanelRules.sections(isLive: isLive)
        HomeTilePanel(
            title: "Record",
            summary: on ? "Recording starts by itself with the meeting." : "Recording starts when you press Record.",
            value: RecordPanelRules.headerValue(autoRecord: on),
            art: DockHintVisual.record(withMeeting: on),
            moreTitle: "More recording settings\u{2026}", onMore: more
        ) {
            if sections.isEmpty {
                Text("Recording choices wait until the meeting ends.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if sections.contains(.start) {
                HomeTileSection(title: "Start recording") {
                    HomeTileChoiceRow(
                        choices: [
                            HomeTileChoice(id: "auto", title: "With the meeting", symbol: "record.circle.fill", selected: on),
                            HomeTileChoice(id: "manual", title: "When I press it", symbol: "hand.tap", selected: !on),
                        ],
                        tileWidth: 147, autofocus: true,
                        pick: { coordinator.autoRecordOnStart = ($0 == 0) })
                }
            }
            if sections.contains(.clipBuffer) {
                HomeTileToggleRow(
                    title: "Keep the last few minutes clippable",
                    isOn: Binding(get: { coordinator.clipBufferEnabled }, set: { coordinator.clipBufferEnabled = $0 }),
                    help: "The clip shortcuts (Settings \u{2192} Shortcuts) save the last minutes as a clip, recording or not. About 300 MB of memory, nothing on disk until you press.")
                HomeTileDependents(hidden: !RecordPanelRules.showsClipLength(clipBufferOn: coordinator.clipBufferEnabled)) {
                    Text(RecordPanelRules.clipLengthText(seconds: SessionFolders.clipBufferSeconds)
                         + " Held in memory; nothing is saved until you press a clip shortcut.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if sections.contains(.folder) {
                HomeTileSection(title: "Saved in") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text("Documents/Greenroom").font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Show in Finder", action: showFolder)
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Brand.text)
                            .help("Open the recordings folder")
                    }
                }
            }
        }
    }

    private func showFolder() {
        let url = SessionFolders.recordingsDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
