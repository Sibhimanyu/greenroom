//
//  NotchStatusRules.swift
//
//  The pure parts of the island that grows out of the notch: what each start
//  step says, the state machine from readiness to pill, what the island shows
//  when several things want it (status, countdown, then a FIFO of upload
//  prompts and toasts), its sizes, the notch's rectangle, and where it sits.
//  No AppKit view code here, so the unit tests compile it alone.
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

// MARK: - Everything else the island says

/// The recording countdown on the island: a number ticking down, then "go".
enum CountdownPhase: Equatable {
    case tick(Int)
    case go
}

enum IslandToastKind: Equatable {
    case working, success, failure

    var symbol: String {
        switch self {
        case .working: return "hourglass"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }
}

struct IslandToast: Equatable {
    var id = UUID()
    var title: String
    var detail: String?
    var kind: IslandToastKind
    /// Seconds on the island; nil holds it until replaced, removed or clicked.
    var duration: TimeInterval?
    /// Clicking runs something, so the island takes clicks and a failure waits for one.
    var hasAction = false

    var hasDetail: Bool { !(detail ?? "").isEmpty }
    /// A toast that waits for its own result to replace it.
    var holds: Bool { duration == nil }
}

struct IslandPrompt: Equatable {
    var id = UUID()
    var title: String
    /// ONE line: "Class \u{00B7} 14 Nov \u{00B7} 982 KB \u{00B7} Unlisted".
    var detail: String
    /// The longer explanation, as hover help.
    var help: String?
    var uploadTitle = "Upload"
    var timeout: TimeInterval = IslandRules.promptTimeout
}

enum IslandMessage: Equatable {
    case toast(IslandToast)
    case prompt(IslandPrompt)

    var id: UUID {
        switch self {
        case .toast(let t): return t.id
        case .prompt(let p): return p.id
        }
    }
}

/// What the island is drawing right now.
enum IslandContent: Equatable {
    case none
    case status(NotchPhase)
    case countdown(CountdownPhase)
    case toast(IslandToast)
    case prompt(IslandPrompt)

    var isNone: Bool { self == .none }
    /// The island takes clicks only when it has something to press.
    var isInteractive: Bool {
        switch self {
        case .none: return false
        case .status(let phase): return phase.isFailure
        case .countdown(let c): return c != .go
        case .toast(let t): return t.hasAction
        case .prompt: return true
        }
    }
    var messageID: UUID? {
        switch self {
        case .toast(let t): return t.id
        case .prompt(let p): return p.id
        default: return nil
        }
    }
}

enum IslandRules {
    /// How long a plain toast stays; a failure stays a little longer.
    static let toastHold: TimeInterval = 2.5
    static let failureHold: TimeInterval = 4
    /// An unanswered upload prompt counts as "Not now" after this.
    static let promptTimeout: TimeInterval = 120
    /// How long "Recording" holds after the countdown reaches go.
    static let goHold: TimeInterval = 1
    /// The island retracts for this long between two queued messages.
    static let retractGap: TimeInterval = 0.45

    /// nil means hold: a failure toast with an action waits for the click.
    static func toastDuration(kind: IslandToastKind, hasAction: Bool) -> TimeInterval? {
        switch kind {
        case .failure: return hasAction ? nil : failureHold
        case .working, .success: return toastHold
        }
    }

    /// 3, 2, 1, go. Empty when the countdown is Off.
    static func countdownSequence(seconds: Int) -> [CountdownPhase] {
        guard seconds > 0 else { return [] }
        return stride(from: seconds, through: 1, by: -1).map { CountdownPhase.tick($0) } + [.go]
    }
}

/// Who gets the island. A failure first, then the countdown, then the start's
/// status; upload prompts and toasts wait in a FIFO and show one at a time.
/// Nothing stacks. A message that was showing when something stronger arrived
/// keeps its place and comes back once that is gone.
struct IslandQueue: Equatable {
    private(set) var status: NotchPhase = .hidden
    private(set) var countdown: CountdownPhase?
    /// The message that has the floor (shown unless something stronger is up).
    private(set) var current: IslandMessage?
    private(set) var waiting: [IslandMessage] = []

    var content: IslandContent {
        if status.isFailure { return .status(status) }
        if let countdown { return .countdown(countdown) }
        if !status.isHidden { return .status(status) }
        switch current {
        case .toast(let t)?: return .toast(t)
        case .prompt(let p)?: return .prompt(p)
        case nil: return .none
        }
    }

    var pendingCount: Int { waiting.count + (current == nil ? 0 : 1) }

    mutating func setStatus(_ phase: NotchPhase) { status = phase }
    mutating func setCountdown(_ phase: CountdownPhase?) { countdown = phase }

    /// Adds a message at the back. A toast replaces a held toast (a "working"
    /// one waiting for its result) that is current or still waiting.
    mutating func enqueue(_ message: IslandMessage) {
        if case .toast = message {
            if case .toast(let old)? = current, old.holds { current = message; return }
            if let i = waiting.firstIndex(where: { if case .toast(let t) = $0 { return t.holds } else { return false } }) {
                waiting[i] = message
                return
            }
        }
        waiting.append(message)
    }

    /// Gives the floor to the next message when nobody holds it.
    mutating func promote() {
        guard current == nil, !waiting.isEmpty else { return }
        current = waiting.removeFirst()
    }

    /// The current message was answered, timed out or clicked.
    @discardableResult
    mutating func finish(_ id: UUID) -> Bool {
        guard current?.id == id else { return false }
        current = nil
        return true
    }

    /// Drops every message the test matches, current or waiting; returns them.
    @discardableResult
    mutating func remove(where match: (IslandMessage) -> Bool) -> [IslandMessage] {
        var gone: [IslandMessage] = []
        if let c = current, match(c) { gone.append(c); current = nil }
        gone += waiting.filter(match)
        waiting.removeAll(where: match)
        return gone
    }
}

/// Where the notch is and where the island goes. Rectangles are in AppKit screen
/// coordinates (bottom-left origin), like NSScreen's own.
enum NotchGeometry {
    static let workingWidth: CGFloat = 360
    static let failureWidth: CGFloat = 460
    /// The pill's body below the notch line.
    static let bodyHeight: CGFloat = 44
    /// The widest and tallest the island gets (the upload prompt): the panel is
    /// this big, so it never resizes while the island inside morphs.
    static let panelWidth: CGFloat = 540
    static let panelBodyHeight: CGFloat = 76
    static let promptSize = CGSize(width: 540, height: 76)
    static let countdownSize = CGSize(width: 320, height: 56)
    static let goSize = CGSize(width: 220, height: 44)
    static let toastWidth: CGFloat = 360
    static let toastOneLine: CGFloat = 44
    static let toastTwoLines: CGFloat = 58
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

    /// The island's body (below the notch line) for what it shows.
    static func bodySize(for content: IslandContent) -> CGSize {
        switch content {
        case .none: return CGSize(width: workingWidth, height: bodyHeight)
        case .status(let phase): return CGSize(width: width(for: phase), height: bodyHeight)
        case .countdown(.go): return goSize
        case .countdown: return countdownSize
        case .prompt: return promptSize
        case .toast(let t):
            return CGSize(width: toastWidth, height: t.hasDetail ? toastTwoLines : toastOneLine)
        }
    }

    static func panelFrame(screenFrame: CGRect, visibleFrame: CGRect, notch: CGRect?) -> CGRect {
        if let notch {
            let height = notch.height + panelBodyHeight
            return CGRect(x: notch.midX - panelWidth / 2, y: screenFrame.maxY - height,
                          width: panelWidth, height: height)
        }
        let top = visibleFrame.maxY - fallbackGap
        return CGRect(x: visibleFrame.midX - panelWidth / 2, y: top - panelBodyHeight,
                      width: panelWidth, height: panelBodyHeight)
    }

    /// The island's own frame inside that panel: top-aligned, centred.
    static func pillFrame(panel: CGRect, notch: CGRect?, content: IslandContent) -> CGRect {
        let body = bodySize(for: content)
        let h = (notch?.height ?? 0) + body.height
        return CGRect(x: panel.midX - body.width / 2, y: panel.maxY - h, width: body.width, height: h)
    }
}
