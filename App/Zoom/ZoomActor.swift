//
//  ZoomActor.swift
//  Greenroom
//
//  Runs one `ActionPlan` against a `ZoomPage` (docs/specs/zoom-setup-flow.md, "ZoomActor").
//  One interface: `run(plan)`. The allow-list is the plan's own ZoomControl IDs, and only the ones
//  the actor may touch at all (never sign-in, never a control the person owns). The deny-list is
//  checked by the page on the element's text at the moment of the press and always wins. After
//  every step it reads again; a wait that does not come true, a control that is missing, a denied
//  press or a sign-out stops the run and says why. Key values it captures are returned in memory
//  only. Pure: Foundation only.
//
import Foundation

struct ZoomActor {
    enum Reason: Error, Equatable {
        /// The plan names a control the actor may never press or type into.
        case refused(ZoomControl)
        case notFound(ZoomControl)
        case denied(ZoomControl)
        case timedOut(ZoomCondition)
        case signedOut
        /// A key could not be read or copied.
        case noKey(ZoomKeyField)
    }

    enum Outcome: Equatable {
        case done(captured: [ZoomKeyField: String])
        case stopped(Reason)
    }

    let page: any ZoomPage
    var pacing: ZoomPacing = .live
    /// Told every page reading the actor takes, so evidence also grows from pages the plan only passes through.
    var observer: @MainActor (ZoomPageSnapshot) -> Void = { _ in }

    /// What a plan may press, by ID. Sign-in, "try another way" and closing someone else's window are the person's.
    static func mayPress(_ c: ZoomControl) -> Bool {
        switch c {
        case .plus, .buildApp, .typeRadio, .create, .addScopes, .scopesDone, .activate, .continue, .copy, .appRow, .meetingSDKSwitch: return true
        case .scopeCheckbox(let name): return ZoomScopes.names.contains(name)
        default: return false
        }
    }

    static func mayType(_ c: ZoomControl) -> Bool {
        switch c {
        case .nameField, .scopeSearch, .infoField: return true
        default: return false
        }
    }

    @MainActor
    func run(_ plan: ActionPlan) async -> Outcome {
        for step in plan.steps {
            switch step {
            case .press(let c, _), .pressDeep(let c):
                if !Self.mayPress(c) { return .stopped(.refused(c)) }
            case .hover: break
            case .type(let c, _):
                if !Self.mayType(c) { return .stopped(.refused(c)) }
            case .waitFor, .capture: break
            }
        }
        var captured: [ZoomKeyField: String] = [:]
        for step in plan.steps {
            switch step {
            case .press(let c, let unless):
                if let unless {
                    switch await judge(unless) {
                    case .holds: continue
                    case .doesNot: break
                    case .signedOut: return .stopped(.signedOut)
                    case .unknown: return .stopped(.timedOut(unless))
                    }
                }
                if let stop = await act(.press(c), c) { return .stopped(stop) }
            case .pressDeep(let c):
                if let stop = await act(.pressDeep(c), c) { return .stopped(stop) }
            case .hover(let c):
                _ = await page.perform(.hover(c))
            case .type(let c, let text):
                if let stop = await act(.type(c, text), c) { return .stopped(stop) }
            case .waitFor(let condition):
                if let stop = await wait(condition) { return .stopped(stop) }
            case .capture(let field):
                switch await capture(field, already: Set(captured.values)) {
                case .success(let value): captured[field] = value
                case .failure(let reason): return .stopped(reason)
                }
            }
        }
        return .done(captured: captured)
    }

    @MainActor
    private func act(_ action: ZoomPageAction, _ control: ZoomControl) async -> Reason? {
        // A control may need a moment to appear (a menu, a dialog): look a few times before giving up.
        for poll in 0..<max(1, pacing.polls) {
            switch await page.perform(action) {
            case .done: return nil
            case .denied: return .denied(control)
            case .notFound:
                if let s = await page.read(), s.isSignedOut { return .signedOut }
                if poll < pacing.polls - 1 { await pause() }
            }
        }
        return .notFound(control)
    }

    private enum Judgement { case holds, doesNot, signedOut, unknown }
    /// Waits until the page shows whether `condition` holds (a sign-out ends the wait at once).
    @MainActor
    private func judge(_ condition: ZoomCondition) async -> Judgement {
        for poll in 0..<max(1, pacing.polls) {
            if let s = await page.read() {
                observer(s)
                if s.isSignedOut { return .signedOut }
                if condition.isKnown(in: s) { return condition.holds(in: s) ? .holds : .doesNot }
            }
            if poll < pacing.polls - 1 { await pause() }
        }
        return .unknown
    }

    @MainActor
    private func wait(_ condition: ZoomCondition) async -> Reason? {
        for poll in 0..<max(1, pacing.polls) {
            if let s = await page.read() {
                observer(s)
                if s.isSignedOut { return .signedOut }
                if condition.holds(in: s) { return nil }
            }
            if poll < pacing.polls - 1 { await pause() }
        }
        return .timedOut(condition)
    }

    /// A readable key is taken as it is; a hidden one is copied with Zoom's own Copy control and taken from the copy hook.
    @MainActor
    private func capture(_ field: ZoomKeyField, already: Set<String>) async -> Result<String, Reason> {
        // The page may still be loading: look until the key is readable or its Copy control is there.
        var copyable = false
        for poll in 0..<max(1, pacing.polls) {
            if let s = await page.read() {
                observer(s)
                if let v = s.keys[field]?.text, ZoomMarketplacePages.isKey(v) { return .success(v) }
                if s.has(.copy(field)) { copyable = true; break }
            }
            if poll < pacing.polls - 1 { await pause() }
        }
        guard copyable else { return .failure(.noKey(field)) }
        _ = page.takeCopiedKey()
        _ = await page.perform(.hover(.keyRow(field)))
        if let stop = await act(.pressDeep(.copy(field)), .copy(field)) { return .failure(stop) }
        for poll in 0..<max(1, pacing.polls) {
            if let k = page.takeCopiedKey(), ZoomMarketplacePages.isKey(k), !already.contains(k) { return .success(k) }
            if poll < pacing.polls - 1 { await pause() }
        }
        return .failure(.noKey(field))
    }

    private func pause() async {
        if pacing.pause > 0 { try? await Task.sleep(nanoseconds: pacing.pause) } else { await Task.yield() }
    }
}

extension ZoomActor.Reason {
    /// Why a run stopped, in plain words for the card.
    var words: String {
        switch self {
        case .refused: return "Greenroom isn\u{2019}t allowed to do that part by itself."
        case .notFound(let c): return "Greenroom couldn\u{2019}t find \(c.words) on Zoom\u{2019}s page."
        case .denied: return "Zoom\u{2019}s button looked risky, so Greenroom left it alone."
        case .timedOut: return "Zoom didn\u{2019}t answer the way Greenroom expected."
        case .signedOut: return "You\u{2019}re signed out of Zoom."
        case .noKey(let f): return "Greenroom couldn\u{2019}t copy the \(f.label)."
        }
    }
}

extension ZoomControl {
    /// A short plain name for a control, for sentences.
    var words: String {
        switch self {
        case .plus: return "the + button"
        case .buildApp: return "Build app"
        case .typeRadio(let k): return k == .hosting ? "the Server-to-Server choice" : "the General app choice"
        case .create: return "Create"
        case .nameField: return "the name field"
        case .addScopes, .scopesDone, .scopeSearch, .scopeCheckbox: return "the scopes window"
        case .activate: return "Activate"
        case .continue: return "Continue"
        case .copy(let f): return "the Copy button for the \(f.label)"
        case .meetingSDKSwitch: return "the Meeting SDK switch"
        case .infoField(let f): return "the \(f.label) field"
        case .appRow: return "the app in the list"
        default: return "a button"
        }
    }
}
