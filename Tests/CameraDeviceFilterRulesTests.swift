//
//  CameraDeviceFilterRulesTests.swift
//  GreenroomTests
//
//  R49.12 (owner, 2026-11-27): Zoom's own virtual camera and any device Zoom installs are never
//  offered as the owner's camera device.
//
import XCTest

final class CameraDeviceFilterRulesTests: XCTestCase {
    private typealias R = CameraDeviceFilterRules

    func testZoomVirtualCameraIsHidden() {
        XCTAssertFalse(R.isListable(uniqueID: "zoom_virtual_device", modelID: "", name: "Zoom Virtual Camera"))
        XCTAssertFalse(R.isListable(uniqueID: "ZOOM_VIRTUAL_DEVICE", modelID: "", name: "x"))
    }

    func testAnythingZoomInstallsIsHiddenByNameOrModel() {
        XCTAssertFalse(R.isListable(uniqueID: "abc", modelID: "zoom virtual", name: "Camera"))
        XCTAssertFalse(R.isListable(uniqueID: "abc", modelID: "", name: "ZoomVirtualCamera"))
        XCTAssertFalse(R.isListable(uniqueID: "abc", modelID: "us.zoom.xos", name: "Camera"))
    }

    func testGreenroomsOwnOutputsAreHidden() {
        XCTAssertFalse(R.isListable(uniqueID: "abc", modelID: "", name: "Greenroom Camera"))
    }

    func testRealCamerasStay() {
        XCTAssertTrue(R.isListable(uniqueID: "0x1", modelID: "UVC Camera VendorID_1133", name: "Logitech BRIO"))
        XCTAssertTrue(R.isListable(uniqueID: "FaceTime", modelID: "Apple Camera", name: "FaceTime HD Camera"))
        XCTAssertTrue(R.isListable(uniqueID: "x", modelID: "", name: "Sony ZV-E10"))
    }
}
