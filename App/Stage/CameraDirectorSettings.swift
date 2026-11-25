//
//  CameraDirectorSettings.swift
//  Greenroom
//
//  The camera director's saved settings and the cut style. Split from
//  CameraDirector.swift (which needs Vision and the device list) so the settings
//  file can be compiled by GreenroomTests.
//
import Foundation

struct CameraDirectorSettings: Codable, Equatable {

    /// Off until someone turns it on. A teacher with one camera must never
    /// discover this by having their picture cut somewhere else.
    var enabled: Bool = false

    /// The cameras to cut between, in order. The first is where a session
    /// starts and where it returns when nothing is working.
    ///
    /// AVFoundation uniqueIDs, which is what survives an unplug and replug - the same identifier
    /// LocalDeviceResolver hands out.
    var cameraUIDs: [String] = []

    /// How long another camera must have the teacher clearly more head-on
    /// than the live one before the shot moves.
    ///
    /// The failure modes either side are not symmetric. Too short and the
    /// shot cuts every time they glance at a note, which is unwatchable. Too
    /// long and they finish the sentence before the camera catches up, which
    /// is merely late. Late is better.
    ///
    /// One second, down from two. Two was set when the only evidence was
    /// "this camera has lost you", which a glance at a note also produces. A
    /// second camera actually seeing the teacher's face turned to it is much
    /// harder to fake by accident. Saved settings keep whatever they had.
    var dwellSeconds: Double = 1.0

    /// How far off the lens the settings window calls "looking at this
    /// camera", while a camera is being aimed.
    ///
    /// Only that. The switching itself compares the cameras against each
    /// other (see CameraDirector.Chooser) and has no fixed line, because
    /// where the angles fall depends on where each camera is mounted. For
    /// aiming, one number to get under is still the easiest instruction:
    /// twenty-five degrees, which a teacher reading the screen under the
    /// camera sits comfortably inside.
    var awayDegrees: Double = 25

    /// What the class sees at the moment the shot moves.
    var transition: CameraTransition = .cut

    /// "No camera" on the Webcam page: the picture is the shared content
    /// alone and no camera is opened at all.
    ///
    /// Kept here, beside the camera list, because the same cards set both:
    /// picking a camera card clears it. A flag rather than a sentinel in
    /// `cameraUIDs`, which is a list of real devices that `availableOnly`,
    /// the director and the transfer file all read as such. It is one half of the
    /// camera state (Off / Only me), read through `Visibility.cameraEveryoneSees`
    /// (`CoordinatorController.cameraIsOff`), never directly. It holds with
    /// switching on too.
    var noCamera: Bool = false

    static let key = "cameraDirectorSettings"

    /// Usable only when there is somewhere to cut TO.
    var isUsable: Bool { enabled && cameraUIDs.count >= 2 }

    static func load(_ defaults: UserDefaults = .standard) -> CameraDirectorSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CameraDirectorSettings.self, from: data) else {
            return CameraDirectorSettings()
        }
        return decoded
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Decoded key by key, because the synthesized decoder refuses a whole value
/// over one missing key - and every settings blob saved before `transition`
/// existed is missing it. That would not have been a crash. It would have
/// been worse: `load` falls back to defaults, so adding a setting would have
/// quietly switched the feature off and forgotten which cameras were chosen,
/// on every Mac and in every exported config.
extension CameraDirectorSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CameraDirectorSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        cameraUIDs = try container.decodeIfPresent([String].self, forKey: .cameraUIDs) ?? fallback.cameraUIDs
        dwellSeconds = try container.decodeIfPresent(Double.self, forKey: .dwellSeconds) ?? fallback.dwellSeconds
        awayDegrees = try container.decodeIfPresent(Double.self, forKey: .awayDegrees) ?? fallback.awayDegrees
        // An unknown case, from a newer build, is a cut rather than a failure.
        transition = (try? container.decodeIfPresent(CameraTransition.self, forKey: .transition))
            .flatMap { $0 } ?? fallback.transition
        noCamera = try container.decodeIfPresent(Bool.self, forKey: .noCamera) ?? fallback.noCamera
    }
}

enum CameraTransition: String, Codable, CaseIterable, Identifiable {
    /// Straight from one camera to the other, as a vision mixer does it.
    case cut
    /// A short dissolve, for anyone who finds a hard cut abrupt.
    case crossfade

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cut: return "Cut"
        case .crossfade: return "Crossfade"
        }
    }

    /// Half a second. Long enough to read as a dissolve rather than a
    /// glitch, short enough that the teacher is not two people for a whole
    /// word. It was four tenths while the fade stepped; with the steps
    /// smooth, the extra tenth is what lets the ease at each end show.
    var fadeSeconds: Double {
        switch self {
        case .cut: return 0
        case .crossfade: return 0.5
        }
    }
}
