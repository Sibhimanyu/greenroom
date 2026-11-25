//
//  RoomDisplayNote.swift
//
//  R15.2: Home's note when the active layout puts a Room screen on a second
//  display and that display is not usable. Pure (Foundation only) so it is
//  tested; it never blocks Start (Q10): the layout's main arrangement runs and
//  the Room screen is skipped.
//
import Foundation

extension LayoutTemplate {
    /// The one place that reads where the Room screen sits, so a change to the
    /// two-display model touches this line alone.
    var putsRoomScreenOnSecondDisplay: Bool {
        twoDisplays?.second.contains { $0.kind == .roomScreen } ?? false
    }
}

enum RoomDisplayNote: Equatable {
    case connect
    case mirrored

    static let openDisplaysSettingsURL = "x-apple.systempreferences:com.apple.Displays-Settings.extension"
    static let hint = "Set the room's screen as an extended display (not mirrored) in System Settings → Displays."

    var text: String {
        switch self {
        case .connect: return "Connect the room display"
        case .mirrored: return "Your room display is mirrored. Set it to extended to use the Room screen."
        }
    }

    /// `connectedDisplays`: screens macOS reports (a mirror set counts once).
    /// `isMirrored`: some connected display is in a mirror set.
    static func note(for template: LayoutTemplate?, connectedDisplays: Int, isMirrored: Bool) -> RoomDisplayNote? {
        guard let template, template.putsRoomScreenOnSecondDisplay, connectedDisplays < 2 else { return nil }
        return isMirrored ? .mirrored : .connect
    }
}
