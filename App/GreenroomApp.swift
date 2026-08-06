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

@main
struct GreenroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = CoordinatorController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
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
            MenuBarView()
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
