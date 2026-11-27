//
//  MuteHintRules.swift
//  Greenroom
//
//  Pure (Foundation only). Zoom's Mute (`setMyMute`) silences the microphone for the meeting only.
//  The recording's `MicrophoneTap` is separate and keeps the voice, so while a take is rolling and the
//  owner is muted, the Mute control says the recording still hears them (owner's call, 2026-11-27).
//  Both the floating bar and the Meeting window's toolbar ask here.
//
import Foundation

enum MuteHintRules {
    static let hint = "Muted for the meeting. The recording still hears you."

    /// Muted in Zoom while a take is rolling (GLOSSARY "Take": not paused, not saving).
    static func recordingHearsYou(muted: Bool, inMeeting: Bool, hasAudio: Bool = true,
                                  recording: Bool, paused: Bool, saving: Bool) -> Bool {
        muted && inMeeting && hasAudio && recording && !paused && !saving
    }

    /// The hover text: the hint while the recording hears you, else the control's usual words.
    static func tooltip(hearsYou: Bool, plain: String) -> String { hearsYou ? hint : plain }

    /// The accessibility value (nil: none to add).
    static func spokenValue(hearsYou: Bool) -> String? { hearsYou ? hint : nil }
}
