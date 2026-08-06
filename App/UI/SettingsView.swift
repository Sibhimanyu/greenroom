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
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        TabView {
            WebcamSettingsTab()
                .tabItem { Label("Webcam", systemImage: "video.fill") }

            LayoutSettingsTab()
                .tabItem { Label("Layout", systemImage: "rectangle.split.2x1") }

            MeetingSDKSettingsTab()
                .tabItem { Label("Meeting Chat", systemImage: "bubble.left.and.bubble.right.fill") }

            StartMeetingSettingsTab()
                .tabItem { Label("Start Meeting", systemImage: "video.badge.plus") }

            TransferSettingsTab()
                .tabItem { Label("Transfer", systemImage: "square.and.arrow.up.on.square") }
        }
        .frame(width: 540, height: 520)
        // Secrets stay out of the Keychain at launch (see loadSecretsIfNeeded)
        // - opening Settings is the first moment the fields actually need them.
        .onAppear { coordinator.loadSecretsIfNeeded() }
    }
}

private struct WebcamSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Form {
            Picker("Bubble shape", selection: $coordinator.webcamShape) {
                ForEach(WebcamShape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            Text(coordinator.webcamShape == .cutout
                 ? "Cutout removes your background with a chroma key, so you appear as a cutout over the shared screen \u{2014} needs a real green screen behind you. Tune the key in OBS \u{2192} the webcam source \u{2192} Filters if the edges look rough."
                 : "Pick a shape, then Start/Restart on the main window to apply it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

/// The generalized main-pane + side-column arrangement: pick any app for
/// the main pane, choose how much of the screen it takes, and toggle what
/// fills the leftover column - with a live schematic of the result.
private struct LayoutSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var apps: [AppInfo] = []
    @State private var hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission

    // AXIsProcessTrusted() has no change notification, so poll it while
    // the tab is visible - the warning below disappears on its own once
    // the user flips the switch in System Settings.
    private let permissionTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Picker("Main app", selection: $coordinator.mainAppBundleID) {
                ForEach(apps) { app in
                    HStack(spacing: 6) {
                        if let icon = AppCatalog.icon(forBundleID: app.bundleID) {
                            Image(nsImage: sized(icon))
                        }
                        Text(app.name)
                    }
                    .tag(app.bundleID)
                }
            }

            if AppCatalog.isBrowser(coordinator.mainAppBundleID) {
                TextField("Open website", text: $coordinator.mainAppURL, prompt: Text("e.g. docs.google.com"))
            }

            if needsAccessibility && !hasAccessibilityPermission {
                accessibilityWarning
            }

            Section {
                Picker("Main pane width", selection: $coordinator.workspaceLayout.split) {
                    ForEach(WorkspaceLayout.Split.allCases) { split in
                        Text(split.glyph).tag(split)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Main pane side", selection: $coordinator.workspaceLayout.mainOnLeft) {
                    Text("Left").tag(true)
                    Text("Right").tag(false)
                }
                .pickerStyle(.segmented)

                LayoutSchematicView(layout: coordinator.workspaceLayout,
                                    appName: coordinator.mainAppDisplayName,
                                    appIcon: AppCatalog.icon(forBundleID: coordinator.mainAppBundleID))
                    .frame(height: 120)
                    .padding(.vertical, 4)
            }

            Section("Side column") {
                Toggle("Zoom meeting tile", isOn: $coordinator.workspaceLayout.sideShowsZoomTile)
                Toggle("Chat window", isOn: $coordinator.workspaceLayout.sideShowsChat)

                if coordinator.workspaceLayout.sideShowsZoomTile && coordinator.workspaceLayout.sideShowsChat {
                    Slider(value: $coordinator.workspaceLayout.zoomSlotRatio, in: 0.25...0.65) {
                        Text("Zoom tile height \(Int(coordinator.workspaceLayout.zoomSlotRatio * 100))%")
                    }
                }
            }

            Toggle("Open the main app automatically on Start", isOn: $coordinator.mainAppOnStart)

            Text("The Zoom meeting tile and chat window tile themselves into whatever space the main pane leaves free.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onAppear { apps = pickerApps() }
        .onReceive(permissionTick) { _ in
            hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission
        }
    }

    /// Chrome is driven through its own AppleScript dictionary (per-app
    /// Automation permission, prompted on first use) - every other app
    /// needs the system-wide Accessibility grant to be moved at all.
    private var needsAccessibility: Bool {
        coordinator.mainAppBundleID != ChromeWindowManager.chromeBundleID
    }

    /// Without this, picking an ungranted app just silently fails to move
    /// its window at Start - say so up front, with a way to fix it.
    private var accessibilityWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 3) {
                Text("Greenroom can't move \(coordinator.mainAppDisplayName)'s window yet.")
                    .font(.callout.weight(.medium))
                Text("Apps other than Chrome are positioned with the Accessibility API. Allow Greenroom under System Settings \u{2192} Privacy & Security \u{2192} Accessibility \u{2014} until then, \(coordinator.mainAppDisplayName) will open but stay wherever it is.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings\u{2026}") {
                AppWindowManager.promptForAccessibilityPermission()
                AppWindowManager.openAccessibilitySettings()
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Installed + running apps, with the saved choice force-included so
    /// the picker never shows blank if that app has since been removed.
    private func pickerApps() -> [AppInfo] {
        var list = AppCatalog.installedAndRunning()
        if !list.contains(where: { $0.bundleID == coordinator.mainAppBundleID }) {
            list.insert(AppInfo(bundleID: coordinator.mainAppBundleID,
                                name: AppCatalog.displayName(forBundleID: coordinator.mainAppBundleID) ?? coordinator.mainAppBundleID,
                                url: nil),
                        at: 0)
        }
        return list
    }

    /// NSWorkspace icons come at 32pt+; menu rows want 16.
    private func sized(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

/// A miniature live preview of the three panes: the main app's slice, and
/// the side column with the Zoom tile stacked over the chat - everything
/// proportioned exactly as the real layout will be, updating as the
/// controls above change.
private struct LayoutSchematicView: View {
    let layout: WorkspaceLayout
    let appName: String
    let appIcon: NSImage?

    private let spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let mainWidth = (geo.size.width - spacing) * layout.split.fraction
            let sideWidth = geo.size.width - spacing - mainWidth

            HStack(spacing: spacing) {
                if layout.mainOnLeft {
                    mainPane.frame(width: mainWidth)
                    sideColumn(height: geo.size.height).frame(width: sideWidth)
                } else {
                    sideColumn(height: geo.size.height).frame(width: sideWidth)
                    mainPane.frame(width: mainWidth)
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: layout)
    }

    private var mainPane: some View {
        pane(tint: .blue) {
            VStack(spacing: 4) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 24, height: 24)
                }
                Text(appName)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
        }
    }

    private func sideColumn(height: CGFloat) -> some View {
        VStack(spacing: spacing) {
            if layout.sideShowsZoomTile {
                pane(tint: .indigo) {
                    Label("Zoom", systemImage: "video.fill")
                        .font(.caption2.weight(.medium))
                }
                .frame(height: layout.sideShowsChat
                       ? (height - spacing) * layout.effectiveZoomSlotRatio
                       : nil)
            }
            if layout.sideShowsChat {
                pane(tint: .teal) {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right.fill")
                        .font(.caption2.weight(.medium))
                }
            }
            if !layout.sideShowsZoomTile && !layout.sideShowsChat {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .overlay(Text("Free").font(.caption2).foregroundStyle(.tertiary))
            }
        }
    }

    private func pane<Content: View>(tint: Color, @ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(tint.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(0.45), lineWidth: 1)
            )
            .overlay(content().foregroundStyle(tint))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingSDKSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Form {
            TextField("Client ID", text: $coordinator.sdkClientID)
            SecureField("Client Secret", text: $coordinator.sdkClientSecret)

            Text("From your Zoom Marketplace app (General App \u{2192} Features \u{2192} Embed \u{2192} Meeting SDK). Only works for meetings hosted under this same Zoom account - joining a meeting hosted elsewhere fails with Zoom's cross-account restriction.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

private struct StartMeetingSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Form {
            TextField("Account ID", text: $coordinator.s2sAccountID)
            TextField("Client ID", text: $coordinator.s2sClientID)
            SecureField("Client Secret", text: $coordinator.s2sClientSecret)

            Text("A different Zoom app than Meeting Chat's - create one at marketplace.zoom.us: Build App \u{2192} Server-to-Server OAuth, add a meeting-write scope, then copy its Account ID/Client ID/Secret here. If it's the same Zoom account as your Meeting Chat app, meetings started here automatically satisfy that feature's same-account requirement too.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Use built-in meeting client", isOn: $coordinator.useBuiltInClient)
            TextField("Your display name", text: $coordinator.userDisplayName)

            Text("On (default): New Meeting runs entirely inside Greenroom's built-in Zoom client \u{2014} one participant (you), hosting directly, chat sent as you, no separate Zoom app. Off: the classic flow \u{2014} the native Zoom app plus a hidden \u{201C}Greenroom Chat\u{201D} participant carrying the chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

/// Export/import all of the above as one JSON file - the whole point is
/// setting up a teammate's machine without them ever touching the Zoom
/// Marketplace: send them the app + this file, they import it, done.
private struct TransferSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var statusMessage = ""

    var body: some View {
        Form {
            HStack {
                Button("Export Settings\u{2026}") { exportSettings() }
                Button("Import Settings\u{2026}") { importSettings() }
            }

            Text("One file with every setting on this screen, Zoom credentials included \u{2014} in plaintext. Hand it over directly (e.g. AirDrop) and delete it once imported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption)
            }
        }
        .padding(20)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Greenroom Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.exportSettingsData().write(to: url, options: .atomic)
            statusMessage = "Exported to \(url.lastPathComponent)."
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try coordinator.importSettings(from: Data(contentsOf: url))
            statusMessage = "Imported from \(url.lastPathComponent). You can delete that file now."
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
