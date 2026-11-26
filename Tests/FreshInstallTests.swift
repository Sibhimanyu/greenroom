//
//  FreshInstallTests.swift
//  GreenroomTests
//
//  A brand-new Mac: no UserDefaults at all. Runs the launch-time model setup the
//  coordinator's init runs (LayoutLibrary.loadOrMigrate with every migration in it,
//  then the P3 camera-and-share copy), the camera and shortcut loads, and the
//  surface the first meeting goes live on, against an empty defaults suite. The
//  first Start on someone else's Mac failed (2026-11-26); this pins that nothing
//  in the launch path assumes the owner's saved state.
//
import XCTest

final class FreshInstallTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "FreshInstallTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// What `CoordinatorController.init` does to the library, in the same order.
    private func launch() -> LayoutLibrary {
        var library = LayoutLibrary.loadOrMigrate(from: defaults, defaultSiteURL: "https://example.com")
        library.migrateCameraAndShare(camera: .global(from: defaults), share: LayoutCamera.globalShare(from: defaults),
                                      defaults: defaults, save: { [store = defaults!] in $0.save(to: store) })
        return library
    }

    func testEmptyDefaultsGiveTheThreeBuiltInsWithLeaveMyWindowsAloneActive() {
        let library = launch()
        XCTAssertEqual(library.templates.map(\.starter), [LayoutLibrary.leaveAlone, LayoutLibrary.rajMode, LayoutLibrary.roomLaptop])
        XCTAssertEqual(library.activeID, library.leaveAloneID)
        XCTAssertNotNil(library.active)
        XCTAssertEqual(library.active?.movesWindows, false, "a fresh Mac must not arrange windows on its first Start")
    }

    func testEveryLayoutOwnsACameraAndAShareOnAFreshMac() {
        let library = launch()
        for template in library.templates {
            XCTAssertNotNil(template.camera, "\(template.name) has no camera piece")
            XCTAssertNotNil(template.share, "\(template.name) has no share")
        }
    }

    func testNoSavedDisplayIdsComeWithTheBuiltIns() {
        // A display UUID belongs to one Mac. A built-in carrying the owner's would never match here.
        for template in launch().templates {
            XCTAssertEqual(template.twoDisplays?.secondUUID ?? "", "", "\(template.name) names a display")
        }
    }

    func testEveryMigrationKeyIsSetSoTheSecondLaunchChangesNothing() {
        let first = launch()
        for key in [LayoutLibrary.oneArrangementMigratedKey, LayoutLibrary.builtInsV2MigratedKey,
                    LayoutLibrary.threeBuiltInsMigratedKey, LayoutLibrary.shownToEveryoneMigratedKey,
                    LayoutLibrary.appsShownMigratedKey, LayoutLibrary.rajRenamedKey,
                    LayoutLibrary.cameraMigratedKey, LayoutLibrary.shareMigratedKey] {
            XCTAssertTrue(defaults.bool(forKey: key), "\(key) not set after the first launch")
        }
        let second = launch()
        XCTAssertEqual(second, first, "the second launch migrated the fresh library again")
        XCTAssertEqual(launch(), first, "the third launch migrated the fresh library again")
    }

    func testTheCameraStartsOnAndShownWithNothingSaved() {
        let director = CameraDirectorSettings.load(defaults)
        XCTAssertFalse(director.noCamera)
        XCTAssertFalse(director.isUsable, "no cameras chosen: the director cannot run")
        let shownOnMyScreen = (defaults.object(forKey: "cameraShownOnMyScreen") as? Bool) ?? true
        XCTAssertEqual(CameraState(noCamera: director.noCamera, shownOnMyScreen: shownOnMyScreen), .everyoneAndMe)
    }

    func testNoSavedShortcutsMeansEveryDefaultAndNoClash() {
        let bindings = defaults.data(forKey: "shortcuts.bindings").flatMap(ShortcutBindings.from(jsonData:)) ?? ShortcutBindings()
        XCTAssertEqual(bindings, ShortcutBindings())
        let resolved = bindings.resolved(among: ShortcutAction.allCases.map { ShortcutSlot.action($0) })
        let combos = resolved.map(\.combo)
        XCTAssertFalse(combos.isEmpty)
        XCTAssertEqual(Set(combos.map { "\($0.keyCode)-\($0.modifiers)" }).count, combos.count, "two defaults share a key")
    }

    func testTheFirstMeetingGoesLiveOnTheBar() {
        // Leave my windows alone places no Meeting piece, so R48 puts the first meeting on the Bar.
        let library = launch()
        let placesMeeting = library.active?.movesWindows == true
        XCTAssertEqual(MeetingSurface.wentLive(layoutPlacesMeeting: placesMeeting), .wentLiveOnBar)
    }

    func testAnImportFromTheOwnersMacDropsItsDisplaysAndMicrophone() {
        // The owner's file, imported in onboarding on another Mac.
        var owners = launch()
        if let i = owners.templates.firstIndex(where: { $0.starter == LayoutLibrary.rajMode }) {
            owners.templates[i].twoDisplays?.secondUUID = "OWNERS-AIRPLAY-DISPLAY"
            owners.activeID = owners.templates[i].id
        }
        var transfer = SettingsTransfer()
        transfer.layoutLibrary = owners
        transfer.micDeviceUID = "owners-usb-mic"
        let (clean, _) = SettingsImportRules.sanitized(transfer, in: SettingsImportEnvironment(
            connectedDisplayUUIDs: ["THIS-MAC-BUILT-IN"], connectedMicrophoneUIDs: ["this-mac-mic"]))
        XCTAssertNil(clean.micDeviceUID)
        XCTAssertTrue(clean.layoutLibrary?.templates.allSatisfy { ($0.twoDisplays?.secondUUID ?? "").isEmpty } ?? false)
        XCTAssertNotNil(clean.layoutLibrary?.active)
    }
}
