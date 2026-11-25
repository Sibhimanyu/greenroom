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

enum SettingsImportRules {

    /// The recording countdowns the Record page offers.
    static let countdownChoices = [0, 3, 5, 10]

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
        if var library = t.layoutLibrary {
            library.templates = library.templates.map {
                withLocalDisplays($0, connected: environment.connectedDisplayUUIDs)
            }
            t.layoutLibrary = library
        }
        return (t, [])
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
