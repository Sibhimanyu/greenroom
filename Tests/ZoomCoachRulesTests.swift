import XCTest
@testable import GreenroomTests

/// R6: which control the coach points at on each page, and what its card says.
final class ZoomCoachRulesTests: XCTestCase {
    private let id = "AbC_123-xyZ789qrstuvw1"

    private func coach(_ part: ZoomGuidePart, _ page: ZoomMarketplacePage, filled: Bool = false, tips: Bool = true) -> ZoomCoach? {
        ZoomCoachRules.coach(part: part, page: page, keysFilled: filled, tipsOn: tips)
    }

    func testChooseTypePointsAtTheRightRadioForThePart() {
        XCTAssertEqual(coach(.hostingApp, .chooseType(id)),
                       ZoomCoach(label: "Server to server OAuth app", kind: .row, counter: "Step 1 of 4",
                                 text: "Choose Server to server OAuth app, then press Create."))
        XCTAssertEqual(coach(.meetingApp, .chooseType(id)),
                       ZoomCoach(label: "General app", kind: .row, counter: "Step 1 of 3",
                                 text: "Choose General app, then press Create."))
    }

    func testScopesPointAtAddScopesAndKnowTheSearchFieldText() {
        XCTAssertEqual(coach(.hostingApp, .s2s(id, .scopes)),
                       ZoomCoach(label: "Add Scopes", kind: .control, counter: "Step 2 of 4",
                                 text: "Press + Add Scopes.",
                                 searchText: "Paste one scope, tick it, repeat. Copy scopes is in the guide."))
    }

    func testActivationAndEmbed() {
        XCTAssertEqual(coach(.hostingApp, .s2s(id, .activation)),
                       ZoomCoach(label: "Activate", kind: .control, counter: "Step 3 of 4", text: "Press Activate to turn the app on."))
        XCTAssertEqual(coach(.meetingApp, .general(id, .embed)),
                       ZoomCoach(label: "Meeting SDK", kind: .toggle, counter: "Step 2 of 3", text: "Turn on Meeting SDK."))
    }

    func testCredentialsPagesHaveNoSpotlightAndSpeakOnlyAfterTheFill() {
        XCTAssertNil(coach(.hostingApp, .s2s(id, .credentials)))
        XCTAssertNil(coach(.meetingApp, .general(id, .information)))
        XCTAssertEqual(coach(.hostingApp, .s2s(id, .credentials), filled: true),
                       ZoomCoach(label: nil, kind: .none, counter: "Step 4 of 4", text: "Got it: the keys are in Greenroom."))
        XCTAssertEqual(coach(.meetingApp, .general(id, .information), filled: true)?.counter, "Step 3 of 3")
    }

    func testNoCoachWhereThereIsNothingToSay() {
        XCTAssertNil(coach(.hostingApp, .createdApps))
        XCTAssertNil(coach(.hostingApp, .signIn))
        XCTAssertNil(coach(.hostingApp, .s2s(id, .information)))
        XCTAssertNil(coach(.hostingApp, .general(id, .embed)))   // the other kind
        XCTAssertNil(coach(.meetingApp, .s2s(id, .scopes)))
        XCTAssertNil(coach(.check, .chooseType(id)))
    }

    func testTipsOffMeansNoCoach() {
        XCTAssertNil(coach(.hostingApp, .chooseType(id), tips: false))
        XCTAssertNil(coach(.hostingApp, .s2s(id, .credentials), filled: true, tips: false))
    }

    func testTheCardTextTravelsAsJSONAndNeverSaysClass() throws {
        let c = try XCTUnwrap(coach(.hostingApp, .s2s(id, .scopes)))
        let obj = try JSONSerialization.jsonObject(with: Data(c.json.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["label"] as? String, "Add Scopes")
        XCTAssertEqual(obj?["kind"] as? String, "control")
        XCTAssertEqual(obj?["counter"] as? String, "Step 2 of 4")
        XCTAssertNotNil(obj?["searchText"] as? String)
        for t in [c.text, c.searchText ?? ""] { XCTAssertFalse(t.lowercased().contains("class")) }
    }

    func testTheCoachScriptIsAClosedShadowRootThatNeverClicks() {
        let js = ZoomCoachScript.source
        XCTAssertTrue(js.contains("mode: 'closed'"))
        XCTAssertTrue(js.contains("pointer-events: none"))
        XCTAssertTrue(js.contains("prefers-reduced-motion"))
        for banned in [".click(", ".focus(", "dispatchEvent", ".submit(", "console.", "fetch(", "XMLHttpRequest"] {
            XCTAssertFalse(js.contains(banned), banned)
        }
    }

    // The Greenroom mark on every card, so the tip is plainly Greenroom's.

    func testTheMarkTravelsAsADataURIAndNeverAsAnAddress() {
        let ok = "data:image/png;base64,iVBORw0KGgo+/="
        XCTAssertEqual(ZoomCoachScript.safeMark(ok), ok)
        XCTAssertNil(ZoomCoachScript.safeMark("https://example.com/mark.png"))
        XCTAssertNil(ZoomCoachScript.safeMark("data:text/html;base64,AAAA"))
        XCTAssertNil(ZoomCoachScript.safeMark("data:image/png;base64,AA'AA"))
        XCTAssertNil(ZoomCoachScript.safeMark(""))
        let call = ZoomCoachScript.call("null", ring: "rgb(1,2,3)", mark: ok)
        XCTAssertTrue(call.contains(ok))
        let bad = ZoomCoachScript.call("null", ring: "rgb(1,2,3)", mark: "https://example.com/mark.png")
        XCTAssertFalse(bad.contains("example.com"))
    }

    func testTheCardHeaderIsMarkNameAndCounter() {
        let js = ZoomCoachScript.source
        XCTAssertTrue(js.contains("'Greenroom'"))
        XCTAssertTrue(js.contains("font-weight:600"))
        XCTAssertFalse(js.contains("http"), "no address anywhere in the script")
    }

    // R15: Created apps is a real step, always coached.

    /// Zoom's create flow happens inside Created apps (owner live test, 2026-11-27): + opens a
    /// menu, Build opens the "What kind of app" dialog, then a choice and Create. The address
    /// never changes, so the coach carries the later stages and the page picks the furthest shown.
    func testTheCreateFlowFollowsTheMenuAndTheDialog() {
        XCTAssertEqual(ZoomCoachRules.createFlow(.meetingApp), [
            ZoomCoachStage(kind: .menuItem, label: "Build", text: "Press Build."),
            ZoomCoachStage(kind: .chooseRow, label: "General app", text: "Choose General app."),
            ZoomCoachStage(kind: .createAfter, label: "General app", text: "Press Create."),
        ])
        XCTAssertEqual(ZoomCoachRules.createFlow(.hostingApp).map(\.label),
                       ["Build", "Server to server OAuth app", "Server to server OAuth app"])
        XCTAssertEqual(created(.meetingApp, [])?.then, ZoomCoachRules.createFlow(.meetingApp))
        XCTAssertEqual(created(.hostingApp, [s2s, general])?.then, ZoomCoachRules.createFlow(.hostingApp),
                       "someone with an app may still build a new one")
    }

    private func created(_ part: ZoomGuidePart, _ rows: [String]?, tips: Bool = true) -> ZoomCoach? {
        ZoomCoachRules.coach(part: part, page: .createdApps, keysFilled: false, tipsOn: tips, appRows: rows)
    }
    private let general = "General app \u{00B7} User Managed", s2s = "Server-to-Server OAuth \u{00B7} Intend to publish: No"

    func testOneMatchingRowIsSpotlitAndNamedForThePart() {
        XCTAssertEqual(created(.meetingApp, [s2s, general]),
                       ZoomCoach(label: nil, kind: .appRow, counter: "Step 1 of 3", text: "This is your Meeting app. Click it.", rowIndex: 1, then: ZoomCoachRules.createFlow(.meetingApp)))
        XCTAssertEqual(created(.hostingApp, [s2s, general]),
                       ZoomCoach(label: nil, kind: .appRow, counter: "Step 1 of 4", text: "This is your Hosting app. Click it.", rowIndex: 0, then: ZoomCoachRules.createFlow(.hostingApp)))
    }

    func testSeveralMatchingRowsSpotlightTheFirst() {
        XCTAssertEqual(created(.meetingApp, [s2s, general, "General app", general]),
                       ZoomCoach(label: nil, kind: .appRow, counter: "Step 1 of 3", text: "Click the General app you made for Greenroom.", rowIndex: 1, then: ZoomCoachRules.createFlow(.meetingApp)))
        XCTAssertEqual(created(.hostingApp, [general, s2s, s2s]),
                       ZoomCoach(label: nil, kind: .appRow, counter: "Step 1 of 4", text: "Click the Server-to-Server OAuth app you made for Greenroom.", rowIndex: 1, then: ZoomCoachRules.createFlow(.hostingApp)))
    }

    func testNoMatchingRowPointsAtThePlusButton() {
        XCTAssertEqual(created(.meetingApp, [s2s]),
                       ZoomCoach(label: nil, kind: .build, counter: "Step 1 of 3", text: "Press + to build your Meeting app.", then: ZoomCoachRules.createFlow(.meetingApp)))
        XCTAssertEqual(created(.hostingApp, []),
                       ZoomCoach(label: nil, kind: .build, counter: "Step 1 of 4", text: "Press + to build your Hosting app.", then: ZoomCoachRules.createFlow(.hostingApp)))
        XCTAssertEqual(created(.hostingApp, [general])?.kind, .build)
    }

    func testTypeTextIsMatchedLooselyButNeverByAppName() {
        XCTAssertEqual(ZoomCoachRules.matchingRows(.hostingApp, ["server to server oauth app", "GENERAL APP"]), [0])
        XCTAssertEqual(ZoomCoachRules.matchingRows(.meetingApp, ["server to server oauth app", "GENERAL APP"]), [1])
        XCTAssertEqual(ZoomCoachRules.matchingRows(.meetingApp, ["Greenroom", "Webhook only app"]), [])
        XCTAssertEqual(ZoomCoachRules.matchingRows(.check, [general]), [])
    }

    func testNotScannedYetOrTipsOffMeansNoCoach() {
        XCTAssertNil(created(.meetingApp, nil))
        XCTAssertNil(created(.meetingApp, [general], tips: false))
        XCTAssertNil(created(.check, [general]))
    }

    func testTheRowIndexTravelsInTheJSON() throws {
        let c = try XCTUnwrap(created(.meetingApp, [s2s, general]))
        let obj = try JSONSerialization.jsonObject(with: Data(c.json.utf8)) as? [String: Any]
        XCTAssertEqual(obj?["kind"] as? String, "appRow")
        XCTAssertEqual(obj?["rowIndex"] as? Int, 1)
    }

    func testTheScriptsShareOneRowScanAndReportAStatus() {
        let js = ZoomCoachScript.source
        XCTAssertTrue(js.contains("scanAppRows"))
        for status in ["'drawn'", "'no-target'", "'cleared'"] { XCTAssertTrue(js.contains(status), status) }
        let scan = ZoomAppListScript.source
        XCTAssertTrue(scan.contains("scanAppRows"))
        for banned in [".click(", ".focus(", "dispatchEvent", ".submit(", "console.", "fetch(", "XMLHttpRequest", "postMessage", "localStorage", "document.cookie", ".value ="] {
            XCTAssertFalse(scan.contains(banned), banned)
        }
    }

    func testThePasskeyPageSaysWhatToDoInsteadAndStillShowsIfTheButtonIsMissing() {
        let expected = ZoomCoach(label: "Try another way", kind: .control, counter: "",
                                 text: "Passkeys don\u{2019}t work in this window. Press Try another way and use your password, or sign in in Safari.",
                                 optional: true)
        for part in [ZoomGuidePart.meetingApp, .hostingApp, .check] {
            XCTAssertEqual(ZoomCoachRules.coach(part: part, page: .passkey, keysFilled: false, tipsOn: true), expected)
        }
        XCTAssertNil(ZoomCoachRules.coach(part: .meetingApp, page: .passkey, keysFilled: false, tipsOn: false))
        XCTAssertTrue(ZoomCoachScript.source.contains("optional"))
    }
}
