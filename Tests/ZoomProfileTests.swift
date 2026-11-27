import XCTest
@testable import GreenroomTests

/// The signed-in Zoom account's own name and email, read from Zoom's profile page text, so Set up for me fills
/// Zoom's Developer Contact with the person's real details (owner, 2026-11-27: "we should just fill in their own email").
final class ZoomProfileTests: XCTestCase {
    func testTheSignInEmailAndDisplayNameAreFound() {
        let text = """
        Profile
        Sibhimanyu V
        Basic Information
        Display Name
        Sibhimanyu V
        Sign-In Email
        sibhi.v@example.org
        Change
        Personal Meeting ID
        354 247 1135
        """
        let p = ZoomProfile.parse(text)
        XCTAssertEqual(p.email, "sibhi.v@example.org")
        XCTAssertEqual(p.name, "Sibhimanyu V")
    }

    func testZoomsOwnAddressesAreNotTheirs() {
        let p = ZoomProfile.parse("Contact support@zoom.us\nSign-In Email\nme@school.edu")
        XCTAssertEqual(p.email, "me@school.edu")
    }

    func testNothingFoundIsNil() {
        let p = ZoomProfile.parse("Sign in to Zoom\nEmail Address\nPassword")
        XCTAssertNil(p.email)
        XCTAssertNil(p.name)
    }
}
