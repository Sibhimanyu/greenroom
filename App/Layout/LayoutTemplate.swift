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

    init(bundleID: String, url: String = "", opensAtStart: Bool = true, closesOnStop: Bool = false) {
        self.bundleID = bundleID
        self.url = url
        self.opensAtStart = opensAtStart
        self.closesOnStop = closesOnStop
    }

    private enum CodingKeys: String, CodingKey { case bundleID, url, opensAtStart, closesOnStop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(bundleID: (try? c.decodeIfPresent(String.self, forKey: .bundleID)) ?? "",
                  url: (try? c.decodeIfPresent(String.self, forKey: .url)) ?? "",
                  opensAtStart: (try? c.decodeIfPresent(Bool.self, forKey: .opensAtStart)) ?? true,
                  closesOnStop: (try? c.decodeIfPresent(Bool.self, forKey: .closesOnStop)) ?? false)
    }
}

struct LayoutPiece: Codable, Identifiable, Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        /// Greenroom's meeting window (Zoom's own with custom UI off).
        /// `fillsDisplay` is the Participants form: the whole display.
        case meeting(fillsDisplay: Bool, startsHidden: Bool)
        case chat
        case app(AppPiece)
    }

    var id: UUID
    var kind: Kind
    var rect: UnitRect

    init(id: UUID = UUID(), kind: Kind, rect: UnitRect) {
        self.id = id
        self.kind = kind
        self.rect = rect
    }

    private enum CodingKeys: String, CodingKey { case id, kind, rect }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // No kind, no piece: the lossy array around this drops it.
        let kind = try c.decode(Kind.self, forKey: .kind)
        self.init(id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
                  kind: kind,
                  rect: (try? c.decodeIfPresent(UnitRect.self, forKey: .rect)) ?? .full)
    }
}

extension LayoutPiece.Kind: Codable {
    private enum CodingKeys: String, CodingKey { case type, fillsDisplay, startsHidden, app }

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
        }
    }
}

extension LayoutPiece.Kind {
    var isMeeting: Bool { if case .meeting = self { return true } else { return false } }
    var isChat: Bool { if case .chat = self { return true } else { return false } }
    var app: AppPiece? { if case let .app(a) = self { return a } else { return nil } }
}

/// Decodes an array, dropping any element that will not decode.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: - Templates

/// Where a set of pieces lives: the only display, or the main / second one of
/// a two-display version.
enum LayoutSlot: String, Codable, Hashable {
    case one, main, second
}

struct TwoDisplay: Codable, Equatable {
    var main: [LayoutPiece]
    var second: [LayoutPiece]
    /// A display UUID (DisplayResolver.uuidString), "" = the first display that
    /// is not the main one.
    var secondUUID: String

    init(main: [LayoutPiece] = [], second: [LayoutPiece] = [], secondUUID: String = "") {
        self.main = main
        self.second = second
        self.secondUUID = secondUUID
    }

    private enum CodingKeys: String, CodingKey { case main, second, secondUUID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(main: ((try? c.decodeIfPresent([Lossy<LayoutPiece>].self, forKey: .main)) ?? [])
                    .compactMap(\.value),
                  second: ((try? c.decodeIfPresent([Lossy<LayoutPiece>].self, forKey: .second)) ?? [])
                    .compactMap(\.value),
                  secondUUID: (try? c.decodeIfPresent(String.self, forKey: .secondUUID)) ?? "")
    }
}

struct LayoutTemplate: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Which starter this began as ("teach-browser", "meeting-chat"), so
    /// "Restore starters" can find it again after a rename. nil for your own.
    var starter: String?
    var oneDisplay: [LayoutPiece]
    var twoDisplays: TwoDisplay?

    init(id: UUID = UUID(), name: String, starter: String? = nil,
         oneDisplay: [LayoutPiece] = [], twoDisplays: TwoDisplay? = nil) {
        self.id = id
        self.name = name
        self.starter = starter
        self.oneDisplay = oneDisplay
        self.twoDisplays = twoDisplays
    }

    private enum CodingKeys: String, CodingKey { case id, name, starter, oneDisplay, twoDisplays }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
                  name: (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled layout",
                  starter: try? c.decodeIfPresent(String.self, forKey: .starter),
                  oneDisplay: ((try? c.decodeIfPresent([Lossy<LayoutPiece>].self, forKey: .oneDisplay)) ?? [])
                    .compactMap(\.value),
                  twoDisplays: try? c.decodeIfPresent(TwoDisplay.self, forKey: .twoDisplays))
    }

    // MARK: Pieces by slot

    func pieces(for slot: LayoutSlot) -> [LayoutPiece] {
        switch slot {
        case .one: return oneDisplay
        case .main: return twoDisplays?.main ?? []
        case .second: return twoDisplays?.second ?? []
        }
    }

    mutating func setPieces(_ pieces: [LayoutPiece], for slot: LayoutSlot) {
        switch slot {
        case .one: oneDisplay = pieces
        case .main: twoDisplays?.main = pieces
        case .second: twoDisplays?.second = pieces
        }
    }

    /// Every piece of the version the slot belongs to: one display, or both of
    /// a pair. Meeting and Chat are single windows, so their limits count
    /// across the pair.
    func piecesInVersion(of slot: LayoutSlot) -> [LayoutPiece] {
        slot == .one ? oneDisplay : pieces(for: .main) + pieces(for: .second)
    }

    var pieceCount: Int { oneDisplay.count + (twoDisplays.map { $0.main.count + $0.second.count } ?? 0) }

    static let maxApps = 4

    /// What a version may hold: one Meeting, one Chat, up to four apps, one
    /// piece per app (two windows of the same app cannot be told apart).
    func canAdd(_ kind: LayoutPiece.Kind, to slot: LayoutSlot) -> Bool {
        let existing = piecesInVersion(of: slot)
        switch kind {
        case .meeting: return !existing.contains { $0.kind.isMeeting }
        case .chat: return !existing.contains { $0.kind.isChat }
        case let .app(app):
            let apps = existing.compactMap { $0.kind.app }
            return apps.count < Self.maxApps && !apps.contains { $0.bundleID == app.bundleID }
        }
    }

    // MARK: Apps

    /// The first App piece's bundle ID, in the order a person reads the layout:
    /// one display, then the main display of a pair.
    var firstAppBundleID: String? {
        (oneDisplay + (twoDisplays?.main ?? []) + (twoDisplays?.second ?? [])).lazy.compactMap { $0.kind.app?.bundleID }.first
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
            two.main = swap(two.main)
            two.second = swap(two.second)
            twoDisplays = two
        }
    }

    // MARK: Display variants

    /// Starts a two-display version from the one-display one: whatever was
    /// there stays on the main display (without the Meeting), and the Meeting
    /// fills the second.
    mutating func addTwoDisplayVersion() {
        guard twoDisplays == nil else { return }
        var main = oneDisplay.filter { !$0.kind.isMeeting }
        // The old column the Meeting sat in goes to the Chat, if there is one.
        if let meeting = oneDisplay.first(where: { $0.kind.isMeeting }),
           let chat = main.firstIndex(where: { $0.kind.isChat }),
           abs(main[chat].rect.x - meeting.rect.x) < 1e-6, abs(main[chat].rect.w - meeting.rect.w) < 1e-6 {
            main[chat].rect = UnitRect(x: meeting.rect.x, y: 0, w: meeting.rect.w, h: 1)
        }
        twoDisplays = TwoDisplay(
            main: main,
            second: [LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)],
            secondUUID: "")
    }

    mutating func removeTwoDisplayVersion() { twoDisplays = nil }
}

// MARK: - The library

struct LayoutLibrary: Codable, Equatable {
    var version = 1
    var templates: [LayoutTemplate]
    /// The Start layout. nil is None: Greenroom moves nothing.
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
                  // A saved choice whose template is gone means None.
                  activeID: templates.contains { $0.id == active } ? active : nil)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
    }

    var active: LayoutTemplate? { activeID.flatMap(template(id:)) }

    func template(id: UUID) -> LayoutTemplate? { templates.first { $0.id == id } }

    // MARK: Editing

    mutating func select(_ id: UUID?) {
        activeID = id.flatMap { template(id: $0) }?.id
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
        let t = LayoutTemplate(name: name)
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
            two.main = fresh(two.main)
            two.second = fresh(two.second)
            copy.twoDisplays = two
        }
        templates.insert(copy, at: i + 1)
        return copy.id
    }

    mutating func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
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
    /// AppCatalog.builtInBrowserID, repeated because this file must not need AppKit.
    static let builtInBrowserBundleID = "com.sibhimanyu.greenroom.browser"

    /// The two ordinary, editable templates every library begins with.
    static func starters() -> [LayoutTemplate] {
        let third = 1.0 / 12
        return [
            LayoutTemplate(
                name: "Teach from a browser", starter: teachFromBrowser,
                oneDisplay: [
                    LayoutPiece(kind: .app(AppPiece(bundleID: builtInBrowserBundleID)),
                                rect: UnitRect(x: 0, y: 0, w: 8 * third, h: 1)),
                    LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: false),
                                rect: UnitRect(x: 8 * third, y: 0, w: 4 * third, h: 5 * third)),
                    LayoutPiece(kind: .chat,
                                rect: UnitRect(x: 8 * third, y: 5 * third, w: 4 * third, h: 7 * third)),
                ]),
            LayoutTemplate(
                name: "Meeting and chat", starter: meetingAndChat,
                oneDisplay: [
                    LayoutPiece(kind: .meeting(fillsDisplay: false, startsHidden: false),
                                rect: UnitRect(x: 0, y: 0, w: 9 * third, h: 1)),
                    LayoutPiece(kind: .chat, rect: UnitRect(x: 9 * third, y: 0, w: 3 * third, h: 1)),
                ]),
        ]
    }

    /// Brings back any starter that was deleted and resets any that were
    /// edited, leaving everything else alone.
    mutating func restoreStarters() {
        let all = Self.starters()
        for (order, fresh) in all.enumerated() {
            if let i = templates.firstIndex(where: { $0.starter == fresh.starter }) {
                var reset = fresh
                reset.id = templates[i].id
                templates[i] = reset
            } else {
                templates.insert(fresh, at: min(templates.count, order))
            }
        }
    }

    /// The starter with this key, restoring it first if it was deleted.
    @discardableResult
    mutating func starterID(_ key: String) -> UUID? {
        if let t = templates.first(where: { $0.starter == key }) { return t.id }
        guard let fresh = Self.starters().first(where: { $0.starter == key }) else { return nil }
        templates.append(fresh)
        return fresh.id
    }
}

// MARK: - Storage and migration

extension LayoutLibrary {
    static let defaultsKey = "layoutLibrary"

    static func load(from defaults: UserDefaults) -> LayoutLibrary? {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(LayoutLibrary.self, from: $0) }
    }

    func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// The saved library, or - the first time - the starters plus
    /// "Your previous layout" built from today's settings (written back, so it
    /// happens once). The old keys are left exactly as they were.
    static func loadOrMigrate(from defaults: UserDefaults, defaultSiteURL: String) -> LayoutLibrary {
        if let saved = load(from: defaults) { return saved }
        let library = firstRun(legacy: LegacyLayoutSettings.read(from: defaults, defaultSiteURL: defaultSiteURL))
        library.save(to: defaults)
        return library
    }

    static func firstRun(legacy: LegacyLayoutSettings) -> LayoutLibrary {
        var library = LayoutLibrary(templates: starters())
        if let previous = legacy.asTemplate() {
            library.templates.append(previous)
            if legacy.arrangeWindowsOnStart { library.activeID = previous.id }
        }
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
            // the full column on the main one.
            var main = app
            if sideShowsChat {
                main.append(LayoutPiece(kind: .chat, rect: UnitRect(x: sideX, y: 0, w: sideW, h: 1)))
            }
            template.twoDisplays = TwoDisplay(
                main: main,
                second: [LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)],
                secondUUID: peopleViewDisplayUUID)
        }
        return template
    }
}
