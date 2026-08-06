//
//  LocalDeviceResolver.swift
//  Greenroom
//
//  Resolves the exact identifiers OBS's own source kinds expect - a display
//  UUID for `screen_capture`, a device UID for `av_capture_input_v2` -
//  directly from macOS, the same way OBS resolves them internally. Asking
//  OBS's own dynamic properties UI for these (GetInputPropertiesListPropertyItems)
//  turned out slow/unreliable in testing, so this sidesteps it entirely.
//
import Foundation
import CoreGraphics
import AVFoundation

enum LocalDeviceResolver {

    static var mainDisplayUUID: String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID())?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String
    }

    /// The real physical webcam - explicitly never "OBS Virtual Camera"
    /// itself. That device shows up in this same AVFoundation enumeration
    /// once OBS's virtual cam is active, and testing showed
    /// `AVCaptureDevice.default(for: .video)` can hand it back as the
    /// "default" device - which would wire OBS's own webcam source to itself.
    static func physicalCameraUID() -> String? {
        var deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            deviceTypes.append(.external)
        } else {
            deviceTypes.append(.externalUnknown)
        }

        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
            .devices
            .filter { $0.localizedName != "OBS Virtual Camera" }

        return (devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first)?.uniqueID
    }
}
