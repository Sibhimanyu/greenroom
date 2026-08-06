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

final class AppDelegate: NSObject, NSApplicationDelegate {

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
