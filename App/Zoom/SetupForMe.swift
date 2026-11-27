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
    private let answers: SetupAnswers
    private let keys: any ZoomKeyStore
    private let checker: any ZoomChecker
    private var stopRequested = false
    private var pendingCheck = false
    private var checks: [ZoomApp: AppCheck] = [:]
    private var attempts: [String: Int] = [:]

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
    private func runCheck() async {
        let at = evidence.tick
        checks = ZoomSetupFlow.checks(from: await checker.run(), at: at)
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

    func run() async -> SetupForMeEnd {
        for _ in 0..<60 {
            guard let snapshot = await page.read() else { continue }
            evidence = ZoomSetupFlow.absorb(snapshot, into: evidence)
            let step = ZoomSetupFlow.step(for: facts(snapshot))
            onStep(step)
            if stopRequested { return .stopped }
            switch step.cta {
            case .doThisStep(let plan):
                switch await actor.run(plan) {
                case .done(let captured):
                    apply(plan, captured)
                    if pendingCheck { pendingCheck = false; await runCheck() }
                case .stopped(let reason): return .handedOver(step, why: "\(reason)")
                }
            case .goTo(let place, _):
                _ = await page.perform(.navigate(place))
            case .checkAgain:
                await runCheck()
            case .backToGreenroom:
                return .done
            default:
                return .handedOver(step, why: "That one is yours to do.")
            }
        }
        return .handedOver(ZoomSetupFlow.step(for: facts(nil)), why: "Greenroom kept going round in circles.")
    }
}
