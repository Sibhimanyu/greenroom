//
//  MeetingMode.swift
//  Greenroom
//
//  The one up-front decision in the single-button flow. Its own file so the test
//  target can compile it with the saved settings (docs/specs/saved-settings.md D7).
//  Foundation only. Moved unchanged from CoordinatorController.swift.
//
import Foundation

/// The one up-front decision in the single-button flow: does Start create
/// a fresh meeting, or start one of your scheduled meetings?
enum MeetingMode: String, CaseIterable, Identifiable {
    case create, join
    /// No meeting: the Webcam page's picture recorded to this Mac. See
    /// `startRecordingFlow`.
    case record

    var id: String { rawValue }

    /// The raw value "join" is what older versions saved, so it keeps loading
    /// into the My Meetings tab.
    static let scheduledHelp = "Your personal room and the meetings scheduled on your Zoom account. To join someone else\u{2019}s meeting, use the Zoom app."

    var label: String {
        switch self {
        case .create: return "New Meeting"
        case .join: return "My Meetings"
        case .record: return "Record"
        }
    }

    /// The toolbar switcher's words: short, so the switcher, Sessions, Help and
    /// Settings all fit a 560pt window without an overflow chevron.
    var shortLabel: String {
        switch self {
        case .create: return "New"
        case .join: return "My Meetings"
        case .record: return "Record"
        }
    }
}
