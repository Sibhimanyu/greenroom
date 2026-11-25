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
import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Home's Layout chip and Zoom readiness pill: Settings, on the tab named
    /// by the notification's object ("layout", "devices", "zoom", ...; `SettingsTabs`). The old
    /// "webcam" id and `SettingsTabs.cameraLookID` open Layouts with the camera piece selected.
    static let showSettingsTab = Notification.Name("GreenroomShowSettingsTab")
}

struct SettingsView: View {
    private static let tabOrder = SettingsTabs.order(includingAccount: SettingsTabs.buildHasAccount)

    private var tabShortcuts: some View {
        ZStack {
            ForEach(Array(Self.tabOrder.enumerated()), id: \.offset) { index, tag in
                if let key = SettingsTabs.shortcutKey(at: index) {
                    Button("") { tab = tag }
                        .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                }
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
        case "zoom": return 640
        case "general": return 360
        case "youtube": return 640
        default: return 730
        }
    }

    @EnvironmentObject private var coordinator: CoordinatorController
    /// Home and the other windows choose a tab from outside by its tag; the other tags are there so
    /// the TabView can track which tab is showing.
    @State private var tab = "layout"

    var body: some View {
        TabView(selection: $tab) {
            #if DEBUG
            AccountSettingsTab()
                .settingsPageClip()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag("account")
            #endif

            LayoutSettingsTab()
                .settingsPageClip()
                .tabItem { Label("Layouts", systemImage: "rectangle.split.2x1") }
                .tag("layout")

            DevicesSettingsTab()
                .settingsPageClip()
                .tabItem { Label("Devices", systemImage: "headphones") }
                .tag("devices")

            GeneralSettingsTab()
                .settingsPageClip()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")

            ShortcutsSettingsTab()
                .settingsPageClip()
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag("shortcuts")

            ZoomSettingsTab()
                .settingsPageClip()
                .tabItem { Label("Zoom", systemImage: "video.bubble") }
                .tag("zoom")

            YouTubeSettingsTab()
                .settingsPageClip()
                .tabItem { Label("YouTube", systemImage: "play.rectangle.fill") }
                .tag("youtube")

            CuesSettingsTab()
                .settingsPageClip()
                .tabItem { Label("Cues", systemImage: "waveform.and.magnifyingglass") }
                .tag("cues")

            TransferSettingsTab()
                .settingsPageClip()
                .tabItem { Label("Transfer", systemImage: "square.and.arrow.up.on.square") }
                .tag("transfer")
        }
        .frame(width: 760, height: Self.height(for: tab))
        .settingsTopEdge()
        .background(SettingsContentClip())
        .animation(.snappy(duration: 0.25), value: tab)
        // ⌘1...⌘9 (and ⌘0 for a tenth in Debug) pick a tab, as in every macOS Settings window. The buttons
        // live in this view, so the shortcuts exist only while Settings is key.
        .background(tabShortcuts)
        // Secrets are loaded lazily (see loadSecretsIfNeeded) - opening
        // Settings is the first moment the fields actually need them.
        .onAppear { coordinator.loadSecretsIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsTab)) { note in
            guard let id = note.object as? String else { return }
            show(tabID: id)
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugTourSettingsTab)) { note in
            if let id = note.object as? String { show(tabID: id) }
        }
        #endif
    }
}


extension SettingsView {
    /// Every deep link (Home's links, the DEBUG tour) goes through `SettingsTabs.destination`, so an
    /// old id such as "webcam" lands on Layouts with the camera piece selected.
    fileprivate func show(tabID id: String) {
        let destination = SettingsTabs.destination(for: id)
        guard Self.tabOrder.contains(destination.tab) else { return }
        if destination.selectsCamera { coordinator.layoutsCameraRequested = true }
        tab = destination.tab
    }
}

extension View {
    /// The Settings title bar and tab toolbar are part of the window's frost
    /// (WindowFrost leaves the title bar transparent), and a page's Form
    /// scrolls under them. Two layers, so a page ends cleanly at the bottom
    /// edge of the tab bar instead of showing through the tab labels (owner,
    /// 2026-11-20):
    /// 1. every OS: `settingsPageClip` (`pageScrollClip`) masks the page to the area below the
    ///    top safe area (the toolbar). It paints nothing, so the wallpaper
    ///    tint of the frost is untouched (DESIGN.md, 2026-11-12).
    /// 2. macOS 26: the HARD scroll edge effect, on the TabView and again on
    ///    each page's own scroll view, which cannot rely on the TabView's
    ///    environment reaching it.
    @ViewBuilder
    func settingsTopEdge() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }

    /// One Settings tab: the hard top scroll edge; the cut itself is `SettingsContentClip`.
    func settingsPageClip() -> some View {
        pageScrollEdge()
    }
}

/// Cuts the Settings window's whole content view at the bottom edge of the
/// toolbar (the tab row). A page's ScrollView is laid out under the transparent
/// title bar, so a SwiftUI mask on the page never held once it scrolled (the
/// page's own frame sits where the safe area says, but its scroll content
/// still draws above it). The toolbar is a sibling of the content view, not
/// inside it, so masking the content view to `contentLayoutRect` hides only
/// scrolled-up content; the frost behind it stays. Paints nothing, takes no clicks.
private struct SettingsContentClip: NSViewRepresentable {
    final class Probe: NSView {
        private let maskLayer = CALayer()
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func layout() { super.layout(); apply() }

        func apply() {
            guard let content = window?.contentView else { return }
            content.wantsLayer = true
            let rect = content.convert(window?.contentLayoutRect ?? .zero, from: nil)
            maskLayer.backgroundColor = NSColor.black.cgColor
            maskLayer.frame = rect
            if content.layer?.mask !== maskLayer { content.layer?.mask = maskLayer }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ probe: Probe, context: Context) { probe.apply() }
}
