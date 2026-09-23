//
//  GreenroomApp.swift
//  Greenroom
//
//  One coordinator instance, shared between the main window and the
//  Settings scene (SwiftUI scenes don't otherwise share view state) - so
//  editing a setting there is instantly reflected in the main window's
//  behavior, not a separate copy.
//
import AppKit
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

    /// Green that is allowed to be TEXT.
    ///
    /// `Brand.green` is the asset-catalog accent, which controls tint and is a
    /// FILL. DESIGN.md's hard rule is that the logo's lime fails AA at every
    /// text size on white (2.25), so anything green with words in it uses this
    /// instead: `--brand-green` #2F6118, which measures 7.38.
    ///
    /// Dynamic, because the rule is about the background and not about the
    /// colour. #2F6118 on a dark window is as unreadable as lime on a white
    /// one, so dark mode gets the lime - where it passes comfortably. Written
    /// as an NSColor because SwiftUI has no appearance-aware Color literal.
    static let text = Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0x78 / 255, green: 0xC0 / 255, blue: 0x00 / 255, alpha: 1)
            : NSColor(srgbRed: 0x2F / 255, green: 0x61 / 255, blue: 0x18 / 255, alpha: 1)
    })

    /// The logo's lime, `--accent-lime` #78C000. Fills, tints, shapes. Never
    /// text - see `Brand.text`.
    static let fill = Color(nsColor: NSColor(srgbRed: 0x78 / 255,
                                             green: 0xC0 / 255,
                                             blue: 0x00 / 255, alpha: 1))

    /// The de-emphasis grey charts draw context in, so the one series that
    /// matters is the only thing carrying colour.
    static let recessive = Color(nsColor: .tertiaryLabelColor)
}

@main
struct GreenroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = CoordinatorController()

    /// Sparkle auto-updater: checks the appcast (SUFeedURL in Info.plist)
    /// every SUScheduledCheckInterval and offers "Install and Relaunch" -
    /// installed copies stop needing hand-delivered zips. Updates are
    /// EdDSA-verified against SUPublicEDKey, so only zips signed with our key
    /// install. Nothing installs unattended: SUAutomaticallyUpdate is
    /// deliberately unset, so an update is always an offer.
    /// UpdateGate refuses a scheduled check while a class is running - the
    /// interval in Info.plist says how often, the gate says when not.
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: UpdateGate.shared, userDriverDelegate: nil)

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
        // Derived from the button row, not chosen - see
        // ContentView.minimumWindowWidth. It grows when Screenroom is in the
        // build, because that is when there is a fifth button in the row.
        .defaultSize(width: ContentView.defaultWindowWidth, height: 400)
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
        // Sessions is a WINDOW, not a sheet.
        //
        // As a sheet it was attached to the main window, and AppKit moves a
        // parent to make room for a sheet that does not fit - so opening
        // Sessions shoved Greenroom up the screen. Reported as "the greenroom
        // window moves up in a weird way... it seems like the modal is somehow
        // mounted to the greenroom window", which is exactly what a sheet is.
        //
        // It is also not modal in any real sense: you read it while the main
        // window is doing nothing, and a teacher may well want both open.
        Window("Sessions", id: "sessions") {
            RecordingsView()
                .environmentObject(coordinator)
                .tint(Brand.green)
        }
        .defaultSize(width: 1_180, height: 760)

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

        // The report, full width. It used to live in the 320pt column beside
        // the player, which is the right width for a queue of notes and the
        // wrong one for a document somebody is about to send a student.
        Window("Screenroom \u{2014} Report", id: "screenroom-report") {
            if ScreenroomAvailability.isReleased {
                ScreenroomReportView()
            }
        }
        .defaultSize(width: 960, height: 760)
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
