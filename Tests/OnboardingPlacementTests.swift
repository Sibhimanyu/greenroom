import XCTest
@testable import GreenroomTests

final class OnboardingPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 25, width: 1512, height: 900)
    private let size = CGSize(width: 680, height: 728)

    func testCentresOnTheMainWindow() {
        let main = CGRect(x: 186, y: 300, width: 1140, height: 380)
        let f = OnboardingPlacement.frame(size: size, anchor: main, visible: screen)
        XCTAssertEqual(f.midX, main.midX, accuracy: 1)
        XCTAssertEqual(f.midY, main.midY, accuracy: 1)
    }

    func testCentresOnTheScreenWithoutAMainWindow() {
        let f = OnboardingPlacement.frame(size: size, anchor: nil, visible: screen)
        XCTAssertEqual(f.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(f.midY, screen.midY, accuracy: 1)
    }

    func testClampedInsideTheVisibleScreen() {
        let low = CGRect(x: 1300, y: 25, width: 400, height: 300)
        let f = OnboardingPlacement.frame(size: size, anchor: low, visible: screen)
        XCTAssertTrue(screen.contains(f))
    }
}
