//
//  GreenroomApp.swift
//  Greenroom
//
//  One coordinator instance, shared between the main window and the
//  Settings scene (SwiftUI scenes don't otherwise share view state) - so
//  editing a setting there is instantly reflected in the main window's
//  behavior, not a separate copy.
//
import SwiftUI
import Sparkle

/// App-wide external links, defined once so the in-app entry points and
/// the site can't drift.
enum AppLinks {
    /// The public "how it works & why it's safe" transparency page.
    static let safety = URL(string: "https://sibhimanyu.github.io/greenroom/how-it-works.html")!
    /// The product site - also the DEFAULT page the main-pane browser
    /// opens on a fresh install, until the user sets their own URL.
    static let site = "https://sibhimanyu.github.io/greenroom/index.html"
}

/// Brand tokens applied EXPLICITLY at every scene root. The asset-catalog
/// AccentColor + NSAccentColorName cover most controls, but AppKit lets a
/// user-chosen System Settings accent override the app's - which left
/// borderedProminent buttons blue while everything else went green
/// (reported live, twice). An explicit .tint outranks that negotiation.
enum Brand {
    static let green = Color("AccentColor")
}

@main
struct GreenroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = CoordinatorController()

    /// Sparkle auto-updater: checks the appcast (SUFeedURL in Info.plist)
    /// periodically and offers "Install and Relaunch" - installed copies
    /// stop needing hand-delivered zips. Updates are EdDSA-verified
    /// against SUPublicEDKey, so only zips signed with our key install.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        // Window (single, id-addressable), not WindowGroup: closing the
        // WindowGroup window destroyed it with NO recreation path - dock
        // reopen, the reopen Apple event, and "Show Greenroom" (which can
        // only order front an EXISTING window) all failed, leaving the
        // app running windowless (reproduced live). A Window scene
        // recreates via openWindow(id:) and dock reopen reliably.
        Window("Greenroom", id: "main") {
            ContentView()
                .environmentObject(coordinator)
                .tint(Brand.green)
        }
        .defaultSize(width: 620, height: 400)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") {
                    updaterController.checkForUpdates(nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(coordinator)
                .tint(Brand.green)
        }

        // Screenroom: evaluated presentations (App/Screenroom/, and
        // docs/marks-evaluation-plan.md). A Window, not a WindowGroup, for
        // the reason recorded above - and a separate scene rather than a
        // sheet on the main window because it holds a live camera and a
        // recording, so it has to outlive whatever the main window is doing.
        //
        // Deliberately NOT given the coordinator: Screenroom runs without a
        // class, a meeting or OBS, and handing it the session object would
        // quietly make that untrue the first time someone reached for it.
        // Two gates, because one is not enough and the scene cannot be the
        // one that moves.
        //
        // A Window scene contributes its own item to the Window menu, so a
        // gated-off Screenroom would still be listed there and open an empty
        // window. The obvious fix - wrapping the scene in `if` - does not
        // compile: SceneBuilder has no empty scene to infer for the other
        // branch. `.commandsRemoved()` is the documented way to drop a
        // scene's menu contribution, and it is applied unconditionally
        // because Screenroom has its own two entry points and does not want a
        // third that bypasses them.
        //
        // The body is gated as well, so even a stray openWindow(id: "screenroom")
        // opens an empty window rather than an unreleased feature.
        Window("Screenroom", id: "screenroom") {
            if ScreenroomAvailability.isReleased {
                ScreenroomWindow()
                    .tint(Brand.green)
            }
        }
        .defaultSize(width: 1000, height: 620)
        .commandsRemoved()

        // The other half: presentations that already happened. A separate
        // window rather than a mode inside the first, because the live one
        // holds a camera and a recording and must not be navigated away from
        // while a student is still speaking.
        Window("Screenroom \u{2014} Past Presentations", id: "screenroom-review") {
            if ScreenroomAvailability.isReleased {
                ScreenroomReviewWindow()
                    .tint(Brand.green)
            }
        }
        .defaultSize(width: 1180, height: 700)
        .commandsRemoved()

        // The speaker's own view of the notes, when the teacher turns it on.
        // A window of its own so it can go on the second display, or be
        // handed over on a mirrored iPad, without dragging the note box with
        // it.
        Window("Screenroom \u{2014} What your evaluator is writing", id: "screenroom-speaker") {
            if ScreenroomAvailability.isReleased {
                ScreenroomSpeakerView()
                    .tint(Brand.green)
            }
        }
        .defaultSize(width: 520, height: 640)
        .commandsRemoved()

        // Text label rather than an image: a glyph that fails to render
        // leaves an invisible item, and text makes the item's presence
        // unambiguous when diagnosing "it's not showing up". (A template
        // image of the brand mark was tried and reverted - at 16pt the
        // mark reads worse than plain "GR".) While recording, the label
        // flips to a record glyph + REC - the menu bar renders extras
        // monochrome, so the SHAPE change is the indicator, not color.
        MenuBarExtra {
            MenuBarView(checkForUpdates: { updaterController.checkForUpdates(nil) })
                .environmentObject(coordinator)
                .tint(Brand.green)
        } label: {
            // REC keeps precedence. The waveform says Cues is listening,
            // and it appears HERE only while the participants panel is the
            // surface for its cards - when the panel is closed, Cues has
            // its own status item with the same glyph, and the menu bar must
            // never show two.
            if coordinator.isRecording {
                HStack(spacing: 3) {
                    Image(systemName: "record.circle.fill")
                    Text("REC")
                }
            } else if coordinator.cuesListening && coordinator.cuesOnRail {
                HStack(spacing: 3) {
                    Image(systemName: coordinator.cuesPaused ? "waveform.slash" : "waveform")
                    Text("GR")
                }
            } else {
                Text("GR")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
