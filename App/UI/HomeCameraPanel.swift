//
//  HomeCameraPanel.swift
//
//  The Camera tile's popover: every connected camera as a row, the switch to
//  the camera you are facing, its tuning (only with two or more cameras
//  chosen), and a footer into Settings -> Webcam. Built only from settings
//  that already exist (CameraDirectorSettings); what shows is decided by
//  CameraPanelRules. Shell: HomeTilePanels.swift.
//
import SwiftUI

struct HomeCameraPanel: View {
    @AppStorage(PresenceFeed.mirrorKey) private var mirrorSelfView = true
    @AppStorage(PresenceRecorderRules.key) private var visibleToRecorders = true
    @ObservedObject var coordinator: CoordinatorController
    let cameras: [LocalDeviceResolver.Camera]
    let more: () -> Void

    private struct Row: Identifiable {
        var id: String
        var name: String
        var symbol: String
    }

    private var settings: CameraDirectorSettings { coordinator.cameraDirectorSettings }
    private var single: String? { coordinator.sceneCameraUIDs(limit: 1).first }
    private var chosenCount: Int {
        CameraPanelRules.chosen(order: settings.cameraUIDs, available: cameras.map(\.id)).count
    }

    private var rows: [Row] {
        cameras.map { Row(id: $0.id, name: $0.name, symbol: CameraPanelRules.symbol(name: $0.name, isBuiltIn: $0.isBuiltIn)) }
    }

    var body: some View {
        let switchOn = settings.enabled
        HomeTilePanel(
            title: "Camera",
            summary: "Which camera you appear on.",
            value: CameraPanelRules.headerValue(
                noCamera: coordinator.cameraIsOff, switchOn: switchOn, chosenCount: chosenCount,
                singleName: cameras.first { $0.id == single }?.name),
            art: DockHintVisual.camera(off: coordinator.cameraIsOff),
            moreTitle: "More camera settings\u{2026}", onMore: more
        ) {
            // This meeting only: the saved choice is in Settings -> Layouts.
            HomeTileSection(title: "Who sees my camera") {
                HomeTileChoiceRow(
                    choices: CameraState.allCases.map { state in
                        HomeTileChoice(id: state.raw, title: state.name, symbol: VisibilitySymbol.camera(state).name,
                                       selected: state == coordinator.cameraState,
                                       enabled: !state.noCamera || CameraPanelRules.noCameraEnabled(
                                           shareIsNothing: coordinator.shareTarget.sharesNothing),
                                       badge: VisibilitySymbol.camera(state).badge)
                    },
                    tileWidth: 76,
                    pick: { coordinator.setLiveCameraState(CameraState.allCases[$0]) })
                Text(coordinator.cameraState.detail + " Only for this meeting.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HomeTileSection(title: "Cameras") {
                if cameras.isEmpty {
                    Text("No camera found. Plug one in, or turn the camera off.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HomeTileList(rows: rows, selected: isSelected, autofocus: true, pick: pickRow) { row, keyed in
                    HomeTileListRow(
                        symbol: row.symbol, title: row.name,
                        detail: CameraPanelRules.position(of: row.id, switchOn: switchOn, order: settings.cameraUIDs)
                            .map { "\($0)" },
                        selected: isSelected(row),
                        keyFocused: keyed) { pickRow(rows.firstIndex { $0.id == row.id } ?? 0) }
                }
            }

            if CameraPanelRules.showsSwitchToggle(availableCount: cameras.count) {
                HomeTileToggleRow(
                    title: "Switch to the camera you\u{2019}re facing",
                    isOn: Binding(get: { settings.enabled }, set: setSwitching),
                    help: "Put a camera on each monitor and everyone sees whichever one you face.")
                HomeTileDependents(hidden: !switchOn) {
                    if CameraPanelRules.showsPickAnotherHint(switchOn: switchOn, chosenCount: chosenCount) {
                        Text("Tick a second camera above to switch between them.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }

            HomeTileDependents(hidden: !CameraPanelRules.showsSwitching(switchOn: switchOn, chosenCount: chosenCount)) {
                HomeTileSection(title: "Switching") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Switch after").font(.system(size: 12))
                            Spacer()
                            Text(String(format: "%.1f s", settings.dwellSeconds))
                                .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(get: { settings.dwellSeconds },
                                              set: { coordinator.cameraDirectorSettings.dwellSeconds = $0 }),
                               in: 0.5...6, step: 0.5)
                            .controlSize(.small)
                            .accessibilityLabel("Switch after")
                            .accessibilityValue(String(format: "%.1f seconds", settings.dwellSeconds))
                    }
                    .help("How long you must face another camera before the view cuts to it.")
                    HomeTileChoiceRow(
                        choices: CameraTransition.allCases.map {
                            HomeTileChoice(id: $0.rawValue, title: $0.label,
                                           symbol: $0 == .cut ? "arrow.left.arrow.right" : "circle.lefthalf.filled",
                                           selected: $0 == settings.transition)
                        },
                        pick: { coordinator.cameraDirectorSettings.transition = CameraTransition.allCases[$0] })
                }
            }

            // The same switch as Settings › Webcam, one click from Start.
            VStack(alignment: .leading, spacing: 2) {
                HomeTileToggleRow(
                    title: "Mirror my camera",
                    isOn: $mirrorSelfView,
                    help: visibleToRecorders
                        ? PresenceRecorderRules.mirrorDisabledNote
                        : "Only you see yourself mirrored. Everyone in the meeting and the recording see the true picture.")
                .disabled(!PresenceRecorderRules.mirrorSettingEnabled(visibleToRecorders: visibleToRecorders))
                if visibleToRecorders {
                    Text(PresenceRecorderRules.mirrorDisabledNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 330)
    }

    private func isSelected(_ row: Row) -> Bool {
        return CameraPanelRules.isSelected(uid: row.id, switchOn: settings.enabled, order: settings.cameraUIDs,
                                           single: single, noCamera: coordinator.cameraIsOff)
    }

    private func pickRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        var next = coordinator.cameraDirectorSettings
        next.cameraUIDs = CameraPanelRules.tapped(uid: row.id, switchOn: next.enabled, order: next.cameraUIDs)
        coordinator.cameraDirectorSettings = next
        // Choosing a camera is asking for it: if this meeting has the camera off,
        // that goes back to what everyone sees. The saved default is not touched.
        let state = coordinator.cameraState
        if state.noCamera { coordinator.setLiveCameraState(CameraState(noCamera: false, shownOnMyScreen: state.shownOnMyScreen)) }
        coordinator.previewCamerasChanged()
    }

    private func setSwitching(_ on: Bool) {
        var next = coordinator.cameraDirectorSettings
        if on {
            next.cameraUIDs = CameraPanelRules.orderWhenSwitchingOn(order: next.cameraUIDs, single: single)
        }
        next.enabled = on
        coordinator.cameraDirectorSettings = next
        let state = coordinator.cameraState
        if on, state.noCamera { coordinator.setLiveCameraState(CameraState(noCamera: false, shownOnMyScreen: state.shownOnMyScreen)) }
        coordinator.previewCamerasChanged()
    }
}
