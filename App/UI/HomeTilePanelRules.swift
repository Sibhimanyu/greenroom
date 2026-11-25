//
//  HomeTilePanelRules.swift
//
//  Pure rules for the Home tile panels (Look, Camera, ...): which sections a
//  panel shows, how a tap changes the camera list, and how arrow keys move.
//  Foundation only, so Tests/ compiles it without any view code.
//
import Foundation

/// Arrow-key movement through a row of choices.
enum HomeTileKeyRules {
    /// The next index after `delta` steps, clamped to the ends (no wrap: the
    /// edge is where the eye expects the row to stop).
    static func moved(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }

    /// Where the keyboard starts: the chosen one, else the first.
    static func startIndex(selected: Int?, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(selected ?? 0, 0), count - 1)
    }
}

/// What the Camera panel shows and what a tap does.
enum CameraPanelRules {
    enum Section: Equatable { case cameras, switching }

    /// The switch is only worth offering with somewhere to cut to.
    static func showsSwitchToggle(availableCount: Int) -> Bool { availableCount >= 2 }

    /// Auto-switch tuning (delay, cut or fade) needs the switch on AND two or
    /// more cameras chosen: with one there is nothing to switch between.
    static func showsSwitching(switchOn: Bool, chosenCount: Int) -> Bool {
        switchOn && chosenCount >= 2
    }

    /// Switch on with fewer than two chosen: say what is missing.
    static func showsPickAnotherHint(switchOn: Bool, chosenCount: Int) -> Bool {
        switchOn && chosenCount < 2
    }

    static func sections(switchOn: Bool, chosenCount: Int) -> [Section] {
        showsSwitching(switchOn: switchOn, chosenCount: chosenCount) ? [.cameras, .switching] : [.cameras]
    }

    /// Chosen cameras that are plugged in right now, in cut order.
    static func chosen(order: [String], available: [String]) -> [String] {
        let present = Set(available)
        return order.filter { present.contains($0) }
    }

    /// Whether a camera's row carries the check.
    static func isSelected(uid: String, switchOn: Bool, order: [String], single: String?, noCamera: Bool) -> Bool {
        if switchOn { return order.contains(uid) }
        return !noCamera && single == uid
    }

    /// The 1-based cut position shown on a row; only while switching is on.
    static func position(of uid: String, switchOn: Bool, order: [String]) -> Int? {
        guard switchOn, let index = order.firstIndex(of: uid) else { return nil }
        return index + 1
    }

    /// The list after tapping a camera. Switching on: toggles membership, so
    /// the order is the order they were chosen in. Off: that camera becomes
    /// the one, moved to the front of the same list.
    static func tapped(uid: String, switchOn: Bool, order: [String]) -> [String] {
        if switchOn {
            return order.contains(uid) ? order.filter { $0 != uid } : order + [uid]
        }
        return [uid] + order.filter { $0 != uid }
    }

    /// The list when the switch turns on: the camera already in use stays in
    /// it, so turning switching on starts from what the picture shows.
    static func orderWhenSwitchingOn(order: [String], single: String?) -> [String] {
        guard let single, !order.contains(single) else { return order }
        return [single] + order
    }

    /// "No camera" is refused while nothing is shared (the picture would be
    /// an empty backdrop).
    static func noCameraEnabled(shareIsNothing: Bool) -> Bool { !shareIsNothing }

    /// SF Symbol for a camera row.
    static func symbol(name: String, isBuiltIn: Bool) -> String {
        if isBuiltIn { return "laptopcomputer" }
        if name.localizedCaseInsensitiveContains("iphone") { return "iphone" }
        return "web.camera"
    }

    /// The panel header's value: the camera in use, "2 cameras, switching",
    /// or Off.
    static func headerValue(noCamera: Bool, switchOn: Bool, chosenCount: Int, singleName: String?) -> String {
        if noCamera { return "Off" }
        if switchOn, chosenCount >= 2 { return "\(chosenCount) cameras, switching" }
        return singleName ?? "No camera found"
    }
}

/// What a Home camera tile (Look) shows and does, from the camera setting and
/// whether any camera device exists. Home is a control surface, so a camera
/// that is only off by setting is one click from on.
enum CameraTileRules {
    enum State: Equatable {
        case on
        /// The setting turned the camera off: the tile stays live and turns it on.
        case offBySetting
        /// No camera is connected at all: nothing to turn on.
        case noDevice
    }

    static func state(cameraIsOff: Bool, deviceCount: Int) -> State {
        if deviceCount == 0 { return .noDevice }
        return cameraIsOff ? .offBySetting : .on
    }

    static func isEnabled(_ state: State) -> Bool { state != .noDevice }

    /// Just me (the Screen panel) needs a camera on screen: from the off-by-setting
    /// state a click turns it on, so only a missing device blocks it.
    static func justMeEnabled(_ state: State) -> Bool { isEnabled(state) }
    static func justMeTurnsCameraOn(_ state: State) -> Bool { tapTurnsCameraOn(state) }
    static let justMeNoDeviceHint = "Just me needs a camera. None is connected."

    static func value(_ state: State, onValue: String) -> String {
        switch state {
        case .on: return onValue
        case .offBySetting: return "Camera off"
        case .noDevice: return "No camera"
        }
    }

    static func symbol(_ state: State, onSymbol: String) -> String {
        switch state {
        case .on: return onSymbol
        case .offBySetting: return VisibilitySymbol.cameraOff.name
        case .noDevice: return VisibilitySymbol.noCameraDevice.name
        }
    }

    /// The corner badge: a question mark when no camera is connected.
    static func badge(_ state: State) -> String? {
        state == .noDevice ? VisibilitySymbol.noCameraDevice.badge : nil
    }

    /// A tap turns the camera on only from the off-by-setting state.
    static func tapTurnsCameraOn(_ state: State) -> Bool { state == .offBySetting }

    static let noDeviceHelp = "No camera is connected. Plug one in to use it in the meeting."
    static let offHelp = "Camera is off. Click to turn it on for everyone in the meeting."

    /// The panel's off row: the action while the camera is on, the state once off.
    static func offRowTitle(cameraIsOff: Bool) -> String { cameraIsOff ? "Camera off" : "Turn camera off" }
}

/// What the Mic panel shows.
enum MicPanelRules {
    /// A saved microphone that is not plugged in stays listed (and checked),
    /// so the panel never silently forgets the choice.
    static func showsSavedMissing(selection: String, available: [String]) -> Bool {
        !selection.isEmpty && !available.contains(selection)
    }

    /// The header's value: the device the meeting hears.
    static func headerValue(name: String, savedMissing: Bool) -> String {
        savedMissing ? "Saved microphone (not connected)" : name
    }

    /// The Mac's sound comes from what is shared; with nothing shared there
    /// is none to add, so the toggle says so.
    static func showsNeedsShareHint(recordSystemAudio: Bool, shareIsNothing: Bool) -> Bool {
        recordSystemAudio && shareIsNothing
    }
}

/// What the Auto-rec panel shows.
enum RecordPanelRules {
    enum Section: Equatable { case start, clipBuffer, folder }

    /// Recording choices change nothing mid-meeting (the tile is disabled then),
    /// so a panel that is somehow open while live shows nothing to change.
    static func sections(isLive: Bool) -> [Section] {
        isLive ? [] : [.start, .clipBuffer, .folder]
    }

    /// The clip buffer's length is fixed (SessionFolders.clipBufferSeconds);
    /// shown only under the toggle, so only when it is on.
    static func showsClipLength(clipBufferOn: Bool) -> Bool { clipBufferOn }

    static func clipLengthText(seconds: Int) -> String {
        let minutes = seconds / 60
        return seconds % 60 == 0 && minutes >= 1
            ? "Keeps the last \(minutes) minute\(minutes == 1 ? "" : "s")."
            : "Keeps the last \(seconds) seconds."
    }

    static func headerValue(autoRecord: Bool) -> String { autoRecord ? "Auto-record" : "Manual" }
}

/// The Settings tabs, in toolbar order (derived from `MorePanelRules`' one list). Pure, so the order, the shortcuts and
/// the Home "More" panel stay in step (HomeTilePanelRulesTests).
enum SettingsTabs {
    /// The Account tab is a mock that only exists in Debug.
    #if DEBUG
    static let buildHasAccount = true
    #else
    static let buildHasAccount = false
    #endif

    static func order(includingAccount: Bool) -> [String] {
        MorePanelRules.tabs(includingAccount: includingAccount).map(\.id)
    }

    /// Home's "Look" and "Share" More…: the camera piece in Layouts, where the look now lives.
    static let cameraLookID = "camera"

    /// Where a deep link lands. The Webcam tab is gone (R11): its old id, and `cameraLookID`, open
    /// Layouts with the camera piece selected. Any other id is its own tab and selects nothing.
    static func destination(for id: String) -> (tab: String, selectsCamera: Bool) {
        id == "webcam" || id == cameraLookID ? ("layout", true) : (id, false)
    }

    /// ⌘1...⌘9, then ⌘0; nothing past ten. (`Character("10")` would trap.)
    static func shortcutKey(at index: Int) -> Character? {
        switch index {
        case 0...8: return Character(String(index + 1))
        case 9: return "0"
        default: return nil
        }
    }
}

/// What the More panel shows: the Settings tabs it jumps to, in order.
enum MorePanelRules {
    struct Tab: Equatable {
        var id: String      // SettingsView's tag, and .showSettingsTab's object
        var title: String
        var symbol: String
        var beta = false
    }

    /// The Account tab is a mock that only exists in Debug (SettingsView), so
    /// a Release More panel must not list it.
    #if DEBUG
    static let tabs: [Tab] = tabs(includingAccount: true)
    #else
    static let tabs: [Tab] = tabs(includingAccount: false)
    #endif

    static func tabs(includingAccount: Bool) -> [Tab] {
        (includingAccount ? [account] : []) + common
    }

    private static let account = Tab(id: "account", title: "Account", symbol: "person.crop.circle")

    /// The one list of tabs: `SettingsTabs.order` is derived from it.
    private static let common: [Tab] = [
        Tab(id: "layout", title: "Layouts", symbol: "rectangle.split.2x1"),
        Tab(id: "devices", title: "Devices", symbol: "headphones"),
        Tab(id: "general", title: "General", symbol: "gearshape"),
        Tab(id: "shortcuts", title: "Shortcuts", symbol: "command"),
        Tab(id: "zoom", title: "Zoom", symbol: "video.bubble"),
        Tab(id: "youtube", title: "YouTube", symbol: "play.rectangle.fill"),
        Tab(id: "cues", title: "Cues", symbol: "waveform.and.magnifyingglass", beta: true),
        Tab(id: "transfer", title: "Transfer", symbol: "square.and.arrow.up.on.square"),
    ]
}

/// What the Screen panel shows. Kinds come from `SetupSummary.ShareKind` so
/// this file stays free of ShareTarget (AppKit).
enum ScreenPanelRules {
    /// The four things the SHARE row offers. "One app" is not offered: a saved
    /// one is read back as the whole screen.
    enum Tile: String, CaseIterable { case screen, window, whiteboard, camera }
    enum Section: Hashable { case share, gone, permission, displays, windows, follow }

    static func tile(for kind: SetupSummary.ShareKind) -> Tile {
        switch kind {
        case .display, .app: return .screen
        case .window: return .window
        case .whiteboard: return .whiteboard
        case .nothing: return .camera
        }
    }

    /// "Just my camera" with no camera device would be an empty backdrop; a camera that is only off by setting is turned on by the click.
    static func tileEnabled(_ tile: Tile, camera: CameraTileRules.State) -> Bool {
        tile != .camera || CameraTileRules.justMeEnabled(camera)
    }

    static func capturesScreen(_ kind: SetupSummary.ShareKind) -> Bool {
        switch kind {
        case .display, .app, .window: return true
        case .whiteboard, .nothing: return false
        }
    }

    /// Top to bottom. `browsingWindows`: the Window tile was tapped but no
    /// window is picked yet, so the list shows to pick from.
    static func sections(kind: SetupSummary.ShareKind, displayCount: Int, browsingWindows: Bool,
                         gone: Bool, permissionMissing: Bool) -> [Section] {
        var out: [Section] = [.share]
        if gone { out.append(.gone) }
        if permissionMissing && capturesScreen(kind) { out.append(.permission) }
        if (kind == .display || kind == .app) && displayCount >= 2 { out.append(.displays) }
        if kind == .window || browsingWindows { out.append(.windows) }
        if kind == .window { out.append(.follow) }
        return out
    }

    /// Windows in app groups, each app at its first appearance, windows in
    /// their given order. `firstOfApp` marks where an app's heading goes.
    static func grouped(bundleIDs: [String]) -> (order: [Int], firstOfApp: [Bool]) {
        var seen: [String] = []
        for id in bundleIDs where !seen.contains(id) { seen.append(id) }
        var order: [Int] = []
        for id in seen { order += bundleIDs.indices.filter { bundleIDs[$0] == id } }
        var shown = Set<String>()
        let first = order.map { shown.insert(bundleIDs[$0]).inserted }
        return (order, first)
    }
}

/// What the Layout panel shows.
enum LayoutPanelRules {
    enum Section: Hashable { case layouts, locked, actions }

    /// "Show on screen" needs a layout with pieces; "Open this layout's apps"
    /// needs a piece that is an app.
    static func showsShowOnScreen(activePieceCount: Int?) -> Bool { (activePieceCount ?? 0) > 0 }

    static func sections(locked: Bool, activePieceCount: Int?, hasApps: Bool) -> [Section] {
        var out: [Section] = [.layouts]
        if locked { out.append(.locked) }
        if showsShowOnScreen(activePieceCount: activePieceCount) || hasApps { out.append(.actions) }
        return out
    }

    /// The header value: the layout's name, or "No layout".
    static func headerValue(name: String) -> String { name == "None" ? "No layout" : name }

    /// The header hint for a layout with a two-display version: nil without one.
    static func twoDisplayNote(hasTwoDisplays: Bool, secondConnected: Bool) -> String? {
        guard hasTwoDisplays else { return nil }
        return secondConnected ? "Using two displays" : "Two displays when connected"
    }

    static let twoDisplayBadgeHelp = "Has a two-display version"

    static let lockedNote = "A meeting runs the layout it started with. Pick the next one after it ends."
}

/// The one container every Home pop-out (Screen, Camera, Mic, Record, Layout, Look, More) is built in:
/// width, inner padding and the gap between sections. A panel never pads or sizes itself.
enum HomeTileMetrics {
    static let width: CGFloat = 330
    static let padding: CGFloat = 14
    static let sectionSpacing: CGFloat = 10
    static let tileGap: CGFloat = 6
    /// What is left for content.
    static var contentWidth: CGFloat { width - 2 * padding }

    /// Whether `count` tiles of `tileWidth` and their gaps fit in the content width.
    static func rowFits(tileWidth: CGFloat, count: Int) -> Bool {
        tileWidth * CGFloat(count) + tileGap * CGFloat(max(0, count - 1)) <= contentWidth
    }

    /// The widest whole-point tile that lets `count` of them fill the row.
    static func tileWidth(count: Int) -> CGFloat {
        ((contentWidth - tileGap * CGFloat(max(0, count - 1))) / CGFloat(max(1, count))).rounded(.down)
    }
}
