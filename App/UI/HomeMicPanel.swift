//
//  HomeMicPanel.swift
//
//  The Mic tile's popover: every microphone as a row (System default first, a
//  saved one that is unplugged stays listed), the Mac's-sound switch, and a
//  footer into Settings -> Webcam. Built only from settings that exist
//  (micDeviceUID, recordSystemAudio); what shows is decided by MicPanelRules.
//  Shell: HomeTilePanels.swift.
//
//  No live input meter here: MicLevelMonitor opens the microphone (the orange
//  dot, and a permission prompt on a first run), and Home only ever starts it
//  while a meeting already has the mic open (see HomeView.micMeterLevel). The
//  tile keeps showing that meter while live; the panel does not open the mic.
//
import SwiftUI

struct HomeMicPanel: View {
    @ObservedObject var coordinator: CoordinatorController
    let microphones: [LocalDeviceResolver.Microphone]
    /// The device name when "System default" is chosen.
    let systemName: String?
    let more: () -> Void

    private struct Row: Identifiable {
        var id: String      // the device UID; "" is the system default
        var name: String
        var symbol: String
    }

    private var selection: String { coordinator.micDeviceUID }
    private var savedMissing: Bool {
        MicPanelRules.showsSavedMissing(selection: selection, available: microphones.map(\.id))
    }

    private var rows: [Row] {
        var out = [Row(id: "", name: systemName.map { "System default (\($0))" } ?? "System default",
                       symbol: "gearshape")]
        out += microphones.map { Row(id: $0.id, name: $0.name, symbol: MicrophoneContent.symbol(for: $0)) }
        if savedMissing { out.append(Row(id: selection, name: "Saved microphone (not connected)", symbol: "mic.slash")) }
        return out
    }

    var body: some View {
        HomeTilePanel(
            title: "Microphone",
            summary: "Which microphone everyone hears, and the recording takes.",
            value: MicPanelRules.headerValue(
                name: microphones.first { $0.id == selection }?.name ?? systemName ?? "System microphone",
                savedMissing: savedMissing),
            art: DockHintVisual.microphone,
            moreTitle: "More sound settings\u{2026}", onMore: more
        ) {
            HomeTileSection(title: "Microphones") {
                HomeTileList(rows: rows, selected: { $0.id == selection }, autofocus: true, pick: pickRow) { row, keyed in
                    HomeTileListRow(symbol: row.symbol, title: row.name, selected: row.id == selection,
                                    keyFocused: keyed) { pickRow(rows.firstIndex { $0.id == row.id } ?? 0) }
                }
                if selection.isEmpty {
                    Text("Follows the input in System Settings \u{2192} Sound.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else if savedMissing {
                    Text("Recording uses the system input until it is plugged back in.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            HomeTileToggleRow(
                title: "Record the Mac\u{2019}s sound",
                isOn: Binding(get: { coordinator.recordSystemAudio }, set: { coordinator.recordSystemAudio = $0 }),
                help: "Adds what is playing from the screen or app you share (a video, a call) to the recording, mixed with your microphone. Needs something shared under Behind you.")
            HomeTileDependents(hidden: !MicPanelRules.showsNeedsShareHint(
                recordSystemAudio: coordinator.recordSystemAudio,
                shareIsNothing: coordinator.shareTarget.kind == .nothing)) {
                Text("Share a screen or app to give it sound to record.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 330)
    }

    private func pickRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        coordinator.micDeviceUID = rows[index].id
        coordinator.previewCamerasChanged()
    }
}
