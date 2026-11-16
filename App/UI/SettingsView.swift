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
    /// Home's Layout chip and Zoom readiness pill: Settings, on the tab named
    /// by the notification's object ("layout", "zoom").
    static let showSettingsTab = Notification.Name("GreenroomShowSettingsTab")
}

struct SettingsView: View {
    private static let tabOrder = ["account", "webcam", "layout", "shortcuts", "zoom", "youtube", "cues", "transfer"]

    private var tabShortcuts: some View {
        ZStack {
            ForEach(Array(Self.tabOrder.enumerated()), id: \.offset) { index, tag in
                Button("") { tab = tag }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// The window fits the tab: short pages (Transfer, Cues) no longer sit in a
    /// window three times taller than they are. The long ones scroll past 730.
    private static func height(for tab: String) -> CGFloat {
        switch tab {
        case "transfer": return 420
        case "cues": return 480
        case "account": return 560
        case "zoom": return 600
        case "youtube": return 640
        default: return 730
        }
    }

    @EnvironmentObject private var coordinator: CoordinatorController
    /// Only Webcam is ever chosen from outside; the other tags are there so
    /// the TabView can track which tab is showing.
    @State private var tab = "webcam"

    var body: some View {
        TabView(selection: $tab) {
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag("account")

            WebcamSettingsTab()
                .tabItem { Label("Webcam", systemImage: "video.fill") }
                .tag("webcam")

            LayoutSettingsTab()
                .tabItem { Label("Layout", systemImage: "rectangle.split.2x1") }
                .tag("layout")

            ShortcutsSettingsTab()
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag("shortcuts")

            ZoomSettingsTab()
                .tabItem { Label("Zoom", systemImage: "video.bubble") }
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
        .frame(width: 760, height: Self.height(for: tab))
        .animation(.snappy(duration: 0.25), value: tab)
        // ⌘1...⌘8 pick a tab, as in every macOS Settings window. The buttons
        // live in this view, so the shortcuts exist only while Settings is key.
        .background(tabShortcuts)
        // Secrets are loaded lazily (see loadSecretsIfNeeded) - opening
        // Settings is the first moment the fields actually need them.
        .onAppear { coordinator.loadSecretsIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .showWebcamSettings)) { _ in tab = "webcam" }
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsTab)) { note in
            if let tag = note.object as? String, Self.tabOrder.contains(tag) { tab = tag }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugTourSettingsTab)) { tab = ($0.object as? String) ?? tab }
        #endif
    }
}

