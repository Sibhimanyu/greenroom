import XCTest

final class ShelvedTests: XCTestCase {
    // Spec: shelved S1, S4 (Record the Mac's own sound)
    func testStoredOnIsOffWhenShelved() {
        XCTAssertFalse(Shelved.effectiveMacSound(stored: true, macSoundAvailable: false))
    }

    func testStoredValueUsedWhenAvailable() {
        XCTAssertTrue(Shelved.effectiveMacSound(stored: true, macSoundAvailable: true))
        XCTAssertFalse(Shelved.effectiveMacSound(stored: false, macSoundAvailable: true))
    }

    func testStoredOffStaysOffWhenShelved() {
        XCTAssertFalse(Shelved.effectiveMacSound(stored: false, macSoundAvailable: false))
    }
}
