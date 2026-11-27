//
//  SetupForMe.swift
//  Greenroom
//
//  "Set up for me" (docs/specs/zoom-setup-flow.md): the one-button loop. It reads the page, asks
//  `ZoomSetupFlow` for the step, and runs that step's call to action: `.doThisStep` through
//  `ZoomActor`, `.goTo` by loading the address, `.wait`/`.checkAgain` by running the check.
//  Anything else (sign-in, a control only the person can press, a stopped plan, a step that keeps
//  failing) ends the run and hands over to the guided step, which names where it stopped and why.
//  One interface: `run()` and `stop()`. Pure: Foundation only.
//
import Foundation

enum SetupForMeEnd: Equatable {
    /// The check passed for both apps: Back to Greenroom.
    case done
    /// The person pressed Stop.
    case stopped
    /// Greenroom could not carry on; the guided step shows `step`.
    case handedOver(SetupStep, why: String)
}

/// Where Greenroom keeps the keys it has copied (Keychain and settings in the app; memory in tests).
/// What the Connect Zoom step shows about Set up for me.
enum ZoomSetUpForMeState: Equatable {
    case idle
    /// The Zoom window is opening and Created apps is being read.
    case preparing
    /// The one small form; `existing` are the app types Created apps already lists.
    case asking(existing: Set<ZoomApp>)
    case running(String)
    /// Greenroom stopped (or the person did); the guided steps carry on from there.
    case handedOver(String)
    case done
}

@MainActor
protocol ZoomKeyStore: AnyObject {
    func keys(for app: ZoomApp) -> [ZoomKeyField: String]
    func save(_ keys: [ZoomKeyField: String], for app: ZoomApp)
}

/// Runs Check Zoom setup and returns its lines.
@MainActor
protocol ZoomChecker: AnyObject {
    func run() async -> [ZoomCheckLine]
}

@MainActor
final class SetupForMe {
    private let page: any ZoomPage
    private var actor: ZoomActor
    private let pacing: ZoomPacing
    private(set) var evidence = Evidence()
    var answers: SetupAnswers
    private let keys: any ZoomKeyStore
    private let checker: any ZoomChecker
    private var stopRequested = false
    private var pendingCheck = false
    private var nilReads = 0
    private var checks: [ZoomApp: AppCheck] = [:]
    private var attempts: [Int: Int] = [:]

    /// Told each time the flow picks a step (the bar shows "Step n of 8 · title…").
    var onStep: (SetupStep) -> Void = { _ in }

    init(page: any ZoomPage, keys: any ZoomKeyStore, checker: any ZoomChecker, answers: SetupAnswers, pacing: ZoomPacing = .live) {
        self.page = page
        self.keys = keys
        self.checker = checker
        self.actor = ZoomActor(page: page, pacing: pacing)
        self.pacing = pacing
        self.answers = answers
        self.actor.observer = { [weak self] s in if let self { self.evidence = ZoomSetupFlow.absorb(s, into: self.evidence) } }
    }

    func stop() { stopRequested = true }

    /// Check Zoom setup runs by itself after an app's keys are copied (and when the table asks for it).
    private func runCheck() async -> Bool {
        pendingCheck = false
        let at = evidence.tick
        let lines = await checker.run()
        checks = ZoomSetupFlow.checks(from: lines, at: at)
        return !lines.isEmpty
    }

    private func facts(_ snapshot: ZoomPageSnapshot?) -> SetupFacts {
        SetupFacts(evidence: evidence, stored: [.meeting: keys.keys(for: .meeting), .hosting: keys.keys(for: .hosting)],
                   checks: checks, snapshot: snapshot, answers: answers)
    }

    /// What a finished plan means: settings changed (keys copied before are stale), or keys copied (stored now).
    private func apply(_ plan: ActionPlan, _ captured: [ZoomKeyField: String]) {
        guard let app = plan.app else { return }
        switch plan.effect {
        case .changesSettings: evidence.settingsChanged(app)
        case .copiesKeys:
            keys.save(captured, for: app)
            evidence.keysCopied(app, clientID: captured[.clientID])
            pendingCheck = true
        case .createsApp, .nothing: break
        }
    }

    /// Reads the page, folds it into the evidence and tells `onStep` where setup stands. Does nothing on the page.
    @discardableResult
    func refresh() async -> SetupStep? {
        guard let snapshot = await settledRead() else { return nil }
        nilReads = 0
        evidence = ZoomSetupFlow.absorb(snapshot, into: evidence)
        let step = ZoomSetupFlow.step(for: facts(snapshot))
        onStep(step)
        return step
    }

    /// A reading to decide from (live run, 2026-11-27): Zoom fills a page in over a second or two, and an
    /// unfinished page looks like an empty one (no apps, no fields). Settled = the same reading twice in a row
    /// with something on it. Sign-in pages are taken as they are. Nil: it never settled.
    /// Created apps shows + about a second before its list (live run 3): an EMPTY list must hold still for
    /// longer (about 3s live) before Greenroom believes there are no apps.
    private func settledRead() async -> ZoomPageSnapshot? {
        var last: ZoomPageSnapshot?, same = 0
        let live = pacing.pause > 0
        let emptyListNeeds = live ? 12 : 6            // about 3s live
        // Information keeps its fields disabled for up to a minute after opening, then unlocks by itself
        // (live run 3). Only fields still disabled after about 90s live are the account's own limit.
        let lockedInfoNeeds = live ? 360 : 20         // about 90s live
        for _ in 0..<(lockedInfoNeeds + 12) {
            guard let s = await page.read() else { return nil }
            if s.isSignedOut { return s }
            same = (s == last) ? same + 1 : 0
            let locked: Bool = {
                if case .s2s(_, .information)? = s.address { return s.infoFields.values.contains(.disabled) }
                return false
            }()
            let needs = locked ? lockedInfoNeeds : (s.address == .createdApps && s.appList.isEmpty) ? emptyListNeeds : 1
            if !s.controls.isEmpty, s.isReady, same >= needs { return s }
            last = s
            if pacing.pause > 0 { try? await Task.sleep(nanoseconds: pacing.pause) } else { await Task.yield() }
        }
        return nil
    }

    /// The whole one-button loop.
    func run() async -> SetupForMeEnd {
        stopRequested = false
        attempts = [:]
        for _ in 0..<60 {
            if let end = await advance() { return end }
        }
        return .handedOver(ZoomSetupFlow.step(for: facts(nil)), why: "Greenroom kept going round in circles.")
    }

    /// One turn: look, pick the step, do what it says if Greenroom may (nil: carry on). The guided "Do this step"
    /// is one turn of this same loop, so both paths use the same steps, plans and safety.
    func advance() async -> SetupForMeEnd? {
        guard let step = await refresh() else {
            nilReads += 1
            if nilReads > 40 { return .handedOver(ZoomSetupFlow.step(for: facts(nil)), why: "Greenroom could not read Zoom\u{2019}s page.") }
            try? await Task.sleep(nanoseconds: pacing.pause)
            return nil
        }
        if stopRequested { return .stopped }
        switch step.cta {
        case .doThisStep(let plan):
            // Greenroom did this step and Zoom (the check) still says it is not right: stop, don't go round again.
            attempts[step.number ?? 0, default: 0] += 1
            if attempts[step.number ?? 0, default: 0] > 3 {
                return .handedOver(step, why: "Greenroom did this step, but Zoom still says it isn\u{2019}t right.")
            }
            switch await actor.run(plan) {
            case .done(let captured):
                apply(plan, captured)
                if pendingCheck, !(await runCheck()) { return .handedOver(step, why: "Greenroom could not run the check.") }
            case .stopped(let reason): return .handedOver(step, why: reason.words)
            }
        case .goTo(let place, _):
            _ = await page.perform(.navigate(place))
        case .press(.appRow(let row), _):
            // Using an app that is already there: the plan is one press and a wait to land on its page.
            guard let app = step.app else { return .handedOver(step, why: "That one is yours to do.") }
            let plan = ActionPlan(app: app, effect: .nothing, steps: [.press(.appRow(row)), .waitFor(.onApp(app))])
            if case .stopped(let reason) = await actor.run(plan) { return .handedOver(step, why: reason.words) }
        case .checkAgain where step.number == nil:
            if !(await runCheck()) { return .handedOver(step, why: "Greenroom could not run the check.") }
        case .backToGreenroom:
            return .done
        default:
            return .handedOver(step, why: "That one is yours to do.")
        }
        return nil
    }

    /// Forget what was learned about one app (the person chose a different one, or started over).
    func forget(_ app: ZoomApp) {
        evidence.apps[app] = AppEvidence()
        checks[app] = nil
        attempts = [:]
    }
}
