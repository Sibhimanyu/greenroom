//
//  SettingsView.swift
//  Greenroom
//
//  Everything here is "set once, rarely touched" - opened via
//  Greenroom -> Settings... (⌘,), the standard macOS location, rather
//  than cluttering the main window's day-to-day flow. Shares the same
//  CoordinatorController instance as ContentView (injected via
//  .environmentObject in GreenroomApp.swift), so changes take effect
//  immediately.
//
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Home's "Change..." beside the picture summary: Settings, on Webcam.
    static let showWebcamSettings = Notification.Name("GreenroomShowWebcamSettings")
}

struct SettingsView: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    /// Only Webcam is ever chosen from outside; the other tags are there so
    /// the TabView can track which tab is showing.
    @State private var tab = "webcam"

    var body: some View {
        TabView(selection: $tab) {
            WebcamSettingsTab()
                .tabItem { Label("Webcam", systemImage: "video.fill") }
                .tag("webcam")

            LayoutSettingsTab()
                .tabItem { Label("Layout", systemImage: "rectangle.split.2x1") }
                .tag("layout")

            ZoomSettingsTab()
                .tabItem { Label("Zoom", systemImage: "video.fill") }
                .tag("zoom")

            YouTubeSettingsTab()
                .tabItem { Label("YouTube", systemImage: "play.rectangle.fill") }
                .tag("youtube")

            CuesSettingsTab()
                .tabItem { Label("Cues", systemImage: "waveform.and.magnifyingglass") }
                .tag("cues")

            TransferSettingsTab()
                .tabItem { Label("Transfer", systemImage: "square.and.arrow.up.on.square") }
                .tag("transfer")
        }
        .frame(width: 760, height: 730)
        // Secrets are loaded lazily (see loadSecretsIfNeeded) - opening
        // Settings is the first moment the fields actually need them.
        .onAppear { coordinator.loadSecretsIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .showWebcamSettings)) { _ in tab = "webcam" }
    }
}

