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

        // The brand mark as a TEMPLATE image (black + alpha, tinted by the
        // system per menu bar appearance). Unlike the systemImage-name
        // route this replaced-a-"GR"-text-label to avoid, a catalog asset
        // can't silently fail to resolve - a missing asset is a build-time
        // problem, not an invisible menu bar item.
        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
        } label: {
            Image("MenuBarMark")
        }
        .menuBarExtraStyle(.menu)
    }
}
