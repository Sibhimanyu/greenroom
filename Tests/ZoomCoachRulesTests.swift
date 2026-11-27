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
}
