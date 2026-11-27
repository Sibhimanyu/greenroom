//
//  SettingsImportRules.swift
//  Greenroom
//
//  What an import refuses, in one place (docs/specs/settings-transfer.md R3,
//  R6, R7). Pure: it is handed what this Mac looks like and returns the file's
//  contents with anything invalid or unavailable removed, plus what to tell the
//  person. The coordinator then assigns what is left through its published
//  properties.
//
import Foundation

/// What this Mac can do, as far as an import cares.
struct SettingsImportEnvironment {
    /// `CuesAvailability.isReleased`.
    var cuesReleased = true
    /// Whether the Whisper transcriber can run here. nil where it cannot be
    /// asked (macOS 14/15): the value is then carried, not forced to false.
    var whisperAvailable: Bool?
    /// Display UUIDs connected now.
    var connectedDisplayUUIDs: Set<String> = []
    /// Microphone uniqueIDs connected now.
    var connectedMicrophoneUIDs: Set<String> = []
    /// Whether the user's own background picture is on this Mac.
    var customPictureAvailable = false
}

/// What an import did beyond assigning: things the person should be told.
struct SettingsImportReport: Equatable {
    var notes: [String] = []
}

enum SettingsImportRules {

    /// The recording countdowns the Record page offers.
    static let countdownChoices = [0, 3, 5, 10]

    /// Shown after an import that had to give up the person's own background picture.
    static let pictureDidNotTravelNote =
        "The background picture did not travel (it is a file on the other Mac), so your background is set to Blur."

    static func sanitized(_ transfer: SettingsTransfer,
                          in environment: SettingsImportEnvironment) -> (transfer: SettingsTransfer, notes: [String]) {
        var t = transfer
        // A colleague's export can carry prompterEnabled=true. It must not
        // switch on a feature this build is holding back.
        if !environment.cuesReleased { t.prompterEnabled = nil }
        // Same rule as prompterEnabled: a colleague's file must not switch on
        // a transcriber this Mac cannot run. Whisper is checked only where the
        // check exists. On macOS 14/15 Cues cannot run at all, so the value is
        // carried and left for the OS that can use it rather than being forced
        // to false and lost on the next export.
        if let value = t.cuesUseWhisper, let available = environment.whisperAvailable {
            t.cuesUseWhisper = value && available
        }
        if let value = t.recordingCountdownSeconds, !countdownChoices.contains(value) {
            t.recordingCountdownSeconds = nil
        }
        // The camera background (D1, D2).
        if let name = t.cameraBackground, CameraBackground(rawValue: name) == nil { t.cameraBackground = nil }
        var notes: [String] = []
        if let image = t.cameraBackgroundImage {
            if CameraBackgroundPreset.isCustomPicture(image) {
                if !environment.customPictureAvailable {
                    // The setting travels; the file does not. Without it the
                    // picture would be empty, so fall back to the blur.
                    t.cameraBackgroundImage = nil
                    if t.cameraBackground == CameraBackground.image.rawValue {
                        t.cameraBackground = CameraBackground.blur.rawValue
                        notes.append(pictureDidNotTravelNote)
                    }
                }
            } else if CameraBackgroundPreset(rawValue: image) == nil {
                t.cameraBackgroundImage = nil
            }
        }
        // A microphone from another Mac matches nothing here. Empty is the
        // system's input, which every Mac has.
        if let uid = t.micDeviceUID, !uid.isEmpty, !environment.connectedMicrophoneUIDs.contains(uid) {
            t.micDeviceUID = nil
        }
        // The meeting window's choices, as the views themselves would read them.
        if let raw = t.meetingWindowView, MeetingViewMode(rawValue: raw) == nil { t.meetingWindowView = nil }
        if let raw = t.meetingWindowShareLayout, MeetingShareLayout(rawValue: raw) == nil {
            t.meetingWindowShareLayout = nil
        }
        if let split = t.meetingWindowShareSplit { t.meetingWindowShareSplit = MeetingSplit.clamp(split) }
        if var library = t.layoutLibrary {
            library.templates = library.templates.map {
                withLocalDisplays($0, connected: environment.connectedDisplayUUIDs)
            }
            t.layoutLibrary = library
        }
        return (t, notes)
    }

    /// meeting-setup R1.3: an older file's app-wide camera state goes to every layout it brings in that
    /// has none. The file's `noCamera` and `cameraShownOnMyScreen` read as one state; what the file
    /// omits keeps this Mac's (`fallback`). Layouts that already carry one are left alone.
    static func applyingOldCameraState(_ library: LayoutLibrary, noCamera: Bool?, shownOnMyScreen: Bool?,
                                       fallback: CameraState) -> LayoutLibrary {
        var library = library
        let state = CameraState(noCamera: noCamera ?? fallback.noCamera, shownOnMyScreen: shownOnMyScreen ?? fallback.shownOnMyScreen)
        for i in library.templates.indices where library.templates[i].cameraState == nil {
            library.templates[i].cameraState = state
        }
        return library
    }

    /// A template with its saved second display cleared when that display is not
    /// connected to this Mac: an exported UUID from another Mac matches nothing
    /// here, and "automatic" finds the right one.
    static func withLocalDisplays(_ template: LayoutTemplate, connected: Set<String>) -> LayoutTemplate {
        guard var two = template.twoDisplays, !two.secondUUID.isEmpty else { return template }
        guard !connected.contains(two.secondUUID) else { return template }
        var copy = template
        two.secondUUID = ""
        copy.twoDisplays = two
        return copy
    }
}
