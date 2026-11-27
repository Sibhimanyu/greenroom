//
//  ZoomSetupAssist.swift
//  Greenroom
//
//  Joins the Zoom window to the setup guide (docs/specs/zoom-setup-assist.md,
//  R3 to R5, R7): remembers each kind's app ID, fills the guide's key fields
//  from the window's credential pages (or offers to, when something else is
//  typed), and starts Check Zoom setup once when both parts become complete.
//  The decisions are pure (`ZoomKeyFillRules`, `ZoomGuideFollowRules`); this
//  only applies them. Key values pass through here into the same fields typing
//  uses (so the same Keychain save) and are never logged or kept elsewhere
//  than the pending offer, in memory, until it is used or the page changes.
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

    /// What the guide shows (the page, the IDs, the notices).
    @Published private(set) var state: ZoomGuideAssistState {
        didSet { if state != oldValue { coordinator?.objectWillChange.send(); ZoomMarketplaceWindow.shared.updateBar() } }
    }
    private var offerValues: [ZoomGuidePart: [ZoomKeyField: String]] = [:]
    private var filledFields: [ZoomGuidePart: [ZoomKeyField]] = [:]
    /// Parts the person undid on this visit to the page: not filled again until the page changes.
    private var undone: Set<ZoomGuidePart> = []
    private var checkWatch: [AnyCancellable] = []
    private var lastRecheck = Date.distantPast
    /// What "Use a different app" took away, until Undo or the next change (in memory only).
    private var removedBackup: [ZoomGuidePart: (values: [ZoomKeyField: String], id: String?)] = [:]

    // MARK: Set up for me

    @Published private(set) var setUpForMe = ZoomSetUpForMeState.idle {
        didSet { if setUpForMe != oldValue { coordinator?.objectWillChange.send() } }
    }
    private var runner: SetupForMe?

    init(coordinator: CoordinatorController) {
        self.coordinator = coordinator
        state = ZoomGuideAssistState(ids: ZoomAppIDs(meeting: defaults.string(forKey: Self.meetingKey),
                                                     hosting: defaults.string(forKey: Self.hostingKey)))
        let window = ZoomMarketplaceWindow.shared
        window.onPage = { [weak self] in self?.pageChanged($0) }
        window.onKeys = { [weak self] page, found in self?.keysFound(page, found) }
        window.barState = { [weak self] in
            guard let self, let c = self.coordinator else { return (false, false, ZoomAppIDs(), [], false) }
            return (self.isComplete(.sdk, c), self.isComplete(.s2s, c), self.state.ids,
                    c.zoomSetupChecker.lines, c.zoomSetupChecker.isRunning)
        }
        window.onStepDone = { [weak self] in self?.recheck() }
        // The check is the judge: whenever its lines change, the bar and the coach look again.
        checkWatch = [coordinator.zoomSetupChecker.$lines.sink { _ in
            DispatchQueue.main.async { ZoomMarketplaceWindow.shared.updateBar(); ZoomMarketplaceWindow.shared.refresh() }
        }, coordinator.zoomSetupChecker.$isRunning.sink { _ in
            DispatchQueue.main.async { ZoomMarketplaceWindow.shared.updateBar() }
        }]
        window.onBackToGreenroom = { [weak self] in self?.backToGreenroom() }
        window.onStop = { [weak self] in self?.stopSetUpForMe() }
        window.missingKeys = { [weak self] page in self?.missingKeys(on: page) }
        window.onCopied = { [weak self] page, text in self?.copied(on: page, text: text) }
        window.needsApp = { [weak self] part in self?.needsApp(part) ?? false }
        window.keysFilled = { [weak self] in
            guard let self, let page = self.state.page, let app = page.app else { return false }
            return self.state.filled.contains(Self.part(of: app))
        }
    }

    /// Opens the Zoom window beside the guide, at `url`, for the guide part being worked on.
    func open(_ url: URL?, part: ZoomGuidePart?) {
        ZoomMarketplaceWindow.shared.show(url: url, part: part, guideWindow: OnboardingWindowController.shared.guideWindow)
    }

    static func part(of app: ZoomOwnApp) -> ZoomGuidePart { app == .sdk ? .meetingApp : .hostingApp }
    private static func app(of part: ZoomGuidePart) -> ZoomOwnApp? {
        switch part { case .meetingApp: return .sdk; case .hostingApp: return .s2s; case .check: return nil }
    }

    // MARK: The page

    private func pageChanged(_ page: ZoomMarketplacePage?) {
        var next = state
        let moved = next.page != page
        next.page = page
        if let page { next.ids.see(page) }
        if moved {
            undone = []
            // An offer belongs to the page that made it.
            if let part = page?.app.map(Self.part(of:)) {
                next.offers = next.offers.filter { $0 == part }
            } else {
                next.offers = []
            }
            if next.offers.isEmpty { offerValues = [:] }
            next.filled = next.filled.filter { part in page?.app.map(Self.part(of:)) == part }
        }
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
                next.filled.remove(part); next.offers.remove(part)
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

    /// R18: when a part's keys become complete, the check runs for it by itself (not in a session, not twice).
    private func checkIfPartCompleted(_ app: ZoomOwnApp, before: Bool) {
        guard let coordinator else { return }
        if ZoomRunRules.shouldCheckAfterKeys(completeBefore: before, completeAfter: isComplete(app, coordinator),
                                             inSession: coordinator.phase.isInMeeting, running: coordinator.zoomSetupChecker.isRunning) {
            coordinator.checkZoomSetup()
        }
    }

    /// After a completed step (or leaving a fixed place): check again while something fails, at most every 4s.
    func recheck() {
        guard let coordinator, Date().timeIntervalSince(lastRecheck) > 4 else { return }
        let lines = coordinator.zoomSetupChecker.lines
        let hasFix = [ZoomOwnApp.sdk, .s2s].contains { ZoomRunRules.fix($0, lines: lines, keysComplete: isComplete($0, coordinator)) != nil }
        if ZoomRunRules.shouldRecheck(hasFix: hasFix, running: coordinator.zoomSetupChecker.isRunning, inSession: coordinator.phase.isInMeeting) {
            lastRecheck = Date()
            coordinator.checkZoomSetup()
        }
    }

    private func isComplete(_ app: ZoomOwnApp, _ c: CoordinatorController) -> Bool {
        fields(app, c).values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The bar's "Back to Greenroom": the guide comes forward and the check starts once.
    private func backToGreenroom() {
        guard let coordinator else { return }
        coordinator.openZoomSetupGuide(at: .zoomStep)
        if ZoomBarRules.shouldCheckOnReturn(checkRunning: coordinator.zoomSetupChecker.isRunning,
                                            hasResults: !coordinator.zoomSetupChecker.lines.isEmpty,
                                            inSession: coordinator.phase.isInMeeting) {
            coordinator.checkZoomSetup()
        }
    }

    private var bothFilled: Bool {
        guard let c = coordinator else { return false }
        return [fields(.sdk, c), fields(.s2s, c)].allSatisfy { $0.values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    private func keysFound(_ page: ZoomMarketplacePage, _ found: [ZoomKeyField: String]) {
        guard let coordinator, let app = page.app, state.page == page else { return }
        let part = Self.part(of: app)
        guard !undone.contains(part) else { return }
        apply(app, found)
    }

    /// A key copied with Zoom's own copy button (R17): the clipboard text becomes the field the coach points at.
    /// Never logged and never kept: it goes straight into the same fill/offer path as a page read.
    func copied(on page: ZoomMarketplacePage, text: String) {
        guard let coordinator, let app = page.app, let wanted = ZoomMarketplacePages.keyFields(on: page) else { return }
        let part = Self.part(of: app)
        guard !undone.contains(part) else { return }
        coordinator.loadSecretsIfNeeded()
        let have = fields(app, coordinator).filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let missing = wanted.filter { have[$0] == nil }
        guard let field = ZoomClipboardRules.assign(copied: text, found: have, missing: missing, pointedAt: missing.first),
              let key = ZoomClipboardRules.clean(text) else { return }
        apply(app, [field: key])
    }

    /// The page's key fields Greenroom does not have yet, in the page's order (nil off the credentials pages).
    func missingKeys(on page: ZoomMarketplacePage) -> [ZoomKeyField]? {
        guard let coordinator, let app = page.app, let wanted = ZoomMarketplacePages.keyFields(on: page) else { return nil }
        coordinator.loadSecretsIfNeeded()
        let have = fields(app, coordinator)
        return wanted.filter { (have[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func apply(_ app: ZoomOwnApp, _ found: [ZoomKeyField: String]) {
        guard let coordinator else { return }
        let part = Self.part(of: app)
        // A secret not loaded yet would look empty, and be overwritten.
        coordinator.loadSecretsIfNeeded()
        let partBefore = isComplete(app, coordinator)
        var next = state
        switch ZoomKeyFillRules.decide(current: fields(app, coordinator), found: found) {
        case .nothing:
            return
        case .fill(let values):
            write(app, values, coordinator)
            filledFields[part] = Array(Set((filledFields[part] ?? []) + values.keys))
            next.filled.insert(part); next.offers.remove(part); offerValues[part] = nil
        case .offer(let values):
            offerValues[part] = values
            next.offers.insert(part)
        }
        state = next
        // The coach says "Got it" now.
        ZoomMarketplaceWindow.shared.refresh()
        checkIfPartCompleted(app, before: partBefore)
    }

    /// "Use the keys from this page".
    func useOffer(_ part: ZoomGuidePart) {
        guard let coordinator, let app = Self.app(of: part), let values = offerValues[part] else { return }
        let partBefore = isComplete(app, coordinator)
        write(app, values, coordinator)
        filledFields[part] = Array(values.keys)
        offerValues[part] = nil
        var next = state
        next.offers.remove(part); next.filled.insert(part)
        state = next
        ZoomMarketplaceWindow.shared.refresh()
        checkIfPartCompleted(app, before: partBefore)
    }

    /// "Undo" on "Filled in from Zoom": empties what the window filled.
    func undoFill(_ part: ZoomGuidePart) {
        guard let coordinator, let app = Self.app(of: part), let fields = filledFields[part] else { return }
        write(app, Dictionary(uniqueKeysWithValues: fields.map { ($0, "") }), coordinator)
        filledFields[part] = nil
        undone.insert(part)
        var next = state
        next.filled.remove(part)
        state = next
        ZoomMarketplaceWindow.shared.refresh()
    }

    // MARK: Ways back (R10 to R12)

    /// The part's keys are filled in (any of them) but the window has not seen its app yet.
    func needsApp(_ part: ZoomGuidePart) -> Bool {
        guard let coordinator, let app = Self.app(of: part), state.ids.id(for: app) == nil else { return false }
        return fields(app, coordinator).values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Start over: forget all five keys (the secrets leave the Keychain through the same save path
    /// typing uses), both app IDs, the last check and the notices; sign the Zoom window out; open part 1.
    func startOver() {
        guard let coordinator else { return }
        coordinator.loadSecretsIfNeeded()
        for app in [ZoomOwnApp.sdk, .s2s] {
            write(app, Dictionary(uniqueKeysWithValues: fields(app, coordinator).keys.map { ($0, "") }), coordinator)
        }
        offerValues = [:]; filledFields = [:]; removedBackup = [:]; undone = []
        var next = state
        next.ids = ZoomAppIDs()
        next.filled = []; next.offers = []; next.removed = []
        state = next
        defaults.removeObject(forKey: Self.meetingKey)
        defaults.removeObject(forKey: Self.hostingKey)
        coordinator.zoomSetupChecker.credentialsChanged()
        ZoomMarketplaceWindow.shared.signOut()
        coordinator.openZoomSetupGuide(at: .sdkCredentials)
    }

    /// "Use a different app": clears this part's keys and app ID, remembers them for Undo, opens Created apps.
    func useDifferentApp(_ part: ZoomGuidePart) {
        guard let coordinator, let app = Self.app(of: part) else { return }
        coordinator.loadSecretsIfNeeded()
        removedBackup[part] = (fields(app, coordinator), state.ids.id(for: app))
        write(app, Dictionary(uniqueKeysWithValues: fields(app, coordinator).keys.map { ($0, "") }), coordinator)
        filledFields[part] = nil; offerValues[part] = nil
        undone.insert(part)   // the old app's page must not fill them straight back
        var next = state
        next.ids.forget(app)
        next.filled.remove(part); next.offers.remove(part); next.removed.insert(part)
        state = next
        defaults.set(next.ids.meeting, forKey: Self.meetingKey)
        defaults.set(next.ids.hosting, forKey: Self.hostingKey)
        open(ZoomMarketplaceGuide.builderURL, part: part)
    }

    /// "Keys removed · Undo".
    func undoRemoved(_ part: ZoomGuidePart) {
        guard let coordinator, let app = Self.app(of: part), let backup = removedBackup[part] else { return }
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
        guard runner == nil, setUpForMe != .preparing else { return }
        setUpForMe = .preparing
        open(ZoomMarketplaceGuide.builderURL, part: .meetingApp)
        Task { @MainActor in
            var existing: Set<ZoomApp> = []
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let s = await ZoomMarketplaceWindow.shared.read(), s.address == .createdApps, s.has(.plus) else { continue }
                existing = Set(s.appList).intersection([.meeting, .hosting])
                break
            }
            guard setUpForMe == .preparing else { return }
            setUpForMe = .asking(existing: existing)
        }
    }

    func cancelSetUpForMe() { if runner == nil { setUpForMe = .idle } }

    func startSetUpForMe(_ info: InfoValues, buildNew: Set<ZoomApp>) {
        guard let coordinator, runner == nil else { return }
        coordinator.loadSecretsIfNeeded()
        var answers = SetupAnswers()
        answers.info = info
        answers.buildNew = buildNew
        let window = ZoomMarketplaceWindow.shared
        let run = SetupForMe(page: window, keys: CoordinatorZoomKeys(assist: self, coordinator: coordinator),
                             checker: CoordinatorZoomChecker(coordinator: coordinator), answers: answers)
        runner = run
        run.onStep = { [weak self] step in
            let line = (step.number.map { "Step \($0) of \(SetupStep.total) \u{00B7} " } ?? "") + step.title + "\u{2026}"
            window.setAutopilot(line)
            self?.setUpForMe = .running(line)
        }
        window.setAutopilot("Setting up\u{2026}")
        setUpForMe = .running("Setting up\u{2026}")
        Task { @MainActor in
            let end = await run.run()
            runner = nil
            window.setAutopilot(nil)
            switch end {
            case .done:
                setUpForMe = .done
                window.close()
                coordinator.openZoomSetupGuide(at: .zoomStep)
            case .stopped:
                setUpForMe = .handedOver("You stopped Set up for me. The guided steps carry on from here.")
            case .handedOver(let step, let why):
                let at = (step.number.map { "Step \($0) of \(SetupStep.total) \u{00B7} " } ?? "") + step.title
                setUpForMe = .handedOver("Greenroom stopped at \(at). \(why) The guided steps carry on from here.")
            }
            ZoomMarketplaceWindow.shared.refresh()
        }
    }

    func stopSetUpForMe() { runner?.stop() }
}

/// Where Set up for me keeps the keys it copies: the same fields (and Keychain) typing uses.
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
