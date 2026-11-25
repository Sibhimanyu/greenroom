//
//  LayoutBuiltIns.swift
//  Greenroom
//
//  The six built-in layouts (P9, Q4): what each places, its camera piece and its share, plus the
//  one-line description the Layouts inspector shows when nothing is selected. Also Restore original
//  for one built-in, and what "Leave my windows alone" means for the Start path.
//
//  Pure (Foundation only), and compiled by the test target as it is.
//
import Foundation

extension LayoutLibrary {
    static let talkToMeeting = "talk-to-meeting"
    static let present = "present"
    static let roomLaptop = "room-laptop"
    static let leaveAlone = "leave-alone"

    /// The six, in the order the strip shows them. Each owns a camera and a share.
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
        let screen = ShareTarget()   // Present shares the screen, big
        var nothing = ShareTarget()
        nothing.kind = .nothing

        // Browser large, the speaker and chat at the side, the camera in the browser's corner.
        let teach = LayoutTemplate(
            name: "Teach from a browser", starter: teachFromBrowser,
            oneDisplay: [browser(width: 8 * third), speaker(x: 8 * third, w: 4 * third), chat(x: 8 * third, w: 4 * third)],
            camera: camera(.circle, width: 0.12, right: 0.36, bottom: 0.06), share: ShareTarget())
        // Share Nothing: the camera is the whole picture; the speaker and chat are for the owner's screen.
        let talk = LayoutTemplate(
            name: "Talk to the meeting", starter: talkToMeeting,
            oneDisplay: [speaker(x: 0, w: 9 * third, h: 1), chat(x: 9 * third, w: 3 * third, top: 0)],
            camera: camera(.roundedRectangle, width: 0.6, right: 0.2, bottom: 0.2), share: nothing)
        // The screen is shared and fills the picture; the camera is small in the top right.
        let presenting = LayoutTemplate(
            name: "Present", starter: present,
            oneDisplay: [speaker(x: 9 * third, w: 3 * third), chat(x: 9 * third, w: 3 * third)],
            camera: camera(.roundedRectangle, width: 0.14, right: 0.03, bottom: 0.75), share: screen)
        // The Main display is shared; the Room screen is on Second.
        let room = LayoutTemplate(
            name: "Room + laptop", starter: roomLaptop,
            oneDisplay: [browser(width: 9 * third), chat(x: 9 * third, w: 3 * third, top: 0)],
            twoDisplays: TwoDisplay(
                main: [browser(width: 9 * third), chat(x: 9 * third, w: 3 * third, top: 0)],
                second: [LayoutPiece(kind: .roomScreen, rect: .full)], sharedSlot: .main),
            camera: camera(.circle, width: 0.12, right: 0.30, bottom: 0.06), share: ShareTarget())
        // No pieces: no window moves. Only the camera has a place.
        let leave = LayoutTemplate(
            name: "Leave my windows alone", starter: leaveAlone,
            camera: camera(.circle, width: 0.12, right: 0.04, bottom: 0.06), share: ShareTarget())
        // The old fixed arrangement. The second display keeps a full-display Meeting.
        let raj = LayoutTemplate(
            name: "Raj San Mode", starter: rajMode,
            oneDisplay: [browser(width: 9 * third), speaker(x: 9 * third, w: 3 * third), chat(x: 9 * third, w: 3 * third)],
            twoDisplays: TwoDisplay(
                main: [browser(width: 9 * third), chat(x: 9 * third, w: 3 * third, top: 0)],
                second: [LayoutPiece(kind: .meeting(fillsDisplay: true, startsHidden: false), rect: .full)]),
            camera: LayoutCamera(), share: ShareTarget())
        return [teach, talk, presenting, room, leave, raj]
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

    // MARK: Existing installs (Q8)

    static let builtInsV2MigratedKey = "layoutLibrary.builtInsV2Migrated"

    /// Teach from a browser as the last release shipped it, to tell an edited copy from an untouched one.
    private static func isOldTeachFromABrowser(_ t: LayoutTemplate) -> Bool {
        let third = 1.0 / 12
        let old: [(LayoutPiece.Kind, UnitRect)] = [
            (.app(AppPiece(bundleID: builtInBrowserBundleID)), UnitRect(x: 0, y: 0, w: 8 * third, h: 1)),
            (.view(.activeSpeaker, startsHidden: false), UnitRect(x: 8 * third, y: 0, w: 4 * third, h: 5 * third)),
            (.chat, UnitRect(x: 8 * third, y: 5 * third, w: 4 * third, h: 7 * third)),
        ]
        return t.twoDisplays == nil && t.oneDisplay.count == old.count
            && zip(t.oneDisplay, old).allSatisfy { $0.kind == $1.0 && $0.rect == $1.1 }
    }

    /// One time, with its own key, set only after `save` worked (R16.1):
    /// - Raj stays as the owner edited it;
    /// - Teach from a browser is replaced in place (an edited one is kept first as the owner's own layout);
    /// - Meeting and chat stays, as the owner's own (starter tag cleared); Talk to the meeting is its new version;
    /// - the built-ins this library lacks are added; nothing is deleted;
    /// - no active layout (None) becomes Leave my windows alone.
    /// Returns whether it ran and saved.
    @discardableResult
    mutating func migrateBuiltInsV2(defaults: UserDefaults, save: (LayoutLibrary) -> Bool) -> Bool {
        guard !defaults.bool(forKey: Self.builtInsV2MigratedKey) else { return false }
        // Meeting and chat is the owner's now.
        for i in templates.indices where templates[i].starter == Self.meetingAndChat { templates[i].starter = nil }
        // Teach from a browser: the new version, same id and place.
        if let i = templates.firstIndex(where: { $0.starter == Self.teachFromBrowser }),
           var fresh = Self.shipped(Self.teachFromBrowser) {
            let old = templates[i]
            if !Self.isOldTeachFromABrowser(old) {
                var kept = old
                kept.id = UUID()
                kept.starter = nil
                kept.name = "My " + old.name
                templates.insert(kept, at: i)
            }
            let at = templates.firstIndex { $0.id == old.id }!
            fresh.id = old.id
            templates[at] = fresh
        }
        // Only the four new ones; a Raj San Mode the owner deleted stays deleted.
        let added = [Self.talkToMeeting, Self.present, Self.roomLaptop, Self.leaveAlone]
        for fresh in Self.builtIns() {
            guard let key = fresh.starter, added.contains(key), !templates.contains(where: { $0.starter == key }) else { continue }
            templates.append(fresh)
        }
        if active == nil { activeID = nil; ensureActive() }
        guard save(self) else { return false }
        defaults.set(true, forKey: Self.builtInsV2MigratedKey)
        return true
    }

    /// The one line the inspector shows for a built-in that is as shipped.
    static func description(forStarter key: String) -> String? {
        switch key {
        case teachFromBrowser: return "Teach from a website with the meeting and chat beside it, and you in a small circle."
        case talkToMeeting: return "A conversation: you large for everyone, the active speaker and chat on your screen."
        case present: return "Share your screen, with you small in a corner. The speaker and chat stay at the side of your screen."
        case roomLaptop: return "People in the room watch the Room screen while you work on the laptop."
        case leaveAlone: return "Moves no windows. It only says where your camera sits. Press + to start your own layout from it."
        case rajMode: return "The browser on the left, the active speaker top right with chat below, and your camera in the corner."
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
            a.count == b.count && zip(a, b).allSatisfy { $0.kind == $1.kind && $0.rect == $1.rect && $0.showsToEveryone == $1.showsToEveryone }
        }
        guard name == s.name, camera == s.camera, share == s.share, same(oneDisplay, s.oneDisplay) else { return false }
        switch (twoDisplays, s.twoDisplays) {
        case (nil, nil): return true
        case let (a?, b?): return a.sharedSlot == b.sharedSlot && same(a.main, b.main) && same(a.second, b.second)
        default: return false
        }
    }
}
