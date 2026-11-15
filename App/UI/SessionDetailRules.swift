//
//  SessionDetailRules.swift
//
//  The session (watch) page's pure rules, kept free of views so tests can
//  compile them: when the rail drops under the picture, how the picture is
//  fitted, the timeline's click maths, the playback speeds, the order of the
//  moments list, and when the space bar may play and pause.
//
import SwiftUI

/// One thing marked on the recording: a clip or a note. Plain values, so the
/// list can be ordered and drawn without knowing where they came from.
struct SessionMoment: Identifiable, Equatable {
    enum Kind: Equatable { case clip, note }
    let id: String
    let kind: Kind
    /// Where it sits in the recording, in seconds.
    let at: Double
    /// "Clip \u{00B7} 2 min", or the note's own words.
    let label: String
    /// Clips only: already cut to a file.
    var exported = false
}

enum SessionDetailRules {
    /// The right rail's width on a wide page.
    static let railWidth: CGFloat = 320

    /// Below this page width the rail moves under the picture and the page
    /// scrolls (the page minimum is 900 less the sidebar, which a session
    /// does not show).
    static let narrowBelow: CGFloat = 960

    static func isNarrow(width: CGFloat) -> Bool { width > 0 && width < narrowBelow }

    /// The picture's size: the largest rectangle of `aspect` (width over
    /// height) that fits `available`. Anything unusable falls back to 16:9.
    static func fit(aspect: CGFloat, in available: CGSize) -> CGSize {
        guard available.width > 0, available.height > 0 else { return .zero }
        let ratio = aspect.isFinite && aspect > 0.05 && aspect < 20 ? aspect : 16.0 / 9.0
        let byWidth = CGSize(width: available.width, height: available.width / ratio)
        if byWidth.height <= available.height { return byWidth }
        return CGSize(width: available.height * ratio, height: available.height)
    }

    /// The movie's shape from its presentation size; 16:9 until it is known.
    static func aspect(of size: CGSize) -> CGFloat {
        size.width > 0 && size.height > 0 ? size.width / size.height : 16.0 / 9.0
    }

    /// A click or drag on the timeline's track, as a time in the recording.
    static func seekTime(x: CGFloat, width: CGFloat, duration: Double) -> Double? {
        guard duration > 0, width > 0 else { return nil }
        return min(duration, max(0, duration * Double(x / width)))
    }

    /// Where a mark sits along the track, 0...1.
    static func fraction(of seconds: Double, in duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }

    static let speeds: [Float] = [1, 1.25, 1.5, 2]

    /// "1\u{00D7}", "1.25\u{00D7}".
    static func speedLabel(_ speed: Float) -> String {
        let text = speed == speed.rounded() ? String(Int(speed)) : String(format: "%g", speed)
        return "\(text)\u{00D7}"
    }

    /// "4:05", or "1:02:09" past the hour.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Clips and notes in one list, in time order. Equal times keep clips
    /// before notes so the order never flickers.
    static func ordered(_ moments: [SessionMoment]) -> [SessionMoment] {
        moments.enumerated().sorted { a, b in
            if a.element.at != b.element.at { return a.element.at < b.element.at }
            if a.element.kind != b.element.kind { return a.element.kind == .clip }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// A note's click lands a little before it: it was stamped when the
    /// evaluator began typing, so what it describes is just behind it.
    static func noteSeekTime(_ at: Double) -> Double { max(0, at - 4) }

    /// The space bar plays and pauses the picture only when nothing is being
    /// typed: no text input has the keyboard, no modifier is held, no sheet
    /// is up, and the page is the one on screen.
    static func spaceTogglesPlayback(textInputFocused: Bool, controlFocused: Bool,
                                     hasModifiers: Bool, sheetUp: Bool, pageActive: Bool) -> Bool {
        pageActive && !textInputFocused && !controlFocused && !hasModifiers && !sheetUp
    }

    /// The first upload asks once; after that it just goes.
    static let uploadConfirmedKey = "youtubeUploadConfirmed"
}
