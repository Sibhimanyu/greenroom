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
                // Speaker-tile quick-hide/float. Pref-gated in the action
                // (toggleSpeakerTile checks speakerTileShortcutEnabled),
                // so flipping the setting needs no re-registration.
                .init(keyCode: UInt32(kVK_ANSI_Z), modifiers: mods) {
                    CoordinatorController.shared?.toggleSpeakerTile()
                },
            ])

            // OBS's cold launch is most of Start's wait - warm it now so
            // Start begins at "connect" (keep-warm setting gates this).
            CoordinatorController.shared?.prewarmOBSIfEnabled()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let coordinator = CoordinatorController.shared else { return .terminateNow }
            coordinator.prepareForTermination()
            // OBS gets a graceful, WAITED-FOR shutdown before this process
            // exits: stop the virtual camera, ask OBS to quit, wait for
            // its real exit. Terminating it and _exit()ing from under it
            // crashed OBS in its own teardown - the "OBS quit
            // unexpectedly" dialog after every Greenroom quit.
            Task { @MainActor in
                await coordinator.windDownForQuit()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            CoordinatorController.shared?.zoomChatClient.shutdown()
        }
        OBSProcessManager.terminateAnyRunningInstance()
        // Belt and braces on top of the SDK shutdown above: whatever
        // teardown the Zoom SDK's ~80 dylibs still run at process exit
        // SEGV'd reliably (zVideoUIBridge/viper destructors - see the
        // crash reports), putting a "Greenroom quit unexpectedly" dialog
        // on EVERY quit of an SDK-touched session. By this point the
        // meeting is left, the SDK is uninited, and OBS has been told to
        // quit - there is nothing left worth crashing over. _exit skips
        // the remaining static destructors outright.
        usleep(300_000) // let the OBS terminate Apple Event leave the process
        _exit(0)
    }
}
