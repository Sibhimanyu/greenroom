//
//  ScreenroomDefaults.swift
//  Greenroom
//
//  Carrying the preferences across the rename from Marks to Screenroom.
//
//  Nothing has shipped, so strictly this is unnecessary: no Mac in the world
//  has a `marksAgentSettings` in it except the ones this was built on. It is
//  here anyway because those Macs include the one it is being tested on, and
//  losing a typed-out agent command to a rename would be a self-inflicted
//  wound in the middle of trying the feature out.
//
//  Runs once, copies only what it finds, and never overwrites a preference
//  the new name has already written. It can be deleted after the first
//  release under the new name, at which point there is nothing left to
//  migrate from.
//
import Foundation

enum ScreenroomDefaults {

    private static let pairs = [
        ("marksAgentSettings", ScreenroomAgentSettings.key),
        ("marksTranscriberSettings", ScreenroomTranscriberSettings.key),
        ("marksDefaultRubric", "screenroomDefaultRubric"),
        ("marksCameraUID", "screenroomCameraUID"),
        ("marksSource", "screenroomSource"),
    ]

    /// `static let` rather than a function with a flag: Swift runs a static
    /// initialiser exactly once, lazily, the first time it is touched, which
    /// is precisely the semantics wanted and is one line instead of three.
    static let migrated: Void = {
        let defaults = UserDefaults.standard
        for (old, new) in pairs where defaults.object(forKey: new) == nil {
            guard let value = defaults.object(forKey: old) else { continue }
            defaults.set(value, forKey: new)
        }
    }()
}
