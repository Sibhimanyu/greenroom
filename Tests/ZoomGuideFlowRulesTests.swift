import XCTest

/// The setup guide's Zoom step is a guided flow (owner, 2026-11-26): three
/// numbered parts, each with its own state, only the current one open. One
/// table: every state, its part states, the open part, the footer's note, and
/// where Settings' one button lands.
final class ZoomGuideFlowRulesTests: XCTestCase {

    private struct Row {
        let name: String
        let facts: ZoomGuideFlowFacts
        let flow: ZoomGuideFlow
        let labels: [String]
        let entry: ZoomSetupEntry
    }

    private static func f(_ sdk: Int, _ s2s: Int, _ check: ZoomGuideCheckState = .notRun,
                          sdkFix: Bool = false, s2sFix: Bool = false) -> ZoomGuideFlowFacts {
        ZoomGuideFlowFacts(sdkFilled: sdk, s2sFilled: s2s, check: check,
                           meetingAppNeedsFix: sdkFix, hostingAppNeedsFix: s2sFix)
    }

    private static let notConnected = "Zoom isn\u{2019}t connected yet; you can finish this later in Settings \u{2192} Zoom."
    private static let notChecked = "Zoom is set up. Run Check Zoom setup to make sure it works."
    private static let setUp = "Set up Zoom\u{2026}"
    private static let cont = "Continue setup\u{2026}"
    private static let edit = "Edit setup\u{2026}"

    private static let rows: [Row] = [
        Row(name: "nothing filled in",
            facts: f(0, 0),
            flow: ZoomGuideFlow(meetingApp: .notStarted, hostingApp: .notStarted, check: .notStarted,
                                open: .meetingApp, footerNote: notConnected),
            labels: ["Not started", "Not started", "Not run yet"],
            entry: ZoomSetupEntry(title: setUp, spot: .zoomStep)),
        Row(name: "meeting app half filled",
            facts: f(1, 0),
            flow: ZoomGuideFlow(meetingApp: .inProgress, hostingApp: .notStarted, check: .notStarted,
                                open: .meetingApp, footerNote: notConnected),
            labels: ["In progress", "Not started", "Not run yet"],
            entry: ZoomSetupEntry(title: cont, spot: .zoomStep)),
        Row(name: "part 1 done",
            facts: f(2, 0),
            flow: ZoomGuideFlow(meetingApp: .done, hostingApp: .notStarted, check: .notStarted,
                                open: .hostingApp, footerNote: notConnected),
            labels: ["Done", "Not started", "Not run yet"],
            entry: ZoomSetupEntry(title: cont, spot: .zoomStep)),
        Row(name: "part 1 done, part 2 under way",
            facts: f(2, 2),
            flow: ZoomGuideFlow(meetingApp: .done, hostingApp: .inProgress, check: .notStarted,
                                open: .hostingApp, footerNote: notConnected),
            labels: ["Done", "In progress", "Not run yet"],
            entry: ZoomSetupEntry(title: cont, spot: .zoomStep)),
        Row(name: "only the hosting app filled in",
            facts: f(0, 3),
            flow: ZoomGuideFlow(meetingApp: .notStarted, hostingApp: .done, check: .notStarted,
                                open: .meetingApp, footerNote: notConnected),
            labels: ["Not started", "Done", "Not run yet"],
            entry: ZoomSetupEntry(title: cont, spot: .zoomStep)),
        Row(name: "parts 1 and 2 done, not checked",
            facts: f(2, 3),
            flow: ZoomGuideFlow(meetingApp: .done, hostingApp: .done, check: .notStarted,
                                open: .check, footerNote: notChecked),
            labels: ["Done", "Done", "Not run yet"],
            entry: ZoomSetupEntry(title: edit, spot: .zoomStep)),
        Row(name: "checking",
            facts: f(2, 3, .running),
            flow: ZoomGuideFlow(meetingApp: .done, hostingApp: .done, check: .inProgress,
                                open: .check, footerNote: notConnected),
            labels: ["Done", "Done", "Checking\u{2026}"],
            entry: ZoomSetupEntry(title: edit, spot: .zoomStep)),
        Row(name: "all done and checked",
            facts: f(2, 3, .passed),
            flow: ZoomGuideFlow(meetingApp: .done, hostingApp: .done, check: .done,
                                open: nil, footerNote: nil),
            labels: ["Done", "Done", "Passed"],
            entry: ZoomSetupEntry(title: edit, spot: .zoomStep)),
        Row(name: "check failed in the hosting app (missing scopes)",
            facts: f(2, 3, .failed, s2sFix: true),
            flow: ZoomGuideFlow(meetingApp: .done, hostingApp: .inProgress, check: .inProgress,
                                open: .hostingApp, footerNote: notConnected),
            labels: ["Done", "Needs a fix", "Needs a fix"],
            entry: ZoomSetupEntry(title: cont, spot: .zoomStep)),
        Row(name: "check failed in the meeting app (bad keys)",
            facts: f(2, 3, .failed, sdkFix: true),
            flow: ZoomGuideFlow(meetingApp: .inProgress, hostingApp: .done, check: .inProgress,
                                open: .meetingApp, footerNote: notConnected),
            labels: ["Needs a fix", "Done", "Needs a fix"],
            entry: ZoomSetupEntry(title: cont, spot: .zoomStep)),
        Row(name: "check failed, nothing to fix in either app (offline)",
            facts: f(2, 3, .failed),
            flow: ZoomGuideFlow(meetingApp: .done, hostingApp: .done, check: .inProgress,
                                open: .check, footerNote: notConnected),
            labels: ["Done", "Done", "Needs a fix"],
            entry: ZoomSetupEntry(title: edit, spot: .zoomStep)),
    ]

    func testEveryState() {
        for row in Self.rows {
            XCTAssertEqual(ZoomGuideFlowRules.flow(row.facts), row.flow, row.name)
            XCTAssertEqual(ZoomGuidePart.allCases.map { ZoomGuideFlowRules.label($0, row.facts) }, row.labels, row.name)
            XCTAssertEqual(ZoomGuideFlowRules.setupEntry(row.facts), row.entry, row.name)
        }
    }

    /// "Show me where" and Settings' button open the part that holds the spot.
    func testDeepLinksOpenTheirPart() {
        XCTAssertEqual(ZoomGuideFlowRules.part(for: .sdkCredentials), .meetingApp)
        XCTAssertEqual(ZoomGuideFlowRules.part(for: .s2sCredentials), .hostingApp)
        XCTAssertEqual(ZoomGuideFlowRules.part(for: .s2sScopes), .hostingApp)
        XCTAssertEqual(ZoomGuideFlowRules.part(for: .s2sActivation), .hostingApp)
        XCTAssertNil(ZoomGuideFlowRules.part(for: .zoomStep))
    }

    /// The facts from the fields and the last check: the app a failed line's fix is in needs a fix.
    func testFactsComeFromTheFieldsAndTheCheck() {
        let ids = ZoomCheckActionContext()
        func line(_ id: String, _ status: ZoomCheckStatus, _ problem: ZoomCheckProblem) -> ZoomCheckLine {
            ZoomCheckLine(id: id, title: id, status: status, detail: "",
                          actions: ZoomCheckActionRules.buttons(.ownApps, check: id, status: status, problem: problem, ids: ids))
        }
        let fields = (sdk: ["id", " "], s2s: ["a", "b", "c"])
        let none = ZoomGuideFlowRules.facts(sdkFields: fields.sdk, s2sFields: fields.s2s, lines: [], running: false)
        XCTAssertEqual(none, ZoomGuideFlowFacts(sdkFilled: 1, s2sFilled: 3, check: .notRun))
        XCTAssertEqual(ZoomGuideFlowRules.facts(sdkFields: fields.sdk, s2sFields: fields.s2s, lines: [], running: true).check, .running)
        let scopes = ZoomGuideFlowRules.facts(sdkFields: fields.sdk, s2sFields: fields.s2s,
                                              lines: [line("sdk", .passed, .nothing), line("update", .failed, .missingScopes(["x"]))],
                                              running: false)
        XCTAssertEqual(scopes, ZoomGuideFlowFacts(sdkFilled: 1, s2sFilled: 3, check: .failed,
                                                  meetingAppNeedsFix: false, hostingAppNeedsFix: true))
        let badSDK = ZoomGuideFlowRules.facts(sdkFields: fields.sdk, s2sFields: fields.s2s,
                                              lines: [line("sdk", .failed, .badCredentials)], running: false)
        XCTAssertTrue(badSDK.meetingAppNeedsFix)
        XCTAssertFalse(badSDK.hostingAppNeedsFix)
        let offline = ZoomGuideFlowRules.facts(sdkFields: fields.sdk, s2sFields: fields.s2s,
                                               lines: [line("account", .failed, .network)], running: false)
        XCTAssertEqual(offline.check, .failed)
        XCTAssertFalse(offline.meetingAppNeedsFix || offline.hostingAppNeedsFix)
        let passed = ZoomGuideFlowRules.facts(sdkFields: fields.sdk, s2sFields: fields.s2s,
                                              lines: [line("sdk", .passed, .nothing), line("x", .warned, .other)], running: false)
        XCTAssertEqual(passed.check, .passed)
    }

    func testThePartsAreNumberedInOrder() {
        XCTAssertEqual(ZoomGuidePart.allCases.map(\.number), [1, 2, 3])
        XCTAssertEqual(ZoomGuidePart.allCases.map(\.title), ["Meeting app", "Hosting app", "Check"])
    }

    func testNoWordSaysClass() {
        for row in Self.rows {
            let words = row.labels + [row.flow.footerNote ?? "", row.entry.title]
                + ZoomGuidePart.allCases.flatMap { [$0.title, $0.subtitle] }
            for w in words { XCTAssertFalse(w.lowercased().contains("class"), w) }
        }
    }
}
