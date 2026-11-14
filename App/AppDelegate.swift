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
//   2. applicationWillTerminate: shut the Zoom SDK down in order, then exit
//      without running its destructors. By then the recording is finished and
//      the cameras and screen capture are stopped (windDownForQuit).
//
import AppKit
import Apptics
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Zoho Apptics: sessions, screens and events.
    ///
    /// Gated on AP_INFOPLIST_FILE, which the Apptics pre-build script writes
    /// into Info.plist only when apptics-config.plist exists. That makes the
    /// key an honest signal for "this build was actually wired up", so a clone
    /// without an API key launches silently instead of logging SDK errors at
    /// every start.
    ///
    /// Crash reporting IS active here, via AppticsCrashKit + KSCrash. It only
    /// covers Greenroom's own process.
    private func startAnalytics() {
        guard Bundle.main.object(forInfoDictionaryKey: "AP_INFOPLIST_FILE") != nil else { return }
        #if DEBUG
        Apptics.initialize(withVerbose: true)
        #else
        Apptics.initialize(withVerbose: false)
        #endif
        // Honour a previous opt-out before anything is sent. setCompleteOff
        // suppresses every call including device registration, so a user who
        // turned analytics off stays off across launches rather than
        // re-registering each time.
        if UserDefaults.standard.object(forKey: "analyticsEnabled") != nil,
           !UserDefaults.standard.bool(forKey: "analyticsEnabled") {
            // Same shape as applicationDidFinishLaunching below: the delegate
            // callback is nonisolated, and everything it reaches here is
            // main-actor work already running on the main thread.
            MainActor.assumeIsolated { Analytics.setEnabled(false) }
        }
    }

    /// Apptics is started here, not in `applicationDidFinishLaunching`.
    ///
    /// Zoho documents this specifically for macOS: "For Mac applications, make
    /// sure you call Apptics.initializewithVerbose: in
    /// applicationWillFinishLaunching:". Starting it a phase later appears to
    /// work and quietly misses the earliest part of the session, which is also
    /// where launch crashes happen.
    func applicationWillFinishLaunching(_ notification: Notification) {
        startAnalytics()
    }

    /// System-wide shortcuts (see HotkeyManager and ShortcutRuntime - they work
    /// while OTHER apps are focused, which is the whole point mid-class).
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Find whisper once, off the main thread, before any view asks.
        // See ScreenroomWhisper.resolvedBinary for why a view must never be
        // the first to ask.
        DispatchQueue.global(qos: .utility).async { _ = ScreenroomWhisper.resolvedBinary }
        MainActor.assumeIsolated {
            // The Sessions page opens on this, so its window can grow without
            // waiting on a walk of the recordings folder.
            RecordingsView.prewarm()
            // What each key does, and its default, is in ShortcutModel; the
            // bindings are Settings -> Shortcuts. ShortcutRuntime registers them
            // and keeps them registered as they change.
            ShortcutRuntime.shared.start()
            #if DEBUG
            DebugTour.start()
            #endif
        }
    }

    /// A Dock click while a class is live brings the class forward: the meeting
    /// window, or the control bar if it is shrunk. Returning false stops AppKit
    /// also opening the main window over it. With nothing live, the usual
    /// reopen (the main window) applies.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            guard let coordinator = CoordinatorController.shared else { return true }
            return !coordinator.bringLiveSessionForward()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let coordinator = CoordinatorController.shared else { return .terminateNow }
            // Before prepareForTermination, not after: that begins tearing the
            // session down, so asking afterwards would be asking about something
            // already half-ended.
            // Logout, shutdown and restart arrive as a quit Apple event whose reason
            // says so: those end cleanly and save, with no question.
            let reason = NSAppleEventManager.shared().currentAppleEvent?
                .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
            let systemEnding = LiveExit.isSystemEnd(quitReason: reason)
            guard coordinator.confirmQuitWhileLive(systemEnding: systemEnding) else { return .terminateCancel }
            coordinator.prepareForTermination()
            // A recording gets a graceful, WAITED-FOR finish before this
            // process exits, and the cameras and screen capture are stopped,
            // so no file is cut short and no camera light is left on.
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
        // Belt and braces on top of the SDK shutdown above: whatever
        // teardown the Zoom SDK's ~80 dylibs still run at process exit
        // SEGV'd reliably (zVideoUIBridge/viper destructors - see the
        // crash reports), putting a "Greenroom quit unexpectedly" dialog
        // on EVERY quit of an SDK-touched session. By this point the
        // meeting is left, the SDK is uninited and the recording is finished -
        // there is nothing left worth crashing over. _exit skips the
        // remaining static destructors outright.
        _exit(0)
    }
}
