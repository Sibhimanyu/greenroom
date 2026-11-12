import XCTest
import Carbon.HIToolbox

final class ShortcutModelTests: XCTestCase {

    private let g = ShortcutSlot.action(.startClass)
    private let mic = ShortcutSlot.action(.toggleMic)
    private let hide = ShortcutSlot.action(.toggleMeeting)

    // MARK: Bindings: encode / decode / defaults

    func testDefaultsAreTodaysHotkeys() {
        let b = ShortcutBindings()
        XCTAssertEqual(b.combo(for: g), .optionCommand(kVK_ANSI_G))
        XCTAssertEqual(b.combo(for: .action(.endSession)), .optionCommand(kVK_ANSI_X))
        XCTAssertEqual(b.combo(for: .action(.toggleRecording)), .optionCommand(kVK_ANSI_R))
        XCTAssertEqual(b.combo(for: .action(.snapBack)), .optionCommand(kVK_ANSI_S))
        XCTAssertEqual(b.combo(for: hide), .optionCommand(kVK_ANSI_Z))
        XCTAssertEqual(b.combo(for: .action(.clip1)), .optionCommand(kVK_ANSI_1))
        XCTAssertEqual(b.combo(for: .action(.clip2)), .optionCommand(kVK_ANSI_2))
        XCTAssertEqual(b.combo(for: .action(.clip5)), .optionCommand(kVK_ANSI_5))
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
        XCTAssertEqual(back.combo(for: hide), .optionCommand(kVK_ANSI_Z), "missing means the default")
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
        b.set(.optionCommand(kVK_ANSI_G), for: g)
        XCTAssertTrue(b.entries.isEmpty)
        b.clear(mic)                     // unbound by default: nothing to switch off
        XCTAssertTrue(b.entries.isEmpty)
    }

    func testDamagedEntryFallsBackToDefault() throws {
        let json = #"{"version":1,"entries":{"start":{"nonsense":1},"mic":{"keyCode":46,"modifiers":2304}}}"#
        let b = try XCTUnwrap(ShortcutBindings.from(jsonData: Data(json.utf8)))
        XCTAssertEqual(b.combo(for: g), .optionCommand(kVK_ANSI_G))
        XCTAssertEqual(b.combo(for: mic), .optionCommand(kVK_ANSI_M))
    }

    func testResetAndResetAll() {
        var b = ShortcutBindings()
        b.clear(g)
        b.set(.optionCommand(kVK_ANSI_M), for: mic)
        b.reset(g)
        XCTAssertEqual(b.combo(for: g), .optionCommand(kVK_ANSI_G))
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
        for action in ShortcutAction.allCases {
            if let d = action.defaultCombo { XCTAssertNil(ReservedShortcuts.reason(for: d), d.glyphs) }
        }
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
        XCTAssertEqual(b.conflict(for: .optionCommand(kVK_ANSI_Z), besides: mic, among: slots), hide)
        // A row does not conflict with itself.
        XCTAssertNil(b.conflict(for: .optionCommand(kVK_ANSI_Z), besides: hide, among: slots))
        // Free combination.
        XCTAssertNil(b.conflict(for: .optionCommand(kVK_ANSI_M), besides: mic, among: slots))
        // Once the other row is cleared, the key is free.
        b.clear(hide)
        XCTAssertNil(b.conflict(for: .optionCommand(kVK_ANSI_Z), besides: mic, among: slots))
    }

    func testResolvedNeverDoubleClaims() {
        var b = ShortcutBindings()
        b.set(.optionCommand(kVK_ANSI_G), for: mic)     // same as Start
        let resolved = b.resolved(among: ShortcutCatalog.slots(layouts: []))
        let keys = resolved.map(\.combo)
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertEqual(resolved.first { $0.combo == .optionCommand(kVK_ANSI_G) }?.slot, g, "first in list order keeps it")
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
        XCTAssertEqual(groups.map(\.group.title), ["Class", "Meeting", "Layout", "Greenroom"])
        XCTAssertEqual(groups[0].slots.count, 6)
        XCTAssertEqual(groups[1].slots.count, 9)
    }

    // MARK: Glyphs

    func testGlyphOrderIsControlOptionShiftCommand() {
        let all = KeyCombo(keyCode: UInt32(kVK_ANSI_G),
                           modifiers: KeyCombo.command | KeyCombo.shift | KeyCombo.option | KeyCombo.control)
        XCTAssertEqual(all.glyphs, "\u{2303}\u{2325}\u{21E7}\u{2318}G")
        XCTAssertEqual(KeyCombo.optionCommand(kVK_ANSI_G).glyphs, "\u{2325}\u{2318}G")
        XCTAssertEqual(KeyCombo.optionCommand(kVK_ANSI_G).spokenName, "Option Command G")
        XCTAssertEqual(all.spokenName, "Control Option Shift Command G")
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_Space), modifiers: KeyCombo.command | KeyCombo.control).glyphs, "\u{2303}\u{2318}Space")
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: KeyCombo.option).glyphs, "\u{2325}\u{2190}")
        XCTAssertEqual(KeyCombo.optionCommand(kVK_ANSI_5).menuKey, "5")
    }
}
