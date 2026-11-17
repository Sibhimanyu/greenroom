//
//  StartChoreography.swift
//  Greenroom
//
//  Starting a meeting is one smooth movement (owner, 2026-11-17): Home steps
//  aside toward the Control bar at the click, the bar is the only status
//  surface while the meeting comes up, and it becomes the live bar (or hands
//  over to the Meeting window) when the meeting is live. These are the
//  decisions behind it, with no AppKit, so the test target compiles this file
//  as it is. The coordinator and the bar turn them into windows.
//
import CoreGraphics
import Foundation

enum StartChoreography {

    /// Where a start is. `failed` covers a failure and a cancel: both put Home back.
    enum Phase: Equatable { case idle, starting, live, failed }

    /// Which surface shows in a phase.
    struct Surfaces: Equatable {
        var home: Bool
        /// The Control bar, in its Starting state or its live one.
        var bar: Bool
        /// The notch island's readiness card.
        var island: Bool
    }

    /// One surface says what is happening, never two. Starting: the bar alone.
    /// A failure is the exception: the island keeps the message with Try again
    /// and Close, as it always has, and Home is back.
    static func surfaces(_ phase: Phase) -> Surfaces {
        switch phase {
        case .idle: return Surfaces(home: true, bar: false, island: false)
        case .starting: return Surfaces(home: false, bar: true, island: false)
        case .live: return Surfaces(home: false, bar: true, island: false)
        case .failed: return Surfaces(home: true, bar: false, island: true)
        }
    }

    /// The words in the bar while it starts. Plain, no step names.
    enum BarStage: Equatable { case starting, joining }

    static func barText(_ stage: BarStage) -> String {
        switch stage {
        case .starting: return "Starting\u{2026}"
        case .joining: return "Joining\u{2026}"
        }
    }

    /// Waiting for the screens to be quiet guards opening apps and placing
    /// windows against a changing arrangement. A start that does neither has
    /// nothing to protect, so it does not wait (up to 6 s before).
    static func needsDisplayQuiet(opensApps: Bool, arranges: Bool) -> Bool {
        opensApps || arranges
    }

    /// On live, the Meeting window opens only when somebody else is already in
    /// the meeting. Alone, the bar is the surface and the window comes up when
    /// the first person joins. A layout places the Meeting itself.
    static func opensMeetingWindowOnLive(arranged: Bool, customUI: Bool, othersPresent: Bool) -> Bool {
        !arranged && customUI && othersPresent
    }

    /// The bar outlives the start unless a layout runs on Zoom's own window,
    /// which keeps Zoom's controls.
    static func barKeptAfterLive(arranged: Bool, customUI: Bool) -> Bool {
        !arranged || customUI
    }

    // MARK: Geometry

    /// How long Home takes to step aside, and to come back.
    static let homeSeconds: TimeInterval = 0.25
    /// The bar while it starts: grip, spinner, words, Cancel.
    static let startingBarWidth: CGFloat = 228

    /// Where Home ends up as it hides: smaller, and part of the way to the bar,
    /// so it reads as the bar coming out of the window.
    static func homeExitFrame(home: CGRect, bar: CGRect) -> CGRect {
        let scale: CGFloat = 0.5
        let size = CGSize(width: (home.width * scale).rounded(), height: (home.height * scale).rounded())
        let travel: CGFloat = 0.6
        let centre = CGPoint(x: home.midX + (bar.midX - home.midX) * travel,
                             y: home.midY + (bar.midY - home.midY) * travel)
        return CGRect(x: (centre.x - size.width / 2).rounded(), y: (centre.y - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }
}
