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
    /// covers Greenroom's own process - OBS crashing in its own binary is
    /// invisible to this, since it is a separate application.
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

    /// System-wide shortcuts (see HotkeyManager - they work while OTHER
    /// apps are focused, which is the whole point mid-class). Actions
    /// resolve the coordinator at press time and guard on session state,
    /// mirroring the buttons' enabled states.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Option+Command, not Control+Option+Command.
            //
            // Three modifiers was chosen for collision safety and is genuinely
            // hard to hit one-handed - reported as such. Option and Command are
            // ADJACENT at the bottom left, so one thumb covers both and the
            // other fingers are free for the letter; Control+Option needs the
            // pinky as well.
            //
            // Control is the one dropped rather than Command, deliberately:
            // Control+Option is VoiceOver's own modifier, so those combinations
            // are swallowed whenever VoiceOver is running. Option+Command has no
            // such owner, and none of the letters used here (G X R S Z) collide
            // with the system's Option+Command shortcuts - those are H (Hide
            // Others), D (Dock), Space (Finder search) and Escape (Force Quit).
            let mods = UInt32(cmdKey | optionKey)
            let unavailable = HotkeyManager.shared.register([
                .init(keyCode: UInt32(kVK_ANSI_G), modifiers: mods, label: "\u{2325}\u{2318}G") {
                    CoordinatorController.shared?.start() // guards itself when busy/live
                },
                .init(keyCode: UInt32(kVK_ANSI_X), modifiers: mods, label: "\u{2325}\u{2318}X") {
                    guard let coordinator = CoordinatorController.shared,
                          coordinator.isRunning || coordinator.virtualCamActive else { return }
                    coordinator.confirmAndStop() // destructive - always confirms
                },
                .init(keyCode: UInt32(kVK_ANSI_R), modifiers: mods, label: "\u{2325}\u{2318}R") {
                    guard let coordinator = CoordinatorController.shared,
                          coordinator.virtualCamActive || coordinator.isRecording else { return }
                    coordinator.toggleRecording()
                },
                .init(keyCode: UInt32(kVK_ANSI_S), modifiers: mods, label: "\u{2325}\u{2318}S") {
                    CoordinatorController.shared?.snapWindowsBack()
                },
                // Speaker-tile quick-hide/float. Pref-gated in the action
                // (toggleSpeakerTile checks speakerTileShortcutEnabled),
                // so flipping the setting needs no re-registration.
                .init(keyCode: UInt32(kVK_ANSI_Z), modifiers: mods, label: "\u{2325}\u{2318}Z") {
                    CoordinatorController.shared?.toggleSpeakerTile()
                },
                // Clip marks. The digit IS the number of minutes, so there is
                // nothing to remember: something good just happened, press the
                // number of minutes it took. Digits rather than more letters
                // because the mapping is the mnemonic, and because Option-Command
                // digits are unclaimed by the system (unlike ⌘1-9, which is
                // window and tab switching in nearly every app).
                .init(keyCode: UInt32(kVK_ANSI_1), modifiers: mods, label: "\u{2325}\u{2318}1") {
                    CoordinatorController.shared?.markClip(minutes: 1)
                },
                .init(keyCode: UInt32(kVK_ANSI_2), modifiers: mods, label: "\u{2325}\u{2318}2") {
                    CoordinatorController.shared?.markClip(minutes: 2)
                },
                .init(keyCode: UInt32(kVK_ANSI_5), modifiers: mods, label: "\u{2325}\u{2318}5") {
                    CoordinatorController.shared?.markClip(minutes: 5)
                },
            ])

            // Another running app already owning a combination is the one way
            // these silently do nothing, so say it out loud rather than leaving
            // the user pressing a dead key.
            if !unavailable.isEmpty {
                CoordinatorController.shared?.reportUnavailableShortcuts(unavailable)
            }

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
