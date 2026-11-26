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
    /// A meeting start in flight: the island offers Cancel.
    var cancellable = false
    /// The failure's button when it is not Try again (e.g. "Open Settings").
    var actionTitle: String? = nil
}

struct NotchProgress: Equatable {
    var steps: [NotchStep]
    var detail: String?
    var cancellable = false

    /// Steps this start actually takes: a skipped one is not counted, so a
    /// class with no apps and no layout reads "1/3", not "2/5" while it is
    /// still on its first real step (owner, 2026-11-15).
    private var counted: [NotchStep] { steps.filter { $0.state != .skipped } }
    var total: Int { counted.count }
    var settled: Int { steps.filter { $0.state == .done || $0.state == .skipped }.count }
    var allSettled: Bool { !steps.isEmpty && settled == steps.count }
    /// 0...1, for the ring: the same step as the counter, so "2/3" fills two
    /// thirds (owner, 2026-11-23: it filled only the finished steps, one third).
    var fraction: Double {
        total == 0 ? 0 : Double(position) / Double(total)
    }
    /// The step being worked on: the active one, else the first not yet settled.
    var currentIndex: Int? {
        steps.firstIndex { $0.state == .active }
            ?? steps.firstIndex { $0.state == .pending }
    }
    /// "3/5": the step in hand out of all of them.
    var counter: String { "\(position)/\(total)" }
    /// The number the counter shows: the step in hand, 1-based.
    var position: Int {
        let n = currentIndex.map { i in steps[..<i].filter { $0.state != .skipped }.count + 1 } ?? total
        return min(n, max(total, 1))
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
    /// The button beside the headline.
    var actionTitle: String = "Try again"

    /// The one line the folded island shows.
    var headline: String { NotchStatusRules.headline(for: message) }
    /// Everything there is to read once it is opened.
    var fullText: String {
        [message, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    /// What the opened island shows under the headline: the whole message,
    /// or only the detail when the headline already is the whole message (it
    /// said the same line twice, 2026-11-16).
    var openedText: String {
        let body = Self.plain(message) == headline ? nil : message
        return [body, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    /// More to read than the headline: the island offers to open.
    var hasMore: Bool { Self.plain(fullText) != headline }

    private static func plain(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

enum NotchPhase: Equatable {
    case hidden
    case working(NotchProgress)
    case live(recording: Bool)
    case failed(NotchFailure)

    var isFailure: Bool { if case .failed = self { return true } else { return false } }
    var isHidden: Bool { self == .hidden }
    /// A working phase that offers Cancel (a meeting start).
    var isCancellable: Bool { if case .working(let p) = self { return p.cancellable } else { return false } }
}

enum NotchStatusRules {
    /// A failure's first line: its first sentence, cut at the first clause
    /// break, so it fits the island beside Try again (owner, 2026-11-16: "how
    /// can i see the full msg?"). The whole message is one click away.
    static func headline(for message: String) -> String {
        var s = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: ". ") { s = String(s[..<r.lowerBound]) }
        for cut in [" (", ", so ", "; ", ": "] {
            if let r = s.range(of: cut) { s = String(s[..<r.lowerBound]) }
        }
        while s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? message : s
    }

    /// The step in words, for the middle of the pill.
    static func words(forStep label: String) -> String {
        switch label {
        // What the person would say is happening, not the step's name: "your
        // picture" meant nothing to anyone (owner, 2026-11-15).
        case "Workspace": return "Opening your apps\u{2026}"
        case "Picture": return "Getting your camera and screen ready\u{2026}"
        case "Creating meeting": return "Creating the meeting on Zoom\u{2026}"
        case "Meeting": return "Connecting to Zoom\u{2026}"
        case "Joining meeting": return "Joining the meeting\u{2026}"
        case "Recording": return "Starting the recording\u{2026}"
        case "Tiling windows": return "Arranging your windows\u{2026}"
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
            return .failed(NotchFailure(message: failure, detail: input.detail,
                                        actionTitle: input.actionTitle ?? "Try again"))
        }
        if !input.steps.isEmpty {
            return .working(NotchProgress(steps: input.steps, detail: input.detail,
                                         cancellable: input.cancellable))
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

// MARK: - Pacing the start

/// Decides what the island DISPLAYS while a start runs, so each step is seen.
/// The real steps can all finish in a tenth of a second; the island opens on
/// "1/N", holds every step `stepHold`, advances one at a time (never skipping,
/// never ahead of the real start), shows "N/N" with a full ring for one hold
/// once the start has finished, and only then shows Live. A failure, a cancel
/// or a hide passes through at once. Pure: time comes in as a parameter.
struct StepPacer {
    /// How long each displayed step stays up (owner, 2026-11-23).
    static let stepHold: TimeInterval = 0.7
    /// The island's own expand animation, which the first step waits out.
    static let openDelay: TimeInterval = 0.35

    var stepHold: TimeInterval = StepPacer.stepHold
    var openDelay: TimeInterval = StepPacer.openDelay

    private(set) var shown: NotchPhase = .hidden
    private var real: NotchPhase = .hidden
    private var template: NotchProgress?
    /// The displayed step, 1-based among the counted ones; 0 when idle.
    private var step = 0
    private var shownAt: TimeInterval = 0

    /// Forget everything: the next start begins again at its first step.
    mutating func reset() {
        shown = .hidden; real = .hidden; template = nil; step = 0
    }

    /// The latest real phase; returns what to display.
    @discardableResult
    mutating func feed(_ phase: NotchPhase, at now: TimeInterval) -> NotchPhase {
        real = phase
        switch phase {
        case .hidden, .failed:
            reset()
            real = phase
            shown = phase
        case .working(let progress):
            template = progress
            if step == 0 {
                step = 1
                shownAt = now + openDelay
            }
            advance(at: now)
            rebuild()
        case .live:
            if step == 0 { shown = phase } else { advance(at: now); rebuild() }
        }
        return shown
    }

    /// A hold may have run out: returns what to display now.
    @discardableResult
    mutating func tick(at now: TimeInterval) -> NotchPhase {
        advance(at: now)
        rebuild()
        return shown
    }

    /// When the display next changes by itself; nil while it waits on reality.
    var nextDeadline: TimeInterval? {
        guard step > 0, canAdvance else { return nil }
        return shownAt + stepHold
    }

    private var total: Int { max(template?.total ?? 1, 1) }

    /// Another step (or Live) is due once the hold is over.
    private var canAdvance: Bool {
        switch real {
        case .working(let p): return step < min(p.position, total)
        case .live: return true
        default: return false
        }
    }

    private mutating func advance(at now: TimeInterval) {
        guard step > 0, canAdvance, now >= shownAt + stepHold else { return }
        if step < total {
            step += 1
            shownAt = now
        } else if case .live(let recording) = real {
            step = 0
            shown = .live(recording: recording)
        }
    }

    /// The displayed working phase: the real steps as they stood at `step`.
    private mutating func rebuild() {
        guard step > 0, let template else { return }
        var counted = 0
        let steps = template.steps.map { s -> NotchStep in
            if s.state == .skipped { return s }
            counted += 1
            var out = s
            out.state = counted < step ? .done : (counted == step ? .active : .pending)
            return out
        }
        shown = .working(NotchProgress(steps: steps, detail: template.detail,
                                       cancellable: template.cancellable))
    }
}

// MARK: - Everything else the island says

/// The recording countdown on the island: a number ticking down, then "go".
enum CountdownPhase: Equatable {
    case tick(Int)
    case go
}

enum IslandToastKind: Equatable {
    /// A quiet word: nothing happened and nothing is wrong (a meeting shortcut outside a meeting).
    case working, success, failure, info

    var symbol: String {
        switch self {
        case .working: return "hourglass"
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
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
    /// An upload offer (amber, leaves this Mac) or a confirmation of something
    /// that ends for other people, like End Meeting for All (red, Zoom's End).
    var style: Style = .upload
    /// The button that answers no; it is also what a timeout counts as.
    var dismissTitle = "Not now"

    enum Style: Equatable { case upload, confirm }
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
    var isFailure: Bool { if case .status(let p) = self { return p.isFailure } else { return false } }

    var isInteractive: Bool {
        switch self {
        case .none: return false
        case .status(let phase): return phase.isFailure || phase.isCancellable
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
    /// An armed End or Stop disarms after this: nothing ends by waiting.
    static let confirmTimeout: TimeInterval = 15
    /// How long "Recording" holds after the countdown reaches go.
    static let goHold: TimeInterval = 1
    /// The island retracts for this long between two queued messages.
    static let retractGap: TimeInterval = 0.45

    /// nil means hold: a failure toast with an action waits for the click.
    static func toastDuration(kind: IslandToastKind, hasAction: Bool) -> TimeInterval? {
        switch kind {
        case .failure: return hasAction ? nil : failureHold
        case .working, .success, .info: return toastHold
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

    /// Takes the floor now, ahead of everything waiting: a question the person
    /// just asked for (End) must not queue behind toasts. Whatever was showing
    /// goes back to the front of the line and shows again afterwards.
    mutating func enqueueFirst(_ message: IslandMessage) {
        if let c = current { waiting.insert(c, at: 0) }
        current = message
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
    /// A failure opened to read in full: its line plus the words below.
    static let failureOpenHeight: CGFloat = 140
    /// The pill's body below the notch line.
    static let bodyHeight: CGFloat = 44
    /// The widest and tallest the island gets (the upload prompt is the
    /// widest, an opened failure the tallest): the panel is this big, so it
    /// never resizes while the island inside morphs.
    static let panelWidth: CGFloat = 540
    static let panelBodyHeight: CGFloat = failureOpenHeight
    /// Room the notch panel keeps either side of and below the island, for the
    /// flared top corners and the soft shadow. Transparent; nothing is drawn
    /// in it while the island is folded.
    static let shadowInset: CGFloat = 24
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
    /// `open` is a failure opened to read in full.
    static func bodySize(for content: IslandContent, open: Bool = false) -> CGSize {
        switch content {
        case .none: return CGSize(width: workingWidth, height: bodyHeight)
        case .status(let phase):
            let opened = open && phase.isFailure
            return CGSize(width: width(for: phase), height: opened ? failureOpenHeight : bodyHeight)
        case .countdown(.go): return goSize
        case .countdown: return countdownSize
        case .prompt: return promptSize
        case .toast(let t):
            return CGSize(width: toastWidth, height: t.hasDetail ? toastTwoLines : toastOneLine)
        }
    }

    static func panelFrame(screenFrame: CGRect, visibleFrame: CGRect, notch: CGRect?) -> CGRect {
        if let notch {
            let height = notch.height + panelBodyHeight + shadowInset
            let width = panelWidth + 2 * shadowInset
            return CGRect(x: notch.midX - width / 2, y: screenFrame.maxY - height,
                          width: width, height: height)
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
