//
//  MeetingMeters.swift
//  Greenroom
//
//  The start-sequence readiness pill and the microphone level meter.
//
import AppKit
import SwiftUI
import Combine

/// The start sequence, carried by the notch island (NotchStatusController).
///
/// Named steps rather than a spinner: a start stuck on one step looks different
/// from a start that is about to finish. The island grows out of the notch, sits
/// above the tiling so nothing hides it, and folds away the moment there is
/// nothing left to say.
enum ReadinessHUDController {

    /// `screen` is unused: the pill goes on the screen the person is working on
    /// (NotchStatusController.swift).
    static func show(_ readiness: ParticipantGridWindowController.Readiness,
                     on screen: NSScreen, cancellable: Bool = false,
                     onCancel: (() -> Void)? = nil) {
        let input = NotchInput(
            steps: readiness.steps.map { NotchStep(label: $0.label, state: NotchStepState($0.state)) },
            failure: readiness.failure,
            detail: readiness.detail,
            cancellable: cancellable && readiness.failure == nil,
            liveConfirmed: readiness.liveConfirmed,
            actionTitle: readiness.failureActionTitle)
        // An empty reading is the end of the start: the island says Live and folds.
        let carrying = !readiness.steps.isEmpty || readiness.failure != nil
        if carrying, !isShowing { shownAt = Date() }
        isShowing = carrying
        MainActor.assumeIsolated {
            NotchStatusController.shared.update(
                input,
                onAction: { ParticipantGridWindowController.readinessTryAgain?() },
                onDismiss: { ParticipantGridWindowController.readinessDismiss?() },
                onCancel: onCancel)
        }
    }

    static func close() {
        isShowing = false
        MainActor.assumeIsolated { NotchStatusController.shared.clear() }
    }

    /// The island is carrying a start right now.
    private(set) static var isShowing = false
    /// When it first came up, for `letItOpen`.
    private static var shownAt: Date?

    /// Waits until the island has finished growing (its spring settles in about
    /// 0.35s), so the start's heavy main-thread work does not stall the grow.
    /// Returns at once when the island is not carrying the start.
    @MainActor static func letItOpen() async {
        guard isShowing, let shownAt else { return }
        let left = 0.35 - Date().timeIntervalSince(shownAt)
        guard left > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
    }
}

extension NotchStepState {
    init(_ state: ParticipantGridWindowController.Readiness.State) {
        switch state {
        case .pending: self = .pending
        case .active: self = .active
        case .done: self = .done
        case .skipped: self = .skipped
        case .failed: self = .failed
        }
    }
}

/// A segmented level bar, the shape of a hardware meter: discrete segments read
/// as "loud enough" at a glance. System greens, amber near the top.
final class LevelMeterView: NSView {

    var level: Double = 0 { didSet { if abs(level - oldValue) > 0.01 { needsDisplay = true } } }
    /// Drawn hollow when the mic is muted in Zoom, so a moving meter never
    /// implies the class can hear you.
    var muted = false { didSet { needsDisplay = true } }

    /// Follows the width, so a segment is always about 10pt and the meter reads
    /// the same whatever it is given. Fixed at 20 it was fine at toolbar widths
    /// and wrong in the rail, where twenty cells stretched across the column
    /// turned a level into a progress track.
    private var segments: Int { max(6, min(20, Int(bounds.width / 12))) }

    override func draw(_ dirtyRect: NSRect) {
        let segments = self.segments
        let gap: CGFloat = 2
        let unit = (bounds.width - CGFloat(segments - 1) * gap) / CGFloat(segments)
        let lit = Int((Double(segments) * level).rounded())

        for index in 0..<segments {
            let rect = NSRect(x: CGFloat(index) * (unit + gap), y: 0, width: unit, height: bounds.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            let hot = index >= segments - 3
            if index < lit && !muted {
                (hot ? NSColor.systemOrange : NSColor.systemGreen).setFill()
                path.fill()
            } else if index < lit && muted {
                // Muted: outline only. The level is still real, but it is going
                // nowhere, and the drawing should say so.
                (hot ? NSColor.systemOrange : NSColor.systemGreen).withAlphaComponent(0.5).setStroke()
                path.lineWidth = 1
                path.stroke()
            } else {
                NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
                path.fill()
            }
        }
    }
}
