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

    // AXIsProcessTrusted() has no change notification, so poll it while
    // the tab is visible - the warning disappears on its own once the user
    // flips the switch in System Settings.
    private let permissionTick = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        LayoutPageContent(
            library: $coordinator.layoutLibrary,
            hideSelfView: $coordinator.hideSelfView,
            analyticsEnabled: $coordinator.analyticsEnabled,
            browserRestoresTabs: $coordinator.browserRestoresTabs,
            browserSearchSuggestions: $coordinator.browserSearchSuggestions,
            apps: apps,
            displays: displays,
            mainSize: DisplayResolver.mainDisplayScreen()?.visibleFrame.size ?? CGSize(width: 1440, height: 875),
            secondSize: { LayoutScreenPreview.secondScreen(uuid: $0)?.visibleFrame.size },
            customUIMode: coordinator.customUIMode,
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
                LayoutScreenPreview.show(LayoutScreenPreview.items(for: template, look: look))
            },
            liveLayoutID: coordinator.liveSessionLayoutID,
            applyNow: { coordinator.applyLayoutNow($0) })
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
    @Binding var hideSelfView: Bool
    @Binding var analyticsEnabled: Bool
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
    let customUIMode: Bool
    /// Accessibility is granted: non-browser apps can be moved.
    let canMoveApps: Bool
    let openAccessibilitySettings: () -> Void
    let showOnScreen: (LayoutTemplate, (LayoutPiece) -> LayoutPieceLook) -> Void
    /// The layout the class in progress is running; nil when there is no arranged
    /// class. An edit to that layout applies by itself; picking another card does
    /// not, so the editor offers "Apply now" for it.
    var liveLayoutID: UUID?
    var applyNow: (UUID) -> Void = { _ in }
    /// Where the editor opens, for the off-screen render (.context/lr). Nil in the app.
    var opensOn: (selection: UUID?, showsTwo: Bool, slot: LayoutSlot)?
    /// Draws the Add panel in place under the row, for the off-screen render.
    var previewsAddPanel = false

    @State private var selection: UUID?
    @State private var showsTwo = false
    @State private var activeSlot: LayoutSlot = .one
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @State private var deleteCandidate: UUID?
    @State private var confirmReset = false
    @State private var showsAddPanel = false
    @FocusState private var focus: LayoutFocus?
    @AppStorage(SessionNotes.enabledKey) private var notesOnStart = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Body

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    cardStrip
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

            Section {
                if let template = library.active {
                    editor(template)
                        .padding(.vertical, 4)
                } else {
                    noneState
                }
            }

            Section("During class") {
                Toggle("Open notes when a session starts", isOn: $notesOnStart)
                Text("Notes are timed to the recording and saved with the session. You can still open or close them during a session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Hide my own tile", isOn: $hideSelfView)
                    Text("Your own video is left out of the meeting you see. The class still sees you.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Privacy") {
                Toggle("Anonymous usage analytics", isOn: $analyticsEnabled)
                    .help("Counts and timings only. Never names, meeting IDs, addresses or chat.")
            }

        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        // Nothing focused when the tab opens: macOS Tab cycles text fields, and
        // a field that claims focus on open cannot be escaped.
        .defaultFocus($focus, nil)
        .onExitCommand { focus = nil }
        .onAppear {
            focus = nil
            if let o = opensOn { selection = o.selection; showsTwo = o.showsTwo; activeSlot = o.slot }
        }
        .onChange(of: library.activeID) { _, _ in resetEditorState() }
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
        return lost + " The layout used at Start goes back to None."
    }

    private var anim: Animation? { reduceMotion ? nil : .snappy(duration: 0.25) }

    private var deleteCandidateName: String {
        deleteCandidate.flatMap { library.template(id: $0)?.name } ?? ""
    }

    private func resetEditorState() {
        selection = nil
        showsTwo = false
        activeSlot = .one
        renamingID = nil
    }

    // MARK: Card strip

    private var thumbHeight: CGFloat { layoutThumbHeight(for: mainSize) }

    private var cardStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                LayoutCard(title: "None", selected: library.activeID == nil, isRenaming: false,
                           draft: .constant(""), select: { choose(nil) }, beginRename: nil,
                           commitRename: {}, cancelRename: {}) {
                    LayoutNoneThumbnail(height: thumbHeight)
                }
                .help("Greenroom opens and moves nothing.")

                ForEach(library.templates) { template in
                    LayoutCard(title: template.name, selected: library.activeID == template.id,
                               isRenaming: renamingID == template.id, draft: $renameDraft,
                               select: { choose(template.id) },
                               beginRename: template.isLocked ? nil : { beginRename(template) },
                               commitRename: { commitRename() },
                               cancelRename: { renamingID = nil }) {
                        LayoutThumbnail(pieces: template.oneDisplay, aspect: layoutCardWidth / thumbHeight, look: look)
                    }
                    .contextMenu {
                        Button("Rename") { beginRename(template) }
                            .disabled(template.isLocked)
                        Button("Duplicate") { duplicate(template.id) }
                        Divider()
                        Button("Delete\u{2026}", role: .destructive) { deleteCandidate = template.id }
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
        guard !template.isLocked else { return }
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
            return "Greenroom starts the class and leaves your windows where they are."
        }
        let pieces = template.oneDisplay + (template.twoDisplays.map { $0.main + $0.second } ?? [])
        var opens: [String] = []
        for piece in template.oneDisplay {
            if let app = piece.kind.app, app.opensAtStart { opens.append(look(piece).name) }
        }
        let places = [
            pieces.contains { $0.kind.isMeeting } ? meetingWord : nil,
            pieces.contains { $0.kind.isChat } ? "chat" : nil,
        ].compactMap { $0 } + (customUIMode && MeetingViewPieces.enabled ? pieces.compactMap { $0.kind.view?.title.lowercased() } : [])
        var sentence: String
        // Raj Mode as shipped: the compact Meeting window is the active speaker.
        if isRajAsShipped(template), let browser = opens.first {
            sentence = "Greenroom opens \(browser) and places the meeting as active speaker, with chat below."
            sentence += " With a second display connected it uses the two-display version."
            return sentence
        }
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
        if template.twoDisplays != nil {
            sentence += " With a second display connected it uses the two-display version."
        }
        return sentence
    }

    private func isRajAsShipped(_ template: LayoutTemplate) -> Bool {
        guard template.starter == LayoutLibrary.rajMode,
              let shipped = LayoutLibrary.starters().first(where: { $0.starter == LayoutLibrary.rajMode }) else { return false }
        let now = template.oneDisplay
        let was = shipped.oneDisplay
        guard now.count == was.count else { return false }
        for (a, b) in zip(now, was) where a.rect != b.rect || a.kind.isChat != b.kind.isChat
            || a.kind.isMeeting != b.kind.isMeeting { return false }
        return true
    }

    private var meetingWord: String { customUIMode ? "meeting window" : "Zoom window" }

    private func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    // MARK: None

    private var noneState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("Greenroom opens and moves nothing")
                    .font(.headline)
                Text("Zoom and your apps stay wherever they are. Pick a layout above, or start from one of these.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                ForEach(LayoutLibrary.starters(), id: \.starter) { starter in
                    Button { pickStarter(starter.starter ?? "") } label: {
                        Label(starter.name, systemImage: starter.starter == LayoutLibrary.teachFromBrowser
                              ? "safari" : starter.starter == LayoutLibrary.rajMode
                              ? "sidebar.right" : "rectangle.split.2x1")
                    }
                }
                Button(action: addLayout) { Label("Start from scratch", systemImage: "plus") }
            }
            Button("Reset to defaults\u{2026}") { confirmReset = true }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Removes your layouts and brings back the built-in ones.")
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(.vertical, 8)
    }

    private func pickStarter(_ key: String) {
        withAnimation(anim) {
            if let id = library.starterID(key) { library.select(id) }
            resetEditorState()
        }
    }

    // MARK: Editor

    private func editor(_ template: LayoutTemplate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if template.isLocked {
                VStack(alignment: .leading, spacing: 6) {
                    titleRow(template)
                    lockLine(template)
                }
            } else {
                titleRow(template)
            }
            canvases(template)
            paletteRow(template)
            // Nothing to change on a built-in layout, so no inspector: its
            // "select a piece" hint would promise something that cannot happen.
            if !template.isLocked { inspector(template) }
        }
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

    /// What a built-in layout says about itself, quietly, with the way out.
    private func lockLine(_ template: LayoutTemplate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Built-in layout. Duplicate it to make your own version.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Duplicate") { duplicate(template.id) }
                .controlSize(.small)
                .help("Makes an editable copy named \u{201C}\(template.name) copy\u{201D} and selects it.")
        }
    }

    private func titleRow(_ template: LayoutTemplate) -> some View {
        HStack(spacing: 12) {
            if template.isLocked {
                Text(template.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            } else {
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
            }
            Spacer(minLength: 8)
            if template.twoDisplays != nil {
                Picker("Layout for", selection: Binding(get: { showsTwo },
                                                        set: { v in
                                                            withAnimation(anim) { showsTwo = v; activeSlot = v ? .main : .one; selection = nil }
                                                        })) {
                    Text("One display").tag(false)
                    Text("Two displays").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else if !template.isLocked {
                Button {
                    withAnimation(anim) {
                        if let i = activeIndex { library.templates[i].addTwoDisplayVersion() }
                        showsTwo = true
                        activeSlot = .main
                        selection = nil
                    }
                } label: {
                    Label("Add a two-display version", systemImage: "display.2")
                }
                .controlSize(.small)
                .help("A second arrangement for when a reference display is connected.")
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(get: { library.active?.name ?? "" },
                set: { if let i = activeIndex, !library.templates[i].isLocked { library.templates[i].name = $0 } })
    }

    // MARK: Canvases

    private var mainSpace: LayoutDisplaySpace {
        LayoutDisplaySpace(name: "Main display", size: mainSize)
    }

    private func secondSpace(_ two: TwoDisplay) -> LayoutDisplaySpace {
        if let size = secondSize(two.secondUUID) {
            return LayoutDisplaySpace(name: "Second display", size: size)
        }
        return LayoutDisplaySpace(name: "Second display", size: CGSize(width: 1440, height: 810), connected: false)
    }

    private func space(for slot: LayoutSlot, _ template: LayoutTemplate) -> LayoutDisplaySpace {
        slot == .second ? secondSpace(template.twoDisplays ?? TwoDisplay()) : mainSpace
    }

    @ViewBuilder
    private func canvases(_ template: LayoutTemplate) -> some View {
        if showsTwo, let two = template.twoDisplays {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    canvas(.main, space: mainSpace)
                    canvas(.second, space: secondSpace(two))
                }
                if !template.isLocked { secondDisplayRow(two) }
            }
        } else {
            canvas(.one, space: mainSpace)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }
    }

    private func canvas(_ slot: LayoutSlot, space: LayoutDisplaySpace) -> some View {
        LayoutCanvas(pieces: binding(for: slot), selection: $selection, display: space,
                     look: look,
                     accepts: { kind in
                        if case .view = kind, !customUIMode || !MeetingViewPieces.enabled { return false }
                        return library.active?.canAdd(kind, to: slot) ?? false
                     },
                     onActivate: { activeSlot = slot; showsAddPanel = false },
                     onNotice: { say($0) },
                     locked: library.active?.isLocked == true)
    }

    private func secondDisplayRow(_ two: TwoDisplay) -> some View {
        HStack(spacing: 10) {
            Text("Second display")
                .font(.callout)
            Picker("Second display", selection: Binding(
                get: { two.secondUUID },
                set: { v in if let i = activeIndex { library.templates[i].twoDisplays?.secondUUID = v } })) {
                Text("Automatic").tag("")
                ForEach(displays.filter { !$0.isMain }) { Text($0.name).tag($0.id) }
                // A saved display that is unplugged stays visible and valid.
                if !two.secondUUID.isEmpty, !displays.contains(where: { $0.id == two.secondUUID }) {
                    Text("Saved display (not connected)").tag(two.secondUUID)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Automatic is the first display that is not your main one.")
            Spacer()
            Button("Remove two-display version") {
                withAnimation(anim) {
                    if let i = activeIndex { library.templates[i].removeTwoDisplayVersion() }
                    showsTwo = false
                    activeSlot = .one
                    selection = nil
                }
            }
            .controlSize(.small)
        }
    }

    // MARK: Palette

    private func paletteRow(_ template: LayoutTemplate) -> some View {
        let slot = showsTwo ? activeSlot : .one
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !template.isLocked {
                    Button { showsAddPanel.toggle() } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .help(MeetingViewPieces.enabled ? "Add the meeting, a view of it, chat or an app" : "Add the meeting, chat or an app")
                    .accessibilityLabel("Add to layout")
                    .popover(isPresented: $showsAddPanel, arrowEdge: .bottom) {
                        addPanel(slot: slot, template: template)
                    }
                }
                Spacer()
                Button {
                    showOnScreen(template, look)
                    if template.twoDisplays != nil, secondSize(template.twoDisplays?.secondUUID ?? "") == nil {
                        say("No second display is connected, so this shows the one-display version.")
                    }
                } label: {
                    Label("Show on screen", systemImage: "rectangle.dashed.badge.record")
                }
                .disabled(template.pieceCount == 0)
                .help("Outlines where each piece would go, on your real displays, for a moment.")
                if let live = liveLayoutID, live != template.id {
                    Button("Apply now") { applyNow(template.id) }
                        .help("A class is running another layout. This moves it to this one now; otherwise this layout starts with the next class.")
                }
            }
            if previewsAddPanel, !template.isLocked {
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
    }

    private func addPanel(slot: LayoutSlot, template: LayoutTemplate, note: String? = nil) -> LayoutAddPanel {
        let version = template.piecesInVersion(of: slot)
        return LayoutAddPanel(
            customUIMode: customUIMode, apps: apps,
            reason: { blockReason($0, template: template, slot: slot) },
            isPlaced: { kind in version.contains { sameKind($0.kind, kind) } },
            add: { kind in
                showsAddPanel = false
                add(kind, slot: slot, template: template)
            },
            close: { showsAddPanel = false },
            initialNote: note)
    }

    /// Why a piece cannot be added right now, or nil when it can. Spoken in the
    /// Add panel's tooltips and caption, and the notice a click would give.
    private func blockReason(_ kind: LayoutPiece.Kind, template: LayoutTemplate, slot: LayoutSlot) -> String? {
        let version = template.piecesInVersion(of: slot)
        if case .view = kind, !MeetingViewPieces.enabled { return "Coming in a later update" }
        if case .view = kind, !customUIMode { return "Needs Greenroom\u{2019}s meeting UI (Settings \u{2192} Zoom)" }
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
        case let .app(app):
            if version.contains(where: { $0.kind.app?.bundleID == app.bundleID }) { return "Already in this layout" }
            return "A layout holds at most \(LayoutTemplate.maxApps) apps."
        }
    }

    /// Click-to-add: into the largest free rectangle. A piece already in the
    /// layout is selected instead of added twice.
    private func add(_ kind: LayoutPiece.Kind, slot: LayoutSlot, template: LayoutTemplate) {
        guard template.canAdd(kind, to: slot), blockReason(kind, template: template, slot: slot) == nil else {
            if let existing = template.piecesInVersion(of: slot).first(where: { sameKind($0.kind, kind) }) {
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
        case (.meeting, .meeting), (.chat, .chat): return true
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
        switch piece.kind {
        case .meeting:
            return LayoutPieceLook(name: customUIMode ? "Meeting window" : "Zoom window", icon: nil, symbol: "video.fill")
        case let .view(view, _):
            return LayoutPieceLook(name: view.title, icon: nil, symbol: view.symbol,
                                   meetingView: view,
                                   needsCustomUI: MeetingViewPieces.enabled && !customUIMode,
                                   comingLater: !MeetingViewPieces.enabled)
        case .chat:
            return LayoutPieceLook(name: "Chat", icon: nil, symbol: "bubble.left.and.bubble.right.fill")
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
        let slots: [LayoutSlot] = showsTwo ? [.main, .second] : [.one]
        for slot in slots {
            if let piece = template.pieces(for: slot).first(where: { $0.id == id }) { return (slot, piece) }
        }
        return nil
    }

    private func update(_ id: UUID, _ change: (inout LayoutPiece) -> Void) {
        guard let i = activeIndex else { return }
        for slot in [LayoutSlot.one, .main, .second] {
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
            for slot in [LayoutSlot.one, .main, .second] {
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
            if let (slot, piece) = selected(in: template) {
                inspectorHeader(piece, slot: slot, template: template)
                switch piece.kind {
                case let .app(app): appControls(piece, app: app, slot: slot, template: template)
                case let .meeting(fills, hidden): meetingControls(piece, fills: fills, hidden: hidden, slot: slot, template: template)
                case let .view(_, hidden): viewControls(piece, view: piece.kind.view ?? .gallery, hidden: hidden)
                case .chat:
                    Text("The meeting chat window. It opens in this space when the class starts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "cursorarrow.click.2")
                        .foregroundStyle(.secondary)
                    Text("Select a piece to change what it does. Arrows move it, \u{21E7}-arrows resize it, \u{232B} removes it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private func inspectorHeader(_ piece: LayoutPiece, slot: LayoutSlot, template: LayoutTemplate) -> some View {
        let l = look(piece)
        let size = space(for: slot, template).size
        let span = LayoutGeometry.cellSpan(of: piece.rect)
        let points = LayoutGeometry.pointSize(of: piece.rect, display: size)
        return HStack(spacing: 8) {
            Group {
                if let icon = l.icon, !l.missing {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: l.symbol).resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)
            Text(l.name)
                .font(.callout.weight(.semibold))
            Text("columns \(span.cols.lowerBound)\u{2013}\(span.cols.upperBound) \u{00B7} rows \(span.rows.lowerBound)\u{2013}\(span.rows.upperBound) \u{00B7} \(points.w)\u{00D7}\(points.h)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { remove(piece.id) } label: {
                Label("Remove", systemImage: "trash")
            }
            .controlSize(.small)
            .help("Takes it out of this layout. \u{232B} does the same.")
        }
    }

    @ViewBuilder
    private func appControls(_ piece: LayoutPiece, app: AppPiece, slot: LayoutSlot, template: LayoutTemplate) -> some View {
        let isBrowser = AppCatalog.isBrowser(app.bundleID)
        let isBuiltIn = AppCatalog.isBuiltInBrowser(app.bundleID)
        let installed = LayoutIcons.isInstalled(app.bundleID)
        let name = look(piece).name
        let taken = Set(template.piecesInVersion(of: slot).compactMap { $0.kind.app?.bundleID }).subtracting([app.bundleID])
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
            .help(isBuiltIn
                  ? "Greenroom\u{2019}s own browser: tabs, find in page, local history, no permissions to grant. Pick Chrome if you need extensions."
                  : "Which app fills this space")
            if isBrowser {
                // .roundedBorder: the borderless field read as an apparently
                // dead empty row, with nothing saying "type a URL here".
                TextField("Website", text: Binding(
                    get: { app.url },
                    set: { new in update(piece.id) { p in
                        if var a = p.kind.app { a.url = AppCatalog.sanitizedURLText(new); p.kind = .app(a) }
                    } }), prompt: Text("e.g. docs.google.com"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .website)
                    .help("Opens at Start")
            }
        }
        if !installed {
            HStack {
                StatusBadge(text: "Not on this Mac", tone: .problem)
                Text("It is skipped at Start. Pick another app or remove it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
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
        HStack(spacing: 24) {
            Toggle("Open at Start", isOn: Binding(
                get: { app.opensAtStart },
                set: { v in update(piece.id) { p in if var a = p.kind.app { a.opensAtStart = v; p.kind = .app(a) } } }))
            Toggle("Close when class ends", isOn: Binding(
                get: { app.closesOnStop },
                set: { v in update(piece.id) { p in if var a = p.kind.app { a.closesOnStop = v; p.kind = .app(a) } } }))
                .help(isBrowser ? "Only the window Start opened. Your other windows and tabs stay open." : "Quits only what Start opened.")
            Spacer()
        }
        if isBuiltIn {
            HStack(spacing: 24) {
                Toggle("Reopen last tabs", isOn: $browserRestoresTabs)
                    .help("Yesterday\u{2019}s tabs come back beside the website above.")
                Toggle("Search suggestions", isOn: $browserSearchSuggestions)
                    .help("Sends what you type to Google for completions. Off: history only, nothing leaves until Return.")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func viewControls(_ piece: LayoutPiece, view: MeetingView, hidden: Bool) -> some View {
        HStack(spacing: 24) {
            Toggle("Starts hidden", isOn: Binding(
                get: { hidden },
                set: { v in update(piece.id) { $0.kind = .view(view, startsHidden: v) } }))
                .help("This view starts out of the way. \(ShortcutStore.phrase(.toggleMeeting)) shows it.")
            Spacer()
        }
        if !MeetingViewPieces.enabled {
            HStack {
                StatusBadge(text: "Coming later", tone: .problem)
                Text("It is skipped at Start. Showing views arrives in a later update.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else if !customUIMode {
            HStack {
                StatusBadge(text: "Needs custom UI", tone: .problem)
                Text("It is skipped at Start. Turn on Greenroom\u{2019}s meeting UI in Settings \u{2192} Zoom.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func meetingControls(_ piece: LayoutPiece, fills: Bool, hidden: Bool, slot: LayoutSlot,
                                 template: LayoutTemplate) -> some View {
        let others = template.pieces(for: slot).filter { $0.id != piece.id }
        HStack(spacing: 24) {
            if slot == .second {
                Toggle("Fill this display", isOn: Binding(
                    get: { fills },
                    set: { v in withAnimation(anim) {
                        update(piece.id) { p in
                            p.kind = .meeting(fillsDisplay: v, startsHidden: hidden)
                            if v { p.rect = .full }
                        }
                    } }))
                    .disabled(!others.isEmpty && !fills)
                    .help(others.isEmpty
                          ? "The whole display shows the meeting and the people in it."
                          : "Remove the other pieces on this display first.")
            }
            Toggle("Start hidden", isOn: Binding(
                get: { hidden },
                set: { v in update(piece.id) { $0.kind = .meeting(fillsDisplay: fills, startsHidden: v) } }))
                .help("The meeting starts out of the way. \(ShortcutStore.phrase(.toggleMeeting)) shows it.")
            Spacer()
        }
        if !customUIMode {
            Text("Custom meeting UI is off, so this is Zoom\u{2019}s own window, moved into this space.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(selected ? Brand.green.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Brand.green : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: select)
        .help(beginRename == nil ? title : "\(title)\nDouble-click the name to rename.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Start layout" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}
