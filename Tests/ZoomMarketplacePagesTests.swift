import XCTest
@testable import GreenroomTests

/// R2 (an address -> the page), R4 (a page -> its address, round trip), R5 (key shape).
final class ZoomMarketplacePagesTests: XCTestCase {
    private let id = "AbC_123-xyZ789qrstuvw1"   // 22 characters, like Zoom's app IDs

    private func page(_ s: String) -> ZoomMarketplacePage? { ZoomMarketplacePages.page(for: URL(string: s)!) }

    // MARK: R2

    func testEveryProbeAddress() {
        XCTAssertEqual(page("https://marketplace.zoom.us/user/build"), .createdApps)
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/applications/\(id)"), .chooseType(id))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/apps/\(id)/information"), .s2s(id, .information))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/apps/\(id)/credentials"), .s2s(id, .credentials))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/apps/\(id)/feature"), .s2s(id, .feature))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/apps/\(id)/scope"), .s2s(id, .scopes))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/apps/\(id)/activation"), .s2s(id, .activation))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/applications/\(id)/information"), .general(id, .information))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/applications/\(id)/features/sdk"), .general(id, .embed))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/applications/\(id)/scopes"), .general(id, .scopes))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/applications/\(id)/features/access"), .general(id, .other))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/applications/\(id)/basic"), .general(id, .other))
    }

    func testQueryStringsAndTrailingSlashesAreIgnored() {
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/apps/\(id)/credentials?tab=a&x=1"), .s2s(id, .credentials))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/apps/\(id)/credentials/"), .s2s(id, .credentials))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/applications/\(id)/features/sdk?x=1#top"), .general(id, .embed))
        XCTAssertEqual(page("https://marketplace.zoom.us/develop/applications/\(id)/"), .chooseType(id))
        XCTAssertEqual(page("https://marketplace.zoom.us/user/build/"), .createdApps)
        XCTAssertEqual(page("https://marketplace.zoom.us/user/build?x=1"), .createdApps)
    }

    func testOnlyTheRealMarketplaceCounts() {
        XCTAssertNil(page("https://marketplace.zoom.us.evil.com/develop/apps/\(id)/credentials"))
        XCTAssertNil(page("https://evil-marketplace.zoom.us/user/build"))
        XCTAssertNil(page("https://marketplace.zoom.us@evil.com/user/build"))
        XCTAssertNil(page("https://zoom.us/develop/apps/\(id)/credentials"))
        XCTAssertNil(page("http://marketplace.zoom.us/user/build"))
        XCTAssertNil(page("https://marketplace.zoom.us:8443/user/build"))
    }

    func testIDsMustLookLikeAppIDs() {
        XCTAssertNil(page("https://marketplace.zoom.us/develop/apps/short/credentials"))
        XCTAssertNil(page("https://marketplace.zoom.us/develop/apps/\(String(repeating: "a", count: 41))/credentials"))
        XCTAssertNil(page("https://marketplace.zoom.us/develop/apps/ab%20cd%20ef%20gh%20ij/credentials"))
        XCTAssertNotNil(page("https://marketplace.zoom.us/develop/apps/\(String(repeating: "a", count: 40))/credentials"))
        XCTAssertNotNil(page("https://marketplace.zoom.us/develop/apps/\(String(repeating: "a", count: 10))/credentials"))
    }

    func testOtherMarketplacePagesAreNotPages() {
        XCTAssertNil(page("https://marketplace.zoom.us/"))
        XCTAssertNil(page("https://marketplace.zoom.us/apps"))
        XCTAssertNil(page("https://marketplace.zoom.us/develop/apps/\(id)"))
        XCTAssertNil(page("https://marketplace.zoom.us/develop/apps/\(id)/credentials/extra"))
        XCTAssertNil(page("https://marketplace.zoom.us/user/build/extra"))
    }

    func testSignInPages() {
        XCTAssertEqual(page("https://zoom.us/signin?next=abc"), .signIn)
        XCTAssertEqual(page("https://accounts.google.com/o/oauth2/v2/auth?x=1"), .signIn)
        XCTAssertEqual(page("https://appleid.apple.com/auth/authorize"), .signIn)
        XCTAssertEqual(page("https://login.microsoftonline.com/common/oauth2"), .signIn)
        XCTAssertNil(page("https://accounts.google.com.evil.com/o/oauth2"))
        XCTAssertNil(page("https://zoom.us.evil.com/signin"))
        XCTAssertNil(page("https://zoom.us/pricing"))
        XCTAssertNil(page("http://zoom.us/signin"))
    }

    func testTheAppKind() {
        XCTAssertEqual(ZoomMarketplacePage.s2s(id, .scopes).app, .s2s)
        XCTAssertEqual(ZoomMarketplacePage.general(id, .embed).app, .sdk)
        XCTAssertNil(ZoomMarketplacePage.chooseType(id).app)
        XCTAssertNil(ZoomMarketplacePage.createdApps.app)
        XCTAssertNil(ZoomMarketplacePage.signIn.app)
        XCTAssertEqual(ZoomMarketplacePage.s2s(id, .scopes).appID, id)
        XCTAssertNil(ZoomMarketplacePage.signIn.appID)
    }

    // MARK: R4

    func testEveryTabRoundTripsThroughItsAddress() {
        var pages: [ZoomMarketplacePage] = [.createdApps, .chooseType(id)]
        pages += [ZoomS2STab.information, .credentials, .feature, .scopes, .activation].map { .s2s(id, $0) }
        pages += [ZoomGeneralTab.information, .embed, .scopes].map { .general(id, $0) }
        for p in pages {
            let url = ZoomMarketplacePages.url(for: p)
            XCTAssertNotNil(url, "\(p)")
            XCTAssertEqual(url.flatMap(ZoomMarketplacePages.page(for:)), p, "\(p)")
        }
    }

    func testTheAddressesTheGuideLinksTo() {
        XCTAssertEqual(ZoomMarketplacePages.url(for: .createdApps)?.absoluteString, "https://marketplace.zoom.us/user/build")
        XCTAssertEqual(ZoomMarketplacePages.url(for: .general(id, .embed))?.absoluteString,
                       "https://marketplace.zoom.us/develop/applications/\(id)/features/sdk")
        XCTAssertEqual(ZoomMarketplacePages.url(for: .general(id, .information))?.absoluteString,
                       "https://marketplace.zoom.us/develop/applications/\(id)/information")
        XCTAssertEqual(ZoomMarketplacePages.url(for: .s2s(id, .scopes))?.absoluteString,
                       "https://marketplace.zoom.us/develop/apps/\(id)/scope")
        XCTAssertEqual(ZoomMarketplacePages.url(for: .s2s(id, .activation))?.absoluteString,
                       "https://marketplace.zoom.us/develop/apps/\(id)/activation")
        XCTAssertEqual(ZoomMarketplacePages.url(for: .s2s(id, .credentials))?.absoluteString,
                       "https://marketplace.zoom.us/develop/apps/\(id)/credentials")
    }

    func testPagesWithoutOneAddressHaveNone() {
        XCTAssertNil(ZoomMarketplacePages.url(for: .signIn))
        XCTAssertNil(ZoomMarketplacePages.url(for: .general(id, .other)))
    }

    // MARK: Remembered app IDs

    func testTheWindowRemembersEachKindsAppID() {
        var ids = ZoomAppIDs()
        ids.see(.createdApps)
        ids.see(.chooseType(id))   // a draft: no kind yet
        XCTAssertNil(ids.meeting); XCTAssertNil(ids.hosting)
        ids.see(.general(id, .embed))
        XCTAssertEqual(ids.meeting, id); XCTAssertNil(ids.hosting)
        let other = "ZzZ_999-aaBBcc1122"
        ids.see(.s2s(other, .scopes))
        XCTAssertEqual(ids.hosting, other)
        ids.see(.signIn)
        XCTAssertEqual(ids.meeting, id)
        ids.forget(.sdk)
        XCTAssertNil(ids.meeting); XCTAssertEqual(ids.hosting, other)
        ids.forget(.s2s)
        XCTAssertNil(ids.hosting)
    }

    func testRememberedIDsOnlyAcceptRealIDs() {
        XCTAssertNil(ZoomAppIDs(meeting: "x y", hosting: nil).meeting)
        XCTAssertEqual(ZoomAppIDs(meeting: id, hosting: nil).meeting, id)
    }

    // MARK: R5 key shape

    func testWhatCountsAsAKey() {
        XCTAssertTrue(ZoomMarketplacePages.isKey("AbCdEfGhIj"))
        XCTAssertTrue(ZoomMarketplacePages.isKey("abc_def-ghi_jkl-mno_pqr-stu_vwx-yz012345"))
        XCTAssertTrue(ZoomMarketplacePages.isKey(String(repeating: "a", count: 64)))
        XCTAssertFalse(ZoomMarketplacePages.isKey(String(repeating: "a", count: 65)))
        XCTAssertFalse(ZoomMarketplacePages.isKey("short"))
        XCTAssertFalse(ZoomMarketplacePages.isKey(String(repeating: "a", count: 9)))
        XCTAssertFalse(ZoomMarketplacePages.isKey(""))
        XCTAssertFalse(ZoomMarketplacePages.isKey("has space inside"))
        XCTAssertFalse(ZoomMarketplacePages.isKey("abcdefghij\n"))
        XCTAssertFalse(ZoomMarketplacePages.isKey("abcdefghij!"))
        XCTAssertFalse(ZoomMarketplacePages.isKey("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}"))
    }

    func testKeysAreOnlyReadOnTheTwoCredentialPages() {
        XCTAssertEqual(ZoomMarketplacePages.keyFields(on: .s2s(id, .credentials)), [.accountID, .clientID, .clientSecret])
        XCTAssertEqual(ZoomMarketplacePages.keyFields(on: .general(id, .information)), [.clientID, .clientSecret])
        XCTAssertNil(ZoomMarketplacePages.keyFields(on: .s2s(id, .scopes)))
        XCTAssertNil(ZoomMarketplacePages.keyFields(on: .general(id, .embed)))
        XCTAssertNil(ZoomMarketplacePages.keyFields(on: .createdApps))
        XCTAssertNil(ZoomMarketplacePages.keyFields(on: .signIn))
    }
}
