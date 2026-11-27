import XCTest
@testable import GreenroomTests

/// Seam 2 (docs/specs/zoom-setup-flow.md, "ZoomActor"): one plan run against a `ZoomPage`. The allow-list is the plan's
/// own controls (and never the person's), the deny-list wins at press time, every wait is verified, and a surprise
/// stops the run with a reason.
@MainActor
final class ZoomActorTests: XCTestCase {
    private func onEmbed(sdkOn: Bool) -> FixturePage {
        let zoom = FixturePage.freshAccount()
        let app = FixturePage.App(kind: .meeting, id: "meetingAppIdIdIdIdId1", clientID: "clientClientClient1", secret: "secretSecretSecret12", sdkOn: sdkOn)
        zoom.apps = [app]
        zoom.address = .general(app.id, .embed)
        return zoom
    }
    private func actor(_ zoom: FixturePage) -> ZoomActor { ZoomActor(page: zoom, pacing: .instant) }

    func testItDoesTheStepAndVerifiesItCameTrue() async {
        let zoom = onEmbed(sdkOn: false)
        let outcome = await actor(zoom).run(ZoomSetupFlow.sdkPlan)
        XCTAssertEqual(outcome, .done(captured: [:]))
        XCTAssertEqual(zoom.apps[0].sdkOn, true)
    }

    func testItNeverTogglesSomethingThatIsAlreadyRight() async {
        let zoom = onEmbed(sdkOn: true)
        _ = await actor(zoom).run(ZoomSetupFlow.sdkPlan)
        XCTAssertEqual(zoom.apps[0].sdkOn, true)
        XCTAssertFalse(zoom.log.contains(.press(.meetingSDKSwitch)), "the switch was not pressed")
    }

    func testTheDenyListWinsOnTheElementsOwnTextAtPressTime() async {
        let zoom = onEmbed(sdkOn: false)
        zoom.elementText[.meetingSDKSwitch] = "Deactivate"
        let outcome = await actor(zoom).run(ZoomSetupFlow.sdkPlan)
        XCTAssertEqual(outcome, .stopped(.denied(.meetingSDKSwitch)))
        XCTAssertEqual(zoom.apps[0].sdkOn, false)
    }

    func testControlsThatArePersonsOwnAreRefusedBeforeAnythingIsDone() async {
        let zoom = onEmbed(sdkOn: false)
        for control in [ZoomControl.signIn, .tryAnotherWay, .closeDialog] {
            let plan = ActionPlan(app: nil, effect: .nothing, steps: [.press(.meetingSDKSwitch), .press(control)])
            let outcome = await actor(zoom).run(plan)
            XCTAssertEqual(outcome, .stopped(.refused(control)))
        }
        XCTAssertTrue(zoom.log.isEmpty, "a refused plan does nothing at all, not even its first step")
        let typing = ActionPlan(app: nil, effect: .nothing, steps: [.type(.plus, "x")])
        let typed = await actor(zoom).run(typing)
        XCTAssertEqual(typed, .stopped(.refused(.plus)))
    }

    func testAScopeThatIsNotOneOfOursCannotBeTicked() async {
        let zoom = onEmbed(sdkOn: false)
        let plan = ActionPlan(app: .hosting, effect: .changesSettings, steps: [.press(.scopeCheckbox("account:write:admin"))])
        let outcome = await actor(zoom).run(plan)
        XCTAssertEqual(outcome, .stopped(.refused(.scopeCheckbox("account:write:admin"))))
    }

    func testAControlThatIsNotOnThePageStopsTheRun() async {
        let zoom = onEmbed(sdkOn: false)
        let plan = ActionPlan(app: nil, effect: .nothing, steps: [.press(.activate)])
        let outcome = await actor(zoom).run(plan)
        XCTAssertEqual(outcome, .stopped(.notFound(.activate)))
    }

    func testAWaitThatNeverComesTrueStopsWithWhatItWaitedFor() async {
        let zoom = onEmbed(sdkOn: false)
        let plan = ActionPlan(app: nil, effect: .nothing, steps: [.waitFor(.activated)])
        let outcome = await actor(zoom).run(plan)
        XCTAssertEqual(outcome, .stopped(.timedOut(.activated)))
    }

    func testBeingSignedOutStopsTheRun() async {
        let zoom = onEmbed(sdkOn: false)
        zoom.signedIn = false
        let outcome = await actor(zoom).run(ZoomSetupFlow.sdkPlan)
        XCTAssertEqual(outcome, .stopped(.signedOut))
    }

    /// Live finding: the General app's secret is only reachable by Zoom's own Copy, pressed deep; a plain press copies nothing.
    func testAHiddenKeyIsTakenFromZoomsOwnCopy() async {
        let zoom = FixturePage.freshAccount()
        let app = FixturePage.App(kind: .meeting, id: "meetingAppIdIdIdIdId1", clientID: "clientClientClient1", secret: "secretSecretSecret12")
        zoom.apps = [app]
        zoom.address = .general(app.id, .information)
        let outcome = await actor(zoom).run(ZoomSetupFlow.keysPlan(.meeting, [.clientID, .clientSecret]))
        XCTAssertEqual(outcome, .done(captured: [.clientID: "clientClientClient1", .clientSecret: "secretSecretSecret12"]))
    }

    /// Live run, 2026-11-27: Set up for me pressed the Meeting SDK switch before Zoom showed whether it was on,
    /// and so could turn it off. A switch whose state isn't shown yet is never pressed; the actor waits.
    func testASwitchWhoseStateIsNotShownYetIsNeverPressed() async {
        let zoom = onEmbed(sdkOn: true)
        zoom.loadingReads = 3
        zoom.address = .createdApps
        zoom.address = .general(zoom.apps[0].id, .embed)
        let outcome = await actor(zoom).run(ZoomSetupFlow.sdkPlan)
        XCTAssertEqual(outcome, .done(captured: [:]))
        XCTAssertEqual(zoom.apps[0].sdkOn, true)
        XCTAssertFalse(zoom.log.contains(.press(.meetingSDKSwitch)), "the switch was not pressed")
    }

    /// Live run, 2026-11-27: step 3 read the keys the moment the page opened, found no Client ID and gave up;
    /// two seconds later it was there. Keys on a page still loading are waited for.
    func testKeysOnAPageStillLoadingAreWaitedFor() async {
        let zoom = FixturePage.freshAccount()
        let app = FixturePage.App(kind: .meeting, id: "meetingAppIdIdIdIdId1", clientID: "clientClientClient1", secret: "secretSecretSecret12")
        zoom.apps = [app]
        zoom.loadingReads = 3
        zoom.address = .general(app.id, .information)
        let outcome = await actor(zoom).run(ZoomSetupFlow.keysPlan(.meeting, [.clientID, .clientSecret]))
        XCTAssertEqual(outcome, .done(captured: [.clientID: "clientClientClient1", .clientSecret: "secretSecretSecret12"]))
    }
}
