import XCTest
@testable import GreenroomTests

/// Whether the Zoom window is signed in to Marketplace (so "Sign out of Zoom" is only offered when it is).
final class ZoomSignInStateRulesTests: XCTestCase {
    private let id = "ZzZ_999-aaBBcc1122"
    private func state(_ page: ZoomMarketplacePage?, _ header: ZoomHeaderReport?, _ current: ZoomSignInState) -> ZoomSignInState {
        ZoomSignInStateRules.state(page: page, header: header, current: current)
    }

    func testSignInPagesAreSignedOut() {
        for cur in [ZoomSignInState.unknown, .signedIn, .signedOut] {
            XCTAssertEqual(state(.signIn, nil, cur), .signedOut)
            XCTAssertEqual(state(.signIn, .account, cur), .signedOut)
        }
    }

    func testThePasskeyPageIsSignedOutToo() {
        XCTAssertEqual(state(.passkey, .account, .signedIn), .signedOut)
    }

    func testTheHeaderDecides() {
        XCTAssertEqual(state(.createdApps, .signInLink, .signedIn), .signedOut)
        XCTAssertEqual(state(.createdApps, .signInLink, .unknown), .signedOut)
        XCTAssertEqual(state(.s2s(id, .scopes), .account, .unknown), .signedIn)
        XCTAssertEqual(state(.createdApps, .account, .signedOut), .signedIn)
        XCTAssertEqual(state(nil, .account, .unknown), .signedIn)   // a Marketplace page that is not a guided one
    }

    func testNoReportKeepsWhatWeKnow() {
        XCTAssertEqual(state(.createdApps, nil, .unknown), .unknown)
        XCTAssertEqual(state(.createdApps, nil, .signedIn), .signedIn)
        XCTAssertEqual(state(.createdApps, .neither, .signedOut), .signedOut)
        XCTAssertEqual(state(.createdApps, .neither, .unknown), .unknown)
    }

    func testSigningOutIsSignedOutAtOnce() {
        XCTAssertEqual(ZoomSignInStateRules.afterSignOut, .signedOut)
    }

    func testOnlyOfferSignOutWhenSignedIn() {
        XCTAssertTrue(ZoomSignInStateRules.offersSignOut(.signedIn))
        XCTAssertFalse(ZoomSignInStateRules.offersSignOut(.unknown))
        XCTAssertFalse(ZoomSignInStateRules.offersSignOut(.signedOut))
    }

    func testTheHeaderScriptOnlyReadsAndAnswersWithAWord() {
        let js = ZoomSignInHeaderScript.source
        XCTAssertTrue(js.contains("Sign In"))
        for banned in [".click(", ".focus(", "dispatchEvent", ".submit(", "console.", "fetch(", "XMLHttpRequest", "postMessage", "localStorage", "document.cookie", ".value ="] {
            XCTAssertFalse(js.contains(banned), banned)
        }
    }

    func testOnlyTheRealMarketplaceHostIsRead() {
        XCTAssertTrue(ZoomMarketplacePages.isMarketplace(URL(string: "https://marketplace.zoom.us/")!))
        XCTAssertTrue(ZoomMarketplacePages.isMarketplace(URL(string: "https://marketplace.zoom.us/user/build?x=1")!))
        XCTAssertFalse(ZoomMarketplacePages.isMarketplace(URL(string: "http://marketplace.zoom.us/")!))
        XCTAssertFalse(ZoomMarketplacePages.isMarketplace(URL(string: "https://marketplace.zoom.us.evil.com/")!))
        XCTAssertFalse(ZoomMarketplacePages.isMarketplace(URL(string: "https://zoom.us/signin")!))
    }
}
