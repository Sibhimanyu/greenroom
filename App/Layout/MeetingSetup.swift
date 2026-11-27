//
//  MeetingSetup.swift
//  Greenroom
//
//  The one owner of the active layout's camera state, camera piece and what's
//  shared (docs/specs/meeting-setup.md, ADR 0004; GLOSSARY.md "Meeting setup").
//  For each of the three it holds the **saved** value (from the active layout)
//  and an optional **for this meeting** change. Nobody else keeps a copy.
//
//  Three doors in, all pure:
//   - `change(_:meetingLive:)`: Home, the bar, the toolbar, the present menu and
//     shortcuts. Before a meeting it saves; during one it is for this meeting.
//   - `savedEdit(_:meetingLive:)`: Settings -> Layouts. Always saves; a live
//     meeting gets it too unless that setting has a for-this-meeting change.
//   - `apply(_:)`: Start, Snap Back, the meeting ending, a layout switch, Keep, Reset.
//  Every call returns an `Effect`: which saved values changed (write the layout)
//  and which values in use changed (tell the Stage). Callers need no other rule.
//
//  Camera state's rules (`lastOn`, click and turn-on targets) stay in
//  `CameraStateSession`, which this wraps and is its only holder (see the note on that type).
//  Foundation only; compiled by the test target as it is.
//
import Foundation

struct MeetingSetup: Equatable {

    enum Setting: CaseIterable, Hashable { case cameraState, cameraPiece, share }

    /// The three saved values of a layout, with no "unset": the caller resolves
    /// a layout that saves no camera piece or share to the app's defaults.
    struct Values: Equatable {
        var cameraState: CameraState
        var cameraPiece: LayoutCamera
        var share: ShareTarget
    }

    /// One new value, naming its setting.
    enum Change: Equatable {
        case cameraState(CameraState)
        case cameraPiece(LayoutCamera)
        case share(ShareTarget)

        var setting: Setting {
            switch self {
            case .cameraState: return .cameraState
            case .cameraPiece: return .cameraPiece
            case .share: return .share
            }
        }
    }

    /// The moments that reshape the setup.
    enum Event: Equatable {
        /// Start, Snap Back and the meeting ending: every for-this-meeting change goes (R5.1).
        case start, snapBack, meetingEnded
        /// Another layout became active, by any route: its saved values come in, changes go (R5.1, R5.2),
        /// except a camera turned Off for this meeting, which stays Off (R5.4).
        case layoutSwitched(to: Values)
        /// Save that setting's for-this-meeting change into the layout and clear it (R4.4).
        case keep(Setting)
        /// Clear that setting's for-this-meeting change (R4.4).
        case reset(Setting)
    }

    /// What a call changed. `saved`: write these into the active layout. `inUse`: the value
    /// in use now differs, so the Stage and the screens need it.
    struct Effect: Equatable {
        var saved: Set<Setting> = []
        var inUse: Set<Setting> = []
    }

    private(set) var savedCameraPiece: LayoutCamera
    private(set) var savedShare: ShareTarget
    private var camera: CameraStateSession
    private var pieceChange: LayoutCamera?
    private var shareChange: ShareTarget?

    init(saved: Values) {
        savedCameraPiece = saved.cameraPiece
        savedShare = saved.share
        camera = CameraStateSession(saved: saved.cameraState)
    }

    // MARK: Queries

    var saved: Values { Values(cameraState: camera.saved, cameraPiece: savedCameraPiece, share: savedShare) }

    /// The values in use: the for-this-meeting change if there is one, else the saved value.
    var cameraState: CameraState { camera.current }
    var cameraPiece: LayoutCamera { pieceChange ?? savedCameraPiece }
    var share: ShareTarget { shareChange ?? savedShare }

    /// A change that differs from the saved value is in effect; one equal to it is not.
    func isForThisMeeting(_ setting: Setting) -> Bool {
        switch setting {
        case .cameraState: return camera.live.map { $0 != camera.saved } ?? false
        case .cameraPiece: return pieceChange.map { $0 != savedCameraPiece } ?? false
        case .share: return shareChange.map { $0 != savedShare } ?? false
        }
    }

    /// The "on" state the camera comes back as after Off (the bar's click, Stop video's press).
    var cameraLastOn: CameraState { camera.lastOn }

    /// What a click on the camera button turns the state into (the bar, the toolbar).
    func cameraClickTarget(noCameraAllowed: Bool) -> CameraState { camera.clickTarget(noCameraAllowed: noCameraAllowed) }
    /// What Home's camera choices turn the camera on to; nil when the meeting already sees it.
    var cameraTurnOnTarget: CameraState? { camera.turnOnTarget }

    // MARK: Changes

    /// A change from Home, the bar, the toolbar, the present menu or a shortcut (R3.1, R4.1).
    @discardableResult
    mutating func change(_ change: Change, meetingLive: Bool) -> Effect {
        edit { me in
            if meetingLive { me.setForThisMeeting(change) } else { me.setSaved(change, alsoInUse: true) }
        }
    }

    /// A change from Settings -> Layouts: always saved; a live meeting gets it unless that
    /// setting has a for-this-meeting change (R4.2).
    @discardableResult
    mutating func savedEdit(_ change: Change, meetingLive: Bool) -> Effect {
        edit { me in me.setSaved(change, alsoInUse: !meetingLive || !me.isForThisMeeting(change.setting)) }
    }

    @discardableResult
    mutating func apply(_ event: Event) -> Effect {
        edit { me in
            switch event {
            case .start, .snapBack, .meetingEnded:
                Setting.allCases.forEach { me.clear($0) }
            case .layoutSwitched(let next):
                // R5.4 (D8): a camera turned Off for this meeting stays Off; everything else goes.
                let keepsOff = me.camera.live == .off
                Setting.allCases.forEach { me.clear($0) }
                me.camera.setSaved(next.cameraState)
                me.camera.resetToDefault()
                if keepsOff { me.camera.setLive(.off) }
                me.savedCameraPiece = next.cameraPiece
                me.savedShare = next.share
            case .keep(let setting):
                guard me.isForThisMeeting(setting) else { me.clear(setting); return }
                switch setting {
                case .cameraState: me.camera.keepLive()
                case .cameraPiece: me.savedCameraPiece = me.pieceChange ?? me.savedCameraPiece; me.pieceChange = nil
                case .share: me.savedShare = me.shareChange ?? me.savedShare; me.shareChange = nil
                }
            case .reset(let setting):
                me.clear(setting)
            }
        }
    }

    // MARK: Inside

    private mutating func setForThisMeeting(_ change: Change) {
        switch change {
        case .cameraState(let s): camera.setLive(s)
        case .cameraPiece(let p): pieceChange = p
        case .share(let s): shareChange = s
        }
    }

    /// Saves the value. `alsoInUse` clears that setting's change so the saved value is what is in use.
    private mutating func setSaved(_ change: Change, alsoInUse: Bool) {
        switch change {
        case .cameraState(let s):
            if alsoInUse { camera.resetToDefault() }
            camera.setSaved(s)
        case .cameraPiece(let p):
            savedCameraPiece = p
            if alsoInUse { pieceChange = nil }
        case .share(let s):
            savedShare = s
            if alsoInUse { shareChange = nil }
        }
    }

    private mutating func clear(_ setting: Setting) {
        switch setting {
        case .cameraState: camera.resetToDefault()
        case .cameraPiece: pieceChange = nil
        case .share: shareChange = nil
        }
    }

    /// Runs a mutation and reports what it changed, by comparing before and after.
    private mutating func edit(_ body: (inout MeetingSetup) -> Void) -> Effect {
        let before = self
        body(&self)
        var effect = Effect()
        if before.saved.cameraState != saved.cameraState { effect.saved.insert(.cameraState) }
        if before.savedCameraPiece != savedCameraPiece { effect.saved.insert(.cameraPiece) }
        if before.savedShare != savedShare { effect.saved.insert(.share) }
        if before.cameraState != cameraState { effect.inUse.insert(.cameraState) }
        if before.cameraPiece != cameraPiece { effect.inUse.insert(.cameraPiece) }
        if before.share != share { effect.inUse.insert(.share) }
        return effect
    }
}
