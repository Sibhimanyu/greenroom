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
}
