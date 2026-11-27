import XCTest
@testable import GreenroomTests

/// Seam 1 (docs/specs/zoom-setup-flow.md, "The guide: every step"): `step(for:)` against the step table, written out
/// by hand here (number, card title, where), never derived from the code.
final class ZoomSetupFlowTests: XCTestCase {
    private let mid = "meetingAppIdIdIdIdId1", hid = "hostingAppIdIdIdIdId1"
    private let allScopes = Set(ZoomScopes.names)

    /// Everything done by evidence, keys copied last and stored.
    private func finished() -> SetupFacts {
        var e = Evidence()
        e.signedIn = true
        e.apps[.meeting] = AppEvidence(id: mid, clientID: "mc", sdkOn: true, keysAt: 10)
        e.apps[.hosting] = AppEvidence(id: hid, clientID: "hc", infoFilled: true, infoMissing: [], scopes: allScopes, activated: true, keysAt: 10)
        e.tick = 10
        return SetupFacts(evidence: e, stored: [.meeting: [.clientID: "mc", .clientSecret: "ms"],
                                                .hosting: [.accountID: "ha", .clientID: "hc", .clientSecret: "hs"]])
    }

    private func at(_ place: ZoomMarketplacePage, _ f: SetupFacts) -> SetupFacts {
        var f = f; f.snapshot = ZoomPageSnapshot(address: place, signedIn: true); return f
    }

    // MARK: The table

    func testEachRowOfTheTable() {
        typealias Row = (String, (inout SetupFacts) -> Void, Int?, String)
        let rows: [Row] = [
            ("signed out", { $0.evidence.signedIn = false }, nil, "Sign in to Zoom"),
            ("nothing yet", { $0 = SetupFacts() }, 1, "Create the meeting app"),
            ("no Meeting SDK", { $0.evidence.apps[.meeting]?.sdkOn = false; $0.evidence.apps[.meeting]?.keysAt = nil }, 2, "Turn on Meeting SDK"),
            ("meeting keys not stored", { $0.stored[.meeting] = nil }, 3, "Copy its keys"),
            ("no hosting app", { $0.evidence.apps[.hosting] = nil }, 4, "Create the hosting app"),
            ("information empty", { $0.evidence.apps[.hosting]?.infoFilled = false; $0.evidence.apps[.hosting]?.activated = nil }, 5, "Fill in Information"),
            ("scopes missing", { $0.evidence.apps[.hosting]?.scopes = Set(ZoomScopes.names.prefix(7)); $0.evidence.apps[.hosting]?.activated = nil }, 6, "Add the permissions"),
            ("not activated", { $0.evidence.apps[.hosting]?.activated = false }, 7, "Turn it on"),
            ("hosting keys not stored", { $0.stored[.hosting] = nil }, 8, "Copy its keys"),
        ]
        for (name, change, number, title) in rows {
            var f = finished(); change(&f)
            let step = ZoomSetupFlow.step(for: f)
            XCTAssertEqual(step.number, number, name)
            XCTAssertEqual(step.title, title, name)
        }
    }

    func testWhenEverythingIsDoneButNotCheckedTheCheckIsTheStep() {
        let step = ZoomSetupFlow.step(for: finished())
        XCTAssertNil(step.number)
        XCTAssertEqual(step.cta, .checkAgain)
    }

    func testABothPassingCheckEndsInBackToGreenroom() {
        var f = finished()
        f.checks = [.meeting: AppCheck(passed: true, fixes: [], at: 10), .hosting: AppCheck(passed: true, fixes: [], at: 10)]
        XCTAssertEqual(ZoomSetupFlow.step(for: f).cta, .backToGreenroom)
        f.checkRunning = true
        XCTAssertEqual(ZoomSetupFlow.step(for: f).cta, .wait("Checking\u{2026}"))
    }

    // MARK: Away from the place, the action is a trip there

    func testAwayFromItsPlaceTheActionIsGoTo() {
        var f = finished(); f.evidence.apps[.meeting]?.sdkOn = false; f.evidence.apps[.meeting]?.keysAt = nil
        XCTAssertEqual(ZoomSetupFlow.step(for: at(.createdApps, f)).cta, .goTo(.general(mid, .embed), "Open Embed"))
        guard case .doThisStep = ZoomSetupFlow.step(for: at(.general(mid, .embed), f)).cta else { return XCTFail("on its page the step is done for you") }
    }

    // MARK: Failure mappings

    private func failing(_ app: ZoomApp, _ fixes: [SetupFix]) -> SetupFacts {
        var f = finished(); f.checks = [app: AppCheck(passed: false, fixes: fixes, at: 10)]; return f
    }

    func testAFailedCheckReopensTheStepItNames() {
        XCTAssertEqual(ZoomSetupFlow.step(for: failing(.meeting, [.keys])).number, 3)
        XCTAssertEqual(ZoomSetupFlow.step(for: failing(.meeting, [.embed])).number, 2)
        XCTAssertEqual(ZoomSetupFlow.step(for: failing(.hosting, [.scopes])).number, 6)
        XCTAssertEqual(ZoomSetupFlow.step(for: failing(.hosting, [.activation])).number, 7)
        XCTAssertEqual(ZoomSetupFlow.step(for: failing(.hosting, [.keys])).number, 8)
    }

    func testACheckThatPredatesAChangeIsIgnored() {
        var f = failing(.hosting, [.scopes])
        f.evidence.apps[.hosting]?.lastChange = 11   // something changed after the check started
        f.evidence.apps[.hosting]?.keysAt = 12
        f.evidence.tick = 12
        XCTAssertNil(ZoomSetupFlow.step(for: f).number, "the old verdict no longer describes the app")
    }

    // MARK: Keys are copied last

    func testKeysCopiedBeforeTheAppsLastSettingsChangeDoNotCount() {
        var f = finished()
        f.evidence.apps[.meeting]?.lastChange = 11    // Meeting SDK switched after the keys were copied
        f.evidence.tick = 11
        XCTAssertEqual(ZoomSetupFlow.step(for: f).number, 3)
        f.evidence.apps[.hosting]?.lastChange = 12    // activated after the hosting keys were copied
        f.evidence.apps[.meeting]?.keysAt = 13
        XCTAssertEqual(ZoomSetupFlow.step(for: f).number, 8)
    }

    func testKeysStoredForAnotherAppDoNotCount() {
        var f = finished()
        f.stored[.meeting]?[.clientID] = "someOtherApp"
        XCTAssertEqual(ZoomSetupFlow.step(for: f).number, 3)
    }

    // MARK: Existing apps and the person's pick

    func testAnExistingAppOfTheNeededTypeIsOfferedAndTheOtherChoiceBuildsOne() {
        var f = SetupFacts()
        f.snapshot = ZoomPageSnapshot(address: .createdApps, signedIn: true, appList: [.hosting, .meeting], controls: [.appRow(0), .appRow(1), .plus])
        XCTAssertEqual(ZoomSetupFlow.step(for: f).cta, .press(.appRow(1), "Use this app"))
        f.answers.buildNew = [.meeting]
        guard case .doThisStep(let plan) = ZoomSetupFlow.step(for: f).cta else { return XCTFail("build a new one") }
        XCTAssertEqual(plan.effect, .createsApp)
    }

    func testOpeningAnotherAppMovesTheEvidenceToIt() {
        var e = Evidence()
        var s = ZoomPageSnapshot(address: .general(mid, .information), signedIn: true)
        e = ZoomSetupFlow.absorb(s, into: e)
        e.apps[.meeting]?.sdkOn = true
        s.address = .general("otherMeetingAppIdIdId", .embed)
        e = ZoomSetupFlow.absorb(s, into: e)
        XCTAssertEqual(e.app(.meeting).id, "otherMeetingAppIdIdId")
        XCTAssertNil(e.app(.meeting).sdkOn, "what was known about the old app is not the new app's")
    }

    // MARK: The permission blocker

    func testDisabledInformationFieldsAreAnExplanationWithCheckAgain() {
        var f = finished(); f.evidence.apps[.hosting]?.infoFilled = nil; f.evidence.apps[.hosting]?.activated = nil
        f.evidence.apps[.hosting]?.infoLocked = true
        let step = ZoomSetupFlow.step(for: f)
        XCTAssertEqual(step.number, 5)
        XCTAssertEqual(step.cta, .checkAgain)
        XCTAssertTrue(step.status?.contains("Roles") ?? false)
    }

    func testAbsorbingADisabledInformationPageLocksIt() {
        let disabled = Dictionary(uniqueKeysWithValues: ZoomInfoField.allCases.map { ($0, ZoomInfoState.disabled) })
        let e = ZoomSetupFlow.absorb(ZoomPageSnapshot(address: .s2s(hid, .information), signedIn: true, infoFields: disabled), into: Evidence())
        XCTAssertTrue(e.app(.hosting).infoLocked)
        var open = disabled; open[.appName] = .filled; open[.shortDescription] = .empty
        let again = ZoomSetupFlow.absorb(ZoomPageSnapshot(address: .s2s(hid, .information), signedIn: true, infoFields: open), into: e)
        XCTAssertFalse(again.app(.hosting).infoLocked, "a field that can be typed in lifts the blocker")
    }

    // MARK: Information needs the person's contact only

    func testAnEmailNobodyKnowsIsAskedForNotMadeUp() {
        var f = finished(); f.evidence.apps[.hosting]?.infoFilled = false; f.evidence.apps[.hosting]?.activated = nil
        f.answers.info = InfoValues(name: "Pat")
        let place = ZoomMarketplacePage.s2s(hid, .information)
        f.snapshot = ZoomPageSnapshot(address: place, signedIn: true, infoFields: [.shortDescription: .empty, .companyName: .empty, .contactName: .empty, .contactEmail: .empty])
        guard case .fill(let c, _) = ZoomSetupFlow.step(for: f).cta else { return XCTFail("expected the person to type the email") }
        XCTAssertEqual(c, .infoField(.contactEmail))
    }

    func testOnlyEmptyRequiredFieldsAreTypedInto() {
        var f = finished(); f.evidence.apps[.hosting]?.infoFilled = false; f.evidence.apps[.hosting]?.activated = nil
        f.answers.info = InfoValues(name: "Pat", email: "pat@example.com")
        f.snapshot = ZoomPageSnapshot(address: .s2s(hid, .information), signedIn: true,
                                      infoFields: [.shortDescription: .filled, .companyName: .empty, .contactName: .filled, .contactEmail: .error])
        guard case .doThisStep(let plan) = ZoomSetupFlow.step(for: f).cta else { return XCTFail("expected a plan") }
        let typed = plan.steps.compactMap { step -> ZoomControl? in if case .type(let c, _) = step { return c } else { return nil } }
        XCTAssertEqual(typed, [.infoField(.companyName), .infoField(.contactEmail)], "what the person already filled is kept")
    }
}
