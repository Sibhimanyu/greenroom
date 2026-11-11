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
import Heresay

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

    /// The name "Greenroom" wherever it's set as a wordmark: one colour, as in
    /// the lockup (Branding/greenroom-mark). `--brand-deep` #00401C on light,
    /// white on dark. Never lime and never two-tone - DESIGN.md, Logo.
    static let name = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .white
            : NSColor(srgbRed: 0x00 / 255, green: 0x40 / 255, blue: 0x1C / 255, alpha: 1)
    })

    /// The logo's lime, `--accent-lime` #78C000. Fills, tints, shapes. Never
    /// text - see `Brand.text`.
    static let fill = Color(nsColor: NSColor(srgbRed: 0x78 / 255,
                                             green: 0xC0 / 255,
                                             blue: 0x00 / 255, alpha: 1))

    /// The de-emphasis grey charts draw context in, so the one series that
    /// matters is the only thing carrying colour.
    static let recessive = Color(nsColor: .tertiaryLabelColor)

    /// "Leaves your Mac", DESIGN.md's `--net` #B9770E: glyphs, strokes,
    /// arrows that cross out of the Mac. Green means local; this is the other
    /// half of that rule. Not for small text - see `netText`.
    static let net = Color(nsColor: NSColor(srgbRed: 0xB9 / 255, green: 0x77 / 255,
                                            blue: 0x0E / 255, alpha: 1))

    /// The same meaning as words. `--net-text` #96600A on light, where `--net`
    /// fails as small text; `--net` itself on dark, where the darker step
    /// would sink into the window.
    static let netText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0xB9 / 255, green: 0x77 / 255, blue: 0x0E / 255, alpha: 1)
            : NSColor(srgbRed: 0x96 / 255, green: 0x60 / 255, blue: 0x0A / 255, alpha: 1)
    })
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

    init() {
        Heresay.configure(
            key: "pk_Bt1i6kv0DKI4Wcm-AzYdlYu2",
            url: URL(string: "https://heresay-sibhi.web.app")!,
            nudge: .all
        )
    }

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
                .heresay()
                // Once per install, and never over onboarding: on a first
                // run it waits for the onboarding sheet to close.
                .onAppear { if !coordinator.showOnboarding { Heresay.introduce() } }
                .onChange(of: coordinator.showOnboarding) { _, showing in
                    if !showing { Heresay.introduce() }
                }
        }
        // Derived from the button row, not chosen - see
        // ContentView.minimumWindowWidth.
        .defaultSize(width: ContentView.defaultWindowWidth, height: 400)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") {
                    updaterController.checkForUpdates(nil)
                }
            }
            HeresayCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(coordinator)
                .tint(Brand.green)
        }

        // Sessions and the report are not scenes. They were windows, and
        // before that a sheet; Greenroom keeps a low profile, so they are
        // pages of the main window (CoordinatorController.MainPage), which
        // grows to hold them and gives its size back on Back.

        // The mark, as a one-colour template image (MenuBarMark, a vector
        // PDF 16pt tall), in place of the old "GR". The old mark was tried
        // here once and reverted because its gradient cascade read worse
        // than text at 16pt; the flat mark keeps its G, head and arm at
        // that size. While recording, the label flips to a record glyph +
        // REC - the menu bar renders extras monochrome, so the SHAPE change
        // is the indicator, not color.
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
                    Image("MenuBarMark").accessibilityLabel("Greenroom")
                }
            } else {
                Image("MenuBarMark").accessibilityLabel("Greenroom")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
