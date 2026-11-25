//
//  LayoutSettingsTab.swift
//  Greenroom
//
//  Settings -> Layout: a layout creator. Named templates built from placed
//  pieces (Meeting, Chat, apps) on a picture of your display; one of them, or
//  None, is what a class start uses. Phase A of
//  .context/layout-creator-plan.md: templates are saved and edited here, and
//  the old runtime still places windows from the old settings until phase B.
//
//  `LayoutPageContent` takes plain bindings, not the coordinator, so the same
//  view can be rendered off screen with sample values to check it by eye
//  (.context/lr/go.sh). `LayoutSettingsTab` is the thin layer that feeds it
//  from the coordinator.
//
import SwiftUI

// MARK: - The tab

struct LayoutSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var apps: [AppInfo] = []
    @State private var displays: [DisplayInfo] = DisplayResolver.connectedDisplays()
    @State private var hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission

    /// "Mirror my camera", one setting for every layout (the camera look).
    @AppStorage(PresenceFeed.mirrorKey) private var mirror = true

    // AXIsProcessTrusted() has no change notification, so poll it while
    // the tab is visible - the warning disappears on its own once the user
    // flips the switch in System Settings.
    private let permissionTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    /// The one presence placement, shared with the floating bubble and Home.
    private var cameraModel: LayoutCameraModel {
        let layout = coordinator.stageLayout
        return LayoutCameraModel(box: layout.presenceBox, shape: layout.cameraShape,
                                 cameraOff: !Visibility.cameraOnMyScreen(state: coordinator.savedCameraState).isOn,
                                 // The one rule decides who sees the camera (R6.1), under this layout's own share.
                                 everyoneSees: Visibility.cameraEveryoneSees(state: coordinator.savedCameraState, target: shownTarget).isOn,
                                 onStep: { coordinator.previewPlacementStep($0) },
                                 onCommit: { coordinator.commitPreviewPlacement($0, source: .settingsLayouts) },
                                 state: coordinator.savedCameraState,
                                 setState: { coordinator.setSavedCameraState($0) },
                                 look: CameraLookModel(
                                     background: $coordinator.cameraBackground,
                                     backgroundImage: $coordinator.cameraBackgroundImage,
                                     removal: $coordinator.backgroundRemoval,
                                     mirror: $mirror,
                                     chooseImage: { coordinator.chooseCameraBackgroundImage() }),
                                 preview: CameraPreviewModel(feed: coordinator.shapePreview,
                                                             aspect: coordinator.shapePreviewAspect,
                                                             seesYou: coordinator.cameraSeesYou || !layout.cameraShape.usesChromaKey),
                                 previewRuns: { coordinator.setLayoutsCameraPreview($0) })
    }

    /// Running: the live target decides what the capture shows. Not running: the layout's own.
    private var shownTarget: Visibility.Target {
        Visibility.Target(coordinator.layoutChoiceLocked
                          ? coordinator.shareTarget
                          : (coordinator.layoutLibrary.active?.share ?? coordinator.shareTarget))
    }

    var body: some View {
        LayoutPageContent(
            library: $coordinator.layoutLibrary,
            browserRestoresTabs: $coordinator.browserRestoresTabs,
            browserSearchSuggestions: $coordinator.browserSearchSuggestions,
            apps: apps,
            displays: displays,
            mainSize: DisplayResolver.mainDisplayScreen()?.visibleFrame.size ?? CGSize(width: 1440, height: 875),
            secondSize: { LayoutScreenPreview.secondScreen(uuid: $0)?.visibleFrame.size },
            // Browsers are driven through the Chromium AppleScript dictionary
            // (per-app Automation permission, prompted on first use) - only
            // non-browser apps need the system-wide Accessibility grant to be
            // moved.
            canMoveApps: hasAccessibilityPermission,
            openAccessibilitySettings: {
                AppWindowManager.promptForAccessibilityPermission()
                AppWindowManager.openAccessibilitySettings()
            },
            showOnScreen: { template, look in
                LayoutScreenPreview.show(LayoutScreenPreview.items(for: template, camera: cameraModel, look: look))
            },
            liveLayoutID: coordinator.liveSessionLayoutID,
            applyNow: { coordinator.applyLayoutNow($0) },
            camera: cameraModel,
            share: shownTarget,
            fallbackShare: coordinator.shareTarget,
            selectCamera: $coordinator.layoutsCameraRequested)
        .onAppear {
            apps = AppCatalog.installedAndRunning()
            displays = DisplayResolver.connectedDisplays()
            hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission
            LayoutIcons.reset()
        }
        .onReceive(permissionTick) { _ in
            hasAccessibilityPermission = AppWindowManager.hasAccessibilityPermission
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayResolver.connectedDisplays()
        }
    }
}

// MARK: - Icons

/// App icons and "is it installed", looked up once per app: the page redraws
/// all the time while a piece is dragged and NSWorkspace is not free.
enum LayoutIcons {
    private static var icons: [String: NSImage] = [:]
    private static var installed: [String: Bool] = [:]

    static func reset() { icons = [:]; installed = [:] }

    static func isInstalled(_ bundleID: String) -> Bool {
        if AppCatalog.isBuiltInBrowser(bundleID) { return true }
        if let known = installed[bundleID] { return known }
        let found = AppCatalog.appURL(forBundleID: bundleID) != nil
        installed[bundleID] = found
        return found
    }

    static func icon(_ bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard isInstalled(bundleID), let icon = AppCatalog.icon(forBundleID: bundleID) else { return nil }
        icons[bundleID] = icon
        return icon
    }

    /// NSWorkspace icons come at 32pt+; menu rows want 16.
    static func menuIcon(_ bundleID: String) -> NSImage? {
        guard let icon = icon(bundleID), let copy = icon.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

// MARK: - The page

private enum LayoutFocus: Hashable {
    case name, website
}

struct LayoutPageContent: View {
    @Binding var library: LayoutLibrary
    @Binding var browserRestoresTabs: Bool
    @Binding var browserSearchSuggestions: Bool
    let apps: [AppInfo]
    let displays: [DisplayInfo]
    /// Usable area (NSScreen.visibleFrame) of the main display, in points.
    let mainSize: CGSize
    /// The second display's usable area for a saved UUID ("" = automatic), nil
    /// when none is connected.
    let secondSize: (String) -> CGSize?
    /// Greenroom's own meeting window rather than Zoom's.
    /// Accessibility is granted: non-browser apps can be moved.
    let canMoveApps: Bool
    let openAccessibilitySettings: () -> Void
    let showOnScreen: (LayoutTemplate, (LayoutPiece) -> LayoutPieceLook) -> Void
    /// The layout the class in progress is running; nil when there is no arranged
    /// class. An edit to that layout applies by itself; picking another card does
    /// not, so the editor offers "Apply now" for it.
    var liveLayoutID: UUID?
    var applyNow: (UUID) -> Void = { _ in }
    /// The camera overlay, drawn on the shared display's canvas. Nil: none.
    var camera: LayoutCameraModel?
    /// What is shared right now: the badges and Preview: Everyone read it.
    var share: Visibility.Target = .wholeScreen
    /// The global share target, shown for a layout that has saved none.
    var fallbackShare = ShareTarget()
    /// Where the editor opens, for the off-screen render (.context/lr). Nil in the app.
    var opensOn: (selection: UUID?, slot: LayoutSlot)?
    /// Draws the Add panel in place under the row, for the off-screen render.
    var previewsAddPanel = false
    /// A deep link asked for the camera piece with its look open (Settings sets it, this clears it).
    var selectCamera: Binding<Bool> = .constant(false)
    /// The camera look group starts open, for the off-screen render.
    var opensLookGroup = false
    @State private var lookOpen = false
    /// The "Everyone sees this" pop-out is open.
    @State private var shareOpen = false

    @State private var selection: UUID?
    /// The width the canvases may use (R29), read from the page.
    @State private var panelWidth: CGFloat = 0
    /// Preview: My screen (false, the default) or Everyone. View state only.
    @State private var previewEveryone = false
    @State private var activeSlot: LayoutSlot = .main
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var deleteCandidate: UUID?
    @State private var restoreCandidate: UUID?
    @State private var confirmReset = false
    /// "Remove second display" on a second display that has pieces asks first (R30.2).
    @State private var confirmRemoveSecond = false
    /// The canvas whose + panel is open.
    @State private var addPanelSlot: LayoutSlot?
    // Dragging a piece between the two displays' canvases.
    @State private var canvasFrames: [LayoutSlot: CGRect] = [:]
    @State private var incoming: (slot: LayoutSlot, preview: LayoutCrossPreview)?
    @State private var refusal: (slot: LayoutSlot, text: String)?
    @State private var refusalTask: Task<Void, Never>?
    @State private var focusRequest: LayoutFocusRequest?
    @FocusState private var focus: LayoutFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The Settings window's undo stack: Cmd-Z, Shift-Cmd-Z and the Edit menu.
    @Environment(\.undoManager) private var undoManager
    @State private var recorder: LayoutEditRecorder?

    // MARK: Body

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    cardStrip
                    // With a layout open, its description is the inspector's empty
                    // state; the caption here is only for None.
                    if LayoutEditorRules.captionUnderCards(hasActiveLayout: library.active != nil) {
                        Text(caption)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                HStack {
                    Text("At start")
                    Spacer()
                    Button("Reset to defaults\u{2026}") { confirmReset = true }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Removes your layouts and brings back the built-in ones.")
                }
            }

            // With None chosen the caption above already says it all: no second
            // set of starter buttons, no second Reset, no tall empty panel.
            if let template = library.active {
                Section {
                    editor(template)
                        .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Nothing focused when the tab opens: macOS Tab cycles text fields, and
        // a field that claims focus on open cannot be escaped.
        .defaultFocus($focus, nil)
        .onExitCommand { focus = nil }
        .onAppear {
            let binding = $library
            recorder = LayoutEditRecorder(library: library, read: { binding.wrappedValue },
                                          write: { binding.wrappedValue = $0 },
                                          nameOf: { look($0).name })
            recorder?.didRestore = { reconcileEditor() }
            focus = nil
            if let o = opensOn { selection = o.selection; activeSlot = o.slot }
            lookOpen = opensLookGroup
            openCameraIfRequested()
            syncCameraPreview()
        }
        .onChange(of: selection) { _, _ in syncCameraPreview() }
        .onChange(of: previewEveryone) { _, _ in syncCameraPreview() }
        .onChange(of: selectCamera.wrappedValue) { _, _ in openCameraIfRequested() }
        .onChange(of: library.activeID) { _, _ in resetEditorState() }
        .onChange(of: library) { _, new in
            recorder?.undoManager = undoManager
            recorder?.observe(new)
        }
        .onDisappear {
            recorder?.forget()
            syncCameraPreview(shown: false)
        }
        .confirmationDialog("Delete \u{201C}\(deleteCandidateName)\u{201D}?",
                            isPresented: Binding(get: { deleteCandidate != nil },
                                                 set: { if !$0 { deleteCandidate = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = deleteCandidate { withAnimation(anim) { library.delete(id) } }
                deleteCandidate = nil
            }
        } message: {
            Text("This layout is removed. The windows it describes are not touched.")
        }
        .confirmationDialog("Remove the second display?",
                            isPresented: $confirmRemoveSecond, titleVisibility: .visible) {
            Button(LayoutEditorRules.removeSecondTitle, role: .destructive) { removeSecondDisplay() }
        } message: {
            Text("Its pieces are removed from this layout. Undo brings them back.")
        }
        .confirmationDialog("Restore \u{201C}\(restoreCandidateName)\u{201D} to the original?",
                            isPresented: Binding(get: { restoreCandidate != nil },
                                                 set: { if !$0 { restoreCandidate = nil } }),
                            titleVisibility: .visible) {
            Button("Restore original", role: .destructive) {
                if let id = restoreCandidate {
                    withAnimation(anim) {
                        if library.restoreOriginal(id) { selection = nil; renamingID = nil }
                    }
                }
                restoreCandidate = nil
            }
        } message: {
            Text("Your changes to this layout are undone. Your other layouts are not touched.")
        }
        .alert("Reset layouts to the defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { withAnimation(anim) { library.resetToDefaults(); resetEditorState() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(resetMessage)
        }
    }

    /// What a reset costs, in the person's terms.
    private var resetMessage: String {
        let n = library.userLayoutCount
        let lost = n == 0
            ? "Your edits to the built-in layouts are undone."
            : "This removes your \(n == 1 ? "1 layout" : "\(n) layouts") and brings back the built-in ones."
        return lost + " The layout used at Start goes back to Leave my windows alone."
    }

    private var anim: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }

    private var deleteCandidateName: String {
        deleteCandidate.flatMap { library.template(id: $0)?.name } ?? ""
    }

    private var restoreCandidateName: String {
        restoreCandidate.flatMap { LayoutLibrary.shipped(library.template(id: $0)?.starter)?.name } ?? ""
    }

    private func resetEditorState() {
        selection = nil
        activeSlot = .main
        renamingID = nil
    }

    // MARK: Card strip

    private var thumbHeight: CGFloat { layoutThumbHeight(for: mainSize) }

    private var cardStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(library.templates) { template in
                    LayoutCard(title: template.name, selected: library.activeID == template.id,
                               isRenaming: renamingID == template.id, draft: $renameDraft,
                               select: { choose(template.id) },
                               beginRename: { beginRename(template) },
                               commitRename: { commitRename() },
                               cancelRename: { renamingID = nil }) {
                        if template.movesWindows {
                            LayoutThumbnail(pieces: template.oneDisplay, aspect: layoutCardWidth / thumbHeight, look: look)
                        } else {
                            LayoutNoneThumbnail(height: thumbHeight)
                        }
                    }
                    .contextMenu {
                        Button("Rename") { beginRename(template) }
                        Button("Duplicate") { duplicate(template.id) }
                        if library.canRestore(template.id) {
                            Button("Restore original\u{2026}") { restoreCandidate = template.id }
                        }
                        if library.canDelete(template.id) {
                            Divider()
                            Button("Delete\u{2026}", role: .destructive) { deleteCandidate = template.id }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                LayoutCard(title: "New layout", selected: false, isRenaming: false, draft: .constant(""),
                           select: addLayout, beginRename: nil, commitRename: {}, cancelRename: {}) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: thumbHeight)
                }
                .help("Start a new, empty layout.")
                .contextMenu {
                    Button("Reset to defaults\u{2026}") { confirmReset = true }
                }
            }
            .padding(3)
        }
        .scrollClipDisabled()
    }

    private func choose(_ id: UUID?) {
        guard id != library.activeID else { return }
        withAnimation(anim) {
            library.select(id)
            resetEditorState()
        }
    }

    private func beginRename(_ template: LayoutTemplate) {
        renameDraft = template.name
        renamingID = template.id
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        renamingID = nil
        library.rename(id, to: renameDraft)
    }

    private func duplicate(_ id: UUID) {
        withAnimation(anim) {
            if let copy = library.duplicate(id) { library.select(copy) }
            resetEditorState()
        }
    }

    private func addLayout() {
        withAnimation(anim) {
            let id = library.addBlank()
            library.select(id)
            resetEditorState()
        }
    }

    // MARK: Caption

    /// What picking this card does, in a sentence.
    private var caption: String {
        guard let template = library.active else {
            return "Greenroom starts the meeting and leaves your windows where they are."
        }
        // A built-in as shipped says what it is in its own one line (R12.1).
        if template.isAsShipped, let line = LayoutLibrary.description(forStarter: template.starter ?? "") { return line }
        // One display uses the main arrangement alone, so the sentence is about that one (ADR 0002).
        let pieces = template.oneDisplay
        var opens: [String] = []
        for piece in template.oneDisplay {
            if let app = piece.kind.app, app.opensAtStart { opens.append(look(piece).name) }
        }
        let places = [
            pieces.contains { $0.kind.isMeeting } ? meetingWord : nil,
            pieces.contains { $0.kind.isChat } ? "chat" : nil,
        ].compactMap { $0 } + (MeetingViewPieces.enabled ? pieces.compactMap { $0.kind.view?.title.lowercased() } : [])
        var sentence: String
        switch (opens.isEmpty, places.isEmpty) {
        case (true, true):
            return "This layout is empty, so nothing moves yet. Add pieces below."
        case (false, true):
            sentence = "Greenroom opens \(list(opens))."
        case (true, false):
            sentence = "Greenroom places the \(list(places))."
        case (false, false):
            sentence = "Greenroom opens \(list(opens)) and places the \(list(places))."
        }
        if let second = template.twoDisplays?.second, !second.isEmpty {
            sentence += " With a second display connected it also arranges that one."
        }
        return sentence
    }


    private var meetingWord: String { "meeting window" }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    // MARK: Editor

    private func editor(_ template: LayoutTemplate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow(template)
            canvases(template)
            noticeRow(template)
            inspector(template)
        }
    }

    /// Which picture the canvas draws: what you see, or what the meeting sees.
    /// Beside it, Show on screen (no shortcut).
    private func previewControls(_ template: LayoutTemplate) -> AnyView {
        AnyView(HStack(spacing: 6) {
            GreenroomSegmented("Preview", selection: $previewEveryone, options: [false, true]) { everyone in
                Text(everyone ? "Everyone" : "My screen")
            }
            .help("Preview. My screen shows what you see. Everyone shows the meeting\u{2019}s picture: only what everyone sees.")
            Button {
                showOnScreen(template, look)
                if template.twoDisplays != nil, secondSize(template.twoDisplays?.secondUUID ?? "") == nil {
                    say("No second display is connected, so this shows the main display only.")
                }
            } label: {
                Image(systemName: VisibilitySymbol.showOnScreen.name)
            }
            .controlSize(.small)
            .disabled(!LayoutEditorRules.canShowOnScreen(pieceCount: template.pieceCount))
            .help("Show on screen: outlines where each piece would go, on your real displays, for a moment.")
            .accessibilityLabel("Show on screen")
        })
    }

    private var activeIndex: Int? {
        library.activeID.flatMap { id in library.templates.firstIndex { $0.id == id } }
    }

    private func binding(for slot: LayoutSlot) -> Binding<[LayoutPiece]> {
        Binding(get: { library.active?.pieces(for: slot) ?? [] },
                set: { new in
                    if let i = activeIndex { library.templates[i].setPieces(new, for: slot) }
                })
    }

    private func titleRow(_ template: LayoutTemplate) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                // The hidden Text sizes the field to its name, so the pencil sits
                // right after the last letter instead of at the field's far end.
                Text(nameBinding.wrappedValue.isEmpty ? "Layout name" : nameBinding.wrappedValue)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .padding(.trailing, 6)
                    .fixedSize()
                    .hidden()
                    .overlay {
                        TextField("Layout name", text: nameBinding)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                            .focused($focus, equals: .name)
                            .onSubmit { focus = nil }
                    }
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .help("Rename this layout")
            .onChange(of: focus) { old, new in
                // A layout with no name cannot be found again.
                if old == .name, new != .name, let i = activeIndex,
                   library.templates[i].name.trimmingCharacters(in: .whitespaces).isEmpty {
                    library.templates[i].name = "Untitled layout"
                }
            }
            layoutMenu(template)
            if LayoutEditorRules.offersApplyNow(liveLayoutID: liveLayoutID, templateID: template.id) {
                Button("Apply now") { applyNow(template.id) }
                    .controlSize(.small)
                    .help("A meeting is running another layout. This moves it to this one now; otherwise this layout starts with the next meeting.")
            }
            Spacer(minLength: 8)
            // Preview and Show on screen belong to the shared canvas; they sit here so every canvas
            // header stays one line.
            previewControls(template)
        }
    }

    /// Rename, Duplicate, Restore original (built-in layouts, when it can be done) and Delete.
    private func layoutMenu(_ template: LayoutTemplate) -> some View {
        Menu {
            ForEach(LayoutEditorRules.layoutMenu(isBuiltIn: template.starter != nil, canRestore: library.canRestore(template.id),
                                                 canDelete: library.canDelete(template.id)), id: \.self) { action in
                switch action {
                case .rename:
                    Button("Rename") { focus = .name }
                case .duplicate:
                    Button("Duplicate") { duplicate(template.id) }
                case .restoreOriginal:
                    Button("Restore original\u{2026}") { restoreCandidate = template.id }
                case .delete:
                    Divider()
                    Button("Delete\u{2026}", role: .destructive) { deleteCandidate = template.id }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rename, duplicate (\u{2318}D) or delete this layout")
        .accessibilityLabel("Layout actions")
        // A shortcut inside a Menu only fires while the menu is open; this one lives as long as
        // the Layouts tab is on screen.
        .background(Button("Duplicate layout") { duplicate(template.id) }
            .keyboardShortcut("d", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true))
    }

    private var nameBinding: Binding<String> {
        Binding(get: { library.active?.name ?? "" },
                set: { if let i = activeIndex { library.templates[i].name = $0 } })
    }

    // MARK: Canvases

    private var mainSpace: LayoutDisplaySpace {
        let screen = DisplayResolver.mainDisplayScreen()
        return LayoutDisplaySpace(name: "Main display", size: mainSize,
                                  cameraSpace: screen.map { LayoutCameraSpace(frame: $0.frame, visibleFrame: $0.visibleFrame) })
    }

    private func secondSpace(_ two: TwoDisplay) -> LayoutDisplaySpace {
        if let size = secondSize(two.secondUUID) {
            let screen = LayoutScreenPreview.secondScreen(uuid: two.secondUUID)
            return LayoutDisplaySpace(name: "Second display", size: size,
                                      cameraSpace: screen.map { LayoutCameraSpace(frame: $0.frame, visibleFrame: $0.visibleFrame) })
        }
        return LayoutDisplaySpace(name: "Second display", size: CGSize(width: 1440, height: 810), connected: false)
    }

    private func space(for slot: LayoutSlot, _ template: LayoutTemplate) -> LayoutDisplaySpace {
        slot == .second ? secondSpace(template.twoDisplays ?? TwoDisplay()) : mainSpace
    }

    /// The gap between the two canvases of a layout with a second display.
    private static let canvasGap: CGFloat = 12

    /// R29: the main canvas always shows and fills the panel (its width less the strip that adds a second
    /// display); with a second arrangement both sit side by side, sharing the width at one height, so
    /// neither is cut off.
    @ViewBuilder
    private func canvases(_ template: LayoutTemplate) -> some View {
        Group {
            if let two = template.twoDisplays {
                let secondSpace = secondSpace(two)
                let widths = LayoutEditorRules.canvasWidths(
                    panelWidth: panelWidth > 0 ? panelWidth : 640, gap: Self.canvasGap,
                    mainAspect: mainSpace.aspect, secondAspect: secondSpace.aspect, inset: LayoutCanvas.bezelInset)
                HStack(alignment: .top, spacing: Self.canvasGap) {
                    canvas(.main, space: mainSpace, template: template)
                        .frame(width: widths.main)
                    canvas(.second, space: secondSpace, template: template)
                        .frame(width: widths.second)
                }
                .coordinateSpace(name: LayoutCrossing.space)
                .onPreferenceChange(LayoutCanvasFrames.self) { canvasFrames = $0 }
            } else {
                canvas(.main, space: mainSpace, template: template)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear.preference(key: LayoutPanelWidth.self, value: geo.size.width)
        })
        .onPreferenceChange(LayoutPanelWidth.self) { panelWidth = $0 }
    }

    /// R29.3: the thin dashed strip at the main canvas's right edge that adds a second display.
    private func addSecondStrip(_ template: LayoutTemplate) -> AnyView? {
        guard LayoutEditorRules.showsAddSecondStrip(hasSecondDisplay: template.twoDisplays != nil) else { return nil }
        return AnyView(AddSecondStrip(width: LayoutEditorRules.stripWidth) {
            withAnimation(anim) {
                // Leave my windows alone cannot take pieces: like +, the strip makes "My layout" and adds there.
                let forked = !template.movesWindows
                if library.addSecondDisplayToActive() != nil {
                    if forked { resetEditorState(); say("Made a new layout") }
                    activeSlot = .main
                    selection = nil
                }
            }
        })
    }

    // MARK: Canvas header controls

    private func sharedSlotBinding() -> Binding<LayoutSlot> {
        Binding(get: { library.active?.effectiveSharedSlot ?? .main },
                set: { v in
                    guard let i = activeIndex else { return }
                    if v == .second, !library.templates[i].canShareSecondDisplay {
                        say("The Room screen is on the second display and would show itself. Remove it first.")
                        return
                    }
                    withAnimation(anim) { library.templates[i].twoDisplays?.sharedSlot = v }
                })
    }

    /// "Everyone sees this": opens the share pop-out Home uses (R32), for what is saved with the layout. A live
    /// change in Home or the bar changes only the running meeting.
    private func sharedTag(_ template: LayoutTemplate) -> AnyView {
        let current = SharePopoutRules.readBack(template.share ?? fallbackShare)
        let label = ShareHintRules.tileLabel(kind: current.kind, appName: current.appName)
        return AnyView(Button { shareOpen.toggle() } label: {
            HStack(spacing: 3) {
                Text("Everyone sees this").font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .greenroomPopover(isPresented: $shareOpen) {
            LayoutSharePopout(
                share: current, apps: apps, camera: camera,
                set: { new in if let i = activeIndex { library.templates[i].share = new } },
                sharedDisplay: template.twoDisplays != nil ? sharedSlotBinding() : nil)
        }
        .help("What everyone sees when you start this layout: \(label)"
              + (template.twoDisplays != nil ? ", from the display marked here. Recordings film it too." : ".")
              + " Changing it in Home or on the bar during a meeting does not change what is saved here.")
        .accessibilityLabel("Everyone sees this")
        .accessibilityValue(label))
    }

    /// "Second": the second display's picker and Remove second display.
    private func secondMenu(_ two: TwoDisplay) -> AnyView {
        let others = displays.filter { !$0.isMain }
        let items = LayoutEditorRules.secondMenu(connectedNonMainIDs: others.map(\.id), savedUUID: two.secondUUID)
        return AnyView(Menu {
            Picker("Second display", selection: Binding(
                get: { two.secondUUID },
                set: { v in if let i = activeIndex { library.templates[i].twoDisplays?.secondUUID = v } })) {
                ForEach(items, id: \.self) { item in
                    switch item {
                    case .automatic: Text("Automatic").tag("")
                    case let .display(id): Text(others.first { $0.id == id }?.name ?? id).tag(id)
                    case let .savedNotConnected(id): Text("Saved display (not connected)").tag(id)
                    }
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button(LayoutEditorRules.removeSecondTitle, role: .destructive) {
                if LayoutEditorRules.removeSecondNeedsConfirmation(secondPieceCount: two.second.count) {
                    confirmRemoveSecond = true
                } else {
                    removeSecondDisplay()
                }
            }
        } label: {
            Text("SECOND")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.8)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which display is the second one (Automatic is the first that is not your main one), or remove the second display."))
    }

    /// The + on one canvas: it adds to that canvas's display.
    private func addButton(slot: LayoutSlot, template: LayoutTemplate) -> AnyView {
        let target = slot   // each canvas's + adds to its own display
        return AnyView(Button {
            // Q22: Leave my windows alone stays clean. + copies it into "My layout" and adds there.
            if !template.movesWindows {
                withAnimation(anim) {
                    if library.forkLeaveAlone() != nil {
                        resetEditorState()
                        say("Made a new layout")
                        addPanelSlot = .main
                    }
                }
                return
            }
            addPanelSlot = addPanelSlot == target ? nil : target
        } label: {
            Image(systemName: "plus")
        }
        .controlSize(.small)
        .help(MeetingViewPieces.enabled ? "Add the meeting, a view of it, chat or an app to this display" : "Add the meeting, chat or an app to this display")
        .accessibilityLabel("Add to \(slot == .second ? "second display" : "this display")")
        .greenroomPopover(isPresented: Binding(get: { addPanelSlot == target },
                                               set: { if !$0 && addPanelSlot == target { addPanelSlot = nil } })) {
            addPanel(slot: target, template: template)
        })
    }

    private func canvas(_ slot: LayoutSlot, space: LayoutDisplaySpace, template: LayoutTemplate? = nil) -> some View {
        let two = template?.twoDisplays != nil
        let sharedSlot = template.map {
            LayoutSharedDisplay.cameraSlot(template: $0, secondConnected: secondSize($0.twoDisplays?.secondUUID ?? "") != nil)
        } ?? .main
        return LayoutCanvas(pieces: binding(for: slot), selection: $selection, display: space,
                     look: look,
                     accepts: { kind in
                        if case .view = kind, !MeetingViewPieces.enabled { return false }
                        return library.active?.canAdd(kind, to: slot) ?? false
                     },
                     onActivate: { activeSlot = slot; addPanelSlot = nil },
                     onNotice: { say($0) },
                     // The camera sits on the display everyone sees ("Everyone sees"); it is
                     // not a piece, so it never crosses displays by itself.
                     camera: slot == sharedSlot ? camera : nil,
                     slot: slot,
                     isShared: two && slot == (template?.effectiveSharedSlot ?? .main),
                     titleMenu: (two && slot == .second) ? template?.twoDisplays.map { secondMenu($0) } : nil,
                     sharedTag: template.flatMap { t in
                         LayoutEditorRules.carriesSharedControls(slot: slot, template: t) ? sharedTag(t) : nil },
                     headerAdd: template.map { addButton(slot: slot, template: $0) },
                     trailingStrip: slot == .main ? template.flatMap { addSecondStrip($0) } : nil,
                     crossing: two ? crossing(from: slot) : nil,
                     incoming: incoming?.slot == slot ? incoming?.preview : nil,
                     refusal: refusal?.slot == slot ? refusal?.text : nil,
                     focusRequest: focusRequest,
                     share: share,
                     previewEveryone: previewEveryone,
                     emptyText: template?.movesWindows == false ? "Your windows stay where they are" : "Drag a piece here, or use + above")
    }

    // MARK: Between the two displays

    /// R30: drops the second arrangement; one undo step ("Remove Second Display") puts it back.
    private func removeSecondDisplay() {
        withAnimation(anim) {
            if let i = activeIndex { library.templates[i].removeSecondDisplay() }
            activeSlot = .main
            selection = nil
        }
    }

    private func otherSlot(_ slot: LayoutSlot) -> LayoutSlot { slot == .main ? .second : .main }

    private func crossing(from slot: LayoutSlot) -> LayoutCrossing {
        let other = otherSlot(slot)
        return LayoutCrossing(
            ownFrame: canvasFrames[slot],
            hover: { id, point in
                guard let frame = canvasFrames[other], frame.contains(point) else {
                    if incoming != nil { incoming = nil }
                    return false
                }
                incoming = (other, preview(id, from: slot, to: other, pair: point))
                return true
            },
            drop: { id, point in
                incoming = nil
                guard canvasFrames[other]?.contains(point) == true else { return false }
                return moveAcross(id, from: slot, to: other, pointer: unitPointer(point, in: other))
            },
            send: { id in
                guard let piece = library.active?.pieces(for: slot).first(where: { $0.id == id }) else { return }
                moveAcross(id, from: slot, to: other, pointer: CGPoint(x: piece.rect.midX, y: piece.rect.midY))
            })
    }

    private func unitPointer(_ point: CGPoint, in slot: LayoutSlot) -> CGPoint {
        guard let f = canvasFrames[slot], f.width > 0, f.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: (point.x - f.minX) / f.width, y: (point.y - f.minY) / f.height)
    }

    private func preview(_ id: UUID, from: LayoutSlot, to: LayoutSlot, pair point: CGPoint) -> LayoutCrossPreview {
        guard let t = library.active else { return LayoutCrossPreview() }
        switch t.placementForMove(id, from: from, to: to, at: unitPointer(point, in: to),
                                  fromDisplay: space(for: from, t).size, toDisplay: space(for: to, t).size) {
        case let .success(rect): return LayoutCrossPreview(rect: rect)
        case let .failure(why): return LayoutCrossPreview(reason: why.message)
        }
    }

    /// Moves the piece to the other display, or says why not on that display's canvas.
    @discardableResult
    private func moveAcross(_ id: UUID, from: LayoutSlot, to: LayoutSlot, pointer: CGPoint) -> Bool {
        guard let i = activeIndex else { return false }
        let t = library.templates[i]
        switch t.movingPiece(id, from: from, to: to, at: pointer,
                             fromDisplay: space(for: from, t).size, toDisplay: space(for: to, t).size) {
        case let .success(moved):
            withAnimation(anim) {
                library.templates[i] = moved
                selection = id
                activeSlot = to
            }
            focusRequest = LayoutFocusRequest(slot: to, tick: (focusRequest?.tick ?? 0) + 1)
            return true
        case let .failure(why):
            refusalTask?.cancel()
            withAnimation(anim) { refusal = (to, why.message) }
            refusalTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }
                withAnimation(anim) { refusal = nil }
            }
            return false
        }
    }

    // MARK: Palette

    /// Notices from the canvases, and (off-screen render only) the Add panel drawn in place.
    @ViewBuilder
    private func noticeRow(_ template: LayoutTemplate) -> some View {
        let slot = activeSlot
        if previewsAddPanel {
            // The off-screen render cannot show a popover window, so it draws
            // the same panel in place.
            HStack {
                addPanel(slot: slot, template: template, note: "meeting")
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.3)))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                Spacer()
            }
            .padding(.bottom, 6)
        }
        if let notice {
            StatusBadge(text: notice, tone: .waiting)
                .transition(.opacity)
        }
    }

    private func addPanel(slot: LayoutSlot, template: LayoutTemplate, note: String? = nil) -> LayoutAddPanel {
        let version = template.allPieces
        return LayoutAddPanel(
            apps: apps,
            reason: { blockReason($0, template: template, slot: slot) },
            isPlaced: { kind in version.contains { sameKind($0.kind, kind) } },
            add: { kind in
                addPanelSlot = nil
                add(kind, slot: slot, template: template)
            },
            close: { addPanelSlot = nil },
            initialNote: note)
    }

    /// Why a piece cannot be added right now, or nil when it can. Spoken in the
    /// Add panel's tooltips and caption, and the notice a click would give.
    private func blockReason(_ kind: LayoutPiece.Kind, template: LayoutTemplate, slot: LayoutSlot) -> String? {
        let version = template.allPieces
        if case .view = kind, !MeetingViewPieces.enabled { return "Views are turned off on this Mac" }
        if template.canAdd(kind, to: slot) { return nil }
        let views = Set(version.compactMap { $0.kind.view })
        switch kind {
        case .meeting:
            if version.contains(where: { $0.kind.isMeeting }) { return "Already in this layout" }
            if !MeetingViewPieces.enabled { return "This layout already shows the meeting another way. Remove that first." }
            return "The Meeting window already has a gallery and a speaker with strip. Remove the \(views.contains(.gallery) ? "Gallery" : "Speaker + strip") view first."
        case let .view(view, _):
            if views.contains(view) { return "Already in this layout" }
            let hasMeeting = version.contains { $0.kind.isMeeting }
            if hasMeeting, view == .gallery || view == .speakerStrip { return "The Meeting window already has a \(view == .gallery ? "gallery" : "speaker with strip"). Remove it first." }
            if view == .speakerStrip { return "Speaker + strip already shows the active speaker. Remove the Active speaker view first." }
            return "Speaker + strip already shows the active speaker. Remove it first."
        case .chat: return "Already in this layout"
        case .roomScreen:
            if slot == .second, let why = template.roomScreenBlockReason { return why }
            return RoomScreenRules.blockReason(slot: slot, existing: version.map(\.kind), hasSecondDisplay: template.twoDisplays != nil)
        case let .app(app):
            if version.contains(where: { $0.kind.app?.bundleID == app.bundleID }) { return "Already in this layout" }
            return "A layout holds at most \(LayoutTemplate.maxApps) apps."
        }
    }

    /// Click-to-add: into the largest free rectangle. A piece already in the
    /// layout is selected instead of added twice.
    private func add(_ kind: LayoutPiece.Kind, slot: LayoutSlot, template: LayoutTemplate) {
        guard template.canAdd(kind, to: slot), blockReason(kind, template: template, slot: slot) == nil else {
            if let existing = template.allPieces.first(where: { sameKind($0.kind, kind) }) {
                withAnimation(anim) { selection = existing.id }
            } else {
                say(blockReason(kind, template: template, slot: slot) ?? "That cannot be added here.")
            }
            return
        }
        let target = slot
        let others = template.pieces(for: target).map(\.rect)
        guard let rect = LayoutGeometry.placeNew(kind, avoiding: others, display: space(for: target, template).size) else {
            say("There is no room for that. Make some space first.")
            return
        }
        let piece = LayoutPiece(kind: kind, rect: rect)
        withAnimation(anim) {
            if let i = activeIndex { library.templates[i].setPieces(template.pieces(for: target) + [piece], for: target) }
            selection = piece.id
        }
    }

    private func sameKind(_ a: LayoutPiece.Kind, _ b: LayoutPiece.Kind) -> Bool {
        switch (a, b) {
        case (.meeting, .meeting), (.chat, .chat), (.roomScreen, .roomScreen): return true
        case let (.app(x), .app(y)): return x.bundleID == y.bundleID
        case let (.view(x, _), .view(y, _)): return x == y
        default: return false
        }
    }

    private func say(_ message: String) {
        noticeTask?.cancel()
        withAnimation(anim) { notice = message }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            withAnimation(anim) { notice = nil }
        }
    }

    // MARK: Looks

    /// Greenroom Browser, Safari and so on as the canvas should draw them.
    func look(_ piece: LayoutPiece) -> LayoutPieceLook {
        Self.look(piece, canMoveApps: canMoveApps)
    }

    /// "Show on screen": outlines where each piece of `template` would go, on the
    /// real displays, for a moment. The one action behind the Layout page's
    /// button and Home's Layout tile.
    @MainActor
    static func showOnScreen(_ template: LayoutTemplate, canMoveApps: Bool,
                             camera: LayoutCameraModel? = nil) {
        LayoutScreenPreview.show(LayoutScreenPreview.items(for: template, camera: camera) {
            look($0, canMoveApps: canMoveApps)
        })
    }

    static func look(_ piece: LayoutPiece, canMoveApps: Bool) -> LayoutPieceLook {
        switch piece.kind {
        case .meeting:
            return LayoutPieceLook(name: "Meeting window", icon: nil, symbol: "person.2.fill")
        case let .view(view, _):
            return LayoutPieceLook(name: view.title, icon: nil, symbol: view.symbol,
                                   meetingView: view,
                                   comingLater: !MeetingViewPieces.enabled)
        case .chat:
            return LayoutPieceLook(name: "Chat", icon: nil, symbol: "bubble.left.and.bubble.right.fill")
        case .roomScreen:
            return LayoutPieceLook(name: RoomScreenRules.title, icon: nil, symbol: RoomScreenRules.symbol)
        case let .app(app):
            let installed = LayoutIcons.isInstalled(app.bundleID)
            let name = AppCatalog.displayName(forBundleID: app.bundleID)
                ?? app.bundleID.split(separator: ".").last.map(String.init) ?? "App"
            var warning: String?
            if installed, !AppCatalog.isBrowser(app.bundleID), !canMoveApps {
                warning = "Can\u{2019}t move \(name) yet. Allow Greenroom under System Settings \u{2192} Privacy & Security \u{2192} Accessibility."
            }
            return LayoutPieceLook(name: name, icon: LayoutIcons.icon(app.bundleID), symbol: "questionmark.app.dashed",
                                   missing: !installed, warning: warning)
        }
    }

    // MARK: Inspector

    private func selected(in template: LayoutTemplate) -> (slot: LayoutSlot, piece: LayoutPiece)? {
        guard let id = selection else { return nil }
        return template.placedPieces.first { $0.piece.id == id }
    }

    /// Home's Look / Share "More...", "Adjust webcam..." and the old Webcam deep links: the camera
    /// piece selected, its look open.
    private func openCameraIfRequested() {
        guard selectCamera.wrappedValue, camera != nil else { return }
        withAnimation(anim) { selection = LayoutCameraModel.selectionID; lookOpen = true }
        selectCamera.wrappedValue = false
    }

    private func update(_ id: UUID, _ change: (inout LayoutPiece) -> Void) {
        guard let i = activeIndex else { return }
        for slot in LayoutSlot.allCases {
            var pieces = library.templates[i].pieces(for: slot)
            if let j = pieces.firstIndex(where: { $0.id == id }) {
                change(&pieces[j])
                library.templates[i].setPieces(pieces, for: slot)
                return
            }
        }
    }

    private func remove(_ id: UUID) {
        guard let i = activeIndex else { return }
        withAnimation(anim) {
            for slot in LayoutSlot.allCases {
                var pieces = library.templates[i].pieces(for: slot)
                if pieces.contains(where: { $0.id == id }) {
                    pieces.removeAll { $0.id == id }
                    library.templates[i].setPieces(pieces, for: slot)
                }
            }
            selection = nil
        }
    }

    private func inspector(_ template: LayoutTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if selection == LayoutCameraModel.selectionID, let camera {
                cameraInspector(camera)
            } else if let (slot, piece) = selected(in: template) {
                pieceHeader(piece, slot: slot, template: template)
                switch piece.kind {
                case let .app(app): appControls(piece, app: app, slot: slot, template: template)
                case let .meeting(fills, hidden): meetingControls(piece, fills: fills, hidden: hidden, slot: slot, template: template)
                case let .view(_, hidden): viewControls(piece, view: piece.kind.view ?? .gallery, hidden: hidden)
                case .roomScreen, .chat:
                    // Nothing at rest (R35.2): the header, and the tooltip says what it is.
                    EmptyView()
                }
            } else {
                // Nothing selected: what this layout does, in a sentence. The key
                // hints are the canvas's tooltip.
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(LayoutEditorRules.keyboardHelp(twoDisplays: template.twoDisplays != nil))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
    }

    /// The camera overlay's card: the live picture, shape, size, who sees it, then its look.
    private func cameraInspector(_ camera: LayoutCameraModel) -> some View {
        let piece: Binding<LayoutCamera>? = activeIndex.map { i in
            Binding<LayoutCamera>(
                get: { library.templates[i].camera ?? LayoutCamera(shape: camera.shape, box: camera.box) },
                set: { library.templates[i].camera = $0 })
        }
        return CameraInspector(camera: undoable(camera), piece: piece, canvasAspect: cameraCanvasAspect,
                               readout: cameraReadout(camera), lookOpen: $lookOpen)
    }

    /// The display the camera is placed on, as width over height (the whole display, not the usable area).
    private var cameraCanvasAspect: Double {
        guard let template = library.active else { return 16.0 / 9.0 }
        let slot = LayoutSharedDisplay.cameraSlot(
            template: template, secondConnected: secondSize(template.twoDisplays?.secondUUID ?? "") != nil)
        let space = space(for: slot, template)
        let size = space.cameraSpace?.full ?? space.size
        return Double(size.width / max(size.height, 1))
    }

    // MARK: Undo for the settings that live outside the library

    /// A setting's write, as one undoable step (the camera state and the camera look, R9.1).
    private func undoable<T: Equatable>(_ edit: LayoutEditHistory.SettingEdit, current: T,
                                        set: @escaping (T) -> Void) -> (T) -> Void {
        { new in
            guard new != current else { return }
            set(new)
            recorder?.undoManager = undoManager
            recorder?.record(edit, undo: { set(current) }, redo: { set(new) })
        }
    }

    private func undoable(_ camera: LayoutCameraModel) -> LayoutCameraModel {
        var c = camera
        c.setState = undoable(.cameraState, current: camera.state, set: camera.setState)
        c.look = camera.look.map { look in
            CameraLookModel(
                background: Binding(get: { look.background.wrappedValue },
                                    set: undoable(.background, current: look.background.wrappedValue) { look.background.wrappedValue = $0 }),
                backgroundImage: Binding(get: { look.backgroundImage.wrappedValue },
                                         set: undoable(.backgroundPicture, current: look.backgroundImage.wrappedValue) { look.backgroundImage.wrappedValue = $0 }),
                removal: Binding(get: { look.removal.wrappedValue },
                                 set: undoable(.removal, current: look.removal.wrappedValue) { look.removal.wrappedValue = $0 }),
                mirror: Binding(get: { look.mirror.wrappedValue },
                                set: undoable(.mirror, current: look.mirror.wrappedValue) { look.mirror.wrappedValue = $0 }),
                chooseImage: look.chooseImage)
        }
        return c
    }

    /// An undo or redo wrote the library: the editor's own state follows it.
    private func reconcileEditor() {
        let next = LayoutEditorRules.reconciled(
            .init(activeSlot: activeSlot, selection: selection),
            in: library.active, cameraID: LayoutCameraModel.selectionID)
        activeSlot = next.activeSlot
        selection = next.selection
    }

    /// R11.3: the camera preview runs only while the camera piece is selected or in Preview: Everyone.
    private func syncCameraPreview(shown: Bool = true) {
        camera?.previewRuns(LayoutEditorRules.runsCameraPreview(
            cameraSelected: selection == LayoutCameraModel.selectionID, previewEveryone: previewEveryone, tabShown: shown))
    }

    private func cameraReadout(_ camera: LayoutCameraModel) -> String {
        // The saved piece, like the tiles; the live camera is only the fallback with no active layout.
        let saved = activeIndex.flatMap { library.templates[$0].camera }
        return PieceInspectorRules.cameraReadout(
            shape: saved?.shape ?? camera.shape, widthFraction: saved?.widthFraction ?? camera.box.widthFraction,
            displayWidth: DisplayResolver.mainDisplayScreen().map { Double($0.frame.size.width) })
    }

    /// R35: the same header for every kind: icon, name, one quiet readout, and a menu for what is secondary.
    private func pieceHeader(_ piece: LayoutPiece, slot: LayoutSlot, template: LayoutTemplate) -> some View {
        let l = look(piece)
        let size = space(for: slot, template).size
        let span = LayoutGeometry.cellSpan(of: piece.rect)
        let points = LayoutGeometry.pointSize(of: piece.rect, display: size)
        var tip = PieceInspectorRules.tooltip(for: piece.kind)
        if case .meeting = piece.kind, !customUIMode {
            tip = "Zoom\u{2019}s own meeting window is on (experimental), so this is Zoom\u{2019}s window, moved into this space."
        }
        return PieceInspectorHeader(
            name: l.name, readout: PieceInspectorRules.readout(points: points),
            readoutHelp: PieceInspectorRules.readoutHelp(columns: span.cols, rows: span.rows, points: points),
            tooltip: tip,
            leading: {
                Group {
                    if let icon = l.icon, !l.missing {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: l.symbol).resizable().scaledToFit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)
            },
            menu: { pieceMenu(piece) })
    }

    /// R35.6: these two belong to the Greenroom Browser everywhere, not to this layout, so they are not part of
    /// the layout's undo; flipping the switch back is the undo.
    private static let browserSettingHelp = "Applies to the Greenroom Browser in every layout. Not part of Undo."

    /// The \u{22EF} menu: what is secondary (R35.3). Remove is last.
    @ViewBuilder
    private func pieceMenu(_ piece: LayoutPiece) -> some View {
        let items = PieceInspectorRules.menu(for: piece.kind)
        ForEach(items, id: \.self) { item in
            switch item {
            case .closesOnStop:
                Toggle(AppCatalog.isBrowser(piece.kind.app?.bundleID ?? "")
                       ? "Close the window Start opened" : "Close when the meeting ends",
                       isOn: appFlag(piece, \.closesOnStop))
            case .opensMinimised:
                Toggle("Opens minimised", isOn: appFlag(piece, \.opensMinimised))
            case .reopenLastTabs:
                Toggle("Reopen last tabs", isOn: $browserRestoresTabs)
                    .help(Self.browserSettingHelp)
            case .searchSuggestions:
                Toggle("Search suggestions", isOn: $browserSearchSuggestions)
                    .help(Self.browserSettingHelp)
            case .remove:
                if items.count > 1 { Divider() }
                Button(role: .destructive) { remove(piece.id) } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }

    private func appFlag(_ piece: LayoutPiece, _ key: WritableKeyPath<AppPiece, Bool>) -> Binding<Bool> {
        Binding(get: { piece.kind.app?[keyPath: key] ?? false },
                set: { v in update(piece.id) { p in if var a = p.kind.app { a[keyPath: key] = v; p.kind = .app(a) } } })
    }

    @ViewBuilder
    private func appControls(_ piece: LayoutPiece, app: AppPiece, slot: LayoutSlot, template: LayoutTemplate) -> some View {
        let isBrowser = AppCatalog.isBrowser(app.bundleID)
        let installed = LayoutIcons.isInstalled(app.bundleID)
        let name = look(piece).name
        let taken = Set(template.allPieces.compactMap { $0.kind.app?.bundleID }).subtracting([app.bundleID])
        // Row 1: which app, and for a browser its website.
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Picker("App", selection: Binding(
                get: { app.bundleID },
                set: { new in update(piece.id) { $0.kind = .app(AppPiece(bundleID: new, url: app.url,
                                                                        opensAtStart: app.opensAtStart,
                                                                        closesOnStop: app.closesOnStop)) } })) {
                if !apps.contains(where: { $0.bundleID == app.bundleID }) {
                    Text("\(name) (not on this Mac)").tag(app.bundleID)
                }
                ForEach(apps.filter { !taken.contains($0.bundleID) }) { info in
                    Label { Text(info.name) } icon: {
                        if let icon = LayoutIcons.menuIcon(info.bundleID) { Image(nsImage: icon) }
                    }
                    .tag(info.bundleID)
                }
            }
            .frame(maxWidth: 280)
            .help(PieceInspectorRules.tooltip(for: piece.kind))
            if isBrowser {
                // .roundedBorder: the borderless field read as an apparently
                // dead empty row, with nothing saying "type a URL here".
                TextField("Website", text: Binding(
                    get: { app.url },
                    set: { new in update(piece.id) { p in
                        if var a = p.kind.app { a.url = AppCatalog.sanitizedURLText(new); p.kind = .app(a) }
                    } }), prompt: Text("e.g. docs.google.com"))
                    .textFieldStyle(.greenroom)
                    .focused($focus, equals: .website)
                    .help("Opens at Start")
            }
            Spacer(minLength: 0)
        }
        // Row 2: the one switch that matters. The rest is in the menu.
        HStack {
            Toggle("Open at Start", isOn: appFlag(piece, \.opensAtStart))
            Spacer()
        }
        // A notice, only while it is true: not at rest.
        if !installed {
            StatusBadge(text: "Not on this Mac", tone: .problem)
                .help("It is skipped at Start. Pick another app or remove it.")
        } else if !isBrowser, !canMoveApps {
            // Without this, an ungranted app opens at Start and then silently
            // stays wherever it is - say so up front, with a way to fix it.
            HStack {
                StatusBadge(text: "Can\u{2019}t move \(name) yet", tone: .problem)
                Spacer()
                Button("Open Settings\u{2026}", action: openAccessibilitySettings)
            }
            .help("Apps other than browsers are placed with the Accessibility API. Allow Greenroom under System Settings \u{2192} Privacy & Security \u{2192} Accessibility. Until then \(name) opens but stays wherever it is.")
        }
    }

    @ViewBuilder
    private func viewControls(_ piece: LayoutPiece, view: MeetingView, hidden: Bool) -> some View {
        HStack {
            Toggle(view == .selfView ? "Start with my Self view hidden" : "Starts hidden on my screen", isOn: Binding(
                get: { hidden },
                set: { v in update(piece.id) { $0.kind = .view(view, startsHidden: v) } }))
                .help(view == .selfView
                      ? "Your own picture stays out of the way at Start."
                      : "This view starts out of the way. \(ShortcutStore.phrase(.toggleMeeting)) shows it.")
            Spacer()
        }
        if !MeetingViewPieces.enabled {
            HStack {
                StatusBadge(text: "Turned off", tone: .problem)
                Text("It is skipped at Start. Views are switched off by the meetingViews.enabled default.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func meetingControls(_ piece: LayoutPiece, fills: Bool, hidden: Bool, slot: LayoutSlot,
                                 template: LayoutTemplate) -> some View {
        let others = template.pieces(for: slot).filter { $0.id != piece.id }
        ForEach(PieceInspectorRules.rows(for: piece.kind, slot: slot), id: \.self) { row in
            HStack {
                switch row {
                case .fillDisplay:
                    Toggle("Fill this display", isOn: Binding(
                        get: { fills },
                        set: { v in withAnimation(anim) {
                            update(piece.id) { p in p = LayoutEditorRules.settingFill(p, on: v) }
                        } }))
                        .disabled(!others.isEmpty && !fills)
                        .help(LayoutEditorRules.fillHint(othersOnDisplay: !others.isEmpty))
                default:
                    Toggle("Starts hidden on my screen", isOn: Binding(
                        get: { hidden },
                        set: { v in update(piece.id) { $0.kind = .meeting(fillsDisplay: fills, startsHidden: v) } }))
                        .help("The meeting starts out of the way. \(ShortcutStore.phrase(.toggleMeeting)) shows it.")
                }
                Spacer()
            }
        }
    }
}

/// The share pop-out for a layout (R32, `.atStart`): the shared SharePopout, writing the layout's saved share.
/// Plain values and closures, so it renders off screen.
struct LayoutSharePopout: View {
    let share: ShareTarget
    let apps: [AppInfo]
    var camera: LayoutCameraModel?
    let set: (ShareTarget) -> Void
    var sharedDisplay: Binding<LayoutSlot>?

    var body: some View {
        SharePopout(
            context: .atStart, share: share,
            value: ShareHintRules.tileLabel(kind: share.kind, appName: share.appName),
            art: DockHintVisual.share(share.kind, shape: camera?.shape ?? .circle, cameraOff: camera?.cameraOff ?? false),
            windows: apps.map { SharePopoutWindow(id: $0.bundleID, bundleID: $0.bundleID, appName: $0.name, title: "") },
            sharedDisplay: sharedDisplay,
            pickTile: { tile in if let next = SharePopoutRules.applying(tile, to: share) { set(next) } },
            pickWindow: { w in set(SharePopoutRules.picking(bundleID: w.bundleID, appName: w.appName, title: "", in: share)) },
            setFollows: { on in var next = share; next.followsSlideShow = on; set(next) })
    }
}

/// The header every piece inspector shares (R35.1): icon, name, one quiet readout, a menu.
struct PieceInspectorHeader<Leading: View, MenuContent: View>: View {
    let name: String
    let readout: String
    var readoutHelp: String?
    var tooltip: String?
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 8) {
            leading()
            Text(name)
                .font(.callout.weight(.semibold))
            Text(readout)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .help(readoutHelp ?? "")
            Spacer(minLength: 8)
            Menu(content: menu) {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More. \u{232B} removes it.")
            .accessibilityLabel("More for \(name)")
        }
        .help(tooltip ?? "")
    }
}

// MARK: - Cards and chips

/// One layout in the strip: a thumbnail at the display's shape over its name.
/// Clicking selects it AND makes it the Start layout; double-clicking the name
/// renames it.
let layoutCardWidth: CGFloat = 112

/// The card thumbnails' height at a display's shape. Shared with onboarding.
func layoutThumbHeight(for mainSize: CGSize) -> CGFloat {
    min(max(layoutCardWidth / max(mainSize.width / max(mainSize.height, 1), 1.2), 44), 84)
}

/// The None card's picture: a dashed outline and a no-entry sign.
struct LayoutNoneThumbnail: View {
    let height: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            Image(systemName: "nosign")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.secondary)
        }
        .frame(height: height)
    }
}

struct LayoutCard<Thumbnail: View>: View {
    let title: String
    let selected: Bool
    let isRenaming: Bool
    @Binding var draft: String
    let select: () -> Void
    let beginRename: (() -> Void)?
    let commitRename: () -> Void
    let cancelRename: () -> Void
    @ViewBuilder let thumbnail: () -> Thumbnail
    @FocusState private var fieldFocused: Bool

    init(title: String, selected: Bool, isRenaming: Bool, draft: Binding<String>,
         select: @escaping () -> Void, beginRename: (() -> Void)?,
         commitRename: @escaping () -> Void, cancelRename: @escaping () -> Void,
         @ViewBuilder thumbnail: @escaping () -> Thumbnail) {
        self.title = title
        self.selected = selected
        self.isRenaming = isRenaming
        self._draft = draft
        self.select = select
        self.beginRename = beginRename
        self.commitRename = commitRename
        self.cancelRename = cancelRename
        self.thumbnail = thumbnail
    }

    var body: some View {
        Button(action: select) {
        VStack(spacing: 6) {
            thumbnail()
                .frame(width: layoutCardWidth)
            if isRenaming {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .focused($fieldFocused)
                    .frame(width: layoutCardWidth, height: 34, alignment: .top)
                    .onSubmit(commitRename)
                    .onExitCommand(perform: cancelRename)
                    .onAppear { fieldFocused = true }
                    .onChange(of: fieldFocused) { _, now in if !now { commitRename() } }
            } else {
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: layoutCardWidth, height: 34, alignment: .top)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename?() })
            }
        }
        .padding(6)
        }
        .greenroomTile(role: .choice(selected: selected))
        .help(beginRename == nil ? title : "\(title)\nDouble-click the name to rename.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Start layout" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}
