import XCTest
import Carbon.HIToolbox

final class ShortcutModelTests: XCTestCase {

    private let g = ShortcutSlot.action(.startClass)
    private let mic = ShortcutSlot.action(.toggleMic)
    private let hide = ShortcutSlot.action(.toggleMeeting)

    // MARK: Bindings: encode / decode / defaults

    func testDefaultsAreTodaysHotkeys() {
        let b = ShortcutBindings()
        XCTAssertEqual(b.combo(for: g), .controlOptionCommand(kVK_ANSI_G))
        XCTAssertEqual(b.combo(for: .action(.endSession)), .controlOptionCommand(kVK_ANSI_E))
        XCTAssertEqual(b.combo(for: .action(.toggleRecording)), .controlOptionCommand(kVK_ANSI_R))
        XCTAssertEqual(b.combo(for: .action(.snapBack)), .controlOptionCommand(kVK_ANSI_S))
        XCTAssertEqual(b.combo(for: hide), .controlOptionCommand(kVK_ANSI_H))
        XCTAssertEqual(b.combo(for: .action(.clip1)), .controlOptionCommand(kVK_ANSI_1))
        XCTAssertEqual(b.combo(for: .action(.clip2)), .controlOptionCommand(kVK_ANSI_2))
        XCTAssertEqual(b.combo(for: .action(.clip5)), .controlOptionCommand(kVK_ANSI_5))
        XCTAssertNil(b.combo(for: mic), "new actions ship unbound")
        XCTAssertNil(b.combo(for: .layout(nil)))
    }

    func testRoundTripKeepsCombosAndCleared() throws {
        var b = ShortcutBindings()
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: KeyCombo.control | KeyCombo.option)
        b.set(combo, for: mic)
        b.clear(g)                       // a default switched off
        let data = try XCTUnwrap(b.jsonData())
        let back = try XCTUnwrap(ShortcutBindings.from(jsonData: data))
        XCTAssertEqual(back, b)
        XCTAssertEqual(back.combo(for: mic), combo)
        XCTAssertNil(back.combo(for: g), "cleared stays cleared, it does not fall back to the default")
        XCTAssertTrue(back.isCustomised(g))
        XCTAssertEqual(back.combo(for: hide), .controlOptionCommand(kVK_ANSI_H), "missing means the default")
    }

    func testJSONShape() throws {
        var b = ShortcutBindings()
        b.set(KeyCombo(keyCode: 46, modifiers: KeyCombo.command | KeyCombo.option), for: mic)
        b.clear(g)
        let text = String(decoding: try XCTUnwrap(b.jsonData()), as: UTF8.self)
        XCTAssertTrue(text.contains("\"cleared\":true"))
        XCTAssertTrue(text.contains("\"keyCode\":46"))
        XCTAssertTrue(text.contains("\"mic\""))
    }

    func testSettingTheDefaultStoresNothing() {
        var b = ShortcutBindings()
        b.set(.controlOptionCommand(kVK_ANSI_G), for: g)
        XCTAssertTrue(b.entries.isEmpty)
        b.clear(mic)                     // unbound by default: nothing to switch off
        XCTAssertTrue(b.entries.isEmpty)
    }

    func testDamagedEntryFallsBackToDefault() throws {
        let json = #"{"version":1,"entries":{"start":{"nonsense":1},"mic":{"keyCode":46,"modifiers":6400}}}"#
        let b = try XCTUnwrap(ShortcutBindings.from(jsonData: Data(json.utf8)))
        XCTAssertEqual(b.combo(for: g), .controlOptionCommand(kVK_ANSI_G))
        XCTAssertEqual(b.combo(for: mic), .controlOptionCommand(kVK_ANSI_M))
    }

    func testResetAndResetAll() {
        var b = ShortcutBindings()
        b.clear(g)
        b.set(.controlOptionCommand(kVK_ANSI_M), for: mic)
        b.reset(g)
        XCTAssertEqual(b.combo(for: g), .controlOptionCommand(kVK_ANSI_G))
        b.resetAll()
        XCTAssertNil(b.combo(for: mic))
    }

    // MARK: Reserved combinations

    func testReservedCombosAreRefused() {
        let cmd = KeyCombo.command, opt = KeyCombo.option
        let refused: [(Int, UInt32)] = [
            (kVK_ANSI_Q, cmd), (kVK_ANSI_W, cmd), (kVK_Tab, cmd), (kVK_Space, cmd),
            (kVK_Escape, cmd | opt), (kVK_ANSI_D, cmd | opt), (kVK_ANSI_H, cmd | opt),
            (kVK_ANSI_H, cmd), (kVK_ANSI_M, cmd), (kVK_ANSI_C, cmd), (kVK_ANSI_V, cmd),
        ]
        for (key, mods) in refused {
            let combo = KeyCombo(keyCode: UInt32(key), modifiers: mods)
            XCTAssertNotNil(ReservedShortcuts.reason(for: combo), combo.glyphs)
            if case .reject = ShortcutCapture.interpret(keyCode: UInt32(key), carbonModifiers: mods) {} else {
                XCTFail("\(combo.glyphs) should be rejected")
            }
        }
        // Our own defaults are not reserved.
        // (A window-scoped default may be a system key: it is never registered system-wide.)
        for action in ShortcutAction.allCases where action.scope == .global {
            if let d = action.defaultCombo { XCTAssertNil(ReservedShortcuts.reason(for: d), d.glyphs) }
        }
    }

    func testKnownAppClashesAreRefused() {
        let cmd = KeyCombo.command, opt = KeyCombo.option
        for key in [kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_F, kVK_ANSI_N] {
            let combo = KeyCombo(keyCode: UInt32(key), modifiers: cmd | opt)
            XCTAssertNotNil(ReservedShortcuts.reason(for: combo), combo.glyphs)
        }
    }

    func testDefaultsUseControlOptionCommandAreUniqueAndNotRefused() {
        let all = KeyCombo.control | KeyCombo.option | KeyCombo.command
        var seen = Set<KeyCombo>()
        for action in ShortcutAction.allCases {
            guard let d = action.defaultCombo else { continue }
            if action != .shrinkToBar {
                XCTAssertEqual(d.modifiers, all, "\(action) should use exactly control, option and command")
            }
            XCTAssertTrue(seen.insert(d).inserted, "\(action) repeats \(d.glyphs)")
            // Window-scoped defaults are never registered system-wide, so may be a system key.
            if action.scope == .global {
                XCTAssertNil(ReservedShortcuts.reason(for: d), "\(action) default \(d.glyphs) is refused")
            }
        }
        XCTAssertEqual(seen.count, 12, "eleven before, and Stop video's Control-Option-Command-V (R49)")
    }

    func testRecorderRules() {
        let g = UInt32(kVK_ANSI_G)
        XCTAssertEqual(ShortcutCapture.interpret(keyCode: UInt32(kVK_Escape), carbonModifiers: 0), .cancel)
        XCTAssertEqual(ShortcutCapture.interpret(keyCode: UInt32(kVK_Delete), carbonModifiers: 0), .clear)
        // A bare letter, or shift alone, is refused with a reason.
        if case .reject = ShortcutCapture.interpret(keyCode: g, carbonModifiers: 0) {} else { XCTFail() }
        if case .reject = ShortcutCapture.interpret(keyCode: g, carbonModifiers: KeyCombo.shift) {} else { XCTFail() }
        XCTAssertEqual(ShortcutCapture.interpret(keyCode: g, carbonModifiers: KeyCombo.control),
                       .accept(KeyCombo(keyCode: g, modifiers: KeyCombo.control)))
        // Cocoa flags: shift 1<<17, control 1<<18, option 1<<19, command 1<<20.
        XCTAssertEqual(KeyCombo.carbonModifiers(cocoaFlags: (1 << 19) | (1 << 20)), KeyCombo.option | KeyCombo.command)
    }

    // MARK: Conflicts

    func testConflictDetection() {
        let layouts: [ShortcutLayoutRef] = []
        let slots = ShortcutCatalog.slots(layouts: layouts)
        var b = ShortcutBindings()
        // The default of "hide meeting" is taken by it, so mic cannot have it.
        XCTAssertEqual(b.conflict(for: .controlOptionCommand(kVK_ANSI_H), besides: mic, among: slots), hide)
        // A row does not conflict with itself.
        XCTAssertNil(b.conflict(for: .controlOptionCommand(kVK_ANSI_H), besides: hide, among: slots))
        // Free combination.
        XCTAssertNil(b.conflict(for: .controlOptionCommand(kVK_ANSI_M), besides: mic, among: slots))
        // Once the other row is cleared, the key is free.
        b.clear(hide)
        XCTAssertNil(b.conflict(for: .controlOptionCommand(kVK_ANSI_H), besides: mic, among: slots))
    }

    func testResolvedNeverDoubleClaims() {
        var b = ShortcutBindings()
        b.set(.controlOptionCommand(kVK_ANSI_G), for: mic)     // same as Start
        let resolved = b.resolved(among: ShortcutCatalog.slots(layouts: []))
        let keys = resolved.map(\.combo)
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertEqual(resolved.first { $0.combo == .controlOptionCommand(kVK_ANSI_G) }?.slot, g, "first in list order keeps it")
    }

    // MARK: Dynamic layout actions

    func testLayoutSlotsFollowTheLibraryAndDropDeletedTemplates() {
        let a = ShortcutLayoutRef(id: UUID(), name: "Teach from browser")
        let b = ShortcutLayoutRef(id: UUID(), name: "Two displays")
        let slots = ShortcutCatalog.slots(layouts: [a, b])
        XCTAssertTrue(slots.contains(.layout(nil)))
        XCTAssertTrue(slots.contains(.layout(a.id)))
        XCTAssertEqual(ShortcutSlot.layout(a.id).title(layouts: [a, b]), "Use layout: Teach from browser")

        var bindings = ShortcutBindings()
        bindings.set(KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: KeyCombo.control | KeyCombo.option), for: .layout(a.id))
        bindings.set(KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: KeyCombo.control | KeyCombo.option), for: .layout(b.id))
        bindings.set(KeyCombo(keyCode: UInt32(kVK_ANSI_0), modifiers: KeyCombo.control | KeyCombo.option), for: .layout(nil))

        // b is deleted: its binding goes, a's and None's stay.
        let pruned = bindings.pruned(keepingTemplates: [a.id])
        XCTAssertNotNil(pruned.combo(for: .layout(a.id)))
        XCTAssertNil(pruned.combo(for: .layout(b.id)))
        XCTAssertNotNil(pruned.combo(for: .layout(nil)))
        // And it is not registered either way.
        let registered = bindings.resolved(among: ShortcutCatalog.slots(layouts: [a])).map(\.slot)
        XCTAssertFalse(registered.contains(.layout(b.id)))
    }

    func testSlotIDsRoundTrip() {
        let id = UUID()
        for slot in ShortcutCatalog.slots(layouts: [ShortcutLayoutRef(id: id, name: "x")]) {
            XCTAssertEqual(ShortcutSlot(id: slot.id), slot)
        }
        XCTAssertNil(ShortcutSlot(id: "nonsense"))
    }

    func testGroupsMatchThePage() {
        let groups = ShortcutCatalog.grouped(layouts: [])
        XCTAssertEqual(groups.map(\.group.title), ["Session", "Meeting", "Layout", "Greenroom"])
        XCTAssertEqual(groups[0].slots.count, 8)
        XCTAssertEqual(groups[1].slots.count, 11 + MeetingView.allCases.count, "the eleven meeting actions and one per view")
    }

    // R49: Stop or start video, rebindable, default Control-Option-Command-V (checked free 2026-11-26:
    // no Greenroom default, no macOS symbolic hotkey, nothing in Safari, Chrome, Finder or Zoom; Zoom's
    // own video key is Shift-Command-V, its minimal window Control-Command-V, Finder's Move Here Option-Command-V).
    func testStopVideoShortcutIsControlOptionCommandV() {
        let a = ShortcutAction.toggleVideoStopped
        XCTAssertEqual(a.defaultCombo, .controlOptionCommand(kVK_ANSI_V))
        XCTAssertEqual(ShortcutBindings().combo(for: .action(a)), .controlOptionCommand(kVK_ANSI_V))
        XCTAssertEqual(a.group, .meeting)
        XCTAssertEqual(a.scope, .global)
        XCTAssertEqual(a.title, "Stop or start video")
        XCTAssertFalse(a.detail.localizedCaseInsensitiveContains("class"))
        XCTAssertEqual(a.symbol, VisibilitySymbol.videoStopped.name)
        XCTAssertNil(ReservedShortcuts.reason(for: .controlOptionCommand(kVK_ANSI_V)))
        let others = ShortcutAction.allCases.filter { $0 != a }.compactMap(\.defaultCombo)
        XCTAssertFalse(others.contains(.controlOptionCommand(kVK_ANSI_V)), "no other default takes it")
        XCTAssertNil(ShortcutAction.toggleCamera.defaultCombo, "the camera shortcut is unchanged: unbound")
    }

    // MARK: Shrink meeting to the Control bar

    func testShrinkToBarIsCommandMInTheMeetingWindowOnly() {
        let shrink = ShortcutSlot.action(.shrinkToBar)
        XCTAssertEqual(shrink.title(layouts: []), "Shrink meeting to the Control bar")
        XCTAssertEqual(ShortcutBindings().combo(for: shrink), KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: KeyCombo.command))
        XCTAssertEqual(shrink.scope, .meetingWindow)
        XCTAssertEqual(shrink.group, .meeting)
        XCTAssertEqual(ShortcutAction.shrinkToBar.rawValue, "meetingShrinkToBar")
        // Every other action stays system-wide.
        for action in ShortcutAction.allCases where action != .shrinkToBar { XCTAssertEqual(action.scope, .global, action.rawValue) }
    }

    func testNoDefaultClashesWithCommandM() {
        let slots = ShortcutCatalog.slots(layouts: [])
        let commandM = KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: KeyCombo.command)
        let holders = slots.filter { ShortcutBindings().combo(for: $0) == commandM }
        XCTAssertEqual(holders, [.action(.shrinkToBar)])
        // Only global slots are registered with the system, so Command-M stays the system's.
        let registered = ShortcutBindings().resolved(among: slots).filter { $0.slot.scope == .global }
        XCTAssertFalse(registered.contains { $0.combo == commandM })
    }

    // MARK: View actions

    func testEveryViewHasAnUnboundOpenOrCloseAction() {
        let actions = ShortcutAction.allCases.compactMap { action in action.meetingView.map { (action, $0) } }
        XCTAssertEqual(Set(actions.map(\.1)), Set(MeetingView.allCases))
        for (action, view) in actions {
            XCTAssertEqual(action.title, "Open or close \(view.title)")
            XCTAssertNil(action.defaultCombo, "\(view) ships unbound")
            XCTAssertEqual(action.group, .meeting)
            XCTAssertEqual(action.rawValue, "view.\(view.rawValue)")
        }
    }

    // MARK: Glyphs

    func testGlyphOrderIsControlOptionShiftCommand() {
        let all = KeyCombo(keyCode: UInt32(kVK_ANSI_G),
                           modifiers: KeyCombo.command | KeyCombo.shift | KeyCombo.option | KeyCombo.control)
        XCTAssertEqual(all.glyphs, "\u{2303}\u{2325}\u{21E7}\u{2318}G")
        XCTAssertEqual(KeyCombo.controlOptionCommand(kVK_ANSI_G).glyphs, "\u{2303}\u{2325}\u{2318}G")
        XCTAssertEqual(KeyCombo.controlOptionCommand(kVK_ANSI_G).spokenName, "Control Option Command G")
        XCTAssertEqual(all.spokenName, "Control Option Shift Command G")
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_Space), modifiers: KeyCombo.command | KeyCombo.control).glyphs, "\u{2303}\u{2318}Space")
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: KeyCombo.option).glyphs, "\u{2325}\u{2190}")
        XCTAssertEqual(KeyCombo.controlOptionCommand(kVK_ANSI_5).menuKey, "5")
    }
}
