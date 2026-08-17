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
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
        }
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
        }

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
        } label: {
            if coordinator.isRecording {
                HStack(spacing: 3) {
                    Image(systemName: "record.circle.fill")
                    Text("REC")
                }
            } else {
                Text("GR")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
