//
//  CameraState.swift
//  Greenroom
//
//  Who sees the owner's camera: one of four, the same four everywhere (GLOSSARY.md,
//  "Camera state"). Derived read-only from the two settings that exist today, so
//  nothing new is stored. Foundation only.
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

    var everyoneSees: Bool { self == .everyoneAndMe || self == .onlyEveryone }
    var iSee: Bool { self == .everyoneAndMe || self == .onlyMe }
}
