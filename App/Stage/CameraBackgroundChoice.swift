//
//  CameraBackgroundChoice.swift
//  Greenroom
//
//  The choices behind "what sits behind you". Foundation only, so the settings
//  file rules and their tests can use them; the drawing is in CameraEffects.swift.
//
import Foundation

/// What sits behind you in the bubble shapes. Cutout and Presenter have their
/// own removal (see `BackgroundRemoval`) and ignore this.
///
/// Upstream also has a `.cutout` case; Greenroom's Cutout is a webcam shape,
/// so it is not repeated here.
enum CameraBackground: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case blur = "Blur"
    case image = "Image"

    var id: String { rawValue }
}

/// The five pictures Recorditor ships, plus the one the user chose.
///
/// A choice is stored as a short string so it travels in `StageConfiguration`
/// (which is Equatable) and in UserDefaults: a preset's `rawValue`, or
/// `custom-<stamp>` for the user's own file. The stamp changes every time a
/// new file is chosen, so the compositor sees a different value and reloads.
enum CameraBackgroundPreset: String, CaseIterable, Identifiable {
    case studio, sunset, ocean, forest, slate

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    /// The bundled file, `bg-1-studio.jpg` and so on (App/Stage/Backgrounds).
    var fileName: String {
        let index = (Self.allCases.firstIndex(of: self) ?? 0) + 1
        return "bg-\(index)-\(rawValue)"
    }

    var url: URL? { Bundle.main.url(forResource: fileName, withExtension: "jpg") }

    static let defaultChoice = CameraBackgroundPreset.studio.rawValue

    /// `custom-<stamp>` names the user's own picture (a file on this Mac), not a preset.
    static func isCustomPicture(_ key: String) -> Bool { key.hasPrefix("custom") }
}
