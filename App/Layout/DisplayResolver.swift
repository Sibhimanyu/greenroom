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

    /// The display carrying the menu bar - the fixed stage every layout
    /// frame is measured against.
    ///
    /// This exists because `NSScreen.main` is NOT that display. AppKit
    /// defines it as the screen holding the KEYBOARD-FOCUSED window, so it
    /// follows the user's clicks between monitors. Every frame computed from
    /// it therefore retargets itself silently: with focus on the extended
    /// display, the side column was placed at that display's origin plus the
    /// column offset (measured live: x=3335 instead of 1415), the main pane
    /// tiled to the wrong monitor, and the participant grid's own target
    /// flipped between monitors tick to tick, so the maintain loop moved the
    /// grid to one display and then the other.
    ///
    /// That flip was one of two self-inflicted halves of the "tug-of-war".
    /// The other was the drift test comparing against a frame AppKit will
    /// never grant - see `peopleViewGrantedFrame` in CoordinatorController.
    /// Whether an external mover ALSO exists is still unproven.
    static func mainDisplayScreen() -> NSScreen? {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.first { displayID(of: $0) == mainID }
            ?? NSScreen.screens.first
    }

    /// The default People-view target: the first display that isn't the
    /// main one (the main being what the tiled workspace - and any class
    /// mirror of it - already uses). nil when only the main display exists.
    ///
    /// Keyed to the MENU-BAR display, not `NSScreen.main`: comparing against
    /// the focused screen made this return the menu-bar display itself the
    /// moment the grid (which lives on the secondary) took focus, so the
    /// maintain loop dutifully "corrected" the grid onto the main display and
    /// back again forever.
    static func firstSecondaryScreen() -> NSScreen? {
        let mainID = CGMainDisplayID()
        return NSScreen.screens.first { displayID(of: $0) != mainID }
    }
}
