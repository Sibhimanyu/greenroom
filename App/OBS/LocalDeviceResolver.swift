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
        uuid(for: CGMainDisplayID())
    }

    static func uuid(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, cfUUID) as String
    }

    struct Display: Identifiable, Hashable {
        /// Stable across unplug/replug and reboot, unlike the display ID.
        let id: String
        let isMain: Bool
        let width: Int
        let height: Int

        var label: String { "\(width)\u{00D7}\(height)" + (isMain ? " \u{00B7} Main" : "") }
    }

    /// Every display attached RIGHT NOW, main first. Read through CoreGraphics
    /// rather than NSScreen because this is what OBS's screen_capture source
    /// speaks, and because it must stay honest about what is physically
    /// present: "the display we captured last time" being absent is exactly
    /// the case that produced a black capture.
    static func activeDisplays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        let main = CGMainDisplayID()
        return ids.compactMap { id -> Display? in
            guard let uuid = uuid(for: id) else { return nil }
            return Display(id: uuid,
                           isMain: id == main,
                           width: CGDisplayPixelsWide(id),
                           height: CGDisplayPixelsHigh(id))
        }
        .sorted { ($0.isMain ? 0 : 1) < ($1.isMain ? 0 : 1) }
    }

    static func isDisplayConnected(uuid: String) -> Bool {
        activeDisplays().contains { $0.id == uuid }
    }

    /// Which display the screen capture should point at: the explicit choice
    /// when it is actually plugged in, the main display otherwise. The second
    /// return value is true when a saved choice had to be abandoned, so the
    /// caller can say so instead of silently capturing the wrong screen.
    static func resolveCaptureDisplay(preferred: String) -> (uuid: String?, fellBack: Bool) {
        if !preferred.isEmpty {
            if isDisplayConnected(uuid: preferred) { return (preferred, false) }
            return (mainDisplayUUID, true)
        }
        return (mainDisplayUUID, false)
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
