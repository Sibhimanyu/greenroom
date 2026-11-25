//
//  LayoutRefineRules.swift
//  Greenroom
//
//  The pure rules behind the refined share and inspector UI (R32 to R36, docs/specs/layouts-builder.md):
//  the one share pop-out (Home live, Layouts saved), the canvas's Shared / Not shared marks, the simple
//  piece inspectors, and Home's hint when the share is not the whole screen. Foundation only, so the
//  test target compiles this file as it is.
//
import Foundation

// MARK: - R32 The share pop-out

/// Where the pop-out opens: Home (the meeting that runs) or Layouts (what is saved to start with).
enum SharePopoutContext: Equatable { case thisMeeting, atStart }

enum SharePopoutRules {
    enum Section: Hashable { case share, gone, permission, sharedDisplay, displays, windows, follow }

    static func title(_ c: SharePopoutContext) -> String {
        "Screen \u{00B7} " + (c == .thisMeeting ? "this meeting" : "at start")
    }

    /// The saved kind in the panel's words.
    static func shareKind(_ kind: ShareTarget.Kind) -> SetupSummary.ShareKind {
        switch kind {
        case .display: return .display
        case .app: return .app
        case .window: return .window
        case .whiteboard: return .whiteboard
        case .nothing: return .nothing
        }
    }

    static func sections(context: SharePopoutContext, kind: ShareTarget.Kind, displayCount: Int, hasTwoDisplays: Bool,
                         browsingWindows: Bool, gone: Bool, permissionMissing: Bool) -> [Section] {
        let live = ScreenPanelRules.sections(kind: shareKind(kind), displayCount: displayCount, browsingWindows: browsingWindows,
                                             gone: gone, permissionMissing: permissionMissing)
        func map(_ s: ScreenPanelRules.Section) -> Section {
            switch s {
            case .share: return .share
            case .gone: return .gone
            case .permission: return .permission
            case .displays: return .displays
            case .windows: return .windows
            case .follow: return .follow
            }
        }
        switch context {
        case .thisMeeting:
            return live.map(map)
        case .atStart:
            var out: [Section] = [.share]
            // The display only matters for Whole screen; a window, app, whiteboard or Just me ignores it.
            // .app reads back as the whole screen.
            if hasTwoDisplays && (kind == .display || kind == .app) { out.append(.sharedDisplay) }
            if live.contains(.windows) { out.append(.windows) }
            if live.contains(.follow) { out.append(.follow) }
            return out
        }
    }

    /// The saved share after a tile; nil for "A window", which waits for a pick.
    static func applying(_ tile: ScreenPanelRules.Tile, to share: ShareTarget) -> ShareTarget? {
        var out = share
        switch tile {
        case .screen: out.kind = .display
        case .whiteboard: out.kind = .whiteboard
        case .camera: out.kind = .nothing
        case .window: return nil
        }
        return out
    }

    static func picking(bundleID: String, appName: String, title: String, in share: ShareTarget) -> ShareTarget {
        var out = share
        out.kind = .window
        out.appBundleID = bundleID
        out.appName = appName
        out.windowTitle = title
        return out
    }

    /// A saved One app is read back as the whole screen.
    static func readBack(_ share: ShareTarget) -> ShareTarget {
        var out = share
        if out.kind == .app { out.kind = .display }
        return out
    }

    static func isChosen(bundleID: String, title: String, in share: ShareTarget) -> Bool {
        share.kind == .window && share.appBundleID == bundleID && share.windowTitle == title
    }

    /// Live windows come under their app's heading; at start the rows are the apps themselves.
    static func groupsByApp(_ c: SharePopoutContext) -> Bool { c == .thisMeeting }
}

// MARK: - R34 Canvas honesty

enum CanvasShareMark: Equatable { case none, shared, notShared }

enum CanvasShareRules {
    static let sharedWords = "Shared"
    static let notSharedWords = "Not shared"

    /// What the piece says on My screen about the share. Whole screen says nothing: the piece's eye does.
    static func mark(piece: LayoutPiece, target: Visibility.Target) -> CanvasShareMark {
        if target == .wholeScreen { return .none }
        return Visibility.everyoneSees(piece: piece, target: target).isOn ? .shared : .notShared
    }

    /// A look only: the piece the meeting does not see is faded.
    static func fades(piece: LayoutPiece, target: Visibility.Target) -> Bool {
        !Visibility.everyoneSees(piece: piece, target: target).isOn
    }

    static func icon(_ mark: CanvasShareMark) -> VisibilitySymbol? {
        switch mark {
        case .none: return nil
        case .shared: return .everyoneSees(true)
        case .notShared: return .everyoneSees(false)
        }
    }
}

// MARK: - R35 Every piece inspector

enum PieceInspectorRules {
    enum Row: Hashable { case whoSees, shapeAndSize, app, opensAtStart, startsHidden, fillDisplay }
    enum MenuItem: Hashable { case closesOnStop, opensMinimised, reopenLastTabs, searchSuggestions, remove }

    static let maxRowsAtRest = 2

    /// The camera header's one readout: the shape's name and its pixel size on the main display.
    /// It reads the saved piece's shape (what the tiles show), never the live camera's.
    static func cameraReadout(shape: WebcamShape, widthFraction: Double, displayWidth: Double?) -> String {
        let name = shape.label
        guard shape != .presenterLarge, shape != .cutout, let displayWidth else { return name }
        let w = Int((widthFraction * displayWidth).rounded())
        let h = Int((Double(w) / (shape.cropsToSquare ? 1 : 16.0 / 9.0)).rounded())
        return "\(name) \u{00B7} \(w)\u{00D7}\(h)"
    }
    static let cameraRows: [Row] = [.whoSees, .shapeAndSize]

    static func rows(for kind: LayoutPiece.Kind, slot: LayoutSlot) -> [Row] {
        switch kind {
        case .chat, .roomScreen: return []
        case .meeting: return slot == .second ? [.fillDisplay, .startsHidden] : [.startsHidden]
        case .view: return [.startsHidden]
        case .app: return [.app, .opensAtStart]
        }
    }

    static func menu(for kind: LayoutPiece.Kind) -> [MenuItem] {
        guard case let .app(app) = kind else { return [.remove] }
        if app.bundleID == Visibility.builtInBrowserID { return [.closesOnStop, .reopenLastTabs, .searchSuggestions, .remove] }
        return [.closesOnStop, .opensMinimised, .remove]
    }

    /// What each hint paragraph said, now on hover.
    static func tooltip(for kind: LayoutPiece.Kind) -> String {
        switch kind {
        case .roomScreen:
            return "What the meeting sees, on the screen in the room. Greenroom\u{2019}s private windows are left out. Set that screen as an extended display, not mirrored."
        case .chat: return "The meeting chat window. It opens in this space when the meeting starts."
        case .meeting: return "The meeting window, in this space."
        case .view: return "One part of the meeting in its own window."
        case let .app(app):
            return app.bundleID == Visibility.builtInBrowserID
                ? "Greenroom\u{2019}s own browser: tabs, find in page, local history, no permissions to grant. Pick Chrome if you need extensions."
                : "Which app fills this space."
        }
    }

    static func readout(points: (w: Int, h: Int)) -> String { "\(points.w)\u{00D7}\(points.h)" }

    static func readoutHelp(columns: ClosedRange<Int>, rows: ClosedRange<Int>, points: (w: Int, h: Int)) -> String {
        "Columns \(columns.lowerBound)\u{2013}\(columns.upperBound), rows \(rows.lowerBound)\u{2013}\(rows.upperBound), \(points.w)\u{00D7}\(points.h) points"
    }

    static let cameraChoices: [CameraState] = CameraState.allCases

    static func cameraTip(_ state: CameraState) -> String { "\(state.name): \(state.detail)" }
}

// MARK: - R36 Home: the share is not the whole screen

enum ShareHintRules {
    enum FooterNote: Equatable { case room(String), hint(String), secondDisplay(String) }

    /// The longest label that fits one dock tile at the minimum width (about 70pt of 10.5pt text).
    static let maxTileChars = 12

    static func hint(kind: ShareTarget.Kind, appName: String) -> String? {
        let lead = "Arranges your screen. The meeting sees "
        switch kind {
        case .display, .app: return nil
        case .nothing: return lead + "just you."
        case .whiteboard: return lead + "the whiteboard."
        case .window: return lead + (appName.isEmpty ? "one window." : appName + ".")
        }
    }

    static func footerNote(room: String?, hint: String?, secondDisplay: String?) -> FooterNote? {
        if let room { return .room(room) }
        if let hint { return .hint(hint) }
        if let secondDisplay { return .secondDisplay(secondDisplay) }
        return nil
    }

    static func tileLabel(kind: ShareTarget.Kind, appName: String) -> String {
        switch kind {
        case .display, .app: return "Whole screen"
        case .whiteboard: return "Whiteboard"
        case .nothing: return "Just me"
        case .window:
            guard !appName.isEmpty else { return "A window" }
            guard appName.count > maxTileChars else { return appName }
            let cut = appName.prefix(maxTileChars - 1).trimmingCharacters(in: .whitespaces)
            return cut + "\u{2026}"
        }
    }
}
