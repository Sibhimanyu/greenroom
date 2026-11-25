import XCTest
@testable import GreenroomTests

final class ZoomMarketplaceGuideTests: XCTestCase {
    func testLinkIsAnHTTPSMarketplacePage() {
        XCTAssertEqual(ZoomMarketplaceGuide.builderURL.scheme, "https")
        XCTAssertEqual(ZoomMarketplaceGuide.builderURL.host, "marketplace.zoom.us")
    }

    func testStepsAreShortAndNeverSayClass() {
        for step in ZoomMarketplaceGuide.sdkSteps + ZoomMarketplaceGuide.s2sSteps {
            XCTAssertFalse(step.isEmpty)
            XCTAssertFalse(step.lowercased().contains("class"))
        }
        XCTAssertEqual(ZoomMarketplaceGuide.sdkSteps.count, 4)
        XCTAssertEqual(ZoomMarketplaceGuide.s2sSteps.count, 4)
    }
}
