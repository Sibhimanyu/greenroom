import XCTest
@testable import GreenroomTests

/// The deny-list: words Greenroom never presses on Zoom's page (the actor tests cover it winning at press time).
final class ZoomActorRulesTests: XCTestCase {
    func testTheDenyListCatchesEveryRiskyWord() {
        for word in ["Regenerate", "Delete app", "Remove", "Deactivate", "Disable", "Submit", "Publish", "I agree", "Accept",
                     "Terms", "Sign out", "Log out", "Uninstall", "REGENERATE secret"] {
            XCTAssertTrue(ZoomActorRules.isDenied(word), word)
        }
    }

    func testOrdinaryWordsOnTheStepsAreNotDenied() {
        for word in ["Activate your app", "Continue", "Create", "Build app", "Copy", "Add Scopes", "Done", "General app"] {
            XCTAssertFalse(ZoomActorRules.isDenied(word), word)
        }
    }
}
