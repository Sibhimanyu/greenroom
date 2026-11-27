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
import SwiftUI

@MainActor
final class ZoomSetupAssist: ObservableObject {
    private weak var coordinator: CoordinatorController?
    private let defaults = UserDefaults.standard
    private static let meetingKey = "zoomSDKAppID"
    private static let hostingKey = "zoomS2SAppID"

    /// What the guide shows (the page, the IDs, the notices).
    @Published private(set) var state: ZoomGuideAssistState {
        didSet { if state != oldValue { coordinator?.objectWillChange.send() } }
    }
    private var offerValues: [ZoomGuidePart: [ZoomKeyField: String]] = [:]
    private var filledFields: [ZoomGuidePart: [ZoomKeyField]] = [:]
    /// Parts the person undid on this visit to the page: not filled again until the page changes.
    private var undone: Set<ZoomGuidePart> = []

    init(coordinator: CoordinatorController) {
        self.coordinator = coordinator
        state = ZoomGuideAssistState(ids: ZoomAppIDs(meeting: defaults.string(forKey: Self.meetingKey),
                                                     hosting: defaults.string(forKey: Self.hostingKey)))
        let window = ZoomMarketplaceWindow.shared
        window.onPage = { [weak self] in self?.pageChanged($0) }
        window.onKeys = { [weak self] page, found in self?.keysFound(page, found) }
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

    private func fields(_ app: ZoomOwnApp, _ c: CoordinatorController) -> [ZoomKeyField: String] {
        switch app {
        case .sdk: return [.clientID: c.sdkClientID, .clientSecret: c.sdkClientSecret]
        case .s2s: return [.accountID: c.s2sAccountID, .clientID: c.s2sClientID, .clientSecret: c.s2sClientSecret]
        }
    }

    private func write(_ app: ZoomOwnApp, _ values: [ZoomKeyField: String], _ c: CoordinatorController) {
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

    private var bothFilled: Bool {
        guard let c = coordinator else { return false }
        return [fields(.sdk, c), fields(.s2s, c)].allSatisfy { $0.values.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    private func keysFound(_ page: ZoomMarketplacePage, _ found: [ZoomKeyField: String]) {
        guard let coordinator, let app = page.app, state.page == page else { return }
        let part = Self.part(of: app)
        guard !undone.contains(part) else { return }
        // A secret not loaded yet would look empty, and be overwritten.
        coordinator.loadSecretsIfNeeded()
        let before = bothFilled
        var next = state
        switch ZoomKeyFillRules.decide(current: fields(app, coordinator), found: found) {
        case .nothing:
            return
        case .fill(let values):
            write(app, values, coordinator)
            filledFields[part] = Array(values.keys)
            next.filled.insert(part); next.offers.remove(part); offerValues[part] = nil
        case .offer(let values):
            offerValues[part] = values
            next.offers.insert(part)
        }
        state = next
        // The coach says "Got it" now.
        ZoomMarketplaceWindow.shared.refresh()
        if ZoomKeyFillRules.shouldAutoCheck(bothFilledBefore: before, bothFilledAfter: bothFilled,
                                            inSession: coordinator.phase.isInMeeting,
                                            checkRunning: coordinator.zoomSetupChecker.isRunning) {
            coordinator.checkZoomSetup()
        }
    }

    /// "Use the keys from this page".
    func useOffer(_ part: ZoomGuidePart) {
        guard let coordinator, let app = Self.app(of: part), let values = offerValues[part] else { return }
        let before = bothFilled
        write(app, values, coordinator)
        filledFields[part] = Array(values.keys)
        offerValues[part] = nil
        var next = state
        next.offers.remove(part); next.filled.insert(part)
        state = next
        ZoomMarketplaceWindow.shared.refresh()
        if ZoomKeyFillRules.shouldAutoCheck(bothFilledBefore: before, bothFilledAfter: bothFilled,
                                            inSession: coordinator.phase.isInMeeting,
                                            checkRunning: coordinator.zoomSetupChecker.isRunning) {
            coordinator.checkZoomSetup()
        }
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
}
