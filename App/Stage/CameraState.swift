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
        case .everyoneAndMe: return "Everyone & me"
        case .onlyEveryone: return "Only the meeting"
        case .onlyMe: return "Only me"
        case .off: return "Off"
        }
    }

    /// One line of what the state does: what the meeting gets first, then the owner's own screen.
    /// The one source for the camera menus, tooltips, Home and the Layouts inspector. Off and Only me
    /// still send the screen, which is what keeps them apart from Stop video (nothing is sent, R49).
    var detail: String {
        switch self {
        case .everyoneAndMe: return "The meeting gets your screen and your camera. You see your camera too."
        case .onlyEveryone: return "The meeting gets your screen and your camera. Your camera is hidden from you."
        case .onlyMe: return "The meeting gets your screen without your camera. You see it as a mirror."
        case .off: return "The meeting gets your screen without your camera."
        }
    }

    var everyoneSees: Bool { self == .everyoneAndMe || self == .onlyEveryone }
    var iSee: Bool { self == .everyoneAndMe || self == .onlyMe }
}

/// The saved camera state of the active layout and the running meeting's own change to it.
/// A live change never reaches `saved`; Start and Snap Back drop it.
/// Not retired in P3 (docs/specs/meeting-setup.md): it stays the camera state's rule book (`lastOn`,
/// click and turn-on targets, `Moment`) behind `MeetingSetup`, which is its only holder in the app.
/// Retiring it means moving `Moment` out of `StopVideoRules` and rewriting `CameraStateTests`,
/// `CameraMatrixTests` and `StopVideoRulesTests` onto `MeetingSetup`; nothing in the app needs that.
struct CameraStateSession: Equatable {
    private(set) var saved: CameraState
    private(set) var live: CameraState?

    init(saved: CameraState) {
        self.saved = saved
        lastOn = Self.onState(of: saved)
    }

    var current: CameraState { live ?? saved }

    /// The "on" state the camera comes back as after Off (R6.6): the last one that was not Off
    /// this meeting, or the layout default's on-state after Start. Every live change (the bar, the
    /// Meeting toolbar, Home) goes through `setLive`, so all of them feed it.
    private(set) var lastOn: CameraState

    private static func onState(of state: CameraState) -> CameraState { state == .off ? .everyoneAndMe : state }

    /// What a click on the camera button changes the live state to (`MeetingBarModel.cameraClickTarget`).
    func clickTarget(noCameraAllowed: Bool) -> CameraState {
        Self.clickTarget(current: current, lastOn: lastOn, noCameraAllowed: noCameraAllowed)
    }

    /// Any "on" state goes Off; Off comes back as `lastOn` (Only the meeting returns as Only the meeting).
    /// With nothing shared Off would leave an empty picture, so a click then leaves the state alone.
    static func clickTarget(current: CameraState, lastOn: CameraState, noCameraAllowed: Bool) -> CameraState {
        if current == .off { return lastOn == .off ? .everyoneAndMe : lastOn }
        return noCameraAllowed ? .off : current
    }

    /// What Home's camera tile and camera choices turn the camera on to: from Off the last "on" state,
    /// like the bar; from Only me the same, with the meeting seeing the camera. nil when already on.
    var turnOnTarget: CameraState? {
        guard current.noCamera else { return nil }
        return current == .off ? lastOn : CameraState(noCamera: false, shownOnMyScreen: current.shownOnMyScreen)
    }

    mutating func setLive(_ state: CameraState) {
        if current != .off { lastOn = current }
        live = state
    }
    mutating func setSaved(_ state: CameraState) {
        saved = state
        if live == nil { lastOn = Self.onState(of: state) }
    }
    /// Keep: the live change becomes the saved value and goes. The camera is unchanged, so the
    /// `lastOn` memory stays as it is.
    mutating func keepLive() {
        if let live { saved = live }
        live = nil
    }
    /// Start and Snap Back: the live change goes, and the memory returns to the default's on-state.
    mutating func resetToDefault() {
        live = nil
        lastOn = Self.onState(of: saved)
    }

    /// The moments that may put the camera back to the saved default.
    enum Moment: Equatable {
        /// Start, Snap Back and the end of the picture: the live change goes (R6.3).
        case start, snapBack, end
        /// Another layout became active. A live Off stays Off (meeting-setup R5.4): switching must never
        /// put the camera back in front of everyone. `MeetingSetup.apply(.layoutSwitched)` holds the rule.
        case layoutSwitch
    }

    static func dropsLiveChange(at moment: Moment) -> Bool { moment != .layoutSwitch }

    /// Whether the live change was dropped.
    @discardableResult
    mutating func reset(at moment: Moment) -> Bool {
        guard Self.dropsLiveChange(at: moment) else { return false }
        let had = live != nil
        resetToDefault()
        return had
    }
}
