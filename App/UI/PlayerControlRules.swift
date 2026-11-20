//
//  PlayerControlRules.swift
//
//  The pure half of the watch page's standard video controls: skip arithmetic,
//  the volume glyph and its saved level, which key does what, and when the
//  full-screen controls hide. No views, no AVKit; compiled by the test target.
//
import Foundation

/// What a key asks of the player.
enum PlayerKeyAction: Equatable {
    case playPause, skipBack, skipForward, toggleMute, toggleFullScreen, exitFullScreen
}

enum PlayerControlRules {
    /// Seconds a skip button or arrow key jumps.
    static let skipSeconds: Double = 10

    /// Where a skip lands: clamped to the playable range. `range` is the
    /// trimmed span when the page has one, else the whole recording.
    static func skipTarget(from now: Double, by delta: Double, duration: Double,
                           range: ClosedRange<Double>? = nil) -> Double {
        let whole = 0...max(0, duration.isFinite ? duration : 0)
        let low = max(whole.lowerBound, range?.lowerBound ?? whole.lowerBound)
        let high = min(whole.upperBound, range?.upperBound ?? whole.upperBound)
        guard low <= high else { return whole.lowerBound }
        let start = now.isFinite ? now : 0
        return min(high, max(low, start + delta))
    }

    // MARK: Volume

    static let volumeKey = "watchPlayerVolume"

    /// A saved level, or full volume when none was saved; always 0...1.
    static func clampedVolume(_ saved: Double?) -> Float {
        guard let saved, saved.isFinite else { return 1 }
        return Float(min(1, max(0, saved)))
    }

    /// The speaker glyph for a level, with the muted one first.
    static func volumeSymbol(volume: Float, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.fill" }
        if volume < 0.67 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    /// Dragging the volume up from zero while muted should be heard.
    static func mutedAfterSetting(volume: Float, muted: Bool) -> Bool {
        volume > 0 ? false : muted
    }

    // MARK: Keys

    /// macOS key codes: space, left, right, M, F, Esc.
    static func action(keyCode: UInt16, hasModifiers: Bool, fullScreen: Bool) -> PlayerKeyAction? {
        guard !hasModifiers else { return nil }
        switch keyCode {
        case 49: return .playPause
        case 123: return .skipBack
        case 124: return .skipForward
        case 46: return .toggleMute
        case 3: return .toggleFullScreen
        case 53: return fullScreen ? .exitFullScreen : nil
        default: return nil
        }
    }

    // MARK: Full-screen auto-hide

    static let hideAfter: TimeInterval = 2.5

    /// Controls and cursor are shown while the mouse moved within `hideAfter`,
    /// or while something holds them up (the volume slider being dragged, the
    /// pointer over the bar, a paused picture).
    static func controlsVisible(now: Date, lastActivity: Date, holding: Bool,
                                hideAfter: TimeInterval = PlayerControlRules.hideAfter) -> Bool {
        holding || now.timeIntervalSince(lastActivity) < hideAfter
    }
}
