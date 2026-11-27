import XCTest
@testable import GreenroomTests

/// Seam 3 (docs/specs/zoom-setup-flow.md, "Set up for me"): the whole one-button loop, run against a
/// `FixturePage` (a scripted Zoom). Expected values come from the spec's step table and the 2026-11-27
/// live run, never from the code under test.
@MainActor
final class SetupForMeTests: XCTestCase {
    private let person = SetupAnswers(info: InfoValues(name: "Test Person", email: "test.person@example.com"))

    private func start(_ zoom: FixturePage, keys: MemoryKeys, answers: SetupAnswers = SetupAnswers()) -> (SetupForMe, MemoryKeys) {
        (SetupForMe(page: zoom, keys: keys, checker: FixtureChecker(zoom: zoom, keys: keys), answers: answers, pacing: .instant), keys)
    }

    func testAFreshAccountGetsItsMeetingAppCreatedThenStepTwoIsNext() async {
        let zoom = FixturePage.freshAccount()
        let (run, _) = start(zoom, keys: MemoryKeys())
        var seen: [Int?] = []
        run.onStep = { step in
            seen.append(step.number)
            if step.number == 2 { run.stop() }
        }
        let end = await run.run()
        XCTAssertEqual(end, .stopped)
        XCTAssertEqual(zoom.apps.map(\.kind), [.meeting], "one General app, nothing else")
        XCTAssertEqual(seen, [1, 2])
    }

    /// Live run: Meeting SDK is a switch on Embed that starts off; Greenroom turns it on, then step 3 is next.
    func testItTurnsMeetingSDKOnAndStopsAtCopyingTheKeys() async {
        let zoom = FixturePage.freshAccount()
        let (run, _) = start(zoom, keys: MemoryKeys())
        var seen: [Int?] = []
        run.onStep = { step in
            if seen.last != step.number { seen.append(step.number) }
            if step.number == 3 { run.stop() }
        }
        let end = await run.run()
        XCTAssertEqual(end, .stopped)
        XCTAssertEqual(seen, [1, 2, 3])
        XCTAssertEqual(zoom.apps.first?.sdkOn, true)
    }

    /// Spec steps 3 and 4: keys are copied after Meeting SDK is on (the secret only through Zoom's deep Copy),
    /// then the hosting app is built and named "Greenroom Hosting".
    func testItCopiesTheMeetingKeysThenBuildsAndNamesTheHostingApp() async {
        let zoom = FixturePage.freshAccount()
        let (run, keys) = start(zoom, keys: MemoryKeys())
        var seen: [Int?] = []
        run.onStep = { step in
            if seen.last != step.number { seen.append(step.number) }
            if step.number == 5 { run.stop() }
        }
        let end = await run.run()
        XCTAssertEqual(end, .stopped)
        XCTAssertEqual(seen, [1, 2, 3, 4, 5])
        let meeting = zoom.apps.first { $0.kind == .meeting }
        XCTAssertEqual(keys.keys(for: .meeting), [.clientID: meeting?.clientID ?? "?", .clientSecret: meeting?.secret ?? "?"])
        XCTAssertEqual(zoom.apps.filter { $0.kind == .hosting }.map { $0.info[.appName] }, ["Greenroom Hosting"])
        XCTAssertTrue(keys.keys(for: .hosting).isEmpty, "the hosting keys are copied last, not now")
    }

    /// Spec step 5: the four required Information fields are filled from the confirmed values; the app name
    /// Zoom already holds is left alone. (Required fields are Short Description, Company Name, Developer contact Name and Email.)
    func testItFillsInTheRequiredInformationFromTheConfirmedValues() async {
        let zoom = FixturePage.freshAccount()
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        var seen: [Int?] = []
        run.onStep = { step in
            if seen.last != step.number { seen.append(step.number) }
            if step.number == 6 { run.stop() }
        }
        let end = await run.run()
        XCTAssertEqual(end, .stopped)
        XCTAssertEqual(seen, [1, 2, 3, 4, 5, 6])
        let info = zoom.apps.first { $0.kind == .hosting }?.info
        XCTAssertEqual(info?[.shortDescription], "Lets Greenroom create, start and host my Zoom meetings.")
        XCTAssertEqual(info?[.companyName], "Test Person", "the company is the person's name unless they change it")
        XCTAssertEqual(info?[.contactName], "Test Person")
        XCTAssertEqual(info?[.contactEmail], "test.person@example.com")
        XCTAssertEqual(info?[.appName], "Greenroom Hosting")
    }

    /// The one-button promise: a brand-new Zoom account goes from nothing to a passing check, in the spec's
    /// order, and Greenroom never touches what is the person's (sign-in, terms) or anything on the deny-list.
    func testAFreshAccountGoesAllTheWayToDone() async {
        let zoom = FixturePage.freshAccount()
        let keys = MemoryKeys()
        let (run, _) = start(zoom, keys: keys, answers: person)
        var seen: [Int?] = []
        run.onStep = { step in if seen.last != step.number { seen.append(step.number) } }
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(seen, [1, 2, 3, 4, 5, 6, 7, 8, nil], "the eight steps in order, then the check")
        let meeting = zoom.apps.first { $0.kind == .meeting }, hosting = zoom.apps.first { $0.kind == .hosting }
        XCTAssertEqual(meeting?.sdkOn, true)
        XCTAssertEqual(hosting?.activated, true)
        XCTAssertEqual(hosting?.scopes, Set(ZoomScopes.names), "all eight scopes")
        XCTAssertEqual(keys.keys(for: .meeting), [.clientID: meeting?.clientID ?? "?", .clientSecret: meeting?.secret ?? "?"])
        XCTAssertEqual(keys.keys(for: .hosting), [.accountID: hosting?.accountID ?? "?", .clientID: hosting?.clientID ?? "?",
                                                  .clientSecret: hosting?.secret ?? "?"])
        let touched = zoom.log.compactMap { action -> ZoomControl? in
            switch action { case .press(let c), .pressDeep(let c): return c; default: return nil }
        }
        XCTAssertFalse(touched.contains(.signIn) || touched.contains(.tryAnotherWay) || touched.contains(.closeDialog))
    }

    // MARK: Existing apps

    private func finishedMeetingApp() -> FixturePage.App {
        FixturePage.App(kind: .meeting, id: "oldMeetingAppIdIdIdIdId", clientID: "oldMeetingClientClient1", secret: "oldMeetingSecretSecretSecret1", sdkOn: true)
    }
    private func finishedHostingApp() -> FixturePage.App {
        var a = FixturePage.App(kind: .hosting, id: "oldHostingAppIdIdIdIdId", clientID: "oldHostingClientClient1", secret: "oldHostingSecretSecretSecret1",
                                accountID: "oldHostingAccountAccount1", scopes: Set(ZoomScopes.names), activated: true)
        a.info = [.appName: "Mine", .shortDescription: "x", .companyName: "x", .contactName: "x", .contactEmail: "x@x.org"]
        return a
    }

    /// Spec "Existing apps": a Created apps list that already has the two apps means "Use this app", no new app is built,
    /// and the keys come from the apps that were already there.
    func testExistingAppsAreUsedNotRebuilt() async {
        let zoom = FixturePage.freshAccount().existing(finishedMeetingApp()).existing(finishedHostingApp())
        let keys = MemoryKeys()
        let (run, _) = start(zoom, keys: keys, answers: person)
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps.count, 2, "nothing new was built")
        XCTAssertEqual(keys.keys(for: .meeting)[.clientID], "oldMeetingClientClient1")
        XCTAssertEqual(keys.keys(for: .hosting)[.accountID], "oldHostingAccountAccount1")
    }

    /// The form's "Build a new one" for the meeting app: a second General app is made even though one exists.
    func testBuildANewOneIgnoresTheExistingApp() async {
        let zoom = FixturePage.freshAccount().existing(finishedMeetingApp()).existing(finishedHostingApp())
        var answers = person
        answers.buildNew = [.meeting]
        let (run, keys) = start(zoom, keys: MemoryKeys(), answers: answers)
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps.filter { $0.kind == .meeting }.count, 2)
        let newest = zoom.apps.last { $0.kind == .meeting }
        XCTAssertEqual(keys.keys(for: .meeting)[.clientID], newest?.clientID, "the keys are the new app's")
    }

    // MARK: Whole-flow replays

    private func checker(_ zoom: FixturePage, _ keys: MemoryKeys) -> FixtureChecker { FixtureChecker(zoom: zoom, keys: keys) }

    /// A failing check re-opens the step it names: Zoom drops a permission after the keys are copied, the check says
    /// that scope is missing, Greenroom adds it again, and the next check passes.
    func testAFailingCheckReopensTheStepItNames() async {
        let zoom = FixturePage.freshAccount()
        let keys = MemoryKeys()
        let fixture = checker(zoom, keys)
        // The checks run after each app's keys; the fault shows in the second.
        fixture.beforeRun = [{}, { zoom.apps[1].scopes.remove("user:read:token:admin") }]
        let run = SetupForMe(page: zoom, keys: keys, checker: fixture, answers: person, pacing: .instant)
        var seen: [Int?] = []
        run.onStep = { step in if seen.last != step.number { seen.append(step.number) } }
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps[1].scopes, Set(ZoomScopes.names), "the missing permission is back")
        XCTAssertEqual(Array(seen.suffix(3)), [6, 8, nil], "the check named permissions (step 6), then the keys are copied last again, then done")
        XCTAssertEqual(fixture.runs, 3, "after the meeting keys, after the hosting keys (the fault shows), after the fix")
    }

    /// Existing hosting app that is half finished: it is used, its missing permissions and activation are done, nothing new is built.
    func testAHalfFinishedExistingHostingAppIsFinished() async {
        var half = finishedHostingApp()
        half.scopes = Set(ZoomScopes.names.prefix(6)); half.activated = false
        let zoom = FixturePage.freshAccount().existing(finishedMeetingApp()).existing(half)
        let keys = MemoryKeys()
        let (run, _) = start(zoom, keys: keys, answers: person)
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps.count, 2)
        XCTAssertEqual(zoom.apps[1].scopes, Set(ZoomScopes.names))
        XCTAssertTrue(zoom.apps[1].activated)
    }

    /// "The app the person picks wins": the window is already on an older Server-to-Server app the person opened,
    /// so that app is the hosting app; no second one is built.
    func testTheAppThePersonOpenedWins() async {
        var theirs = finishedHostingApp()
        theirs.scopes = []; theirs.activated = false
        let zoom = FixturePage.freshAccount().existing(theirs)
        zoom.address = .s2s(theirs.id, .credentials)
        let keys = MemoryKeys()
        let (run, _) = start(zoom, keys: keys, answers: person)
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps.filter { $0.kind == .hosting }.count, 1)
        XCTAssertEqual(keys.keys(for: .hosting)[.clientID], theirs.clientID)
        XCTAssertTrue(zoom.apps.first { $0.id == theirs.id }?.activated ?? false)
    }

    /// Live finding: on an account that cannot edit Server-to-Server apps the Information fields are disabled. That is a
    /// blocker only the Zoom admin can lift, so Greenroom hands over at step 5 with the words to say.
    func testAnAccountThatCannotEditHandsOverWithTheAdminWords() async {
        let zoom = FixturePage.freshAccount()
        zoom.accountCannotEditS2S = true
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        let end = await run.run()
        guard case .handedOver(let step, _) = end else { return XCTFail("expected a hand over, got \(end)") }
        XCTAssertEqual(step.number, 5)
        XCTAssertEqual(step.cta, .checkAgain)
        XCTAssertTrue(step.status?.contains("Server-to-Server OAuth app: Edit") ?? false)
        XCTAssertTrue(step.status?.contains("Ask your Zoom admin") ?? false)
        XCTAssertEqual(zoom.apps.last?.info[.contactEmail], nil, "nothing was typed into disabled fields")
    }

    func testStopEndsBeforeTheNextActionAndLeavesZoomAsItIs() async {
        let zoom = FixturePage.freshAccount()
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        run.onStep = { step in if step.number == 2 { run.stop() } }
        let end = await run.run()
        XCTAssertEqual(end, .stopped)
        XCTAssertEqual(zoom.apps.first?.sdkOn, false, "step 2 had not been done when Stop was pressed")
    }

    /// Sign-in is the person's: the run hands over at once, presses nothing, and works when run again after signing in.
    /// Owner, 2026-11-27: "what if it was not logged in in the beginning". Sign-in is the person's, so the run waits
    /// for it in place (the HUD lifts so they can type) and carries on by itself once Zoom shows them signed in.
    func testSignInIsTheirsThenTheSameRunCarriesOn() async {
        let zoom = FixturePage.signedOutAccount()
        zoom.signsInAfterReads = 5
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        var waitedForSignIn = false
        run.onStep = { step in if step.title == "Sign in to Zoom" { waitedForSignIn = true } }
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertTrue(waitedForSignIn, "the run said it was waiting for the sign-in")
    }

    /// A fault the actor cannot fix by pressing (Zoom keeps saying no) ends the run instead of going round and round.
    func testAStubbornFailureHandsOverInsteadOfLooping() async {
        let zoom = FixturePage.freshAccount()
        let keys = MemoryKeys()
        let fixture = checker(zoom, keys)
        fixture.meetingAlwaysFails = true
        let run = SetupForMe(page: zoom, keys: keys, checker: fixture, answers: person, pacing: .instant)
        let end = await run.run()
        guard case .handedOver(_, let why) = end else { return XCTFail("expected a hand over, got \(end)") }
        XCTAssertTrue(why.contains("still"), why)
    }

    /// Live run, 2026-11-27: Created apps fills its list late. Set up for me looked while it was still empty, saw no
    /// hosting app and built a new one. It decides only from a page that has settled.
    func testAPageStillLoadingIsNotMistakenForAnEmptyOne() async {
        let zoom = FixturePage.freshAccount().existing(finishedMeetingApp()).existing(finishedHostingApp())
        zoom.loadingReads = 3
        zoom.address = .signIn
        zoom.address = .createdApps
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps.count, 2, "nothing new was built")
    }

    /// Live run, 2026-11-27: on the disabled Information page, Set up for me tried to type while the page was still
    /// loading and reported "couldn't find the Short Description field". A settled page shows the fields disabled,
    /// and that is the admin blocker, whatever the loading delay.
    func testTheBlockerIsFoundEvenWhenThePageLoadsSlowly() async {
        let zoom = FixturePage.freshAccount()
        zoom.accountCannotEditS2S = true
        zoom.loadingReads = 3
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        let end = await run.run()
        guard case .handedOver(let step, _) = end else { return XCTFail("expected a hand over, got \(end)") }
        XCTAssertEqual(step.number, 5)
        XCTAssertEqual(step.cta, .checkAgain)
    }

    /// Live run 3, 2026-11-27: Created apps showed + with no apps for two readings in a row, then its list. The run took
    /// that for an empty account and built a third hosting app. An app list is only believed once it has held still.
    func testAnAppListThatFillsLateIsWaitedFor() async {
        let zoom = FixturePage.freshAccount().existing(finishedMeetingApp()).existing(finishedHostingApp())
        zoom.listLateReads = 4
        zoom.address = .signIn
        zoom.address = .createdApps
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps.count, 2, "nothing new was built")
    }

    /// Live run 3, 2026-11-27: Information's fields were disabled when the run looked, so it stopped with "ask your Zoom
    /// admin"; a minute later Zoom had unlocked them by itself. Disabled fields are Zoom still opening the page until
    /// they have stayed disabled for a long while.
    func testInformationThatUnlocksLateIsFilledInNotTreatedAsTheBlocker() async {
        let zoom = FixturePage.freshAccount()
        zoom.infoLockedReads = 10
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps.last?.info[.contactEmail], person.info.email)
    }

    /// Live run 8, 2026-11-27: Zoom's app API answered something with 401, the Scopes page listed no saved scopes to
    /// the reader, and the run stopped with "ask your Zoom admin" - yet Zoom showed Scopes ✓ and "Your app is ready
    /// for activation". What Zoom's Activation page says wins: ready means Information and scopes are done; Activate.
    func testActivationThatSaysReadyIsTrustedOverAStray401() async {
        let zoom = FixturePage.freshAccount()
        zoom.spurious401 = true
        zoom.savedScopesNotListed = true
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps.last?.activated, true)
        XCTAssertEqual(zoom.log.filter { $0 == .press(.addScopes) }.count, 1, "the scopes were added once")
    }

    /// Live run 7, 2026-11-27: Information drew its menu links, then its fields seven seconds later; the run took the
    /// menu for a settled page and tried to type into fields that weren't there. Each page is used once its own
    /// controls show.
    func testAPageIsUsedOnceItsOwnControlsShowNotJustItsMenu() async {
        let zoom = FixturePage.freshAccount()
        zoom.contentLateReads = 6
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps.last?.info[.contactEmail], person.info.email)
    }

    /// Live run 9, 2026-11-27: the eighth scope was ticked and Done pressed in the same instant, before Zoom had
    /// registered the tick, so only seven stuck. Each tick is waited for before the next step.
    func testEveryTickIsSeenBeforeDoneIsPressed() async {
        let zoom = FixturePage.freshAccount()
        zoom.ticksRegisterOnRead = true
        let (run, _) = start(zoom, keys: MemoryKeys(), answers: person)
        let end = await run.run()
        XCTAssertEqual(end, .done)
        XCTAssertEqual(zoom.apps.last?.scopes, Set(ZoomScopes.names))
        XCTAssertEqual(zoom.log.filter { $0 == .press(.addScopes) }.count, 1, "all eight in one pass, no retry")
    }
}
