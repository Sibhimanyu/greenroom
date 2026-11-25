import XCTest

final class HomeTilePanelRulesTests: XCTestCase {
    func testKeyMovementClampsAtEnds() {
        XCTAssertEqual(HomeTileKeyRules.moved(from: 0, by: -1, count: 5), 0)
        XCTAssertEqual(HomeTileKeyRules.moved(from: 4, by: 1, count: 5), 4)
        XCTAssertEqual(HomeTileKeyRules.moved(from: 2, by: 1, count: 5), 3)
        XCTAssertEqual(HomeTileKeyRules.moved(from: 0, by: 1, count: 0), 0)
        XCTAssertEqual(HomeTileKeyRules.startIndex(selected: 3, count: 5), 3)
        XCTAssertEqual(HomeTileKeyRules.startIndex(selected: nil, count: 5), 0)
        XCTAssertEqual(HomeTileKeyRules.startIndex(selected: 9, count: 5), 4)
    }

    func testSwitchingSectionNeedsTwoChosenAndSwitchOn() {
        XCTAssertEqual(CameraPanelRules.sections(switchOn: true, chosenCount: 2), [.cameras, .switching])
        XCTAssertEqual(CameraPanelRules.sections(switchOn: true, chosenCount: 1), [.cameras])
        XCTAssertEqual(CameraPanelRules.sections(switchOn: false, chosenCount: 3), [.cameras])
        XCTAssertTrue(CameraPanelRules.showsPickAnotherHint(switchOn: true, chosenCount: 1))
        XCTAssertFalse(CameraPanelRules.showsPickAnotherHint(switchOn: true, chosenCount: 2))
        XCTAssertFalse(CameraPanelRules.showsPickAnotherHint(switchOn: false, chosenCount: 0))
    }

    func testSwitchToggleNeedsTwoCameras() {
        XCTAssertFalse(CameraPanelRules.showsSwitchToggle(availableCount: 1))
        XCTAssertTrue(CameraPanelRules.showsSwitchToggle(availableCount: 2))
    }

    func testTapPicksOneWhenSwitchOff() {
        XCTAssertEqual(CameraPanelRules.tapped(uid: "b", switchOn: false, order: ["a", "b"]), ["b", "a"])
        XCTAssertEqual(CameraPanelRules.tapped(uid: "c", switchOn: false, order: []), ["c"])
    }

    func testTapTogglesWhenSwitchOn() {
        XCTAssertEqual(CameraPanelRules.tapped(uid: "b", switchOn: true, order: ["a"]), ["a", "b"])
        XCTAssertEqual(CameraPanelRules.tapped(uid: "a", switchOn: true, order: ["a", "b"]), ["b"])
    }

    func testSelectionAndPosition() {
        XCTAssertTrue(CameraPanelRules.isSelected(uid: "a", switchOn: false, order: ["a", "b"], single: "a", noCamera: false))
        XCTAssertFalse(CameraPanelRules.isSelected(uid: "a", switchOn: false, order: ["a"], single: "a", noCamera: true))
        XCTAssertTrue(CameraPanelRules.isSelected(uid: "b", switchOn: true, order: ["a", "b"], single: "a", noCamera: false))
        XCTAssertEqual(CameraPanelRules.position(of: "b", switchOn: true, order: ["a", "b"]), 2)
        XCTAssertNil(CameraPanelRules.position(of: "b", switchOn: false, order: ["a", "b"]))
    }

    func testSwitchingOnKeepsCurrentCamera() {
        XCTAssertEqual(CameraPanelRules.orderWhenSwitchingOn(order: ["b"], single: "a"), ["a", "b"])
        XCTAssertEqual(CameraPanelRules.orderWhenSwitchingOn(order: ["a", "b"], single: "a"), ["a", "b"])
        XCTAssertEqual(CameraPanelRules.orderWhenSwitchingOn(order: [], single: nil), [])
    }

    func testChosenIgnoresUnplugged() {
        XCTAssertEqual(CameraPanelRules.chosen(order: ["a", "x", "b"], available: ["b", "a"]), ["a", "b"])
    }

    func testHeaderValue() {
        XCTAssertEqual(CameraPanelRules.headerValue(noCamera: true, switchOn: false, chosenCount: 0, singleName: "Cam"), "Off")
        XCTAssertEqual(CameraPanelRules.headerValue(noCamera: false, switchOn: true, chosenCount: 2, singleName: "Cam"), "2 cameras, switching")
        XCTAssertEqual(CameraPanelRules.headerValue(noCamera: false, switchOn: false, chosenCount: 1, singleName: "Cam"), "Cam")
        XCTAssertEqual(CameraPanelRules.headerValue(noCamera: false, switchOn: false, chosenCount: 0, singleName: nil), "No camera found")
    }

    func testNoCameraRefusedWhenNothingShared() {
        XCTAssertFalse(CameraPanelRules.noCameraEnabled(shareIsNothing: true))
        XCTAssertTrue(CameraPanelRules.noCameraEnabled(shareIsNothing: false))
    }

    func testSymbols() {
        XCTAssertEqual(CameraPanelRules.symbol(name: "X", isBuiltIn: true), "laptopcomputer")
        XCTAssertEqual(CameraPanelRules.symbol(name: "Sibhi's iPhone Camera", isBuiltIn: false), "iphone")
        XCTAssertEqual(CameraPanelRules.symbol(name: "Logitech", isBuiltIn: false), "web.camera")
    }

    func testMicSavedMissingStaysListed() {
        XCTAssertTrue(MicPanelRules.showsSavedMissing(selection: "x", available: ["a"]))
        XCTAssertFalse(MicPanelRules.showsSavedMissing(selection: "a", available: ["a"]))
        XCTAssertFalse(MicPanelRules.showsSavedMissing(selection: "", available: []))
        XCTAssertEqual(MicPanelRules.headerValue(name: "Yeti", savedMissing: false), "Yeti")
        XCTAssertEqual(MicPanelRules.headerValue(name: "Yeti", savedMissing: true), "Saved microphone (not connected)")
    }

    func testMicSystemAudioHintNeedsShare() {
        XCTAssertTrue(MicPanelRules.showsNeedsShareHint(recordSystemAudio: true, shareIsNothing: true))
        XCTAssertFalse(MicPanelRules.showsNeedsShareHint(recordSystemAudio: true, shareIsNothing: false))
        XCTAssertFalse(MicPanelRules.showsNeedsShareHint(recordSystemAudio: false, shareIsNothing: true))
    }

    func testRecordSectionsOnlyWhenNotLive() {
        XCTAssertEqual(RecordPanelRules.sections(isLive: false), [.start, .clipBuffer, .folder])
        XCTAssertEqual(RecordPanelRules.sections(isLive: true), [])
        XCTAssertTrue(RecordPanelRules.showsClipLength(clipBufferOn: true))
        XCTAssertFalse(RecordPanelRules.showsClipLength(clipBufferOn: false))
        XCTAssertEqual(RecordPanelRules.clipLengthText(seconds: 300), "Keeps the last 5 minutes.")
        XCTAssertEqual(RecordPanelRules.clipLengthText(seconds: 60), "Keeps the last 1 minute.")
        XCTAssertEqual(RecordPanelRules.clipLengthText(seconds: 45), "Keeps the last 45 seconds.")
        XCTAssertEqual(RecordPanelRules.headerValue(autoRecord: true), "Auto-record")
        XCTAssertEqual(RecordPanelRules.headerValue(autoRecord: false), "Manual")
    }

    func testMoreTabsAreTheSettingsTabsAndOnlyCuesIsBeta() {
        XCTAssertEqual(MorePanelRules.tabs.map(\.id),
                       ["account", "webcam", "layout", "devices", "general", "shortcuts", "zoom", "youtube", "cues", "transfer"])
        XCTAssertEqual(MorePanelRules.tabs.map(\.id), SettingsTabs.order(includingAccount: true))
        XCTAssertEqual(MorePanelRules.tabs.filter(\.beta).map(\.id), ["cues"])
        XCTAssertEqual(Set(MorePanelRules.tabs.map(\.id)).count, MorePanelRules.tabs.count)
    }

    func testMoreTabsLeaveOutAccountWhenTheBuildHasNone() {
        let release = MorePanelRules.tabs(includingAccount: false).map(\.id)
        XCTAssertEqual(release, ["webcam", "layout", "devices", "general", "shortcuts", "zoom", "youtube", "cues", "transfer"])
        XCTAssertEqual(release, SettingsTabs.order(includingAccount: false))
        XCTAssertEqual(MorePanelRules.tabs(includingAccount: true).map(\.id).first, "account")
    }
}

final class SettingsTabsTests: XCTestCase {
    func testDevicesAndGeneralAreTabsAndTheOldHomesAreNotDuplicated() {
        let tabs = SettingsTabs.order(includingAccount: true)
        XCTAssertTrue(tabs.contains("devices"))
        XCTAssertTrue(tabs.contains("general"))
        XCTAssertEqual(Set(tabs).count, tabs.count)
    }

    func testEveryTabUpToTenHasAShortcutAndNoneTraps() {
        let n = SettingsTabs.order(includingAccount: true).count
        XCTAssertLessThanOrEqual(n, 10)
        for i in 0..<n { XCTAssertNotNil(SettingsTabs.shortcutKey(at: i), "tab \(i)") }
        XCTAssertEqual(SettingsTabs.shortcutKey(at: 0), "1")
        XCTAssertEqual(SettingsTabs.shortcutKey(at: 9), "0")
        XCTAssertNil(SettingsTabs.shortcutKey(at: 10))
    }
}

final class ScreenLayoutPanelRulesTests: XCTestCase {
    func testScreenTilesMapKinds() {
        XCTAssertEqual(ScreenPanelRules.tile(for: .app), .screen)
        XCTAssertEqual(ScreenPanelRules.tile(for: .display), .screen)
        XCTAssertEqual(ScreenPanelRules.tile(for: .nothing), .camera)
        // Just me: off by setting is one click from on; only no device blocks it.
        XCTAssertTrue(ScreenPanelRules.tileEnabled(.camera, camera: .offBySetting))
        XCTAssertTrue(ScreenPanelRules.tileEnabled(.camera, camera: .on))
        XCTAssertFalse(ScreenPanelRules.tileEnabled(.camera, camera: .noDevice))
        XCTAssertTrue(ScreenPanelRules.tileEnabled(.window, camera: .noDevice))
        XCTAssertTrue(CameraTileRules.justMeTurnsCameraOn(.offBySetting))
        XCTAssertFalse(CameraTileRules.justMeTurnsCameraOn(.on))
        XCTAssertFalse(CameraTileRules.justMeTurnsCameraOn(.noDevice))
        XCTAssertEqual(CameraTileRules.justMeNoDeviceHint, "Just me needs a camera. None is connected.")
    }

    func testScreenSections() {
        func s(_ k: SetupSummary.ShareKind, d: Int = 1, b: Bool = false, g: Bool = false, p: Bool = false) -> [ScreenPanelRules.Section] {
            ScreenPanelRules.sections(kind: k, displayCount: d, browsingWindows: b, gone: g, permissionMissing: p)
        }
        XCTAssertEqual(s(.display), [.share])
        XCTAssertEqual(s(.display, d: 2), [.share, .displays])
        XCTAssertEqual(s(.window), [.share, .windows, .follow])
        XCTAssertEqual(s(.window, d: 3, g: true), [.share, .gone, .windows, .follow])
        XCTAssertEqual(s(.display, b: true), [.share, .windows])
        XCTAssertEqual(s(.whiteboard, d: 2, p: true), [.share])
        XCTAssertEqual(s(.display, p: true), [.share, .permission])
    }

    func testWindowGrouping() {
        let g = ScreenPanelRules.grouped(bundleIDs: ["a", "b", "a", "c", "b"])
        XCTAssertEqual(g.order, [0, 2, 1, 4, 3])
        XCTAssertEqual(g.firstOfApp, [true, false, true, false, true])
    }

    func testLayoutSections() {
        XCTAssertEqual(LayoutPanelRules.sections(locked: false, activePieceCount: nil, hasApps: false), [.layouts])
        XCTAssertEqual(LayoutPanelRules.sections(locked: true, activePieceCount: 3, hasApps: false), [.layouts, .locked, .actions])
        XCTAssertEqual(LayoutPanelRules.sections(locked: false, activePieceCount: 0, hasApps: true), [.layouts, .actions])
        XCTAssertEqual(LayoutPanelRules.headerValue(name: "None"), "No layout")
        XCTAssertEqual(LayoutPanelRules.headerValue(name: "Two apps"), "Two apps")
        XCTAssertNil(LayoutPanelRules.twoDisplayNote(hasTwoDisplays: false, secondConnected: true))
        XCTAssertEqual(LayoutPanelRules.twoDisplayNote(hasTwoDisplays: true, secondConnected: false), "Two displays when connected")
        XCTAssertEqual(LayoutPanelRules.twoDisplayNote(hasTwoDisplays: true, secondConnected: true), "Using two displays")
    }

    func testCameraTileStates() {
        XCTAssertEqual(CameraTileRules.state(cameraIsOff: false, deviceCount: 1), .on)
        XCTAssertEqual(CameraTileRules.state(cameraIsOff: true, deviceCount: 2), .offBySetting)
        XCTAssertEqual(CameraTileRules.state(cameraIsOff: true, deviceCount: 0), .noDevice)
        XCTAssertEqual(CameraTileRules.state(cameraIsOff: false, deviceCount: 0), .noDevice)
        XCTAssertTrue(CameraTileRules.isEnabled(.on))
        XCTAssertTrue(CameraTileRules.isEnabled(.offBySetting))
        XCTAssertFalse(CameraTileRules.isEnabled(.noDevice))
        XCTAssertEqual(CameraTileRules.value(.offBySetting, onValue: "Circle"), "Camera off")
        XCTAssertEqual(CameraTileRules.value(.noDevice, onValue: "Circle"), "No camera")
        XCTAssertEqual(CameraTileRules.value(.on, onValue: "Circle"), "Circle")
        XCTAssertEqual(CameraTileRules.symbol(.offBySetting, onSymbol: "circle"), "video.slash")
        XCTAssertEqual(CameraTileRules.symbol(.on, onSymbol: "circle"), "circle")
        XCTAssertTrue(CameraTileRules.tapTurnsCameraOn(.offBySetting))
        XCTAssertFalse(CameraTileRules.tapTurnsCameraOn(.on))
        XCTAssertFalse(CameraTileRules.tapTurnsCameraOn(.noDevice))
        XCTAssertEqual(CameraTileRules.offRowTitle(cameraIsOff: false), "Turn camera off")
        XCTAssertEqual(CameraTileRules.offRowTitle(cameraIsOff: true), "Camera off")
    }
}
