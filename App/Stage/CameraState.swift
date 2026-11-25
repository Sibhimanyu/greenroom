//
//  CameraState.swift
//  Greenroom
//
//  Who sees the owner's camera: one of four, the same four everywhere (GLOSSARY.md,
//  "Camera state"). The two settings that exist (`noCamera`, `cameraShownOnMyScreen`)
//  stay the stored truth and stay in step, so an old install and a downgrade both
//  keep working; a state is just the pair read as one word. `CameraStateSession`
//  is the saved default plus the running meeting's own change. Foundation only.
//
import Foundation

enum CameraState: Equatable, CaseIterable {
    /// In the meeting's picture and on the owner's screen.
    case everyoneAndMe
    /// In the meeting's picture, hidden on the owner's screen.
    case onlyEveryone
    /// A mirror: the meeting does not see the owner.
    case onlyMe
    case off

    /// `noCamera`: the camera is not sent to the meeting (CoordinatorController.cameraIsOff).
    /// `shownOnMyScreen`: CoordinatorController.cameraShownOnMyScreen.
    init(noCamera: Bool, shownOnMyScreen: Bool) {
        switch (noCamera, shownOnMyScreen) {
        case (false, true): self = .everyoneAndMe
        case (false, false): self = .onlyEveryone
        case (true, true): self = .onlyMe
        case (true, false): self = .off
        }
    }

    /// The pair back out: `noCamera` is "the meeting does not see the owner".
    var noCamera: Bool { !everyoneSees }
    var shownOnMyScreen: Bool { iSee }

    /// Old defaults onto a state. A missing key means what it meant before:
    /// the meeting sees the camera, and it shows on the owner's screen.
    static func migrated(noCamera: Bool?, shownOnMyScreen: Bool?) -> CameraState {
        CameraState(noCamera: noCamera ?? false, shownOnMyScreen: shownOnMyScreen ?? true)
    }

    /// The saved form (defaults key `cameraState`).
    var raw: String {
        switch self {
        case .everyoneAndMe: return "everyoneAndMe"
        case .onlyEveryone: return "onlyEveryone"
        case .onlyMe: return "onlyMe"
        case .off: return "off"
        }
    }

    init?(raw: String) {
        guard let s = CameraState.allCases.first(where: { $0.raw == raw }) else { return nil }
        self = s
    }

    /// The same four words in every menu, tooltip and spoken label.
    var name: String {
        switch self {
        case .everyoneAndMe: return "Everyone and me"
        case .onlyEveryone: return "Only everyone"
        case .onlyMe: return "Only me"
        case .off: return "Off"
        }
    }

    /// One line of what the state does, for tooltips.
    var detail: String {
        switch self {
        case .everyoneAndMe: return "The meeting sees you, and you see your camera on your screen."
        case .onlyEveryone: return "The meeting sees you. Your camera is hidden on your screen."
        case .onlyMe: return "The meeting does not see you. Your camera shows as a mirror on your screen."
        case .off: return "The meeting does not see you, and nothing shows on your screen."
        }
    }

    var symbol: String {
        switch self {
        case .everyoneAndMe: return "person.2.circle"
        case .onlyEveryone: return "person.crop.circle.badge.xmark"
        case .onlyMe: return "person.crop.circle"
        case .off: return "video.slash"
        }
    }

    var everyoneSees: Bool { self == .everyoneAndMe || self == .onlyEveryone }
    var iSee: Bool { self == .everyoneAndMe || self == .onlyMe }
}

/// The saved default (Settings -> Layouts) and the running meeting's own change.
/// A live change never reaches `saved`; Start and Snap Back drop it.
struct CameraStateSession: Equatable {
    private(set) var saved: CameraState
    private(set) var live: CameraState?

    init(saved: CameraState) { self.saved = saved }

    var current: CameraState { live ?? saved }

    mutating func setLive(_ state: CameraState) { live = state }
    mutating func setSaved(_ state: CameraState) { saved = state }
    mutating func resetToDefault() { live = nil }
}
