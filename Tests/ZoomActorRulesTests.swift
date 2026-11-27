import XCTest
@testable import GreenroomTests

/// R16: "Do this step". The actor may press only what its step's allow-list names, never a denied word,
/// and only on the steps listed; the card says what it will do and what it did.
final class ZoomActorRulesTests: XCTestCase {
    private let id = "AbC_123-xyZ789qrstuvw1"

    func testAllowListsPerStep() {
        typealias R = (String, ZoomActorStep, Bool)
        let table: [R] = [
            ("Build", .createApp, true), ("build", .createApp, true), ("  Create ", .createApp, true),
            ("General app", .createApp, true), ("Server to server OAuth app", .createApp, true), ("+", .createApp, true),
            ("Cancel", .createApp, false), ("Webhook only app", .createApp, false), ("Done", .createApp, false),
            ("Add Scopes", .addScopes, true), ("+ Add Scopes", .addScopes, true),
            ("Done", .addScopes, true), ("Save", .addScopes, true), ("Continue", .addScopes, true),
            ("Create", .addScopes, false), ("Activate", .addScopes, false),
            ("Activate", .activate, true), ("Activate your app", .activate, true), ("activate your app", .activate, true),
            ("Done", .activate, false), ("Meeting SDK", .enableSDK, true), ("Activate", .enableSDK, false),
        ]
        for (label, step, ok) in table { XCTAssertEqual(ZoomActorRules.allowed(label, for: step), ok, "\(label) \(step)") }
    }

    func testTheDenyListWinsEvenOverAnAllowedLabel() {
        for word in ["Regenerate", "Delete app", "Remove", "Deactivate", "Disable", "Submit", "Publish", "I agree", "Accept",
                     "Terms", "Sign out", "Log out", "Uninstall", "REGENERATE secret"] {
            XCTAssertTrue(ZoomActorRules.isDenied(word), word)
            for step in ZoomActorStep.allCases { XCTAssertFalse(ZoomActorRules.allowed(word, for: step), "\(word) \(step)") }
        }
        XCTAssertFalse(ZoomActorRules.isDenied("Activate your app"))
        XCTAssertFalse(ZoomActorRules.isDenied("Build"))
        // An allowed label with a denied word added is no longer an exact match, and denied anyway.
        XCTAssertFalse(ZoomActorRules.allowed("Create and publish", for: .createApp))
        XCTAssertFalse(ZoomActorRules.allowed("Done, delete", for: .addScopes))
    }

    func testAnyStepAllowedIsTheUnion() {
        XCTAssertTrue(ZoomActorRules.allowed(label: "Done"))
        XCTAssertTrue(ZoomActorRules.allowed(label: "Create"))
        XCTAssertFalse(ZoomActorRules.allowed(label: "Regenerate"))
        XCTAssertFalse(ZoomActorRules.allowed(label: "Cancel"))
        XCTAssertFalse(ZoomActorRules.allowed(label: ""))
    }

    func testScopeCheckboxesAreOnlyForOurEightScopesAndTheScopeWordsDoNotTripTheDenyList() {
        for scope in ZoomScopes.names { XCTAssertTrue(ZoomActorRules.allowedScopeCheckbox(name: "", scope: scope), scope) }
        XCTAssertTrue(ZoomActorRules.allowedScopeCheckbox(name: "meeting:delete:meeting:admin", scope: "meeting:delete:meeting:admin"))
        XCTAssertFalse(ZoomActorRules.allowedScopeCheckbox(name: "", scope: "meeting:delete:meeting"))
        XCTAssertFalse(ZoomActorRules.allowedScopeCheckbox(name: "", scope: "user:read:user"))
        XCTAssertFalse(ZoomActorRules.allowedScopeCheckbox(name: "Delete app", scope: ZoomScopes.names[0]))
    }

    func testWhichStepEachPageOffers() {
        func step(_ part: ZoomGuidePart, _ page: ZoomMarketplacePage, _ kind: ZoomCoach.Kind) -> ZoomActorStep? {
            ZoomActorRules.step(part: part, page: page, coachKind: kind)
        }
        XCTAssertEqual(step(.meetingApp, .createdApps, .build), .createApp)
        XCTAssertEqual(step(.hostingApp, .createdApps, .build), .createApp)
        XCTAssertNil(step(.hostingApp, .createdApps, .appRow))
        XCTAssertEqual(step(.hostingApp, .chooseType(id), .row), .createApp)
        XCTAssertEqual(step(.hostingApp, .s2s(id, .scopes), .control), .addScopes)
        XCTAssertEqual(step(.hostingApp, .s2s(id, .activation), .control), .activate)
        XCTAssertEqual(step(.meetingApp, .general(id, .embed), .toggle), .enableSDK)
        // Never on credentials pages, sign-in pages or anything else.
        XCTAssertNil(step(.hostingApp, .s2s(id, .credentials), .none))
        XCTAssertNil(step(.meetingApp, .general(id, .information), .none))
        XCTAssertNil(step(.hostingApp, .signIn, .control))
        XCTAssertNil(step(.hostingApp, .passkey, .control))
        XCTAssertNil(step(.hostingApp, .s2s(id, .information), .none))
        XCTAssertNil(step(.check, .createdApps, .build))
        // A step on the wrong part does not exist.
        XCTAssertNil(step(.meetingApp, .s2s(id, .scopes), .control))
    }

    func testThePlanLineSaysWhatItWillDo() {
        XCTAssertEqual(ZoomActorRules.plan(.createApp, part: .meetingApp),
                       "Greenroom will press + \u{2192} Build, choose General app and press Create.")
        XCTAssertEqual(ZoomActorRules.plan(.createApp, part: .hostingApp),
                       "Greenroom will press + \u{2192} Build, choose Server to server OAuth app and press Create.")
        XCTAssertEqual(ZoomActorRules.plan(.addScopes, part: .hostingApp),
                       "Greenroom will add the \(ZoomScopes.countWord) scopes: open + Add Scopes, tick each one and press Done.")
        XCTAssertEqual(ZoomActorRules.plan(.activate, part: .hostingApp), "Greenroom will press Activate your app.")
        XCTAssertEqual(ZoomActorRules.plan(.enableSDK, part: .meetingApp), "Greenroom will turn on Meeting SDK.")
        XCTAssertEqual(ZoomActorRules.buttonTitle, "Do this step")
        XCTAssertEqual(ZoomActorRules.busyTitle, "Working\u{2026}")
    }

    func testTheWordsAfterARun() {
        func r(_ code: String, added: Int? = nil, total: Int? = nil, notFound: [String]? = nil) -> ZoomActorResult {
            ZoomActorResult(code: code, added: added, total: total, notFound: notFound)
        }
        let m = ZoomActorRules.message
        XCTAssertEqual(m(.addScopes, r("done", added: 8, total: 8)), "Added 8 scopes.")
        XCTAssertEqual(m(.addScopes, r("done", added: 6, total: 8, notFound: ["a:b:c", "d:e:f"])),
                       "Added 6 of 8; couldn\u{2019}t find a:b:c, d:e:f: add them by hand (Copy scopes is in the bar).")
        XCTAssertEqual(m(.addScopes, r("already", added: 0, total: 0)), "All the scopes are already on this page.")
        XCTAssertEqual(m(.addScopes, r("no-confirm", added: 8, total: 8)), "Press Done to save the scopes.")
        XCTAssertEqual(m(.addScopes, r("no-add-scopes")), "Couldn\u{2019}t find + Add Scopes. Press it yourself; Copy scopes is in the bar.")
        XCTAssertEqual(m(.createApp, r("done")), "Pressed Create. Fill in what Zoom asks next.")
        XCTAssertEqual(m(.createApp, r("no-plus")), "Couldn\u{2019}t find the + button. Press it yourself.")
        XCTAssertEqual(m(.createApp, r("no-build")), "Couldn\u{2019}t find Build in the menu. Press it yourself.")
        XCTAssertEqual(m(.createApp, r("no-radio")), "Couldn\u{2019}t choose the app type. Choose it yourself, then press Create.")
        XCTAssertEqual(m(.createApp, r("no-create")), "Chose the app type but couldn\u{2019}t find Create. Press it yourself.")
        XCTAssertEqual(m(.activate, r("done")), "Activated. Zoom now shows the app as activated.")
        XCTAssertEqual(m(.activate, r("already")), "The app is already activated.")
        XCTAssertEqual(m(.activate, r("no-button")), "Couldn\u{2019}t find Activate. Finish Information first, then press it yourself.")
        XCTAssertEqual(m(.activate, r("not-verified")), "Pressed Activate, but Zoom doesn\u{2019}t show it as activated yet. Check the page.")
        XCTAssertEqual(m(.enableSDK, r("done")), "Meeting SDK is on.")
        XCTAssertEqual(m(.enableSDK, r("already")), "Meeting SDK was already on.")
        XCTAssertEqual(m(.enableSDK, r("no-switch")), "Couldn\u{2019}t find the Meeting SDK switch. Turn it on yourself.")
        XCTAssertEqual(m(.enableSDK, r("not-verified")), "Pressed the switch, but it doesn\u{2019}t look on. Check the page.")
        XCTAssertEqual(m(.activate, r("refused")), "Greenroom only does this step on its own page.")
        XCTAssertEqual(m(.activate, r("whatever")), "Stopped. Check the page and finish this step yourself.")
        for step in ZoomActorStep.allCases { XCTAssertFalse(m(step, r("whatever")).lowercased().contains("class")) }
    }

    func testTheScriptHasOneClickAndNoSubmitNetworkOrCredentialReads() {
        let js = ZoomActorScript.body
        XCTAssertEqual(js.components(separatedBy: ".click(").count - 1, 1, "one place clicks")
        for banned in [".submit(", "fetch(", "XMLHttpRequest", "localStorage", "document.cookie", "console.", "postMessage", "eval(",
                       "requestSubmit", "dispatchEvent(new MouseEvent", "location.href"] {
            XCTAssertFalse(js.contains(banned), banned)
        }
        XCTAssertTrue(js.contains("credentials"), "refuses credentials pages")
        XCTAssertTrue(js.contains("deny"))
    }

    func testTheArgumentsCarrySwiftsListsNotThePages() throws {
        let args = ZoomActorScript.arguments(.addScopes, part: .hostingApp)
        XCTAssertEqual(args["step"] as? String, "addScopes")
        XCTAssertEqual(args["scopes"] as? [String], ZoomScopes.names)
        XCTAssertEqual(args["deny"] as? String, ZoomActorRules.denyPattern)
        XCTAssertEqual((args["allow"] as? [String])?.contains("done"), true)
        let c = ZoomActorScript.arguments(.createApp, part: .meetingApp)
        XCTAssertEqual(c["typeLabel"] as? String, "General app")
    }
}
