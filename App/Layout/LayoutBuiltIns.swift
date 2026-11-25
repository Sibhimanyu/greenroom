//
//  LayoutBuiltIns.swift
//  Greenroom
//
//  The three built-in layouts (Q28, R39; six from P9 until 2026-11-26): what each places, its camera piece and its share, plus the
//  one-line description the Layouts inspector shows when nothing is selected. Also Restore original
//  for one built-in, and what "Leave my windows alone" means for the Start path.
//
//  Pure (Foundation only), and compiled by the test target as it is.
//
import Foundation

extension LayoutLibrary {
    /// Retired built-ins (Q28): no longer shipped; an install that had them keeps them as the owner's own.
    static let talkToMeeting = "talk-to-meeting"
    static let present = "present"
    static let retiredStarterKeys = [teachFromBrowser, talkToMeeting, present]
    static let roomLaptop = "room-laptop"
    static let leaveAlone = "leave-alone"

    /// The three, in the order the strip shows them (R39.1). Each owns a camera and a share.
    static func builtIns() -> [LayoutTemplate] {
        let third = 1.0 / 12
        func browser(width: Double) -> LayoutPiece {
            LayoutPiece(kind: .app(AppPiece(bundleID: builtInBrowserBundleID)), rect: UnitRect(x: 0, y: 0, w: width, h: 1))
        }
        func speaker(x: Double, w: Double, h: Double = 5.0 / 12) -> LayoutPiece {
            LayoutPiece(kind: .view(.activeSpeaker, startsHidden: false), rect: UnitRect(x: x, y: 0, w: w, h: h))
        }
        func chat(x: Double, w: Double, top: Double = 5.0 / 12) -> LayoutPiece {
            LayoutPiece(kind: .chat, rect: UnitRect(x: x, y: top, w: w, h: 1 - top))
        }
        func camera(_ shape: WebcamShape, width: Double, right: Double, bottom: Double) -> LayoutCamera {
            var c = LayoutCamera()
            c.shape = shape
            c.widthFraction = width
            c.rightInset = right
            c.bottomInset = bottom
            return c
        }
        // The Main display is shared; the Room screen is on Second.
        let room = LayoutTemplate(
            name: "Room + laptop", starter: roomLaptop,
            oneDisplay: [browser(width: 9 * third), chat(x: 9 * third, w: 3 * third, top: 0)],
            twoDisplays: TwoDisplay(second: [LayoutPiece(kind: .roomScreen, rect: .full)], sharedSlot: .main),
            camera: camera(.roundedRectangle, width: 0.12, right: 0.30, bottom: 0.06), share: ShareTarget())
        // No pieces: no window moves. Only the camera has a place.
        let leave = LayoutTemplate(
            name: "Leave my windows alone", starter: leaveAlone,
            camera: camera(.roundedRectangle, width: 0.12, right: 0.04, bottom: 0.06), share: ShareTarget())
        // Raj's camera is the Cutout (owner, 2026-11-26): the person stands at the bottom right at 40% of the
        // picture's height, keeping clear of the top of Chat where its caption is.
        var rajCamera = LayoutCamera()
        rajCamera.shape = .cutout
        rajCamera.cutoutHeightFraction = 0.4
        rajCamera.cutoutRightInset = 0.02
        // The old one-display arrangement, kept as main (ADR 0002): the browser, the speaker top right and
        // Chat below, so the laptop alone still has a meeting surface. A second display holds the Meeting.
        let raj = LayoutTemplate(
            name: "Raj San Mode", starter: rajMode,
            oneDisplay: [browser(width: 9 * third), speaker(x: 9 * third, w: 3 * third), chat(x: 9 * third, w: 3 * third)],
            twoDisplays: TwoDisplay(
                second: [LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)]),
            camera: rajCamera, share: ShareTarget())
        return [leave, raj, room]
    }

    /// The id of Leave my windows alone, the layout there is always an answer to fall back to.
    var leaveAloneID: UUID? { templates.first { $0.starter == Self.leaveAlone }?.id }

    /// No None (Q3): with nothing active, Leave my windows alone is. Stays nil only in a library without it.
    mutating func ensureActive() {
        if active == nil { activeID = leaveAloneID }
    }

    /// The shipped version of a built-in, if this key has one (the retired "meeting-chat" has none).
    static func shipped(_ key: String?) -> LayoutTemplate? {
        key.flatMap { k in builtIns().first { $0.starter == k } }
    }

    /// Restore original (Q6) applies to a layout that began as a built-in with a shipped version.
    func canRestore(_ id: UUID) -> Bool { Self.shipped(template(id: id)?.starter) != nil }

    /// Leave my windows alone is the fallback for "nothing active", so it is never deleted.
    func canDelete(_ id: UUID) -> Bool { template(id: id)?.starter != Self.leaveAlone }

    /// Puts one built-in back as shipped, in its place and with its id; every other layout is untouched.
    @discardableResult
    mutating func restoreOriginal(_ id: UUID) -> Bool {
        guard let i = templates.firstIndex(where: { $0.id == id }),
              var fresh = Self.shipped(templates[i].starter) else { return false }
        fresh.id = id
        templates[i] = fresh
        return true
    }

    /// + on Leave my windows alone (Q22): copies it into a new "My layout" ("My layout 2"...), selects it,
    /// and returns its id. The built-in stays clean. nil for any other layout.
    @discardableResult
    mutating func forkLeaveAlone() -> UUID? {
        guard let source = active, source.starter == Self.leaveAlone else { return nil }
        var copy = source
        copy.id = UUID()
        copy.starter = nil
        var name = "My layout"
        var n = 1
        while templates.contains(where: { $0.name == name }) { n += 1; name = "My layout \(n)" }
        copy.name = name
        templates.append(copy)
        activeID = copy.id
        return copy.id
    }

    /// The dashed strip (R29.3): adds a second arrangement to the active layout. Leave my windows alone
    /// cannot take pieces, so it is forked first, like +. Returns the layout that now has the second.
    @discardableResult
    mutating func addSecondDisplayToActive() -> UUID? {
        if active?.starter == Self.leaveAlone { forkLeaveAlone() }
        guard let i = templates.firstIndex(where: { $0.id == activeID }) else { return nil }
        templates[i].addSecondDisplay()
        return templates[i].id
    }

    // MARK: Existing installs (Q8)

    static let builtInsV2MigratedKey = "layoutLibrary.builtInsV2Migrated"
    static let threeBuiltInsMigratedKey = "layoutLibrary.threeBuiltInsMigrated"

    /// One time, with its own key, set only after `save` worked (R40, Q28): Teach from a browser, Talk to the
    /// meeting and Present lose their built-in tag and are the owner's own layouts, unchanged. Nothing is
    /// deleted and the active layout is kept. The built-ins this library has go first, in their order, then
    /// every other layout as it was; Leave my windows alone is always there (a Raj or Room the owner deleted
    /// stays deleted). Runs after the earlier migrations, so an install that never ran them ends the same.
    @discardableResult
    mutating func migrateThreeBuiltIns(defaults: UserDefaults, save: (LayoutLibrary) -> Bool) -> Bool {
        guard !defaults.bool(forKey: Self.threeBuiltInsMigratedKey) else { return false }
        for i in templates.indices where Self.retiredStarterKeys.contains(templates[i].starter ?? "") { templates[i].starter = nil }
        if leaveAloneID == nil, let fresh = Self.shipped(Self.leaveAlone) { templates.append(fresh) }
        let order = Self.builtIns().compactMap(\.starter)
        let first = order.compactMap { key in templates.first { $0.starter == key } }
        templates = first + templates.filter { t in !first.contains { $0.id == t.id } }
        ensureActive()
        guard save(self) else { return false }
        defaults.set(true, forKey: Self.threeBuiltInsMigratedKey)
        return true
    }

    /// One time, with its own key, set only after `save` worked (R16.1):
    /// - Raj stays as the owner edited it;
    /// - Teach from a browser is left alone (since Q28 it is not built in; `migrateThreeBuiltIns` frees it);
    /// - Meeting and chat stays, as the owner's own (starter tag cleared);
    /// - the built-ins this library lacks are added; nothing is deleted;
    /// - no active layout (None) becomes Leave my windows alone.
    /// - a former None user's own camera and share go to Leave my windows alone, the layout that replaces
    ///   None, so day one looks the same (Q7, R16): `legacyCamera` and `legacyShare` are today's globals,
    ///   read before the camera and share migration copies them into the other layouts.
    /// Returns whether it ran and saved.
    @discardableResult
    mutating func migrateBuiltInsV2(defaults: UserDefaults, legacyCamera: LayoutCamera? = nil, legacyShare: ShareTarget? = nil,
                                    save: (LayoutLibrary) -> Bool) -> Bool {
        guard !defaults.bool(forKey: Self.builtInsV2MigratedKey) else { return false }
        // Meeting and chat is the owner's now.
        for i in templates.indices where templates[i].starter == Self.meetingAndChat { templates[i].starter = nil }
        // Only the new ones (since Q28 that is Room + laptop and Leave my windows alone); a Raj San Mode the owner deleted stays deleted.
        let added = [Self.roomLaptop, Self.leaveAlone]
        for fresh in Self.builtIns() {
            guard let key = fresh.starter, added.contains(key), !templates.contains(where: { $0.starter == key }) else { continue }
            templates.append(fresh)
        }
        if active == nil {
            activeID = nil
            ensureActive()
            // None becomes Leave my windows alone, with the camera and share None had.
            if let i = templates.firstIndex(where: { $0.starter == Self.leaveAlone }) {
                if let legacyCamera { templates[i].camera = legacyCamera }
                if let legacyShare { templates[i].share = legacyShare }
            }
        }
        guard save(self) else { return false }
        defaults.set(true, forKey: Self.builtInsV2MigratedKey)
        return true
    }

    /// The one line the inspector shows for a built-in that is as shipped.
    static func description(forStarter key: String) -> String? {
        switch key {
        case roomLaptop: return "People in the room watch the Room screen while you work on the laptop."
        case leaveAlone: return "Moves no windows. It only says where your camera sits. Press + to start your own layout from it."
        case rajMode: return "The browser with the speaker and chat beside it. With a second display, the meeting fills it."
        default: return nil
        }
    }
}

extension LayoutTemplate {
    /// False for Leave my windows alone: Start, Snap Back and live edits place no window for it
    /// (what "no layout" did), while its camera still applies.
    var movesWindows: Bool { starter != LayoutLibrary.leaveAlone }

    /// Unedited: same name, pieces, camera and share as the shipped version (piece ids ignored).
    var isAsShipped: Bool {
        guard let s = LayoutLibrary.shipped(starter) else { return false }
        func same(_ a: [LayoutPiece], _ b: [LayoutPiece]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.kind == $1.kind && $0.rect.isClose(to: $1.rect) && $0.showsToEveryone == $1.showsToEveryone }
        }
        guard name == s.name, camera == s.camera, share == s.share, same(oneDisplay, s.oneDisplay) else { return false }
        switch (twoDisplays, s.twoDisplays) {
        case (nil, nil): return true
        case let (a?, b?): return a.sharedSlot == b.sharedSlot && same(a.second, b.second)
        default: return false
        }
    }
}
