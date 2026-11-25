//
//  LayoutTemplate.swift
//  Greenroom
//
//  The layout library: named templates built from placed pieces (Meeting,
//  Chat, apps), each stored as fractions of a display's usable area. Phase A
//  of .context/layout-creator-plan.md: saved and edited here, applied by the
//  runtime later.
//
//  Foundation only, on purpose. The unit tests compile this file on its own
//  (no app, no Zoom SDK), and the off-screen page render does the same.
//
//  Every field is decoded optionally, as WorkspaceLayout does, so an older or
//  partial file (a settings export, a hand edit) loads whatever it can.
//
import Foundation

// MARK: - Geometry primitives

/// A rectangle as 0...1 fractions of a display's usable area, origin at the
/// TOP-LEFT (the way the editor draws it and the way AX frames are measured).
struct UnitRect: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }

    static let full = UnitRect(x: 0, y: 0, w: 1, h: 1)

    /// Equal but for floating-point noise (`5 * (1.0 / 12)` is not `5.0 / 12`): what "unedited" detectors
    /// compare with, never `==`.
    func isClose(to other: UnitRect, tolerance: Double = 1e-9) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(w - other.w) <= tolerance && abs(h - other.h) <= tolerance
    }

    var maxX: Double { x + w }
    var maxY: Double { y + h }
    var midX: Double { x + w / 2 }
    var midY: Double { y + h / 2 }

    private enum CodingKeys: String, CodingKey { case x, y, w, h }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(x: (try? c.decodeIfPresent(Double.self, forKey: .x)) ?? 0,
                  y: (try? c.decodeIfPresent(Double.self, forKey: .y)) ?? 0,
                  w: (try? c.decodeIfPresent(Double.self, forKey: .w)) ?? 1,
                  h: (try? c.decodeIfPresent(Double.self, forKey: .h)) ?? 1)
    }
}

// MARK: - Pieces

/// One app placed in a layout. `bundleID` is a real bundle, or the built-in
/// browser's sentinel (AppCatalog.builtInBrowserID).
struct AppPiece: Codable, Equatable, Hashable {
    var bundleID: String
    var url: String
    var opensAtStart: Bool
    var closesOnStop: Bool
    /// The eye badge, off: at Start the app opens (or is placed) minimised, so it is
    /// not on the owner's screen. Another app only; Greenroom's own windows use
    /// "Starts hidden". Saved as `minimised`; old files read as false.
    var opensMinimised: Bool

    init(bundleID: String, url: String = "", opensAtStart: Bool = true, closesOnStop: Bool = false,
         opensMinimised: Bool = false) {
        self.bundleID = bundleID
        self.url = url
        self.opensAtStart = opensAtStart
        self.closesOnStop = closesOnStop
        self.opensMinimised = opensMinimised
    }

    private enum CodingKeys: String, CodingKey { case bundleID, url, opensAtStart, closesOnStop, opensMinimised = "minimised" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(bundleID: (try? c.decodeIfPresent(String.self, forKey: .bundleID)) ?? "",
                  url: (try? c.decodeIfPresent(String.self, forKey: .url)) ?? "",
                  opensAtStart: (try? c.decodeIfPresent(Bool.self, forKey: .opensAtStart)) ?? true,
                  closesOnStop: (try? c.decodeIfPresent(Bool.self, forKey: .closesOnStop)) ?? false,
                  opensMinimised: (try? c.decodeIfPresent(Bool.self, forKey: .opensMinimised)) ?? false)
    }
}

/// Whether the meeting-view pieces are offered and drawn. On by default; the
/// defaults key is the kill switch:
/// `defaults write com.sibhimanyu.greenroom meetingViews.enabled -bool false`
/// hides them again (the Add panel offers only the Meeting window and the runtime
/// skips view pieces at Start). Layouts that already hold view pieces still
/// load, draw and can be edited.
enum MeetingViewPieces {
    static let defaultsKey = "meetingViews.enabled"
    /// Tests set this; nil reads the default.
    static var override: Bool?
    static var enabled: Bool {
        if let override { return override }
        return (UserDefaults.standard.object(forKey: defaultsKey) as? Bool) ?? true
    }

    /// The Meeting group's tiles, as (id, title, kind): the window, then every
    /// view when they are enabled.
    static func addEntries(viewsEnabled: Bool)
        -> [(id: String, title: String, kind: LayoutPiece.Kind)] {
        var entries: [(id: String, title: String, kind: LayoutPiece.Kind)] = [
            ("meeting", "Meeting window",
             .meeting(fillsDisplay: false, startsHidden: false))]
        if viewsEnabled {
            entries += MeetingView.allCases.map { ("view:\($0.rawValue)", $0.title, .view($0, startsHidden: false)) }
        }
        return entries
    }
}

/// One part of the meeting as a window of its own (.context/meeting-views-plan.md).
/// Raw values are stored in saved layouts: never rename one.
enum MeetingView: String, Codable, CaseIterable, Hashable {
    case activeSpeaker, gallery, multiSpeaker, speakerStrip, selfView, people
    /// A shared screen alone, with no people around it.
    case sharedScreen
    /// One participant you pick, large, on a window of its own.
    case spotlight
    /// Raised hands in order, with the waiting room on top. No video.
    case handsUp

    var title: String {
        switch self {
        case .activeSpeaker: return "Active speaker"
        case .gallery: return "Gallery"
        case .multiSpeaker: return "Multi-speaker"
        case .speakerStrip: return "Speaker + strip"
        case .selfView: return "Self view"
        case .people: return "People list"
        case .sharedScreen: return "Shared screen"
        case .spotlight: return "Spotlight person"
        case .handsUp: return "Hands up"
        }
    }

    /// What it is for, in a few words, for the Add panel's tooltip.
    var blurb: String {
        switch self {
        case .activeSpeaker: return "Whoever is talking, large"
        case .gallery: return "Everyone in a grid, with pages"
        case .multiSpeaker: return "The last three who spoke"
        case .speakerStrip: return "The speaker with a strip of people"
        case .selfView: return "Your own picture"
        case .people: return "Participants, with actions"
        case .sharedScreen: return "Only the shared screen"
        case .spotlight: return "One person you choose, large"
        case .handsUp: return "Raised hands and the waiting room"
        }
    }

    /// Draws video, so it needs the SDK's render elements. The People list and
    /// Hands up are plain lists.
    var drawsVideo: Bool { self != .people && self != .handsUp }

    var symbol: String {
        switch self {
        case .activeSpeaker: return "person.crop.rectangle.fill"
        case .gallery: return "square.grid.3x2.fill"
        case .multiSpeaker: return "rectangle.split.3x1.fill"
        case .speakerStrip: return "rectangle.bottomthird.inset.filled"
        case .selfView: return "person.crop.circle.fill"
        case .people: return "person.2.fill"
        case .sharedScreen: return "display"
        case .spotlight: return "person.fill.viewfinder"
        case .handsUp: return "hand.raised.fill"
        }
    }

    /// Smallest size in points the view is usable at.
    var minimumPoints: CGSize {
        switch self {
        case .activeSpeaker: return CGSize(width: 240, height: 135)
        case .gallery: return CGSize(width: 320, height: 200)
        case .multiSpeaker: return CGSize(width: 360, height: 120)
        case .speakerStrip: return CGSize(width: 320, height: 240)
        case .selfView: return CGSize(width: 160, height: 90)
        case .people: return CGSize(width: 220, height: 240)
        case .sharedScreen: return CGSize(width: 320, height: 200)
        case .spotlight: return CGSize(width: 240, height: 135)
        case .handsUp: return CGSize(width: 240, height: 200)
        }
    }

    /// A first size when added from the palette, in grid cells.
    var defaultCells: (cols: Int, rows: Int) {
        switch self {
        case .activeSpeaker: return (4, 3)
        case .gallery: return (6, 5)
        case .multiSpeaker: return (6, 2)
        case .speakerStrip: return (5, 5)
        case .selfView: return (3, 2)
        case .people: return (3, 6)
        case .sharedScreen: return (6, 4)
        case .spotlight: return (4, 3)
        case .handsUp: return (3, 5)
        }
    }
}

struct LayoutPiece: Codable, Identifiable, Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        /// Greenroom's meeting window: the full
        /// window with toolbar and side panels, shown as "Meeting window".
        /// `fillsDisplay` is the Participants form: the whole display.
        case meeting(fillsDisplay: Bool, startsHidden: Bool)
        case chat
        case app(AppPiece)
        /// One part of the meeting in its own window. Needs custom UI.
        case view(MeetingView, startsHidden: Bool)
        /// What the meeting sees, on a screen in the room (RoomScreenWindow). Only
        /// ever on the second display of a two-display version.
        case roomScreen
    }

    var id: UUID
    var kind: Kind
    var rect: UnitRect
    /// "Show to everyone": Greenroom's own window for this piece (Meeting window,
    /// Chat, a meeting view) is let into the picture the meeting sees. On by
    /// default (owner, 2026-11-25: everything a layout places is visible);
    /// for another app it is its 📡 badge (kept out of everyone's picture on a
    /// whole-display share when off); fixed on for the Greenroom Browser.
    var showsToEveryone = LayoutPiece.defaultShowsToEveryone

    /// The default for a piece nobody has chosen for: a layout shows what it places.
    static let defaultShowsToEveryone = true

    init(id: UUID = UUID(), kind: Kind, rect: UnitRect, showsToEveryone: Bool = LayoutPiece.defaultShowsToEveryone) {
        self.id = id
        self.kind = kind
        self.rect = rect
        self.showsToEveryone = showsToEveryone
    }

    /// Whether this piece is one of Greenroom's own windows that can carry the
    /// switch (ShareableWindow.offersSwitch): the Meeting window, Chat, a view.
    /// Other apps' windows have a badge switch of their own (`Visibility.hiddenAppIDs`),
    /// not a window switch; the Greenroom Browser has neither.
    var offersShareSwitch: Bool {
        kind.app == nil && !Visibility.everyoneSees(piece: self, target: .wholeScreen).isFixed
    }

    private enum CodingKeys: String, CodingKey { case id, kind, rect, showsToEveryone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // No kind, no piece: the lossy array around this drops it.
        let kind = try c.decode(Kind.self, forKey: .kind)
        self.init(id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
                  kind: kind,
                  rect: (try? c.decodeIfPresent(UnitRect.self, forKey: .rect)) ?? .full,
                  showsToEveryone: (try? c.decodeIfPresent(Bool.self, forKey: .showsToEveryone)) ?? LayoutPiece.defaultShowsToEveryone)
    }
}

extension LayoutPiece.Kind: Codable {
    private enum CodingKeys: String, CodingKey { case type, fillsDisplay, startsHidden, app, view }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "meeting":
            self = .meeting(fillsDisplay: (try? c.decodeIfPresent(Bool.self, forKey: .fillsDisplay)) ?? false,
                            startsHidden: (try? c.decodeIfPresent(Bool.self, forKey: .startsHidden)) ?? false)
        case "chat":
            self = .chat
        case "app":
            self = .app((try? c.decodeIfPresent(AppPiece.self, forKey: .app)) ?? AppPiece(bundleID: ""))
        case "view":
            // An unknown view throws: the lossy array drops the piece, the way
            // an older build drops view pieces it has never heard of.
            self = .view(try c.decode(MeetingView.self, forKey: .view),
                         startsHidden: (try? c.decodeIfPresent(Bool.self, forKey: .startsHidden)) ?? false)
        case "roomScreen":
            // An older build has no such case: it throws below and its lossy array drops the piece.
            self = .roomScreen
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown piece kind")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .meeting(fills, hidden):
            try c.encode("meeting", forKey: .type)
            try c.encode(fills, forKey: .fillsDisplay)
            try c.encode(hidden, forKey: .startsHidden)
        case .chat:
            try c.encode("chat", forKey: .type)
        case let .app(app):
            try c.encode("app", forKey: .type)
            try c.encode(app, forKey: .app)
        case let .view(view, hidden):
            try c.encode("view", forKey: .type)
            try c.encode(view, forKey: .view)
            try c.encode(hidden, forKey: .startsHidden)
        case .roomScreen:
            try c.encode("roomScreen", forKey: .type)
        }
    }
}

extension LayoutPiece.Kind {
    var isRoomScreen: Bool { if case .roomScreen = self { return true } else { return false } }
    var isMeeting: Bool { if case .meeting = self { return true } else { return false } }
    var isChat: Bool { if case .chat = self { return true } else { return false } }
    var app: AppPiece? { if case let .app(a) = self { return a } else { return nil } }
    var view: MeetingView? { if case let .view(v, _) = self { return v } else { return nil } }
    var isView: Bool { view != nil }
    /// The Meeting window or one of the views: what "hide the meeting" acts on.
    var isMeetingSurface: Bool { isMeeting || isView }
}

/// Decodes an array, dropping any element that will not decode.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Templates

/// Where a set of pieces lives: the main display's arrangement or the second one's
/// (ADR 0002: one arrangement per display).
enum LayoutSlot: String, Codable, Hashable, CaseIterable {
    case main, second
}

/// The optional second-display arrangement, used only while that display is connected.
/// (The name is the saved key's; the main arrangement is `LayoutTemplate.oneDisplay`.)
struct TwoDisplay: Codable, Equatable {
    var second: [LayoutPiece]
    /// A display UUID (DisplayResolver.uuidString), "" = the first display that
    /// is not the main one.
    var secondUUID: String
    /// "Everyone sees": the display the meeting sees and recordings film, `.main` or
    /// `.second`. Old files have none and keep the main display. See `LayoutSharedDisplay`.
    var sharedSlot: LayoutSlot = .main
    /// Read from a file an older build wrote (its separate two-display main arrangement), only so
    /// the one-arrangement migration can keep it (R25.4, R27). Never written, never compared.
    var legacyMain: [LayoutPiece]?

    init(second: [LayoutPiece] = [], secondUUID: String = "", sharedSlot: LayoutSlot = .main,
         legacyMain: [LayoutPiece]? = nil) {
        self.second = second
        self.secondUUID = secondUUID
        self.sharedSlot = sharedSlot == .second ? .second : .main
        self.legacyMain = legacyMain
    }

    static func == (a: TwoDisplay, b: TwoDisplay) -> Bool {
        a.second == b.second && a.secondUUID == b.secondUUID && a.sharedSlot == b.sharedSlot
    }

    private enum CodingKeys: String, CodingKey { case main, second, secondUUID
        case sharedSlot = "sharedDisplay"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(second: ((try? c.decodeIfPresent([Lossy<LayoutPiece>].self, forKey: .second)) ?? [])
                    .compactMap(\.value),
                  secondUUID: (try? c.decodeIfPresent(String.self, forKey: .secondUUID)) ?? "",
                  sharedSlot: (try? c.decodeIfPresent(LayoutSlot.self, forKey: .sharedSlot)) ?? .main,
                  legacyMain: (try? c.decodeIfPresent([Lossy<LayoutPiece>].self, forKey: .main))?.compactMap(\.value))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(second, forKey: .second)
        try c.encode(secondUUID, forKey: .secondUUID)
        try c.encode(sharedSlot, forKey: .sharedSlot)
    }
}

struct LayoutTemplate: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Which starter this began as ("teach-browser", "meeting-chat"), so
    /// a reset can find it again after a rename. nil for your own.
    var starter: String?
    /// The main-display arrangement (ADR 0002). The name and key are the old "one display" ones, kept so
    /// every saved file reads.
    var oneDisplay: [LayoutPiece]
    /// The second-display arrangement, if the layout has one; ignored while that display is not connected.
    var twoDisplays: TwoDisplay?
    /// The camera's spot, size and shape for this layout. nil: the global settings stand
    /// (old files, and layouts made since the migration).
    var camera: LayoutCamera?
    /// What this layout shares at Start. nil: the global share target stands.
    var share: ShareTarget?

    init(id: UUID = UUID(), name: String, starter: String? = nil,
         oneDisplay: [LayoutPiece] = [], twoDisplays: TwoDisplay? = nil,
         camera: LayoutCamera? = nil, share: ShareTarget? = nil) {
        self.id = id
        self.name = name
        self.starter = starter
        self.oneDisplay = oneDisplay
        self.twoDisplays = twoDisplays
        self.camera = camera
        self.share = share
    }

    private enum CodingKeys: String, CodingKey { case id, name, starter, oneDisplay, twoDisplays, camera, share }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
                  name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled layout",
                  starter: try? c.decodeIfPresent(String.self, forKey: .starter),
                  oneDisplay: ((try? c.decodeIfPresent([Lossy<LayoutPiece>].self, forKey: .oneDisplay)) ?? [])
                    .compactMap(\.value),
                  twoDisplays: try? c.decodeIfPresent(TwoDisplay.self, forKey: .twoDisplays),
                  camera: try? c.decodeIfPresent(LayoutCamera.self, forKey: .camera),
                  share: try? c.decodeIfPresent(ShareTarget.self, forKey: .share))
    }

    // MARK: Pieces by slot

    func pieces(for slot: LayoutSlot) -> [LayoutPiece] {
        switch slot {
        case .main: return oneDisplay
        case .second: return twoDisplays?.second ?? []
        }
    }

    mutating func setPieces(_ pieces: [LayoutPiece], for slot: LayoutSlot) {
        switch slot {
        case .main: oneDisplay = pieces
        case .second: twoDisplays?.second = pieces
        }
    }

    /// Every piece of the layout with the display it sits on (the one place that walks the slots).
    var placedPieces: [(slot: LayoutSlot, piece: LayoutPiece)] {
        LayoutSlot.allCases.flatMap { slot in pieces(for: slot).map { (slot: slot, piece: $0) } }
    }

    /// Every piece of the layout, both arrangements: Meeting and Chat are single windows, so their
    /// limits count across both.
    var allPieces: [LayoutPiece] {
        pieces(for: .main) + pieces(for: .second)
    }

    var pieceCount: Int { oneDisplay.count + (twoDisplays?.second.count ?? 0) }

    static let maxApps = 4

    /// What a version may hold: one Meeting window, one Chat, up to four apps,
    /// one piece per app (two windows of the same app cannot be told apart) and
    /// at most one of each view. The Meeting window already has a gallery and a
    /// speaker with strip, so it excludes those two views; Active speaker
    /// excludes Speaker + strip, which contains it. Everything else coexists: the
    /// People list and Hands up, a Shared screen beside the Meeting window, a
    /// Spotlight beside Active speaker.
    func canAdd(_ kind: LayoutPiece.Kind, to slot: LayoutSlot) -> Bool {
        // Leave my windows alone stays clean: + copies it into "My layout" first (LayoutLibrary.forkLeaveAlone).
        guard movesWindows else { return false }
        let existing = allPieces
        let views = Set(existing.compactMap { $0.kind.view })
        let hasMeeting = existing.contains { $0.kind.isMeeting }
        switch kind {
        case .meeting: return !hasMeeting && !views.contains(.gallery) && !views.contains(.speakerStrip)
        case let .view(view, _):
            guard !views.contains(view) else { return false }
            switch view {
            case .gallery: return !hasMeeting
            case .speakerStrip: return !hasMeeting && !views.contains(.activeSpeaker)
            case .activeSpeaker: return !views.contains(.speakerStrip)
            case .multiSpeaker, .selfView, .people, .sharedScreen, .spotlight, .handsUp: return true
            }
        case .chat: return !existing.contains { $0.kind.isChat }
        case .roomScreen:
            return RoomScreenRules.canAdd(to: slot, existing: existing.map(\.kind))
                && !(slot == .second && twoDisplays?.sharedSlot == .second)
        case let .app(app):
            let apps = existing.compactMap { $0.kind.app }
            return apps.count < Self.maxApps && !apps.contains { $0.bundleID == app.bundleID }
        }
    }

    // MARK: Apps

    /// The first App piece's bundle ID, in the order a person reads the layout:
    /// one display, then the main display of a pair.
    var firstAppBundleID: String? {
        (oneDisplay + (twoDisplays?.second ?? [])).lazy.compactMap { $0.kind.app?.bundleID }.first
    }

    /// Puts another app in the place of one (onboarding's single picker), in every
    /// version of the layout. Its website and Start / Stop choices stay.
    mutating func replaceApp(_ old: String, with new: String) {
        func swap(_ pieces: [LayoutPiece]) -> [LayoutPiece] {
            pieces.map { piece in
                guard var app = piece.kind.app, app.bundleID == old else { return piece }
                app.bundleID = new
                var copy = piece
                copy.kind = .app(app)
                return copy
            }
        }
        oneDisplay = swap(oneDisplay)
        if var two = twoDisplays {
            two.second = swap(two.second)
            twoDisplays = two
        }
    }

    // MARK: The second display

    /// R25.3: an empty second-display arrangement; nothing moves out of main.
    mutating func addSecondDisplay() {
        guard twoDisplays == nil else { return }
        twoDisplays = TwoDisplay()
    }

    /// R25.3: drops the second-display arrangement with its pieces.
    mutating func removeSecondDisplay() {
        twoDisplays = nil
    }
}

// MARK: - The library

struct LayoutLibrary: Codable, Equatable {
    var version = 1
    var templates: [LayoutTemplate]
    /// The Start layout. There is no None (Q3): nil only in a library without Leave my windows alone.
    var activeID: UUID?

    init(templates: [LayoutTemplate] = [], activeID: UUID? = nil) {
        self.templates = templates
        self.activeID = activeID
    }

    private enum CodingKeys: String, CodingKey { case version, templates, activeID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let templates = ((try? c.decodeIfPresent([Lossy<LayoutTemplate>].self, forKey: .templates)) ?? [])
            .compactMap(\.value)
        let active = try? c.decodeIfPresent(UUID.self, forKey: .activeID)
        self.init(templates: templates,
                  activeID: templates.contains { $0.id == active } ? active : nil)
        // A saved choice that is missing or whose template is gone means Leave my windows alone (Q3).
        ensureActive()
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
    }

    var active: LayoutTemplate? { activeID.flatMap(template(id:)) }

    func template(id: UUID) -> LayoutTemplate? { templates.first { $0.id == id } }

    // MARK: Editing

    mutating func select(_ id: UUID?) {
        activeID = id.flatMap { template(id: $0) }?.id
        ensureActive()
    }

    mutating func update(_ template: LayoutTemplate) {
        guard let i = templates.firstIndex(where: { $0.id == template.id }) else { return }
        templates[i] = template
    }

    @discardableResult
    mutating func addBlank() -> UUID {
        let n = templates.count + 1
        var name = "Layout \(n)"
        var k = n
        while templates.contains(where: { $0.name == name }) { k += 1; name = "Layout \(k)" }
        let t = LayoutTemplate(name: name, camera: LayoutCamera.rounded, share: ShareTarget())
        templates.append(t)
        return t.id
    }

    @discardableResult
    mutating func duplicate(_ id: UUID) -> UUID? {
        guard let i = templates.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = templates[i]
        copy.id = UUID()
        copy.name = templates[i].name + " copy"
        copy.starter = nil
        func fresh(_ pieces: [LayoutPiece]) -> [LayoutPiece] {
            pieces.map { var p = $0; p.id = UUID(); return p }
        }
        copy.oneDisplay = fresh(copy.oneDisplay)
        if var two = copy.twoDisplays {
            two.second = fresh(two.second)
            copy.twoDisplays = two
        }
        templates.insert(copy, at: i + 1)
        return copy.id
    }

    mutating func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        ensureActive()
    }

    /// An empty name is ignored: a layout with no name cannot be found again.
    mutating func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[i].name = trimmed
    }

    // MARK: Starters

    static let teachFromBrowser = "teach-browser"
    static let meetingAndChat = "meeting-chat"
    static let rajMode = "raj"
    /// The starters every install had before the list could grow. A library
    /// saved without a `knownStarters` record is taken to have known these.
    static let originalStarterKeys = [teachFromBrowser, meetingAndChat]
    /// AppCatalog.builtInBrowserID, repeated because this file must not need AppKit.
    static let builtInBrowserBundleID = "com.sibhimanyu.greenroom.browser"

    /// The ordinary, editable templates every library begins with, in the order the strip shows
    /// them: the three built-ins (LayoutBuiltIns.swift).
    static func starters() -> [LayoutTemplate] { builtIns() }


    /// How many layouts are yours: everything that did not begin as a starter.
    /// A migrated "Your previous layout" counts.
    var userLayoutCount: Int { templates.filter { $0.starter == nil }.count }

    /// Replaces the whole library with the default starters and sets the Start
    /// layout to Leave my windows alone. Your own layouts are removed.
    mutating func resetToDefaults() {
        templates = Self.starters()
        activeID = nil
        ensureActive()
    }

    /// Appends any starter whose key is not in `known` (a starter added by a
    /// newer version), next to None in the order the starters list gives, and
    /// leaves the Start layout alone. Returns whether anything was added.
    @discardableResult
    mutating func addStarters(notIn known: Set<String>) -> Bool {
        var added = false
        for (order, fresh) in Self.starters().enumerated() {
            guard let key = fresh.starter, !known.contains(key),
                  !templates.contains(where: { $0.starter == key }) else { continue }
            var owned = fresh
            owned.camera = owned.camera ?? LayoutCamera()
            owned.share = owned.share ?? ShareTarget()
            templates.insert(owned, at: min(templates.count, order))
            added = true
        }
        return added
    }

    /// The starter with this key, restoring it first if it was deleted.
    @discardableResult
    mutating func starterID(_ key: String) -> UUID? {
        if let t = templates.first(where: { $0.starter == key }) { return t.id }
        guard var fresh = Self.starters().first(where: { $0.starter == key }) else { return nil }
        fresh.camera = fresh.camera ?? LayoutCamera()
        fresh.share = fresh.share ?? ShareTarget()
        templates.append(fresh)
        return fresh.id
    }
}

// MARK: - Storage and migration

extension LayoutLibrary {
    static let defaultsKey = "layoutLibrary"
    static let oneArrangementMigratedKey = "layoutLibrary.oneArrangementMigrated"

    /// One time, with its own key, set only after `save` worked (ADR 0002, R27): `oneDisplay` is the main
    /// arrangement and `twoDisplays.second` the second. Where an old two-display main differed from
    /// `oneDisplay` in pieces or their settings, it is kept as the owner's own layout "<name> (old
    /// two-display)" just after the original, with that main plus the same second. Raj San Mode exactly as
    /// the last build shipped it simply becomes the new one (camera, share and display choice are kept).
    /// Returns whether it ran and saved.
    @discardableResult
    mutating func migrateOneArrangement(defaults: UserDefaults, save: (LayoutLibrary) -> Bool) -> Bool {
        guard !defaults.bool(forKey: Self.oneArrangementMigratedKey) else { return false }
        func reissued(_ pieces: [LayoutPiece]) -> [LayoutPiece] {
            pieces.map { var p = $0; p.id = UUID(); return p }
        }
        var out: [LayoutTemplate] = []
        for original in templates {
            var t = original
            let old = t.twoDisplays?.legacyMain
            t.twoDisplays?.legacyMain = nil
            guard let old, !Self.sameArrangement(old, t.oneDisplay) else { out.append(t); continue }
            if t.starter == Self.rajMode, Self.isOldShippedRaj(main: t.oneDisplay, twoDisplayMain: old, second: t.twoDisplays?.second ?? []),
               let fresh = Self.shipped(Self.rajMode) {
                t.oneDisplay = fresh.oneDisplay
                t.twoDisplays?.second = fresh.twoDisplays?.second ?? []
                out.append(t)
                continue
            }
            var copy = t
            copy.id = UUID()
            copy.starter = nil
            copy.name = t.name + " (old two-display)"
            copy.oneDisplay = reissued(old)
            copy.twoDisplays?.second = reissued(t.twoDisplays?.second ?? [])
            out.append(t)
            out.append(copy)
        }
        templates = out
        guard save(self) else { return false }
        defaults.set(true, forKey: Self.oneArrangementMigratedKey)
        return true
    }

    /// Same pieces in the same order: kind, rectangle and eye (ids are ignored).
    static func sameArrangement(_ a: [LayoutPiece], _ b: [LayoutPiece]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            $0.kind == $1.kind && $0.rect.isClose(to: $1.rect) && $0.showsToEveryone == $1.showsToEveryone
        }
    }

    /// Raj San Mode as the build before ADR 0002 shipped it: three pieces on the laptop, browser and
    /// Chat on the main display of the pair, a full-display Meeting on the second.
    private static func isOldShippedRaj(main: [LayoutPiece], twoDisplayMain: [LayoutPiece], second: [LayoutPiece]) -> Bool {
        let third = 1.0 / 12
        func browser() -> LayoutPiece {
            LayoutPiece(kind: .app(AppPiece(bundleID: builtInBrowserBundleID)), rect: UnitRect(x: 0, y: 0, w: 9 * third, h: 1))
        }
        let speaker = LayoutPiece(kind: .view(.activeSpeaker, startsHidden: false), rect: UnitRect(x: 9 * third, y: 0, w: 3 * third, h: 5 * third))
        let chatBelow = LayoutPiece(kind: .chat, rect: UnitRect(x: 9 * third, y: 5 * third, w: 3 * third, h: 7 * third))
        let chatFull = LayoutPiece(kind: .chat, rect: UnitRect(x: 9 * third, y: 0, w: 3 * third, h: 1))
        let meeting = LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)
        return sameArrangement(main, [browser(), speaker, chatBelow])
            && sameArrangement(twoDisplayMain, [browser(), chatFull])
            && sameArrangement(second, [meeting])
    }

    static func load(from defaults: UserDefaults) -> LayoutLibrary? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(LayoutLibrary.self, from: $0) }
    }

    /// Writes the library. A failure is logged and returned, never swallowed: a migration
    /// sets its key only when this says true.
    @discardableResult
    func save(to defaults: UserDefaults) -> Bool {
        do {
            defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
            return true
        } catch {
            NSLog("Greenroom: could not save the layout library: \(error)")
            return false
        }
    }

    /// The saved library, or - the first time - the starters plus
    /// "Your previous layout" built from today's settings (written back, so it
    /// happens once). The old keys are left exactly as they were.
    static func loadOrMigrate(from defaults: UserDefaults, defaultSiteURL: String) -> LayoutLibrary {
        if var saved = load(from: defaults) {
            // ADR 0002, once: one arrangement per display. First, while the file's old two-display
            // mains are still in memory. Saves itself and sets its own key.
            saved.migrateOneArrangement(defaults: defaults, save: { $0.save(to: defaults) })
            // A starter this library has never had is added once; one the person
            // deleted is in `known` already and stays gone.
            let known = defaults.stringArray(forKey: knownStartersKey).map(Set.init)
                ?? Set(originalStarterKeys)
            var changed = saved.addStarters(notIn: known)
            // P9, once: the new built-ins, None becomes Leave my windows alone. Saves itself and sets its own key.
            saved.migrateBuiltInsV2(defaults: defaults, legacyCamera: .global(from: defaults),
                                    legacyShare: LayoutCamera.globalShare(from: defaults), save: { $0.save(to: defaults) })
            // Q28, once, after the two above: Teach, Talk and Present become the owner's own; the three built-ins lead.
            saved.migrateThreeBuiltIns(defaults: defaults, save: { $0.save(to: defaults) })
            // The old default was hidden; saved layouts hold it explicitly. Flip once.
            if !defaults.bool(forKey: shownToEveryoneMigratedKey) {
                saved.showEverythingToEveryone()
                changed = true
            }
            // Pieces saved before other apps had a real 📡 switch carry false; once, turn it on.
            if !defaults.bool(forKey: appsShownMigratedKey) {
                saved.showAppsToEveryone()
                changed = true
            }
            // Raj Mode became Raj San Mode; a name the owner changed is left alone.
            if !defaults.bool(forKey: rajRenamedKey), saved.renameRajMode() { changed = true }
            // The keys follow a successful save (R16.1); with nothing to change they are simply set.
            if !changed || saved.save(to: defaults) {
                defaults.set(true, forKey: shownToEveryoneMigratedKey)
                defaults.set(true, forKey: appsShownMigratedKey)
                defaults.set(true, forKey: rajRenamedKey)
            }
            recordKnownStarters(in: defaults)
            return saved
        }
        let library = firstRun(legacy: LegacyLayoutSettings.read(from: defaults, defaultSiteURL: defaultSiteURL))
        if library.save(to: defaults) {
            defaults.set(true, forKey: oneArrangementMigratedKey)
            defaults.set(true, forKey: builtInsV2MigratedKey)
            defaults.set(true, forKey: threeBuiltInsMigratedKey)
            defaults.set(true, forKey: shownToEveryoneMigratedKey)
            defaults.set(true, forKey: appsShownMigratedKey)
            defaults.set(true, forKey: rajRenamedKey)
        }
        recordKnownStarters(in: defaults)
        return library
    }

    /// Set once the one-time "show to everyone" flip has run; never cleared, so
    /// a piece hidden afterwards stays hidden.
    static let shownToEveryoneMigratedKey = "layoutLibrary.shownToEveryoneMigrated"
    static let appsShownMigratedKey = "layoutLibrary.appsShownToEveryoneMigrated"
    /// Set once "Raj Mode" has become "Raj San Mode" (after a successful save).
    static let rajRenamedKey = "layoutLibrary.rajSanModeRenamed"

    /// Pure: the starter `raj` whose name is still exactly "Raj Mode" is renamed. True if it changed.
    @discardableResult
    mutating func renameRajMode() -> Bool {
        var changed = false
        for i in templates.indices where templates[i].starter == Self.rajMode && templates[i].name == "Raj Mode" {
            templates[i].name = "Raj San Mode"
            changed = true
        }
        return changed
    }

    /// Pure: every piece that offers the switch (Meeting window, Chat, views), in
    /// every template, one- and two-display, is set to shown.
    mutating func showEverythingToEveryone() {
        func flip(_ pieces: [LayoutPiece]) -> [LayoutPiece] {
            pieces.map { var p = $0; if p.offersShareSwitch { p.showsToEveryone = true }; return p }
        }
        for i in templates.indices {
            templates[i].oneDisplay = flip(templates[i].oneDisplay)
            if var two = templates[i].twoDisplays {
                two.second = flip(two.second)
                templates[i].twoDisplays = two
            }
        }
    }

    /// Pure: every app piece (other than the Greenroom Browser, which is fixed on anyway)
    /// has its 📡 turned on, in every template and version.
    mutating func showAppsToEveryone() {
        func flip(_ pieces: [LayoutPiece]) -> [LayoutPiece] {
            pieces.map { var p = $0; if p.kind.app != nil { p.showsToEveryone = true }; return p }
        }
        for i in templates.indices {
            templates[i].oneDisplay = flip(templates[i].oneDisplay)
            if var two = templates[i].twoDisplays {
                two.second = flip(two.second)
                templates[i].twoDisplays = two
            }
        }
    }

    /// Every starter key this build knows, so a later build can tell which are new.
    static let knownStartersKey = "layoutLibrary.knownStarters"

    private static func recordKnownStarters(in defaults: UserDefaults) {
        defaults.set(starters().compactMap(\.starter), forKey: knownStartersKey)
    }

    static func firstRun(legacy: LegacyLayoutSettings) -> LayoutLibrary {
        var library = LayoutLibrary(templates: starters())
        if let previous = legacy.asTemplate() {
            library.templates.append(previous)
            if legacy.arrangeWindowsOnStart { library.activeID = previous.id }
        }
        library.ensureActive()
        return library
    }
}

/// Today's layout settings, as plain values: WorkspaceLayout's JSON plus the
/// keys beside it. Read here rather than through WorkspaceLayout so this file
/// stays free of AppKit; the clamping below mirrors WorkspaceLayout's.
struct LegacyLayoutSettings: Equatable {
    var arrangeWindowsOnStart = false
    var mainFraction = 0.5
    var mainOnLeft = true
    var sideShowsZoomTile = true
    var sideShowsChat = true
    var zoomSlotRatio = 0.4
    var mainAppBundleID = LegacyLayoutSettings.chromeBundleID
    var mainAppURL = ""
    var mainAppOnStart = true
    var browserClosesOnStop = false
    var peopleViewOnStart = false
    var peopleViewDisplayUUID = ""
    var quickHide = true

    static let chromeBundleID = "com.google.Chrome"

    private struct StoredWorkspaceLayout: Decodable {
        var mainFraction: Double?
        var mainOnLeft: Bool?
        var sideShowsZoomTile: Bool?
        var sideShowsChat: Bool?
        var zoomSlotRatio: Double?
        var arrangeWindowsOnStart: Bool?
        var split: String?
    }

    /// `defaultSiteURL` is what a fresh install's URL field holds (AppLinks.site):
    /// that value means "never changed", not "a website you chose".
    static func read(from defaults: UserDefaults, defaultSiteURL: String) -> LegacyLayoutSettings {
        var s = LegacyLayoutSettings()
        if let data = defaults.data(forKey: "workspaceLayout"),
           let stored = try? JSONDecoder().decode(StoredWorkspaceLayout.self, from: data) {
            let legacySplit: Double? = {
                switch stored.split {
                case "half": return 0.5
                case "twoThirds": return 2.0 / 3.0
                case "threeQuarters": return 0.75
                default: return nil
                }
            }()
            s.mainFraction = stored.mainFraction ?? legacySplit ?? 0.5
            s.mainOnLeft = stored.mainOnLeft ?? true
            s.sideShowsZoomTile = stored.sideShowsZoomTile ?? true
            s.sideShowsChat = stored.sideShowsChat ?? true
            s.zoomSlotRatio = stored.zoomSlotRatio ?? 0.4
            s.arrangeWindowsOnStart = stored.arrangeWindowsOnStart ?? false
        } else if let raw = defaults.string(forKey: "chromeLayout") {
            // The Chrome-only era's three fixed splits, which WorkspaceLayout used
            // to map on load (nothing loads it any more).
            switch raw {
            case "rightHalf": s.mainOnLeft = false
            case "leftThreeQuarters": s.mainFraction = 0.75
            default: break
            }
        }
        s.mainAppBundleID = defaults.string(forKey: "mainAppBundleID") ?? chromeBundleID
        s.mainAppURL = defaults.string(forKey: "mainAppURL") ?? defaults.string(forKey: "chromeURL") ?? defaultSiteURL
        s.mainAppOnStart = (defaults.object(forKey: "mainAppOnStart") as? Bool)
            ?? (defaults.object(forKey: "chromeOnStart") as? Bool) ?? true
        s.browserClosesOnStop = defaults.bool(forKey: "browserClosesOnStop")
        s.peopleViewOnStart = defaults.bool(forKey: "peopleViewOnStart")
        s.peopleViewDisplayUUID = defaults.string(forKey: "peopleViewDisplayUUID") ?? ""
        s.quickHide = (defaults.object(forKey: "speakerTileShortcutEnabled") as? Bool) ?? true
        s.defaultSiteURL = defaultSiteURL
        return s
    }

    /// Carried so `isDefault` can tell a chosen website from the shipped one.
    var defaultSiteURL = ""

    var clampedMainFraction: Double { min(max(mainFraction, 0.35), 0.85) }

    /// The Zoom tile's share of the side column's height.
    var effectiveZoomSlotRatio: Double {
        guard sideShowsZoomTile else { return 0 }
        return sideShowsChat ? min(max(zoomSlotRatio, 0.1), 1.0) : 1.0
    }

    /// True when nothing here differs from a Mac nobody has configured, in
    /// which case there is no "previous layout" worth keeping.
    var isDefault: Bool {
        !arrangeWindowsOnStart
            && abs(mainFraction - 0.5) < 1e-9 && mainOnLeft
            && sideShowsZoomTile && sideShowsChat && abs(zoomSlotRatio - 0.4) < 1e-9
            && mainAppBundleID == Self.chromeBundleID
            && mainAppURL == defaultSiteURL
            && mainAppOnStart
            && !browserClosesOnStop
            && !peopleViewOnStart
    }

    /// "Your previous layout", or nil when the settings are the defaults.
    func asTemplate() -> LayoutTemplate? {
        guard !isDefault else { return nil }
        let f = clampedMainFraction
        let appRect = UnitRect(x: mainOnLeft ? 0 : 1 - f, y: 0, w: f, h: 1)
        let sideX = mainOnLeft ? f : 0
        let sideW = 1 - f
        let ratio = effectiveZoomSlotRatio

        var app: [LayoutPiece] = []
        if !mainAppBundleID.isEmpty {
            app.append(LayoutPiece(kind: .app(AppPiece(bundleID: mainAppBundleID, url: mainAppURL,
                                                       opensAtStart: mainAppOnStart,
                                                       closesOnStop: browserClosesOnStop)),
                                   rect: appRect))
        }
        let hidden = quickHide

        // One display: the app, then the Meeting at the top of the column and
        // the Chat under it.
        var one = app
        if sideShowsZoomTile {
            one.append(LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: hidden),
                                   rect: UnitRect(x: sideX, y: 0, w: sideW, h: ratio)))
        }
        if sideShowsChat {
            let top = sideShowsZoomTile ? ratio : 0
            one.append(LayoutPiece(kind: .chat, rect: UnitRect(x: sideX, y: top, w: sideW, h: 1 - top)))
        }

        var template = LayoutTemplate(name: "Your previous layout", oneDisplay: one)
        if peopleViewOnStart {
            // The participant view was the whole second display; the Chat takes
            // the full column on the main one (ADR 0002: that is the main arrangement now).
            var main = app
            if sideShowsChat {
                main.append(LayoutPiece(kind: .chat, rect: UnitRect(x: sideX, y: 0, w: sideW, h: 1)))
            }
            template.oneDisplay = main
            template.twoDisplays = TwoDisplay(
                second: [LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)],
                secondUUID: peopleViewDisplayUUID)
        }
        return template
    }
}
