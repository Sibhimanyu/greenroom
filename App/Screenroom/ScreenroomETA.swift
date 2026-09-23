//
//  ScreenroomETA.swift
//  Greenroom
//
//  Roughly how much of an analysis is left.
//
//  DESIGN.md asks a wait to say what is happening AND roughly how much is
//  left. The pass already said the first - the step, which of how many, how
//  long it has been going - and nothing about the second, so a teacher looking
//  at "Watching the recording, 2m 10s" could not tell a pass about to finish
//  from one with ten minutes to go.
//
//  Two sources, and only honest ones:
//
//  - A step with a moving bar extrapolates from its own rate. Whisper at 40%
//    after a minute has about a minute and a half to go, whatever any earlier
//    run did.
//  - Everything else is what the same step took last time on this Mac, scaled
//    by the recording's length where the work is per second of video. An agent
//    reports nothing until it answers, so its past is the only clue there is.
//
//  Where neither is known - the first run, or a step already running past
//  what it took before - there is no estimate, and nothing is shown. A guess
//  presented as a number is worse than the elapsed clock on its own.
//
import Foundation

enum ScreenroomStage: Hashable {
    case transcribeWhisper
    case transcribeApple
    case stills
    case watch
    case cohort
    case agent(String)
    case notes

    /// Work done per second of recording, so a forty-minute class is not
    /// promised the minute a five-minute presentation took.
    var scalesWithRecording: Bool {
        switch self {
        case .transcribeWhisper, .transcribeApple, .stills, .watch: return true
        case .cohort, .agent, .notes: return false
        }
    }

    /// Arithmetic over a handful of files. Never worth waiting on, so never
    /// the reason an estimate is missing.
    var isInstant: Bool { self == .cohort }

    fileprivate var key: String {
        switch self {
        case .transcribeWhisper: return "transcribeWhisper"
        case .transcribeApple: return "transcribeApple"
        case .stills: return "stills"
        case .watch: return "watch"
        case .cohort: return "cohort"
        case .agent(let kind): return "agent.\(kind)"
        case .notes: return "notes"
        }
    }
}

/// What each step took before, kept per Mac.
///
/// A moving average rather than the last run alone, so one slow afternoon
/// with a busy agent does not double the next estimate - and rather than a
/// long history, so a faster whisper model shows up within a run or two.
enum ScreenroomTimings {

    static let key = "screenroomStageTimings"
    private static let weight = 0.4

    static func record(_ stage: ScreenroomStage, seconds: TimeInterval,
                       recordingSeconds: TimeInterval,
                       defaults: UserDefaults = .standard) {
        guard seconds > 0, let sample = normalised(stage, seconds, recordingSeconds) else { return }
        var table = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        let previous = table[stage.key]
        table[stage.key] = previous.map { $0 * (1 - weight) + sample * weight } ?? sample
        defaults.set(table, forKey: key)
    }

    static func expected(_ stage: ScreenroomStage, recordingSeconds: TimeInterval,
                         defaults: UserDefaults = .standard) -> TimeInterval? {
        if stage.isInstant { return 0 }
        let table = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        guard let stored = table[stage.key] else { return nil }
        if stage.scalesWithRecording {
            return recordingSeconds > 0 ? stored * recordingSeconds : nil
        }
        return stored
    }

    private static func normalised(_ stage: ScreenroomStage, _ seconds: TimeInterval,
                                   _ recordingSeconds: TimeInterval) -> Double? {
        guard stage.scalesWithRecording else { return seconds }
        return recordingSeconds > 0 ? seconds / recordingSeconds : nil
    }
}

enum ScreenroomETA {

    /// Before this much of a bar has filled, or this long into a step, the
    /// rate is mostly start-up cost - loading a model, opening a file - and
    /// extrapolating from it promises far too long a wait.
    static let minimumProgress = 0.05
    static let minimumStepSeconds: TimeInterval = 3

    struct Estimate: Equatable {
        let seconds: TimeInterval
        /// True when it covers every step left, false when only this one.
        let wholeRun: Bool
    }

    /// Seconds left in the step that is running, or nil when there is no
    /// honest way to say.
    static func currentStep(stage: ScreenroomStage, determinate: Bool,
                            progress: Double, stepElapsed: TimeInterval,
                            expected: TimeInterval?) -> TimeInterval? {
        if determinate, progress >= minimumProgress, stepElapsed >= minimumStepSeconds {
            return stepElapsed * (1 - min(progress, 1)) / progress
        }
        if stage.isInstant { return 0 }
        guard let expected else { return nil }
        let left = expected - stepElapsed
        // Running past what it took last time: the past no longer says
        // anything about this run, so stop pretending it does.
        return left > 0 ? left : nil
    }

    /// The whole run when every step left can be estimated, otherwise just
    /// the running step, otherwise nothing.
    static func estimate(current: TimeInterval?, upcoming: [TimeInterval?]) -> Estimate? {
        guard let current else { return nil }
        let later = upcoming.compactMap { $0 }
        if later.count == upcoming.count {
            return Estimate(seconds: current + later.reduce(0, +), wholeRun: true)
        }
        return Estimate(seconds: current, wholeRun: false)
    }

    /// "About 3 min left". Rounded coarsely on purpose: an estimate that
    /// ticks down a second at a time claims a precision it does not have,
    /// and one that jumps between 2:41 and 2:58 reads as broken.
    static func label(_ estimate: Estimate) -> String {
        let tail = estimate.wholeRun ? "left" : "left on this step"
        if estimate.seconds < 10 { return estimate.wholeRun ? "Almost done" : "Almost done with this step" }
        if estimate.seconds < 50 { return "Under a minute \(tail)" }
        let minutes = max(1, Int((estimate.seconds / 60).rounded()))
        return "About \(minutes) min \(tail)"
    }
}
