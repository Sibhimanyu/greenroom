//
//  HomeScreenPanel.swift
//
//  The Screen tile's popover on Home: the shared SharePopout (SharePopout.swift) in the
//  `.thisMeeting` context, wired to the coordinator's live share. Four choice tiles
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
    /// Cameras present on this Mac (HomeView's list), for the Just me tile.
    var cameraCount = 1
    let more: () -> Void
    let close: () -> Void

    private var share: ShareTarget { coordinator.shareTarget }

    var body: some View {
        SharePopout(
            context: .thisMeeting, share: share, value: value,
            art: DockHintVisual.share(share.kind, shape: coordinator.webcamShape, cameraOff: coordinator.cameraIsOff),
            windows: windows.map {
                SharePopoutWindow(id: "\($0.id)", bundleID: $0.bundleID, appName: $0.appName, title: $0.title,
                                  suffix: $0.placement.menuSuffix)
            },
            displays: displays, captureDisplayID: coordinator.screenCaptureDisplayUUID,
            gone: gone, goneName: share.displayName, permissionMissing: permissionMissing,
            cameraState: CameraTileRules.state(cameraIsOff: coordinator.cameraIsOff, deviceCount: cameraCount),
            moreTitle: "More screen settings\u{2026}", more: more,
            pickTile: pickTile,
            pickWindow: pickWindow,
            pickDisplay: { id in
                coordinator.screenCaptureDisplayUUID = id
                coordinator.shareTarget.kind = .display
                coordinator.requestShapeApply(rebuild: true)
            },
            setFollows: { coordinator.shareTarget.followsSlideShow = $0 })
    }

    private func pickWindow(_ row: SharePopoutWindow) {
        guard let window = windows.first(where: { "\($0.id)" == row.id }) else { return }
        coordinator.shareTarget = SharePopoutRules.picking(bundleID: window.bundleID, appName: window.appName,
                                                           title: window.title, in: coordinator.shareTarget)
        coordinator.requestShapeApply(rebuild: true)
        coordinator.bringSharedWindowForward(window)
        close()
    }

    private func pickTile(_ tile: ScreenPanelRules.Tile) {
        let cameraState = CameraTileRules.state(cameraIsOff: coordinator.cameraIsOff, deviceCount: cameraCount)
        // Same live change as the Look tile: Just me turns the camera on for this meeting only.
        if tile == .camera, CameraTileRules.justMeTurnsCameraOn(cameraState) { coordinator.turnCameraOnFromHome() }
        guard let next = SharePopoutRules.applying(tile, to: coordinator.shareTarget) else { return }
        guard next.kind != share.kind else { return }
        coordinator.shareTarget = next
        coordinator.requestShapeApply(rebuild: true)
    }
}
