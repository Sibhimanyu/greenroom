//
//  DisplayResolver.swift
//  Greenroom
//
//  Enumerates the connected displays for the People-view target picker.
//
//  Note on mirroring: when two physical displays mirror each other (e.g.
//  the built-in screen mirrored to a class projector), macOS reports the
//  pair as a SINGLE NSScreen - the mirror set's main. So a mirrored
//  projector never appears as its own selectable display here; picking
//  "the other display" naturally targets the separate, extended one (the
//  user's reference monitor), which is exactly where the participant
//  gallery should open.
//
//  Displays are keyed by their stable CGDisplay UUID string (survives
//  disconnect/reconnect and reboot, unlike the volatile CGDirectDisplayID),
//  so a saved choice re-resolves to the same physical monitor next time.
//
import AppKit

struct DisplayInfo: Identifiable, Hashable {
    /// Stable across reconnects - what the setting persists.
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let isMain: Bool
    /// Pixel dimensions, for a human-recognisable label.
    let pixelWidth: Int
    let pixelHeight: Int

    var label: String {
        "\(name) — \(pixelWidth)×\(pixelHeight)" + (isMain ? " · Main" : "")
    }
}

enum DisplayResolver {

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, cfUUID) as String
    }

    /// All connected displays (mirror sets collapse to one entry - see the
    /// file note), main first.
    static func connectedDisplays() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let did = displayID(of: screen), let uuid = uuidString(for: did) else { return nil }
            let frame = screen.frame
            let scale = screen.backingScaleFactor
            return DisplayInfo(
                id: uuid,
                displayID: did,
                name: screen.localizedName,
                isMain: did == CGMainDisplayID(),
                pixelWidth: Int((frame.width * scale).rounded()),
                pixelHeight: Int((frame.height * scale).rounded())
            )
        }
        .sorted { ($0.isMain ? 0 : 1) < ($1.isMain ? 0 : 1) }
    }

    /// The NSScreen a saved UUID currently maps to, or nil if that display
    /// isn't connected right now.
    static func screen(forUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let did = displayID(of: screen) else { return false }
            return uuidString(for: did) == uuid
        }
    }

    /// The default People-view target: the first display that isn't the
    /// main one (the main being what the tiled workspace - and any class
    /// mirror of it - already uses). nil when only the main display exists.
    static func firstSecondaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0 != NSScreen.main }
    }
}
