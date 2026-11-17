import XCTest

final class PresentMenuTests: XCTestCase {
    private typealias P = PresentMenu

    private func choice(_ id: String, _ title: String) -> P.Choice { .init(id: id, title: title) }

    private func state(_ edit: (inout P.State) -> Void = { _ in }) -> P.State {
        var s = P.State()
        s.displays = [choice("A", "Built-in \u{2014} 3024\u{00D7}1964 \u{00B7} Main"), choice("B", "Studio \u{2014} 2560\u{00D7}1440")]
        s.windows = [
            .init(bundleID: "com.google.Chrome", appName: "Chrome", title: "Lesson", label: "Chrome \u{2013} Lesson"),
            .init(bundleID: "com.apple.Keynote", appName: "Keynote", title: "", label: "Keynote window"),
        ]
        s.shapes = [choice("circle", "Circle"), choice("square", "Square")]
        s.shapeID = "circle"
        s.layouts = [choice("L1", "Teach"), choice("L2", "Side by side")]
        s.liveLayoutID = "L2"
        s.layoutsAvailable = true
        edit(&s)
        return s
    }

    private func menu(_ s: P.State, _ a: P.Actions = .init()) -> [MenuEntry] { P.entries(s, a) }

    func testOrderIsWhatTheClassSeesThenLookThenLayout() {
        let titles = menu(state()).filter { $0.kind != .separator }.map(\.title)
        XCTAssertEqual(titles, ["What everyone sees", "Whole screen", "One window",
                                "Whiteboard", "Just my camera", "Look", "Layout"])
        XCTAssertEqual(menu(state()).first?.kind, .header)
    }

    func testTheCurrentChoiceIsTickedAtEveryLevel() {
        let onWindow = menu(state { $0.kind = .window; $0.windowBundleID = "com.google.Chrome"; $0.windowTitle = "Lesson" })
        XCTAssertEqual(onWindow.entry(titled: "One window")?.checked, true)
        XCTAssertEqual(onWindow.entry(titled: "Chrome \u{2013} Lesson")?.checked, true)
        XCTAssertEqual(onWindow.entry(titled: "Keynote window")?.checked, false)

        XCTAssertEqual(menu(state { $0.kind = .whiteboard }).entry(titled: "Whiteboard")?.checked, true)
        XCTAssertEqual(menu(state { $0.kind = .nothing }).entry(titled: "Just my camera")?.checked, true)
        XCTAssertEqual(menu(state()).entry(titled: "Circle")?.checked, true)
        XCTAssertEqual(menu(state()).entry(titled: "Square")?.checked, false)
        XCTAssertEqual(menu(state()).entry(titled: "Side by side")?.checked, true)
        XCTAssertEqual(menu(state()).entry(titled: "Teach")?.checked, false)
    }

    func testOneAppIsNotOffered() {
        // Owner, 2026-11-16: one window is the only per-app choice.
        let m = menu(state())
        XCTAssertNil(m.entry(titled: "One app"))
        // A saved app target ticks nothing rather than a stale row.
        let saved = menu(state { $0.kind = .app })
        XCTAssertEqual(saved.entry(titled: "Whole screen")?.checked, false)
        XCTAssertEqual(saved.entry(titled: "One window")?.checked, false)
    }

    func testSeveralDisplaysMakeASubmenuWithAutomaticFirst() {
        let m = menu(state())
        let whole = m.entry(titled: "Whole screen")
        XCTAssertEqual(whole?.kind, .submenu)
        XCTAssertEqual(whole?.children.first?.title, "Automatic (main display)")
        XCTAssertEqual(whole?.children.count, 3)
        XCTAssertEqual(whole?.checked, true)
        XCTAssertEqual(whole?.children.first?.checked, true)
    }

    func testDisplayTicksFollowTheChosenDisplayOnlyOnWholeScreen() {
        let m = menu(state { $0.displayID = "B" })
        XCTAssertEqual(m.entry(titled: "Automatic (main display)")?.checked, false)
        XCTAssertEqual(m.entry(titled: "Studio \u{2014} 2560\u{00D7}1440")?.checked, true)
        let window = menu(state { $0.kind = .window; $0.displayID = "B" })
        XCTAssertEqual(window.entry(titled: "Whole screen")?.checked, false)
        XCTAssertEqual(window.entry(titled: "Studio \u{2014} 2560\u{00D7}1440")?.checked, false)
    }

    func testOneDisplayIsASingleItem() {
        for displays in [[], [choice("A", "Built-in")]] {
            let whole = menu(state { $0.displays = displays }).entry(titled: "Whole screen")
            XCTAssertEqual(whole?.kind, .item)
            XCTAssertEqual(whole?.checked, true)
        }
    }

    func testChoosingRunsTheRightAction() {
        var log: [String] = []
        var a = P.Actions()
        a.pickKind = { log.append("kind:\($0.rawValue)") }
        a.pickDisplay = { log.append("display:\($0)") }
        a.pickWindow = { log.append("window:\($0.bundleID)/\($0.title)") }
        a.pickShape = { log.append("shape:\($0)") }
        a.pickLayout = { log.append("layout:\($0)") }
        let m = menu(state(), a)
        m.entry(titled: "Automatic (main display)")?.action?()
        m.entry(titled: "Studio \u{2014} 2560\u{00D7}1440")?.action?()
        m.entry(titled: "Chrome \u{2013} Lesson")?.action?()
        m.entry(titled: "Whiteboard")?.action?()
        m.entry(titled: "Just my camera")?.action?()
        m.entry(titled: "Square")?.action?()
        m.entry(titled: "Teach")?.action?()
        XCTAssertEqual(log, ["display:", "display:B", "window:com.google.Chrome/Lesson",
                             "kind:whiteboard", "kind:nothing", "shape:square", "layout:L1"])
        let single = menu(state { $0.displays = [] }, a)
        single.entry(titled: "Whole screen")?.action?()
        XCTAssertEqual(log.last, "kind:display")
    }

    func testNoCameraGreysCameraOnlyAndLookWithAReason() {
        let m = menu(state { $0.cameraOff = true })
        let camera = m.entry(titled: "Just my camera")
        XCTAssertEqual(camera?.enabled, false)
        XCTAssertEqual(camera?.note, P.noCameraNote)
        let look = m.entry(titled: "Look")
        XCTAssertEqual(look?.enabled, false)
        XCTAssertEqual(look?.note, P.cameraOffNote)
        // The screen choices still work.
        XCTAssertEqual(m.entry(titled: "Whiteboard")?.enabled, true)
        XCTAssertEqual(m.entry(titled: "One window")?.enabled, true)
    }

    func testWithACameraBothAreOn() {
        let m = menu(state())
        XCTAssertEqual(m.entry(titled: "Just my camera")?.enabled, true)
        XCTAssertNil(m.entry(titled: "Just my camera")?.note)
        XCTAssertEqual(m.entry(titled: "Look")?.enabled, true)
    }

    func testLayoutIsHiddenWhenItDoesNotApply() {
        XCTAssertNil(menu(state { $0.layoutsAvailable = false }).entry(titled: "Layout"))
        XCTAssertNil(menu(state { $0.liveLayoutID = nil }).entry(titled: "Layout"))
        XCTAssertNil(menu(state { $0.layouts = [] }).entry(titled: "Layout"))
        XCTAssertNotNil(menu(state()).entry(titled: "Layout"))
    }

    func testEmptyListsSayWhySoTheSubmenuIsNeverBlank() {
        let m = menu(state { $0.windows = [] })
        XCTAssertEqual(m.entry(titled: "One window")?.children.map(\.title), ["No window to share"])
        XCTAssertEqual(m.entry(titled: "No window to share")?.enabled, false)
    }
}
