//
//  NotchStatusRules.swift
//
//  The pure parts of the status pill that grows out of the notch: what each
//  start step says, the state machine from readiness to pill, the notch's
//  rectangle, and where the pill sits. No AppKit view code here, so the unit
//  tests compile it alone.
//
import Foundation
import CoreGraphics

enum NotchStepState: Equatable { case pending, active, done, skipped, failed }

struct NotchStep: Equatable {
    var label: String
    var state: NotchStepState
}

/// What the readiness model says right now, in plain values.
struct NotchInput: Equatable {
    var steps: [NotchStep] = []
    var failure: String?
    var detail: String?
}

struct NotchProgress: Equatable {
    var steps: [NotchStep]
    var detail: String?

    var total: Int { steps.count }
    var settled: Int { steps.filter { $0.state == .done || $0.state == .skipped }.count }
    var allSettled: Bool { !steps.isEmpty && settled == total }
    /// 0...1, for the ring.
    var fraction: Double { total == 0 ? 0 : Double(settled) / Double(total) }
    /// The step being worked on: the active one, else the first not yet settled.
    var currentIndex: Int? {
        steps.firstIndex { $0.state == .active }
            ?? steps.firstIndex { $0.state == .pending }
    }
    /// "3/5": the step in hand out of all of them.
    var counter: String {
        let n = currentIndex.map { $0 + 1 } ?? total
        return "\(min(n, max(total, 1)))/\(total)"
    }
    var text: String {
        guard let i = currentIndex else { return "Almost there\u{2026}" }
        return NotchStatusRules.words(forStep: steps[i].label)
    }
    /// The recording step actually ran (not skipped), so "Live" can say so.
    var recordingStarted: Bool {
        steps.contains { $0.label == "Recording" && $0.state == .done }
    }
}

struct NotchFailure: Equatable {
    var message: String
    var detail: String?
}

enum NotchPhase: Equatable {
    case hidden
    case working(NotchProgress)
    case live(recording: Bool)
    case failed(NotchFailure)

    var isFailure: Bool { if case .failed = self { return true } else { return false } }
    var isHidden: Bool { self == .hidden }
}

enum NotchStatusRules {
    /// The step in words, for the middle of the pill.
    static func words(forStep label: String) -> String {
        switch label {
        case "Workspace": return "Preparing your workspace\u{2026}"
        case "Picture": return "Opening your picture\u{2026}"
        case "Meeting": return "Joining the meeting\u{2026}"
        case "Recording": return "Starting the recording\u{2026}"
        case "Tiling windows": return "Tiling windows\u{2026}"
        default: return label + "\u{2026}"
        }
    }

    /// The live line: a red dot only when the tape is rolling.
    static func liveText(recording: Bool) -> String {
        recording ? "Live \u{00B7} Recording" : "Live"
    }

    /// How long "Live" holds before the pill folds back into the notch.
    static let liveHold: TimeInterval = 1.5

    /// The next phase for a new readiness reading. An empty step list means the
    /// start finished or was abandoned; only a start whose every step settled
    /// earns the "Live" beat.
    static func next(from phase: NotchPhase, input: NotchInput) -> NotchPhase {
        if let failure = input.failure {
            return .failed(NotchFailure(message: failure, detail: input.detail))
        }
        if !input.steps.isEmpty {
            return .working(NotchProgress(steps: input.steps, detail: input.detail))
        }
        switch phase {
        case .working(let progress) where progress.allSettled:
            return .live(recording: progress.recordingStarted)
        case .live(let recording):
            return .live(recording: recording)
        default:
            return .hidden
        }
    }
}

/// Where the notch is and where the pill goes. Rectangles are in AppKit screen
/// coordinates (bottom-left origin), like NSScreen's own.
enum NotchGeometry {
    static let workingWidth: CGFloat = 360
    static let failureWidth: CGFloat = 460
    /// The pill's body below the notch line.
    static let bodyHeight: CGFloat = 44
    /// Fallback: gap under the menu bar.
    static let fallbackGap: CGFloat = 6

    /// The notch's rectangle from the screen's frame, its top safe-area inset and
    /// the two areas of the menu bar either side of it. Nil without a notch.
    static func notchRect(screenFrame: CGRect, safeAreaTop: CGFloat,
                          leftArea: CGRect?, rightArea: CGRect?) -> CGRect? {
        guard safeAreaTop > 0, let left = leftArea, let right = rightArea else { return nil }
        let x0 = left.maxX, x1 = right.minX
        guard x1 > x0 else { return nil }
        return CGRect(x: x0, y: screenFrame.maxY - safeAreaTop, width: x1 - x0, height: safeAreaTop)
    }

    static func width(for phase: NotchPhase) -> CGFloat {
        phase.isFailure ? failureWidth : workingWidth
    }

    /// The panel is as wide as the widest pill and as tall as the open one, so
    /// it never resizes while the pill inside morphs.
    static func panelFrame(screenFrame: CGRect, visibleFrame: CGRect, notch: CGRect?) -> CGRect {
        if let notch {
            let height = notch.height + bodyHeight
            return CGRect(x: notch.midX - failureWidth / 2, y: screenFrame.maxY - height,
                          width: failureWidth, height: height)
        }
        let top = visibleFrame.maxY - fallbackGap
        return CGRect(x: visibleFrame.midX - failureWidth / 2, y: top - bodyHeight,
                      width: failureWidth, height: bodyHeight)
    }

    /// The pill's own frame inside that panel for a phase: top-aligned, centred.
    static func pillFrame(panel: CGRect, notch: CGRect?, phase: NotchPhase) -> CGRect {
        let w = width(for: phase)
        let h = (notch?.height ?? 0) + bodyHeight
        return CGRect(x: panel.midX - w / 2, y: panel.maxY - h, width: w, height: h)
    }
}

extension BannerLayout {
    /// Other messages stack below the pill when it shows: the area they use
    /// starts under its bottom edge.
    static func clearing(_ visible: CGRect, pill: CGRect?) -> CGRect {
        guard let pill, pill.minY < visible.maxY else { return visible }
        var out = visible
        out.size.height = max(0, pill.minY - visible.minY)
        return out
    }
}
