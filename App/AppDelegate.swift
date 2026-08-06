//
//  AppDelegate.swift
//  Greenroom
//
//  Termination hygiene. Two confirmed-by-experience jobs:
//   1. applicationShouldTerminate: leave any live Zoom SDK meeting BEFORE
//      AppKit's quit machinery runs - otherwise the SDK could raise a
//      leave-confirmation modal mid-quit (possibly one the ghost-window
//      hiding had made invisible), and the app would hang until force
//      quit.
//   2. applicationWillTerminate: never leave OBS (and its virtual camera)
//      running headless after Greenroom exits - confirmed by testing:
//      without this, a manual `killall OBS` was the only way out.
//
import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// System-wide shortcuts (see HotkeyManager - they work while OTHER
    /// apps are focused, which is the whole point mid-class). Actions
    /// resolve the coordinator at press time and guard on session state,
    /// mirroring the buttons' enabled states.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let mods = UInt32(cmdKey | optionKey | controlKey)
            HotkeyManager.shared.register([
                .init(keyCode: UInt32(kVK_ANSI_G), modifiers: mods) {
                    CoordinatorController.shared?.start() // guards itself when busy/live
                },
                .init(keyCode: UInt32(kVK_ANSI_X), modifiers: mods) {
                    guard let coordinator = CoordinatorController.shared,
                          coordinator.isRunning || coordinator.virtualCamActive else { return }
                    coordinator.stop()
                },
                .init(keyCode: UInt32(kVK_ANSI_R), modifiers: mods) {
                    guard let coordinator = CoordinatorController.shared,
                          coordinator.virtualCamActive || coordinator.isRecording else { return }
                    coordinator.toggleRecording()
                },
                .init(keyCode: UInt32(kVK_ANSI_S), modifiers: mods) {
                    CoordinatorController.shared?.snapWindowsBack()
                },
            ])

            // OBS's cold launch is most of Start's wait - warm it now so
            // Start begins at "connect" (keep-warm setting gates this).
            CoordinatorController.shared?.prewarmOBSIfEnabled()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            CoordinatorController.shared?.prepareForTermination()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        OBSProcessManager.terminateAnyRunningInstance()
    }
}
