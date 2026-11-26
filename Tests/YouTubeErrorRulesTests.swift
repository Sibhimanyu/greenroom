import XCTest

/// Google's upload and sign-in errors, in plain words, each with the
/// buttons that get the person going again.
final class YouTubeErrorRulesTests: XCTestCase {

    private func body(_ reason: String, _ message: String = "detail") -> Data {
        Data(#"{"error":{"code":403,"message":"\#(message)","errors":[{"reason":"\#(reason)","message":"\#(message)"}]}}"#.utf8)
    }

    func testReadsTheReasonOutOfGooglesErrorBody() {
        let parsed = YouTubeErrorRules.parse(body("quotaExceeded", "The request cannot be completed"))
        XCTAssertEqual(parsed.reason, "quotaExceeded")
        XCTAssertEqual(parsed.message, "The request cannot be completed")
        XCTAssertNil(YouTubeErrorRules.parse(Data("<html>".utf8)).reason)
    }

    func testQuotaUsedUpOnTheSharedApp() {
        let p = YouTubeErrorRules.problem(status: 403, reason: "quotaExceeded", message: "", sharedApp: true)
        XCTAssertEqual(p.kind, .quotaUsedUp)
        XCTAssertEqual(p.title, "YouTube\u{2019}s daily upload limit for Greenroom is used up")
        XCTAssertEqual(p.detail, "Try again tomorrow, or use Upload in YouTube Studio.")
        XCTAssertEqual(p.actions, [.openStudio])
    }

    func testQuotaUsedUpOnYourOwnApp() {
        let p = YouTubeErrorRules.problem(status: 403, reason: "quotaExceeded", message: "", sharedApp: false)
        XCTAssertEqual(p.title, "YouTube\u{2019}s daily upload limit for your Google app is used up")
        XCTAssertEqual(p.actions, [.openStudio])
    }

    func testAPerAccountUploadLimit() {
        let p = YouTubeErrorRules.problem(status: 400, reason: "uploadLimitExceeded", message: "", sharedApp: true)
        XCTAssertEqual(p.kind, .accountUploadLimit)
        XCTAssertEqual(p.title, "This YouTube account has reached its upload limit for now")
        XCTAssertEqual(p.actions, [.openStudio])
    }

    func testARevokedOrExpiredSignIn() {
        for p in [YouTubeErrorRules.problem(.signInEnded, sharedApp: true),
                  YouTubeErrorRules.problem(status: 401, reason: "authError", message: "", sharedApp: true)] {
            XCTAssertEqual(p.kind, .signInEnded)
            XCTAssertEqual(p.title, "Your Google sign-in has ended")
            XCTAssertEqual(p.detail, "It was signed out or access was removed. Sign in again, then upload.")
            XCTAssertEqual(p.actions, [.signIn, .openStudio])
        }
    }

    func testNotSignedIn() {
        let p = YouTubeErrorRules.problem(.notSignedIn, sharedApp: true)
        XCTAssertEqual(p.title, "Not signed in to YouTube")
        XCTAssertEqual(p.actions, [.signIn, .openStudio])
    }

    func testAnOldTokenWithoutTheRightPermission() {
        let p = YouTubeErrorRules.problem(status: 403, reason: "insufficientPermissions", message: "", sharedApp: true)
        XCTAssertEqual(p.kind, .needsPermission)
        XCTAssertEqual(p.actions, [.signIn])
    }

    func testAGoogleAccountWithNoChannel() {
        let p = YouTubeErrorRules.problem(status: 401, reason: "youtubeSignupRequired", message: "", sharedApp: true)
        XCTAssertEqual(p.kind, .noChannel)
        XCTAssertEqual(p.title, "This Google account has no YouTube channel yet")
        XCTAssertEqual(p.actions, [.createChannel, .signInAnother])
    }

    func testYourOwnAppWithoutTheAPIOn() {
        let p = YouTubeErrorRules.problem(status: 403, reason: "accessNotConfigured", message: "", sharedApp: false)
        XCTAssertEqual(p.kind, .apiNotEnabled)
        XCTAssertEqual(p.detail, "Turn on YouTube Data API v3 for your Google app in Google Cloud, then try again.")
        XCTAssertEqual(p.actions, [.openCloudConsole, .tryAgain])
    }

    func testConnectionDropsAndServerTrouble() {
        XCTAssertEqual(YouTubeErrorRules.problem(.connection, sharedApp: true).actions, [.tryAgain, .openStudio])
        let p = YouTubeErrorRules.problem(status: 503, reason: "backendError", message: "", sharedApp: true)
        XCTAssertEqual(p.kind, .connection)
    }

    func testAnythingElseKeepsGooglesWordsAndOffersBothWaysOn() {
        let p = YouTubeErrorRules.problem(status: 400, reason: "invalidTitle", message: "The title is bad.", sharedApp: true)
        XCTAssertEqual(p.kind, .other)
        XCTAssertEqual(p.title, "YouTube didn\u{2019}t take the upload")
        XCTAssertEqual(p.detail, "The title is bad.")
        XCTAssertEqual(p.actions, [.tryAgain, .openStudio])
    }

    func testEveryProblemSaysTheRecordingIsSafe() {
        XCTAssertEqual(YouTubeErrorRules.savedNote, "The recording is still on this Mac.")
    }

    func testButtonWords() {
        XCTAssertEqual(YouTubeAction.signIn.title, "Sign in again")
        XCTAssertEqual(YouTubeAction.signInAnother.title, "Use another account")
        XCTAssertEqual(YouTubeAction.openStudio.title, "Upload in YouTube Studio")
        XCTAssertEqual(YouTubeAction.tryAgain.title, "Try again")
        XCTAssertEqual(YouTubeAction.createChannel.title, "Create a channel")
        XCTAssertEqual(YouTubeAction.openCloudConsole.title, "Open Google Cloud")
    }
}
