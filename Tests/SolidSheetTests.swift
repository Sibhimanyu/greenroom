import XCTest
import AppKit

/// R38.1: the solid backdrop follows light / dark.
@MainActor
final class SolidSheetTests: XCTestCase {
    private func brightness(_ sheet: SolidSheet) throws -> CGFloat {
        let cg = try XCTUnwrap(sheet.layer?.backgroundColor)
        let color = try XCTUnwrap(NSColor(cgColor: cg)?.usingColorSpace(.sRGB))
        return color.brightnessComponent
    }

    func testTheSolidSheetFollowsLightAndDark() throws {
        let sheet = SolidSheet(frame: NSRect(x: 0, y: 0, width: 100, height: 100), color: .windowBackgroundColor)
        sheet.appearance = NSAppearance(named: .aqua)
        sheet.viewDidChangeEffectiveAppearance()
        XCTAssertGreaterThan(try brightness(sheet), 0.7, "light")
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.viewDidChangeEffectiveAppearance()
        XCTAssertLessThan(try brightness(sheet), 0.4, "dark")
    }
}
