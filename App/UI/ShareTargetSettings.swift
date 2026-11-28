//
//  ShareTargetSettings.swift
//  Greenroom
//
//  Which screen or window is shared (Settings -> Webcam -> Behind you).
//
import CoreGraphics
import SwiftUI

/// What the class sees behind the webcam: a whole display or one window. Its own view because the window list has state of its own and
/// refreshes on its own schedule.
struct ShareTargetSettings: View {
    let displays: [DisplayInfo]
    /// Called after any change, so the live picture can rebuild for it.
    var onChange: () -> Void = {}
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var windows: [ShareTarget.Window] = []
    @State private var canSeeTitles = CGPreflightScreenCaptureAccess()

    /// The kind (screen, window) is picked with the tiles on the
    /// Webcam page; this is the "which one" that follows.
    var body: some View {
        Group {
            switch coordinator.shareTarget.kind {
            case .display:
                displayPicker(title: "Screen")
                    .help("If this screen is unplugged at Start, the main display is shared instead.")
            case .window:
                windowPicker
            case .app, .nothing, .whiteboard:
                // No "which one" to pick.
                EmptyView()
            }
        }
        .animation(.default, value: coordinator.shareTarget.kind)
        // While this picker is up and Greenroom is in front, the capture is
        // never moved to a slide show under the person (SlideShowFollow).
        .onAppear { StageScreenSource.pickersOnScreen.withLock { $0 += 1 }; refresh() }
        .onDisappear { StageScreenSource.pickersOnScreen.withLock { $0 = max(0, $0 - 1) } }
        .onChange(of: coordinator.shareTarget) { _ in onChange() }
        .onChange(of: coordinator.shareTarget.kind) { _ in refresh() }
        .onChange(of: coordinator.screenCaptureDisplayUUID) { _ in onChange() }
    }

    private func displayPicker(title: String) -> some View {
        Picker(title, selection: $coordinator.screenCaptureDisplayUUID) {
            Text("Automatic (your main display)").tag("")
            ForEach(displays) { display in
                Text(display.label).tag(display.id)
            }
            // Keep a saved-but-disconnected choice visible and valid,
            // so unplugging a monitor does not silently reset it.
            if !coordinator.screenCaptureDisplayUUID.isEmpty,
               !displays.contains(where: { $0.id == coordinator.screenCaptureDisplayUUID }) {
                Text("Saved display (not connected)").tag(coordinator.screenCaptureDisplayUUID)
            }
        }
    }

    @ViewBuilder
    private var windowPicker: some View {
        let target = coordinator.shareTarget
        let selected = target.appBundleID.isEmpty ? "" : ShareTarget.windowKey(bundleID: target.appBundleID,
                                                                                 title: target.windowTitle)
        HStack {
            Picker("Window", selection: Binding(
                get: { selected },
                set: { key in
                    guard let window = windows.first(where: { $0.key == key }) else { return }
                    var next = coordinator.shareTarget
                    next.appBundleID = window.bundleID
                    next.appName = window.appName
                    next.windowTitle = window.title
                    coordinator.shareTarget = next
                    coordinator.bringSharedWindowForward(window)
                })) {
                Text("Choose a window").tag("")
                ForEach(windows) { window in
                    Text((window.title.isEmpty ? window.appName : "\(window.appName) \u{2013} \(window.title)")
                         + window.placement.menuSuffix)
                        .tag(window.key)
                }
                if !selected.isEmpty, !windows.contains(where: { $0.key == selected }) {
                    // Not listed under that title, but the app may still be
                    // open - and then Start shares its front window.
                    let open = windows.contains { $0.bundleID == target.appBundleID }
                    let name = target.windowTitle.isEmpty
                        ? target.displayName
                        : "\(target.displayName) \u{2013} \(target.windowTitle)"
                    Text(open ? "\(name) (front window)" : "\(name) (not open)")
                        .tag(selected)
                }
            }
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh the window list")
                .accessibilityLabel("Refresh the window list")
        }
        Toggle("Follow the slide show when the window goes full screen", isOn: $coordinator.shareTarget.followsSlideShow)
            .help("Keynote or PowerPoint play mode, a browser\u{2019}s Present, a PDF presentation: when this window\u{2019}s app opens a full-screen window, the picture moves to it, and back when the show ends. Another app\u{2019}s windows are never followed.")
        if let app = coordinator.followingSlideShowApp {
            Label("Following \(app)\u{2019}s slide show", systemImage: "play.rectangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        }
        if !canSeeTitles {
            HStack {
                Text("Windows are listed by app until Greenroom may read their titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Allow\u{2026}") {
                    StageScreenSource.askForPermission()
                    canSeeTitles = CGPreflightScreenCaptureAccess()
                    refresh()
                }
            }
        }
    }

    /// Without titles every window of an app has the same key, so only the
    /// first (the front one) is listed; picking it shares the front window,
    /// which is what an untitled choice means at Start too.
    private func refresh() {
        var seen = Set<String>()
        windows = ShareTarget.windows().filter { seen.insert($0.key).inserted }
        canSeeTitles = CGPreflightScreenCaptureAccess()
    }
}

