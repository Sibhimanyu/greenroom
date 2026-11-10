//
//  LayoutSettingsTab.swift
//  Greenroom
//
//  Settings -> Layout: the main app, the side column and the panes.
//
//  Drawn the way the Webcam page is: the screen comes first, as a picture you
//  can drag, and every choice under it is a picture of itself (which side,
//  how wide, what fills the column, which display). What each one does lives
//  in hover help, not in captions.
//
//  `LayoutPageContent` takes plain bindings, not the coordinator, so the same
//  view can be rendered off screen with sample values to check it by eye.
//  `LayoutSettingsTab` is the thin layer that feeds it from the coordinator.
//
import SwiftUI

// MARK: - The tab

struct LayoutSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var apps: [AppInfo] = []
    @State private var displays: [DisplayInfo] = DisplayResolver.connectedDisplays()
    @State private var hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission

    // AXIsProcessTrusted() has no change notification, so poll it while
    // the tab is visible - the warning disappears on its own once the user
    // flips the switch in System Settings.
    private let permissionTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        LayoutPageContent(
            layout: $coordinator.workspaceLayout,
            mainAppBundleID: $coordinator.mainAppBundleID,
            mainAppURL: $coordinator.mainAppURL,
            mainAppOnStart: $coordinator.mainAppOnStart,
            browserRestoresTabs: $coordinator.browserRestoresTabs,
            browserSearchSuggestions: $coordinator.browserSearchSuggestions,
            browserClosesOnStop: $coordinator.browserClosesOnStop,
            hideSelfView: $coordinator.hideSelfView,
            quickHide: $coordinator.speakerTileShortcutEnabled,
            analyticsEnabled: $coordinator.analyticsEnabled,
            peopleViewOnStart: $coordinator.peopleViewOnStart,
            panelOnMainDisplay: $coordinator.participantPanelOnMainDisplay,
            peopleViewDisplayUUID: $coordinator.peopleViewDisplayUUID,
            apps: apps,
            displays: displays,
            customUIMode: coordinator.customUIMode,
            mainAppName: coordinator.mainAppDisplayName,
            // Browsers are driven through the Chromium AppleScript dictionary
            // (per-app Automation permission, prompted on first use) - only
            // non-browser apps need the system-wide Accessibility grant to be
            // moved. (A non-Chromium browser would fall back to Accessibility
            // too, but that's rare enough to keep this warning simple.)
            cannotMoveMainApp: !AppCatalog.isBrowser(coordinator.mainAppBundleID) && !hasAccessibilityPermission,
            openAccessibilitySettings: {
                AppWindowManager.promptForAccessibilityPermission()
                AppWindowManager.openAccessibilitySettings()
            })
        .onAppear {
            apps = pickerApps()
            displays = DisplayResolver.connectedDisplays()
        }
        .onReceive(permissionTick) { _ in
            hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayResolver.connectedDisplays()
        }
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
}

// MARK: - The page

private enum LayoutSettingsFocus: Hashable {
    case websiteURL
}

struct LayoutPageContent: View {
    /// Half, two thirds, three quarters - what the fixed widths used to be.
    private static let widthPresets: [(fraction: Double, name: String, mark: String)] = [
        (0.5, "Half", "\u{00BD}"), (2.0 / 3.0, "Two thirds", "\u{2154}"), (0.75, "Three quarters", "\u{00BE}"),
    ]

    @Binding var layout: WorkspaceLayout
    @Binding var mainAppBundleID: String
    @Binding var mainAppURL: String
    @Binding var mainAppOnStart: Bool
    @Binding var browserRestoresTabs: Bool
    @Binding var browserSearchSuggestions: Bool
    @Binding var browserClosesOnStop: Bool
    @Binding var hideSelfView: Bool
    @Binding var quickHide: Bool
    @Binding var analyticsEnabled: Bool
    @Binding var peopleViewOnStart: Bool
    @Binding var panelOnMainDisplay: Bool
    @Binding var peopleViewDisplayUUID: String
    let apps: [AppInfo]
    let displays: [DisplayInfo]
    /// Greenroom's own participant panel rather than Zoom's grid.
    let customUIMode: Bool
    let mainAppName: String
    /// A non-browser app without the Accessibility grant: it would open at
    /// Start but stay wherever it is.
    let cannotMoveMainApp: Bool
    let openAccessibilitySettings: () -> Void

    @FocusState private var focus: LayoutSettingsFocus?

    private var isBrowser: Bool { AppCatalog.isBrowser(mainAppBundleID) }
    private var isBuiltInBrowser: Bool { AppCatalog.isBuiltInBrowser(mainAppBundleID) }

    var body: some View {
        Form {
            Section {
                stage
                stageControls
            }

            Section("Main app") { mainApp }

            Section("Meeting column") {
                SideColumnPicker(layout: $layout)
                HStack(spacing: 24) {
                    Toggle("Hide my own tile", isOn: $hideSelfView)
                        .help("Only changes what you see. The class still gets your video.")
                        .frame(maxWidth: .infinity)
                    Toggle("Quick-hide mode", isOn: $quickHide)
                        .help("Sessions start with the speaker hidden and the chat full height. \u{2325}\u{2318}Z shows it.")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityElement(children: .contain)
            }

            Section("Second display") { secondDisplay }

            Section("Privacy") {
                Toggle("Anonymous usage analytics", isOn: $analyticsEnabled)
                    .help("Counts and timings only. Never names, meeting IDs, addresses or chat.")
            }
        }
        .formStyle(.grouped)
        // Nothing focused when the tab opens. Without this the website field
        // claimed focus immediately and could not be escaped, because macOS Tab
        // cycles text fields and this tab has only one.
        .defaultFocus($focus, nil)
        // Escape always releases it, which is the habit people already have and
        // the only way out when Tab has nowhere to go.
        .onExitCommand { focus = nil }
        .onAppear { focus = nil }
    }

    // MARK: Stage

    /// The main display as a picture: the panes in their real proportions,
    /// with handles to drag. Drawn at a screen's own shape (16:10) and
    /// centred, so it reads as "your screen" rather than as a progress bar.
    private static let stageSize = CGSize(width: 320, height: 200)

    private var stage: some View {
        LayoutSchematicView(layout: $layout,
                            appName: mainAppName,
                            appIcon: AppCatalog.icon(forBundleID: mainAppBundleID))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.3)))
            .frame(width: Self.stageSize.width, height: Self.stageSize.height)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .help("Drag the handles to size the panes. A live session re-tiles as you change it.")
    }

    /// Which side and how wide, as little screens. Presets AND the drag, not
    /// one instead of the other: the drag makes any width possible and the
    /// three common ones fiddly - getting exactly half by hand is a hunt for
    /// a pixel. A width the handles left somewhere else simply lights nothing.
    private var stageControls: some View {
        HStack(spacing: 16) {
            GlyphGroup {
                ForEach([true, false], id: \.self) { left in
                    GlyphButton(selected: layout.mainOnLeft == left,
                                name: left ? "Main app on the left" : "Main app on the right") {
                        MiniScreen(fraction: layout.clampedMainFraction, mainOnLeft: left,
                                   highlighted: layout.mainOnLeft == left)
                    } action: {
                        withAnimation(.snappy(duration: 0.25)) { layout.mainOnLeft = left }
                    }
                }
            }
            Spacer(minLength: 0)
            GlyphGroup {
                ForEach(Self.widthPresets, id: \.fraction) { preset in
                    let selected = abs(preset.fraction - layout.clampedMainFraction) < 0.005
                    GlyphButton(selected: selected, name: "\(preset.name) width") {
                        HStack(spacing: 4) {
                            MiniScreen(fraction: preset.fraction, mainOnLeft: layout.mainOnLeft,
                                       highlighted: selected)
                            Text(preset.mark)
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? .primary : .secondary)
                        }
                    } action: {
                        withAnimation(.snappy(duration: 0.25)) { layout.mainFraction = preset.fraction }
                    }
                }
            }
        }
        // The picture's own width, so the controls line up under its edges
        // instead of drifting out to the form's (DESIGN.md, Panel composition).
        .frame(width: Self.stageSize.width)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    // MARK: Main app

    @ViewBuilder
    private var mainApp: some View {
        Picker("App", selection: $mainAppBundleID) {
            ForEach(apps) { app in
                HStack(spacing: 8) {
                    if let icon = AppCatalog.icon(forBundleID: app.bundleID) {
                        Image(nsImage: sized(icon))
                    }
                    Text(app.name)
                }
                .tag(app.bundleID)
            }
        }
        .help(isBuiltInBrowser
              ? "Greenroom\u{2019}s own browser: tabs, find in page, local history, no permissions to grant. Pick Chrome if you need extensions."
              : "What fills the main pane")

        if cannotMoveMainApp {
            // Without this, picking an ungranted app just silently fails to
            // move its window at Start - say so up front, with a way to fix it.
            HStack {
                StatusBadge(text: "Can\u{2019}t move \(mainAppName) yet", tone: .problem)
                Spacer()
                Button("Open Settings\u{2026}", action: openAccessibilitySettings)
            }
            .help("Non-browser apps are placed with the Accessibility API. Allow Greenroom under System Settings \u{2192} Privacy & Security \u{2192} Accessibility. Until then \(mainAppName) opens but stays wherever it is.")
        }

        if isBrowser {
            // .roundedBorder, not the Form default borderless: the
            // borderless field rendered as an apparently-dead empty
            // row (macOS hides the prompt until focus), so nothing
            // signalled "type a URL here" (design-review F2).
            TextField("Website", text: $mainAppURL, prompt: Text("e.g. docs.google.com"))
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .websiteURL)
                .help("Opens at Start")
        }

        Toggle("Open on Start", isOn: $mainAppOnStart)
            .help("Opens the main app tiled to its pane. The Zoom tile and chat take whatever it leaves free.")

        if isBuiltInBrowser {
            Toggle("Reopen last tabs", isOn: $browserRestoresTabs)
                .help("Yesterday\u{2019}s tabs come back beside the website above.")
            Toggle("Search suggestions", isOn: $browserSearchSuggestions)
                .help("Sends what you type to Google for completions. Off: history only, nothing leaves until Return.")
            Toggle("Close when the session ends", isOn: $browserClosesOnStop)
                .help("Tabs are kept for the next Start.")
        } else if isBrowser {
            // The same switch for an outside browser, which Greenroom
            // can close only because it made that window itself.
            Toggle("Close its window when the session ends", isOn: $browserClosesOnStop)
                .help("Only the window Start opened. Your other \(mainAppName) windows and tabs stay open. Works with Chrome and browsers built like it (Ulaa, Edge, Brave).")
        }
    }

    /// NSWorkspace icons come at 32pt+; menu rows want 16.
    private func sized(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    // MARK: Second display

    @ViewBuilder
    private var secondDisplay: some View {
        Toggle("Participant view", isOn: $peopleViewOnStart)
            .help(customUIMode
                  ? "Every student and the host controls, full-screen on your reference monitor."
                  : "Zoom\u{2019}s participant grid, full-screen on your reference monitor.")

        // Greyed out rather than hidden while the view is off, like the
        // rest of Settings. The main-display option stays hidden with
        // Zoom's own grid, because there it does not exist at all.
        if customUIMode {
            Toggle("Allow on this screen if alone", isOn: $panelOnMainDisplay)
                .help("When no second display is connected. It is large and covers the workspace; for trying the panel without a second monitor.")
                .disabled(!peopleViewOnStart)
        }

        DisplayPicker(selection: $peopleViewDisplayUUID, displays: displays)
            .disabled(!peopleViewOnStart)
            .opacity(peopleViewOnStart ? 1 : 0.5)

        if displays.count <= 1 {
            StatusBadge(text: "Only this display is connected", tone: .waiting)
                .help("Plug in your reference display and it appears here. Mirrored displays show as their main, so use a separate, extended monitor.")
                .opacity(peopleViewOnStart ? 1 : 0.5)
        }
    }
}

// MARK: - Pieces

/// A bordered strip of small picture buttons, like the Webcam page's sizes.
private struct GlyphGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 4) { content() }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

private struct GlyphButton<Label: View>: View {
    let selected: Bool
    let name: String
    @ViewBuilder let label: () -> Label
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label()
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Brand.green.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A thumbnail of the layout: a screen with the main pane filled in.
private struct MiniScreen: View {
    let fraction: Double
    let mainOnLeft: Bool
    let highlighted: Bool

    var body: some View {
        let width: CGFloat = 28, height: CGFloat = 20, inset: CGFloat = 3, gap: CGFloat = 2
        let inner = width - 2 * inset - gap
        let main = inner * fraction
        HStack(spacing: gap) {
            if mainOnLeft {
                block(main, filled: true)
                block(inner - main, filled: false)
            } else {
                block(inner - main, filled: false)
                block(main, filled: true)
            }
        }
        .padding(inset)
        .frame(width: width, height: height)
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func block(_ width: CGFloat, filled: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(filled ? (highlighted ? Brand.green : Color.secondary.opacity(0.6))
                         : Color.secondary.opacity(0.2))
            .frame(width: width)
    }
}

/// The Zoom tile and the chat as two tiles you switch on and off. Both,
/// either or neither: the checkmark says these are toggles, not a choice of one.
private struct SideColumnPicker: View {
    @Binding var layout: WorkspaceLayout

    var body: some View {
        HStack(spacing: 8) {
            tile("Zoom tile", symbol: "video.fill", isOn: $layout.sideShowsZoomTile,
                 help: "The meeting\u{2019}s speaker, at the top of the column")
            tile("Chat", symbol: "bubble.left.and.bubble.right.fill", isOn: $layout.sideShowsChat,
                 help: "The meeting chat, under the Zoom tile")
        }
        .padding(.vertical, 4)
    }

    private func tile(_ title: String, symbol: String, isOn: Binding<Bool>, help: String) -> some View {
        ChoiceTile(title: title, selected: isOn.wrappedValue,
                   badge: isOn.wrappedValue ? "checkmark.circle.fill" : "circle") {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(isOn.wrappedValue ? Brand.green : Color.secondary)
                .frame(height: 32)
        } action: {
            withAnimation(.snappy(duration: 0.25)) { isOn.wrappedValue.toggle() }
        }
        .help(help)
    }
}

/// Where the participant view goes, as the displays themselves: each one
/// drawn at its own shape, the main one with a menu bar.
private struct DisplayPicker: View {
    @Binding var selection: String
    let displays: [DisplayInfo]

    var body: some View {
        HStack(spacing: 8) {
            ChoiceTile(title: "Automatic", selected: selection.isEmpty, badge: nil) {
                Image(systemName: "display.2")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(selection.isEmpty ? Brand.green : Color.secondary)
                    .frame(height: 32)
            } action: { selection = "" }
            .help("The first display that isn\u{2019}t your main one. Mirrored displays show as their main, so this finds the separate, extended monitor.")

            ForEach(displays) { display in
                let selected = selection == display.id
                ChoiceTile(title: display.name, selected: selected, badge: nil) {
                    DisplayGlyph(aspect: Double(display.pixelWidth) / Double(max(display.pixelHeight, 1)),
                                 isMain: display.isMain, highlighted: selected, missing: false)
                } action: { selection = display.id }
                .help(display.label)
            }

            // Keep a saved-but-disconnected choice visible and valid.
            if !selection.isEmpty, !displays.contains(where: { $0.id == selection }) {
                ChoiceTile(title: "Saved display", selected: true, badge: nil) {
                    DisplayGlyph(aspect: 16.0 / 9.0, isMain: false, highlighted: true, missing: true)
                } action: {}
                .help("Not connected right now. The view goes there when it is.")
            }
        }
        .padding(.vertical, 4)
    }
}

/// A display at its own aspect. Dashed when it is not connected.
private struct DisplayGlyph: View {
    let aspect: Double
    let isMain: Bool
    let highlighted: Bool
    let missing: Bool

    var body: some View {
        let height: CGFloat = 30
        let width = min(max(height * aspect, 22), 64)
        let tint = highlighted ? Brand.green : Color.secondary
        RoundedRectangle(cornerRadius: 3)
            .fill(tint.opacity(0.15))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: missing ? [3] : [])))
            .overlay(alignment: .top) {
                if isMain {
                    Rectangle().fill(tint.opacity(0.6)).frame(height: 4)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                        .padding(.horizontal, 1.5).padding(.top, 1.5)
                }
            }
            .frame(width: width, height: height)
            .frame(height: 32)
            .accessibilityHidden(true)
    }
}

/// A miniature live preview of the three panes: the main app's slice, and
/// the side column with the Zoom tile stacked over the chat - everything
/// proportioned exactly as the real layout will be, updating as the
/// controls below change.
private struct LayoutSchematicView: View {
    @Binding var layout: WorkspaceLayout
    let appName: String
    let appIcon: NSImage?

    private let spacing: CGFloat = 4
    @State private var draggingSplit = false
    @State private var draggingSlot = false

    var body: some View {
        GeometryReader { geo in
            let fraction = layout.clampedMainFraction
            let mainWidth = (geo.size.width - spacing) * fraction
            let sideWidth = geo.size.width - spacing - mainWidth
            let dividerX = layout.mainOnLeft ? mainWidth + spacing / 2 : sideWidth + spacing / 2
            let sideCenterX = layout.mainOnLeft ? mainWidth + spacing + sideWidth / 2 : sideWidth / 2

            ZStack(alignment: .topLeading) {
                HStack(spacing: spacing) {
                    if layout.mainOnLeft {
                        mainPane.frame(width: mainWidth)
                        sideColumn(height: geo.size.height).frame(width: sideWidth)
                    } else {
                        sideColumn(height: geo.size.height).frame(width: sideWidth)
                        mainPane.frame(width: mainWidth)
                    }
                }

                // Vertical divider: drag to resize main pane vs side column.
                grabber(width: 6, height: 44, active: draggingSplit)
                    .frame(width: 18, height: geo.size.height)
                    .contentShape(Rectangle())
                    .position(x: dividerX, y: geo.size.height / 2)
                    // NSCursor.set() rather than push/pop: the push/pop
                    // stack desynced across enter/exit events and left the
                    // wrong cursor orientation showing (reported live).
                    // Re-set every drag tick too - AppKit resets the cursor
                    // once the pointer leaves the hover area mid-drag.
                    .onHover { inside in
                        (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("schematic"))
                            .onChanged { value in
                                draggingSplit = true
                                NSCursor.resizeLeftRight.set()
                                let raw = Double(value.location.x / geo.size.width)
                                let fraction = layout.mainOnLeft ? raw : 1 - raw
                                layout.mainFraction = min(max(fraction, WorkspaceLayout.minMainFraction),
                                                          WorkspaceLayout.maxMainFraction)
                            }
                            .onEnded { _ in
                                draggingSplit = false
                                NSCursor.arrow.set()
                            }
                    )
                    // Keyboard/VoiceOver path for the mouse-only drag
                    // (Codex design audit #4).
                    .accessibilityElement()
                    .accessibilityLabel("Main pane width")
                    .accessibilityValue("\(Int((layout.clampedMainFraction * 100).rounded())) percent")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            layout.mainFraction = min(layout.clampedMainFraction + 0.05, WorkspaceLayout.maxMainFraction)
                        case .decrement:
                            layout.mainFraction = max(layout.clampedMainFraction - 0.05, WorkspaceLayout.minMainFraction)
                        @unknown default: break
                        }
                    }

                // Horizontal divider: drag to balance Zoom tile vs chat.
                if layout.sideShowsZoomTile && layout.sideShowsChat {
                    let slotY = (geo.size.height - spacing) * layout.effectiveZoomSlotRatio + spacing / 2
                    grabber(width: 44, height: 6, active: draggingSlot)
                        .frame(width: max(sideWidth - 16, 24), height: 18)
                        .contentShape(Rectangle())
                        .position(x: sideCenterX, y: slotY)
                        .onHover { inside in
                            (inside ? NSCursor.resizeUpDown : NSCursor.arrow).set()
                        }
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("schematic"))
                                .onChanged { value in
                                    draggingSlot = true
                                    NSCursor.resizeUpDown.set()
                                    let ratio = Double(value.location.y / geo.size.height)
                                    layout.zoomSlotRatio = min(max(ratio, 0.15), 0.85)
                                }
                                .onEnded { _ in
                                    draggingSlot = false
                                    NSCursor.arrow.set()
                                }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Zoom tile height")
                        .accessibilityValue("\(Int((layout.effectiveZoomSlotRatio * 100).rounded())) percent")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: layout.zoomSlotRatio = min(layout.zoomSlotRatio + 0.05, 0.85)
                            case .decrement: layout.zoomSlotRatio = max(layout.zoomSlotRatio - 0.05, 0.15)
                            @unknown default: break
                            }
                        }
                }
            }
            .coordinateSpace(name: "schematic")
        }
        // Snappy preset-style animation for external changes only - never
        // mid-drag, where it would lag the pointer.
        .animation(draggingSplit || draggingSlot ? nil : .snappy(duration: 0.25), value: layout)
    }

    /// Deliberately assertive, not decorative: the handles are the fine
    /// width control, so they must read as grabbable at a glance
    /// (design-review F5).
    private func grabber(width: CGFloat, height: CGFloat, active: Bool) -> some View {
        Capsule()
            .fill(active ? AnyShapeStyle(Brand.green) : AnyShapeStyle(Color.secondary))
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.35), radius: active ? 3 : 1.5)
    }

    /// The app's own icon, large, with its share of the screen under it -
    /// always shown, so the number and the picture never disagree.
    private var mainPane: some View {
        pane(fill: Color(nsColor: .controlBackgroundColor)) {
            VStack(spacing: 4) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                }
                Text(appName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(Int((layout.clampedMainFraction * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    /// The Zoom tile dark like a video tile, the chat light like a chat
    /// window: told apart by what they look like, not by a colour code.
    private func sideColumn(height: CGFloat) -> some View {
        VStack(spacing: spacing) {
            if layout.sideShowsZoomTile {
                pane(fill: Color.black.opacity(0.78)) {
                    VStack(spacing: 2) {
                        Image(systemName: "video.fill").font(.title3)
                        Text(draggingSlot ? "\(Int((layout.effectiveZoomSlotRatio * 100).rounded()))%" : "Zoom")
                            .font(.caption.weight(.medium).monospacedDigit())
                    }
                    .foregroundStyle(.white.opacity(0.85))
                }
                .frame(height: layout.sideShowsChat
                       ? (height - spacing) * layout.effectiveZoomSlotRatio
                       : nil)
            }
            if layout.sideShowsChat {
                pane(fill: Color(nsColor: .controlBackgroundColor)) {
                    VStack(spacing: 2) {
                        Image(systemName: "bubble.left.and.bubble.right.fill").font(.title3)
                        Text("Chat").font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            if !layout.sideShowsZoomTile && !layout.sideShowsChat {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .overlay(Text("Free").font(.caption).foregroundStyle(.secondary))
            }
        }
    }

    private func pane<Content: View>(fill: Color, @ViewBuilder content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1))
            .overlay(content())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
