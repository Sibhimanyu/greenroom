import XCTest
@testable import GreenroomTests

/// R3 (the guide follows the page), R5 (fill decision, auto check), R4 (step rows and buttons).
final class ZoomGuideFollowRulesTests: XCTestCase {
    private let id = "AbC_123-xyZ789qrstuvw1"

    // MARK: One continuous run: 7 steps across both apps

    func testOneRunOfEightStepsInZoomsOwnOrder() {
        XCTAssertEqual(ZoomRun.total, 8)
        XCTAssertEqual(ZoomRun.names, ["Create the meeting app", "Copy its keys", "Turn on Meeting SDK",
                                       "Create the hosting app", "Copy its keys", "Fill in Information", "Add the permissions", "Turn it on"])
        XCTAssertEqual(ZoomRun.counter(5), "Step 5 of 8")
        XCTAssertEqual(ZoomRun.firstStep(of: .meetingApp), 1)
        XCTAssertEqual(ZoomRun.firstStep(of: .hostingApp), 4)
        XCTAssertNil(ZoomRun.firstStep(of: .check))
        XCTAssertEqual(ZoomRun.part(ofStep: 3), .meetingApp)
        XCTAssertEqual(ZoomRun.part(ofStep: 4), .hostingApp)
        XCTAssertEqual(ZoomRun.name(2), "Copy its keys")
        XCTAssertEqual(ZoomRun.name(0), "")
        XCTAssertEqual(ZoomRun.name(9), "")
        for n in ZoomRun.names { XCTAssertFalse(n.lowercased().contains("class")) }
    }

    // MARK: R3

    func testEveryPageTimesPartPicksItsStep() {
        typealias Row = (ZoomGuidePart, ZoomMarketplacePage, Int?)
        let table: [Row] = [
            (.meetingApp, .createdApps, 1), (.meetingApp, .chooseType(id), 1),
            (.meetingApp, .general(id, .information), 2), (.meetingApp, .general(id, .embed), 3),
            (.meetingApp, .general(id, .scopes), nil), (.meetingApp, .general(id, .other), nil),
            (.meetingApp, .s2s(id, .scopes), nil), (.meetingApp, .s2s(id, .credentials), nil),
            (.meetingApp, .signIn, nil),
            (.hostingApp, .createdApps, 4), (.hostingApp, .chooseType(id), 4),
            (.hostingApp, .s2s(id, .credentials), 5),
            (.hostingApp, .s2s(id, .information), 6), (.hostingApp, .s2s(id, .feature), 6),
            (.hostingApp, .s2s(id, .scopes), 7), (.hostingApp, .s2s(id, .activation), 8),
            (.hostingApp, .general(id, .embed), nil), (.hostingApp, .general(id, .information), nil),
            (.hostingApp, .signIn, nil),
            (.check, .createdApps, nil), (.check, .s2s(id, .credentials), nil),
        ]
        for (part, page, step) in table {
            XCTAssertEqual(ZoomGuideFollowRules.step(part: part, page: page), step, "\(part) \(page)")
        }
        XCTAssertNil(ZoomGuideFollowRules.step(part: .meetingApp, page: nil))
    }

    func testThePageOpensItsPart() {
        let f = ZoomGuideFollowRules.part
        XCTAssertEqual(f(.s2s(id, .scopes), .meetingApp, false), .hostingApp)
        XCTAssertEqual(f(.general(id, .embed), .hostingApp, false), .meetingApp)
        XCTAssertEqual(f(.general(id, .embed), nil, false), .meetingApp)
        XCTAssertEqual(f(.s2s(id, .credentials), .hostingApp, false), .hostingApp)
        // Neutral pages stay with whatever is open.
        XCTAssertNil(f(.createdApps, .meetingApp, false))
        XCTAssertNil(f(.chooseType(id), .hostingApp, false))
        XCTAssertNil(f(.signIn, .hostingApp, false))
    }

    func testAPageOfTheOtherKindDoesNotStealAPartWithTyping() {
        let f = ZoomGuideFollowRules.part
        XCTAssertNil(f(.s2s(id, .scopes), .meetingApp, true))
        XCTAssertNil(f(.general(id, .embed), .hostingApp, true))
        XCTAssertEqual(f(.general(id, .embed), .meetingApp, true), .meetingApp)
    }

    // MARK: R5

    private func decide(_ cur: [ZoomKeyField: String], _ found: [ZoomKeyField: String]) -> ZoomKeyFillDecision {
        ZoomKeyFillRules.decide(current: cur, found: found)
    }
    private let a = "AccountAAAA11", c = "ClientBBBBB22", s = "SecretCCCCC33"

    func testEmptyFieldsAreFilled() {
        let found: [ZoomKeyField: String] = [.accountID: a, .clientID: c, .clientSecret: s]
        XCTAssertEqual(decide([:], found), .fill(found))
        XCTAssertEqual(decide([.accountID: "", .clientID: " ", .clientSecret: ""], found), .fill(found))
    }

    func testSameValuesDoNothing() {
        XCTAssertEqual(decide([.clientID: c, .clientSecret: s], [.clientID: c, .clientSecret: s]), .nothing)
        XCTAssertEqual(decide([.clientID: " " + c + " "], [.clientID: c]), .nothing)
        XCTAssertEqual(decide([.clientID: c], [:]), .nothing)
    }

    func testADifferentValueIsOnlyOffered() {
        let found: [ZoomKeyField: String] = [.clientID: c, .clientSecret: s]
        XCTAssertEqual(decide([.clientID: "OldClientXXXX9", .clientSecret: ""], found), .offer(found))
        // The same one is not offered again.
        XCTAssertEqual(decide([.clientID: c, .clientSecret: "OldSecretXXXX9"], found), .offer([.clientSecret: s]))
    }

    func testEmptyAndSameTogetherFillsTheEmptyOnes() {
        XCTAssertEqual(decide([.clientID: c, .clientSecret: ""], [.clientID: c, .clientSecret: s]), .fill([.clientSecret: s]))
    }

    func testAPartialReadOffersOrFillsOnlyWhatWasFound() {
        XCTAssertEqual(decide([:], [.clientID: c]), .fill([.clientID: c]))
        XCTAssertEqual(decide([.clientID: "OldClientXXXX9", .clientSecret: s], [.clientID: c]), .offer([.clientID: c]))
        // A field not found is never touched.
        XCTAssertEqual(decide([.accountID: "OldAcctXXXXXX9"], [.clientID: c]), .fill([.clientID: c]))
    }

    func testValuesThatAreNotKeysAreDropped() {
        XCTAssertEqual(decide([:], [.clientID: "short", .clientSecret: s]), .fill([.clientSecret: s]))
        XCTAssertEqual(decide([:], [.clientID: "has a space inside", .clientSecret: "\u{2022}\u{2022}\u{2022}"]), .nothing)
    }

    func testAutoCheckStartsOnceWhenBothPartsBecomeFilledByTheWindow() {
        let go = ZoomKeyFillRules.shouldAutoCheck
        XCTAssertTrue(go(false, true, false, false))
        XCTAssertFalse(go(true, true, false, false))    // already both: not again
        XCTAssertFalse(go(false, false, false, false))
        XCTAssertFalse(go(false, true, true, false))    // a session is live
        XCTAssertFalse(go(false, true, false, true))    // a check is already running
    }

    // MARK: R4

    func testStepsMatchTheGuide() {
        XCTAssertEqual(ZoomMarketplaceGuide.sdkSteps.count, 3)
        XCTAssertEqual(ZoomMarketplaceGuide.s2sSteps.count, 4)
        for t in ZoomMarketplaceGuide.sdkSteps + ZoomMarketplaceGuide.s2sSteps {
            XCTAssertFalse(t.lowercased().contains("class"), t)
        }
    }

    func testBeforeAnIDIsKnownOnlyStepOneHasAButton() {
        for part in [ZoomGuidePart.meetingApp, .hostingApp] {
            let rows = ZoomMarketplaceGuide.rows(part: part, ids: ZoomAppIDs())
            XCTAssertEqual(rows.first?.link, ZoomGuideRowLink(title: "Create the app", page: .createdApps))
            XCTAssertTrue(rows.dropFirst().allSatisfy { $0.link == nil })
        }
        XCTAssertEqual(ZoomMarketplaceGuide.rows(part: .meetingApp, ids: ZoomAppIDs()).count, 3)
        XCTAssertEqual(ZoomMarketplaceGuide.rows(part: .hostingApp, ids: ZoomAppIDs()).count, 4)
    }

    func testOnceAnIDIsKnownTheRowsLinkToTheExactPages() {
        let meeting = ZoomMarketplaceGuide.rows(part: .meetingApp, ids: ZoomAppIDs(meeting: id))
        XCTAssertEqual(meeting.map { $0.link?.title }, [nil, "Open Embed", "Open Basic information"])
        XCTAssertEqual(meeting.map { $0.link?.page }, [nil, .general(id, .embed), .general(id, .information)])
        let hosting = ZoomMarketplaceGuide.rows(part: .hostingApp, ids: ZoomAppIDs(hosting: id))
        XCTAssertEqual(hosting.map { $0.link?.title }, [nil, "Open Scopes", "Open Activation", "Open App Credentials"])
        XCTAssertEqual(hosting.map { $0.link?.page }, [nil, .s2s(id, .scopes), .s2s(id, .activation), .s2s(id, .credentials)])
        // The other kind's ID changes nothing.
        XCTAssertEqual(ZoomMarketplaceGuide.rows(part: .hostingApp, ids: ZoomAppIDs(meeting: id)).first?.link?.title, "Create the app")
    }
}
