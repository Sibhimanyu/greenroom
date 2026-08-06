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

        // Text label rather than a systemImage: a glyph that fails to
        // render leaves an invisible item, and text makes the item's
        // presence unambiguous when diagnosing "it's not showing up".
        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
        } label: {
            Text("GR")
        }
        .menuBarExtraStyle(.menu)
    }
}
