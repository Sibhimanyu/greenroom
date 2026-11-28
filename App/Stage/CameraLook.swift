//
//  CameraLook.swift
//  Greenroom
//
//  The one owner of the camera look (docs/specs/camera-look.md; GLOSSARY.md "Look"):
//  background removal, the background (Normal / Blur / Image), its picture, and Mirror my
//  camera. The same in every layout and every meeting. Not the camera devices and not the
//  camera piece (those are `CameraDirectorSettings` and the Meeting setup).
//
//  A value type. The coordinator keeps exactly one; every screen reads it and every change
//  goes through it. It persists under the keys the three loose settings and the mirror
//  toggle always used, so nothing migrates. Foundation only; compiled by the test target.
//
import Foundation

struct CameraLook: Equatable {

    /// Cutout and Presenter: Greenroom finds you, or keys out a real green screen.
    var removal: BackgroundRemoval = .automatic
    /// Behind you in the bubble shapes.
    var background: CameraBackground = .normal
    /// The picture for `.image`: a preset's name, or `custom-<stamp>`.
    var backgroundImage: String = CameraBackgroundPreset.defaultChoice
    /// Mirror my camera: flips only the owner's bubble on their own screen.
    var mirror: Bool = true

    // The keys are the old ones (R2.1). `mirrorKey` is also `PresenceFeed.mirrorKey` and
    // `SettingsKeys.mirrorSelfView`, which the bubble and the settings file read.
    static let removalKey = "backgroundRemoval"
    static let backgroundKey = "cameraBackground"
    static let backgroundImageKey = "cameraBackgroundImage"
    static let mirrorKey = "camera.mirrorSelfView"

    // MARK: Persistence

    /// A missing key, or a value that is not one of the cases, is that field's default (R2.2).
    static func load(from defaults: UserDefaults) -> CameraLook {
        var look = CameraLook()
        if let raw = defaults.string(forKey: removalKey), let value = BackgroundRemoval(rawValue: raw) { look.removal = value }
        if let raw = defaults.string(forKey: backgroundKey), let value = CameraBackground(rawValue: raw) { look.background = value }
        if let raw = defaults.string(forKey: backgroundImageKey) { look.backgroundImage = raw }
        if let value = defaults.object(forKey: mirrorKey) as? Bool { look.mirror = value }
        return look
    }

    func save(to defaults: UserDefaults) {
        defaults.set(removal.rawValue, forKey: Self.removalKey)
        defaults.set(background.rawValue, forKey: Self.backgroundKey)
        defaults.set(backgroundImage, forKey: Self.backgroundImageKey)
        defaults.set(mirror, forKey: Self.mirrorKey)
    }

    // MARK: The Stage

    /// Mirror never reaches the Stage: the meeting's picture and the recordings are never flipped (R3.1).
    static func reachesStage(from old: CameraLook, to new: CameraLook) -> Bool {
        old.removal != new.removal || old.background != new.background || old.backgroundImage != new.backgroundImage
    }

    // MARK: The settings file (mirror travels through SettingsDefaultsBridge, R4.4)

    var exportedRemoval: String { removal.rawValue }
    var exportedBackground: String { background.rawValue }
    var exportedBackgroundImage: String { backgroundImage }

    /// What an imported file changes: each field that is present and known; the rest stay (R4.2).
    /// The picture goes in with the mode, so Image never shows an empty one (R4.3).
    func importing(removal: String?, background: String?, picture: String?) -> CameraLook {
        var look = self
        if let picture { look.backgroundImage = picture }
        if let background, let mode = CameraBackground(rawValue: background) { look.background = mode }
        if let removal, let mode = BackgroundRemoval(rawValue: removal) { look.removal = mode }
        return look
    }
}
