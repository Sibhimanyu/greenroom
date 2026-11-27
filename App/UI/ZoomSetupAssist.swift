//
//  ZoomSetupAssist.swift
//  Greenroom
//
//  Joins the Zoom window to the setup flow (docs/specs/zoom-setup-flow.md). It owns ONE `SetupForMe`
//  session: the evidence about the person's two Zoom apps, the stored keys and the check. Every time the
//  window looks again it reads the page into that session, takes the step `ZoomSetupFlow` returns and hands
//  it to the window to show (bar and coach); the person's press on the step's button, or Set up for me, runs
//  the same loop (`advance`), so guided and automatic setup use the same steps, plans and safety. Key values
//  pass through here into the same fields typing uses (so the same Keychain save) and are never logged.
//
import AppKit
import Combine
import SwiftUI

@MainActor
final class ZoomSetupAssist: ObservableObject {
    private weak var coordinator: CoordinatorController?
    private let defaults = UserDefaults.standard
    private static let meetingKey = "zoomSDKAppID"
    private static let hostingKey = "zoomS2SAppID"

    /// What the guide shows (the page, the app IDs, "Keys removed").
    @Published private(set) var state: ZoomGuideAssistState {
        didSet { if state != oldValue { coordinator?.objectWillChange.send() } }
    }
    @Published private(set) var setUpForMe = ZoomSetUpForMeState.idle {
        didSet {
            if setUpForMe != oldValue { coordinator?.objectWillChange.send() }
            #if DEBUG
            if setUpForMe != oldValue { ZoomDomDump.log("state " + String(describing: setUpForMe)) }
            #endif
        }
    }

    private var session: SetupForMe?
    private var answers = SetupAnswers(info: InfoValues(name: NSFullUserName()))
    /// The form's starting values: the Zoom account's own name and email when its profile could be read
    /// (owner, 2026-11-27), else the Mac account's name and no email.
    @Published private(set) var formDefaults = InfoValues(name: NSFullUserName(), company: NSFullUserName())
    private var stepNow: SetupStep?
    private var working = false
    /// Why the last turn handed over (shown on the step's card until the page moves on).
    private var handoverNote: String?
    private var refreshing = false
    private var removedBackup: [ZoomGuidePart: (values: [ZoomKeyField: String], id: String?)] = [:]

    init(coordinator: CoordinatorController) {
        self.coordinator = coordinator
        state = ZoomGuideAssistState(ids: ZoomAppIDs(meeting: defaults.string(forKey: Self.meetingKey),
                                                     hosting: defaults.string(forKey: Self.hostingKey)))
        let window = ZoomMarketplaceWindow.shared
        window.onPage = { [weak self] in self?.pageChanged($0) }
        window.onRefresh = { [weak self] in self?.refresh() }
        window.onAct = { [weak self] in self?.act() }
        window.onStop = { [weak self] in self?.stopSetUpForMe() }
    }

    /// Opens the Zoom window beside the guide, at `url` (Created apps when nil).
    func open(_ url: URL?, part: ZoomGuidePart? = nil) {
        ZoomMarketplaceWindow.shared.show(url: url ?? ZoomMarketplaceGuide.builderURL, guideWindow: OnboardingWindowController.shared.guideWindow)
    }

    static func part(of app: ZoomOwnApp) -> ZoomGuidePart { app == .sdk ? .meetingApp : .hostingApp }

    // MARK: The session

    private func makeSession() -> SetupForMe? {
        if let session { return session }
        guard let coordinator else { return nil }
        let s = SetupForMe(page: ZoomMarketplaceWindow.shared, keys: CoordinatorZoomKeys(assist: self, coordinator: coordinator),
                           checker: CoordinatorZoomChecker(coordinator: coordinator), answers: answers)
        s.onStep = { [weak self] step in self?.stepChanged(step) }
        session = s
        return s
    }

    private func stepChanged(_ step: SetupStep) {
        if step != stepNow { handoverNote = step.number == stepNow?.number ? handoverNote : nil }
        stepNow = step
        showStep()
    }

    private func showStep() {
        var shown = stepNow
        if let note = handoverNote { shown?.status = note }
        ZoomMarketplaceWindow.shared.present(step: shown, signedIn: session?.evidence.signedIn, working: working)
    }

    /// The window looked again: read the page into the flow and show the step. One look at a time.
    private func refresh() {
        guard !refreshing, !working, setUpForMe.isIdleForGuided, let session = makeSession() else { return }
        refreshing = true
        Task { @MainActor in
            await session.refresh()
            refreshing = false
        }
    }

    /// The bar's or the card's button: do what the current step says (the guided "Do this step").
    private func act() {
        guard let step = stepNow, !working, let session = makeSession() else { return }
        switch step.cta {
        case .backToGreenroom:
            ZoomMarketplaceWindow.shared.close()
            coordinator?.openZoomSetupGuide(at: .zoomStep)
        case .checkAgain where step.number != nil:
            // The blocker step: look at the page again (the admin may have changed the permission); nothing is pressed.
            Task { @MainActor in await session.refresh() }
        case .doThisStep, .goTo, .checkAgain:
            working = true; handoverNote = nil; showStep()
            Task { @MainActor in
                let end = await session.advance()
                working = false
                if case .handedOver(_, let why)? = end { handoverNote = why }
                if case .done? = end { act(); return }
                await session.refresh()
                showStep()
            }
        case .press, .fill, .wait:
            break   // the person's to do, on Zoom's page
        }
    }

    // MARK: The page

    private func pageChanged(_ page: ZoomMarketplacePage?) {
        var next = state
        next.page = page
        if let page { next.ids.see(page) }
        state = next
        defaults.set(next.ids.meeting, forKey: Self.meetingKey)
        defaults.set(next.ids.hosting, forKey: Self.hostingKey)
    }

    /// The person cleared a part's keys by hand and the window is not on that app: forget its ID.
    func credentialsChanged() {
        guard let coordinator else { return }
        var next = state
        for app in [ZoomOwnApp.sdk, .s2s] {
            let part = Self.part(of: app)
            if next.removed.contains(part), !fields(app, coordinator).values.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                next.removed.remove(part); removedBackup[part] = nil
            }
            if fields(app, coordinator).values.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }),
               next.ids.id(for: app) != nil, state.page?.appID != next.ids.id(for: app) {
                next.ids.forget(app)
            }
        }
        guard next != state else { return }
        state = next
        defaults.set(next.ids.meeting, forKey: Self.meetingKey)
        defaults.set(next.ids.hosting, forKey: Self.hostingKey)
    }

    // MARK: The keys

    func fields(_ app: ZoomOwnApp, _ c: CoordinatorController) -> [ZoomKeyField: String] {
        switch app {
        case .sdk: return [.clientID: c.sdkClientID, .clientSecret: c.sdkClientSecret]
        case .s2s: return [.accountID: c.s2sAccountID, .clientID: c.s2sClientID, .clientSecret: c.s2sClientSecret]
        }
    }

    func write(_ app: ZoomOwnApp, _ values: [ZoomKeyField: String], _ c: CoordinatorController) {
        for (field, value) in values {
            switch (app, field) {
            case (.sdk, .clientID): c.sdkClientID = value
            case (.sdk, .clientSecret): c.sdkClientSecret = value
            case (.s2s, .accountID): c.s2sAccountID = value
            case (.s2s, .clientID): c.s2sClientID = value
            case (.s2s, .clientSecret): c.s2sClientSecret = value
            default: break
            }
        }
    }

    // MARK: Ways back (R10 to R12)

    /// Start over: forget all five keys (the secrets leave the Keychain through the same save path
    /// typing uses), both app IDs, the last check and what the flow learned; sign the Zoom window out; open the guide.
    func startOver() {
        guard let coordinator else { return }
        coordinator.loadSecretsIfNeeded()
        for app in [ZoomOwnApp.sdk, .s2s] {
            write(app, Dictionary(uniqueKeysWithValues: fields(app, coordinator).keys.map { ($0, "") }), coordinator)
        }
        removedBackup = [:]
        session = nil; stepNow = nil; handoverNote = nil
        var next = state
        next.ids = ZoomAppIDs()
        next.removed = []
        state = next
        defaults.removeObject(forKey: Self.meetingKey)
        defaults.removeObject(forKey: Self.hostingKey)
        coordinator.zoomSetupChecker.credentialsChanged()
        ZoomMarketplaceWindow.shared.signOut()
        coordinator.openZoomSetupGuide(at: .sdkCredentials)
    }

    /// "Use a different app": clears this part's keys and app ID, remembers them for Undo, opens Created apps.
    func useDifferentApp(_ part: ZoomGuidePart) {
        guard let coordinator, let app: ZoomOwnApp = part == .meetingApp ? .sdk : part == .hostingApp ? .s2s : nil else { return }
        coordinator.loadSecretsIfNeeded()
        removedBackup[part] = (fields(app, coordinator), state.ids.id(for: app))
        write(app, Dictionary(uniqueKeysWithValues: fields(app, coordinator).keys.map { ($0, "") }), coordinator)
        // The person is choosing another app: what the flow knew about this one is not the new one's.
        answers.buildNew.remove(app == .sdk ? .meeting : .hosting)
        session?.forget(app == .sdk ? .meeting : .hosting)
        var next = state
        next.ids.forget(app)
        next.removed.insert(part)
        state = next
        defaults.set(next.ids.meeting, forKey: Self.meetingKey)
        defaults.set(next.ids.hosting, forKey: Self.hostingKey)
        open(ZoomMarketplaceGuide.builderURL, part: part)
    }

    /// "Keys removed \u{00B7} Undo".
    func undoRemoved(_ part: ZoomGuidePart) {
        guard let coordinator, let app: ZoomOwnApp = part == .meetingApp ? .sdk : part == .hostingApp ? .s2s : nil,
              let backup = removedBackup[part] else { return }
        write(app, backup.values, coordinator)
        removedBackup[part] = nil
        var next = state
        if let id = backup.id, let page = [ZoomMarketplacePage.s2s(id, .information), .general(id, .information)].first(where: { $0.app == app }) {
            next.ids.see(page)
        }
        next.removed.remove(part)
        state = next
        defaults.set(next.ids.meeting, forKey: Self.meetingKey)
        defaults.set(next.ids.hosting, forKey: Self.hostingKey)
    }

    // MARK: Set up for me (docs/specs/zoom-setup-flow.md)

    /// The main button: open the Zoom window at Created apps, look at what is there, then ask the one small form.
    func beginSetUpForMe() {
        guard setUpForMe == .idle || setUpForMe.isHandedOverOrDone else { return }
        setUpForMe = .preparing
        open(ZoomMarketplaceGuide.builderURL, part: .meetingApp)
        Task { @MainActor in
            async let profile = ZoomProfileReader.read()
            var existing: Set<ZoomApp> = []
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let s = await ZoomMarketplaceWindow.shared.read() else { continue }
                // Signed out: straight to Zoom's sign-in page; the run starts and waits there (owner, 2026-11-27).
                if s.signedIn == false || s.address?.isSignIn == true {
                    if s.address?.isSignIn != true { ZoomMarketplaceWindow.shared.goToSignIn() }
                    break
                }
                guard s.address == .createdApps, s.has(.plus) else { continue }
                existing = Set(s.appList).intersection([.meeting, .hosting])
                break
            }
            let found = await profile
            var info = formDefaults
            if let n = found.name, !n.isEmpty { info.name = n }
            info.company = info.name   // everyone's company is their own name (owner, 2026-11-27)
            if let e = found.email { info.email = e }
            formDefaults = info
            guard setUpForMe == .preparing else { return }
            // Nothing to ask (owner, 2026-11-27): the account's own name (also the company) and email, existing
            // apps used. The run starts straight away.
            _ = existing
            startSetUpForMe(info, buildNew: [])
        }
    }

    func cancelSetUpForMe() { if case .asking = setUpForMe { setUpForMe = .idle } else if setUpForMe == .preparing { setUpForMe = .idle } }

    func startSetUpForMe(_ info: InfoValues, buildNew: Set<ZoomApp>) {
        guard let coordinator, let run = makeSession() else { return }
        coordinator.loadSecretsIfNeeded()
        answers.info = info
        answers.buildNew = buildNew
        run.answers = answers
        handoverNote = nil
        let window = ZoomMarketplaceWindow.shared
        run.onStep = { [weak self] step in
            let line = step.barTitle + "\u{2026}"
            window.setAutopilot(line)
            self?.setUpForMe = .running(line)
            self?.stepChanged(step)
        }
        window.setAutopilot("Setting up\u{2026}")
        setUpForMe = .running("Setting up\u{2026}")
        Task { @MainActor in
            let end = await run.run()
            run.onStep = { [weak self] step in self?.stepChanged(step) }
            window.setAutopilot(nil)
            switch end {
            case .done:
                setUpForMe = .done
                window.close()
                coordinator.openZoomSetupGuide(at: .zoomStep)
            case .stopped:
                setUpForMe = .handedOver("You stopped Set up for me. The guided steps carry on from here.")
            case .handedOver(let step, let why):
                handoverNote = why
                setUpForMe = .handedOver("Greenroom stopped at \(step.barTitle). \(why) The guided steps carry on from here.")
            }
            await run.refresh()
        }
    }

    func stopSetUpForMe() { session?.stop() }
}

extension ZoomSetUpForMeState {
    var isHandedOverOrDone: Bool {
        switch self { case .handedOver, .done: return true; default: return false }
    }
    /// Guided looks run unless Set up for me is mid-run (it looks for itself).
    var isIdleForGuided: Bool {
        switch self { case .running, .preparing: return false; default: return true }
    }
}

/// Where Set up for me and the guided steps keep the keys they copy: the same fields (and Keychain) typing uses.
@MainActor
final class CoordinatorZoomKeys: ZoomKeyStore {
    private unowned let assist: ZoomSetupAssist
    private unowned let coordinator: CoordinatorController
    init(assist: ZoomSetupAssist, coordinator: CoordinatorController) { self.assist = assist; self.coordinator = coordinator }

    private func own(_ app: ZoomApp) -> ZoomOwnApp { app == .meeting ? .sdk : .s2s }

    func keys(for app: ZoomApp) -> [ZoomKeyField: String] {
        coordinator.loadSecretsIfNeeded()
        return assist.fields(own(app), coordinator).filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func save(_ keys: [ZoomKeyField: String], for app: ZoomApp) {
        coordinator.loadSecretsIfNeeded()
        assist.write(own(app), keys, coordinator)
        coordinator.zoomSetupChecker.credentialsChanged()
    }
}

/// Runs the shared Check Zoom setup and waits for its lines.
@MainActor
final class CoordinatorZoomChecker: ZoomChecker {
    private unowned let coordinator: CoordinatorController
    init(coordinator: CoordinatorController) { self.coordinator = coordinator }

    func run() async -> [ZoomCheckLine] {
        let checker = coordinator.zoomSetupChecker
        if !checker.isRunning { coordinator.checkZoomSetup() }
        guard checker.isRunning else { return [] }   // in a meeting: no check
        for _ in 0..<300 {
            if !checker.isRunning { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return checker.isRunning ? [] : checker.lines
    }
}
