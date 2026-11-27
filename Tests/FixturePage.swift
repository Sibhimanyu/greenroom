import Foundation
@testable import GreenroomTests

/// Test doubles for the Set up for me tests: the keys Greenroom stores, and the check.
@MainActor
final class MemoryKeys: ZoomKeyStore {
    var stored: [ZoomApp: [ZoomKeyField: String]] = [:]
    func keys(for app: ZoomApp) -> [ZoomKeyField: String] { stored[app] ?? [:] }
    func save(_ keys: [ZoomKeyField: String], for app: ZoomApp) { stored[app, default: [:]].merge(keys) { _, new in new } }
}

/// A scripted Zoom: a small model of Marketplace that behaves the way the 2026-11-27 live run showed it
/// and answers `ZoomPage` like the real window does. Facts it copies from the live run: Create on a
/// General app makes the app at once (no name dialog) and lands on its Basic information; the Client ID is
/// readable there but the secret is only reachable through a deep press of Zoom's Copy (a plain press
/// copies nothing); the Meeting SDK switch starts off; a Server-to-Server app lands on App Credentials,
/// whose keys are only copyable; its Information page needs four fields (and on an account without the
/// permission they are disabled); Activation lists what is missing.
@MainActor
final class FixturePage: ZoomPage {
    struct App: Equatable {
        var kind: ZoomApp
        var id: String
        var clientID: String
        var secret: String
        var accountID = ""
        var sdkOn = false
        var scopes: Set<String> = []
        /// Live run 4, 2026-11-27: scopes added in the Add scopes window show on the page but are only kept when
        /// the Scopes page's own Continue is pressed; leaving the page any other way drops them.
        var unsavedScopes: Set<String> = []
        var activated = false
        var info: [ZoomInfoField: String] = [:]
        var infoDisabled = false
    }

    var apps: [App] = []
    var address: ZoomMarketplacePage = .createdApps { didSet { if address != oldValue { blankReads = loadingReads; lateListReads = listLateReads; lockedInfoReads = infoLockedReads; lateContentReads = contentLateReads; dropUnsaved() } } }
    private func dropUnsaved() { for i in apps.indices { apps[i].unsavedScopes = [] } }
    /// Live finding, 2026-11-27: right after a page opens Zoom shows nothing yet (no switch state, no keys)
    /// for a second or two. The next `loadingReads` reads after a page change come back empty.
    var loadingReads = 0
    private var blankReads = 0
    /// Live finding, 2026-11-27: Created apps shows its + button about a second before it fills the list.
    /// The next `listLateReads` reads of Created apps after a page change show + and no apps.
    var listLateReads = 0
    /// Live finding, 2026-11-27: Information's fields stay disabled for up to a minute after the page opens,
    /// then unlock by themselves. The next `infoLockedReads` reads of Information show them disabled.
    var infoLockedReads = 0
    private var lockedInfoReads = 0
    /// Live run 7, 2026-11-27: a page draws its menu links first and its own controls up to seconds later.
    /// The next `contentLateReads` reads after a page change show only the app's menu links.
    var contentLateReads = 0
    /// The person signs in by themselves after this many reads of the sign-in page (0: never).
    var signsInAfterReads = 0
    /// Called on every read (a test presses Stop mid-wait from here).
    var onRead: () -> Void = {}
    /// The person types this into Information's Email after this many reads (0: never).
    var personTypesEmail: (afterReads: Int, email: String)? = nil
    /// Live run 9, 2026-11-27: a tick in the Add scopes window registers only once the page redraws; Done pressed
    /// straight after the last tick lost it. With this on, a tick counts after the next read.
    var ticksRegisterOnRead = false
    /// Live runs 9 and 10, 2026-11-27: Zoom showed the eighth tick at once yet dropped it on Done. With this on, the
    /// first Done loses its last tick.
    var firstDoneDropsLastTick = false
    private var lastTicked: String?
    private var pendingTicks: Set<String> = []
    private var lateContentReads = 0
    private var lateListReads = 0
    var signedIn = true
    /// Every action the page performed, in order (a press, a type, a navigation), for tests that watch for forbidden ones.
    private(set) var log: [ZoomPageAction] = []
    /// Texts an element would show when pressed, by control (the deny-list reads these).
    var elementText: [ZoomControl: String] = [:]
    /// The account lacks Server-to-Server edit permission: new Hosting apps have disabled Information fields.
    var accountCannotEditS2S = false
    /// Live runs 6-8, 2026-11-27: Zoom's app API answers some write with 401 although the scopes save fine (the owner
    /// saw Scopes ✓ and "ready for activation"), and the Scopes page doesn't list saved scopes where the reader looks.
    var spurious401 = false
    var savedScopesNotListed = false
    private var refusedSave = false

    private var menuOpen = false
    private var dialog: ZoomDialog = .none
    private var radio: ZoomApp?
    private var nameText = ""
    private var search = ""
    private var ticked: Set<String> = []
    private var copied: String?
    private var counter = 0

    static func freshAccount() -> FixturePage { FixturePage() }

    static func signedOutAccount() -> FixturePage {
        let p = FixturePage(); p.signedIn = false; p.address = .signIn; return p
    }

    func personSignsIn() { signedIn = true; address = .createdApps }

    /// Zoom already holds apps (their states as given).
    func existing(_ app: App) -> FixturePage { apps.append(app); return self }

    private func app(_ id: String) -> App? { apps.first { $0.id == id } }
    private func edit(_ id: String, _ change: (inout App) -> Void) {
        if let i = apps.firstIndex(where: { $0.id == id }) { change(&apps[i]) }
    }

    // MARK: ZoomPage

    func read() async -> ZoomPageSnapshot? {
        onRead()
        if let t = personTypesEmail, case .s2s(let id, .information) = address {
            if t.afterReads <= 1 { edit(id) { $0.info[.contactEmail] = t.email }; personTypesEmail = nil }
            else { personTypesEmail = (t.afterReads - 1, t.email) }
        }
        if !pendingTicks.isEmpty { ticked.formUnion(pendingTicks); pendingTicks = [] }
        if !signedIn, signsInAfterReads > 0 { signsInAfterReads -= 1; if signsInAfterReads == 0 { personSignsIn() } }
        guard signedIn else { return ZoomPageSnapshot(address: address, signedIn: false) }
        if blankReads > 0 { blankReads -= 1; return ZoomPageSnapshot(address: address, signedIn: true, dialog: .none) }
        // Live, 2026-11-27: the person deleted an app in Zoom; its page now says "The application is not found".
        if let id = address.appID, app(id) == nil {
            // A deleted Server-to-Server app: Zoom redirects to a generic "Something went wrong" page (live, 2026-11-27).
            if address.zoomApp == .hosting {
                var error = ZoomPageSnapshot(address: nil, signedIn: true, dialog: .none)
                error.pageError = true
                return error
            }
            var gone = ZoomPageSnapshot(address: address, signedIn: true, dialog: .none)
            gone.appMissing = true
            gone.controls.insert(.navLink(.basicInformation))
            return gone
        }
        if lateContentReads > 0, address != .createdApps {
            lateContentReads -= 1
            var menu = ZoomPageSnapshot(address: address, signedIn: true, dialog: .none)
            ZoomNavLink.allCases.forEach { menu.controls.insert(.navLink($0)) }
            return menu
        }
        var s = ZoomPageSnapshot(address: address, signedIn: true, dialog: dialog)
        func nav(_ links: [ZoomNavLink]) { links.forEach { s.controls.insert(.navLink($0)) } }
        switch address {
        case .createdApps:
            s.controls.insert(.plus)
            if lateListReads > 0 { lateListReads -= 1; if menuOpen { s.controls.insert(.buildApp); s.menuItems = ["Build app"] }; return s }
            s.appList = apps.map(\.kind)
            for i in apps.indices { s.controls.insert(.appRow(i)) }
            if menuOpen { s.controls.insert(.buildApp); s.menuItems = ["Build app"] }
            if case .appType = dialog { s.controls.formUnion([.typeRadio(.meeting), .typeRadio(.hosting), .create, .cancel]) }
            if case .name = dialog { s.controls.formUnion([.nameField, .create, .cancel]) }
        case .general(let id, let tab):
            guard let a = app(id) else { break }
            nav([.basicInformation, .access, .surface, .embed, .connect, .customForm, .scopes])
            switch tab {
            case .information:
                s.keys = [.clientID: .value(a.clientID), .clientSecret: .copyable, .accountID: .absent]
                s.controls.formUnion([.copy(.clientID), .copy(.clientSecret)])
            case .embed:
                s.meetingSDKOn = a.sdkOn
                s.controls.insert(.meetingSDKSwitch)
            default: break
            }
        case .s2s(let id, let tab):
            guard let a = app(id) else { break }
            nav([.information, .appCredentials, .feature, .scopes, .activation])
            switch tab {
            case .credentials:
                s.keys = [.accountID: .value(a.accountID), .clientID: .copyable, .clientSecret: .copyable]
                s.controls.formUnion([.copy(.clientID), .copy(.clientSecret), .continue])
            case .information:
                for f in ZoomInfoField.allCases {
                    s.infoFields[f] = (a.infoDisabled || lockedInfoReads > 0) ? .disabled : ((a.info[f] ?? "").isEmpty ? .empty : .filled)
                    s.controls.insert(.infoField(f))
                }
                s.controls.insert(.continue)
            case .feature: s.controls.insert(.continue)
            case .scopes:
                s.scopesOnPage = (savedScopesNotListed ? a.unsavedScopes : a.scopes.union(a.unsavedScopes)).sorted()
                if case .addScopes = dialog {
                    s.controls.formUnion([.scopeSearch, .scopesDone])
                    for n in ZoomScopes.names where !search.isEmpty && n.contains(search) { s.controls.insert(.scopeCheckbox(n)) }
                    s.dialog = .addScopes(searchPresent: true, ticked: ticked.sorted())
                } else {
                    s.controls.formUnion([.addScopes, .continue])
                }
            case .activation:
                s.activated = a.activated
                s.activationMissing = missingInfo(a) + (a.scopes.isEmpty ? ["1. Select at least one scopes"] : [])
                if !a.activated { s.controls.insert(.activate) }
            }
        default: break
        }
        if case .s2s(_, .information) = address, lockedInfoReads > 0 { lockedInfoReads -= 1 }
        if refusedSave { s.saveRefused = true }
        return s
    }

    func perform(_ action: ZoomPageAction) async -> ZoomActionResult {
        log.append(action)
        guard signedIn, let s = await read() else { return .notFound }
        switch action {
        case .navigate(let p): address = p; menuOpen = false; return .done
        case .hover(let c): return s.has(c) || c == .keyRow(.clientSecret) || c == .keyRow(.clientID) || c == .keyRow(.accountID) ? .done : .notFound
        case .press(let c), .pressDeep(let c):
            guard s.has(c) else { return .notFound }
            if let said = elementText[c], ZoomActorRules.isDenied(said) { return .denied }
            let deep: Bool
            if case .pressDeep = action { deep = true } else { deep = false }
            press(c, deep: deep)
        case .type(let c, let text):
            guard s.has(c) else { return .notFound }
            type(c, text)
        }
        return .done
    }

    func takeCopiedKey() -> String? { defer { copied = nil }; return copied }
    func draw(_ coach: CoachDrawing?) {}

    // MARK: Zoom's behaviour

    private func press(_ c: ZoomControl, deep: Bool) {
        switch c {
        case .plus: menuOpen = true
        case .buildApp: menuOpen = false; dialog = .appType([.general: false, .serverToServer: false]); radio = nil
        case .typeRadio(let k): radio = k
        case .create:
            if case .appType = dialog, radio == .meeting { make(.meeting) }
            else if case .appType = dialog, radio == .hosting { dialog = .name(app: .hosting, filled: false, createEnabled: false); nameText = "" }
            else if case .name = dialog, !nameText.isEmpty { make(.hosting) }
        case .cancel: dialog = .none
        case .meetingSDKSwitch:
            if case .general(let id, _) = address { edit(id) { $0.sdkOn.toggle() } }
        case .copy(let f):
            // Live run: a plain press copies nothing; the handler sits on the inner icon.
            guard deep else { return }
            switch address {
            case .general(let id, _): copied = app(id).map { f == .clientSecret ? $0.secret : $0.clientID }
            case .s2s(let id, _): copied = app(id).map { f == .clientSecret ? $0.secret : f == .clientID ? $0.clientID : $0.accountID }
            default: break
            }
        case .continue:
            if case .s2s(let id, let tab) = address, let a = app(id) {
                if tab == .credentials { address = .s2s(id, .information) }
                else if tab == .information, missingInfo(a).isEmpty { address = .s2s(id, .feature) }
                else if tab == .feature { address = .s2s(id, .scopes) }
                else if tab == .scopes {
                    if spurious401 { refusedSave = true }
                    edit(id) { $0.scopes.formUnion($0.unsavedScopes); $0.unsavedScopes = [] }
                    address = .s2s(id, .activation)
                }
            }
        case .addScopes: dialog = .addScopes(searchPresent: true, ticked: []); search = ""; ticked = []
        case .scopeCheckbox(let n):
            lastTicked = n
            if ticksRegisterOnRead { pendingTicks.insert(n) }
            else if ticked.contains(n) { ticked.remove(n) } else { ticked.insert(n) }
        case .scopesDone:
            pendingTicks = []
            if firstDoneDropsLastTick, let last = lastTicked { ticked.remove(last); firstDoneDropsLastTick = false }
            if case .s2s(let id, _) = address { edit(id) { $0.unsavedScopes.formUnion(ticked) } }
            dialog = .none
        case .activate:
            if case .s2s(let id, _) = address, let a = app(id), missingInfo(a).isEmpty, !a.scopes.isEmpty { edit(id) { $0.activated = true } }
        case .appRow(let i):
            guard i < apps.count else { return }
            let a = apps[i]
            address = a.kind == .meeting ? .general(a.id, .information) : .s2s(a.id, .credentials)
        default: break
        }
    }

    private func type(_ c: ZoomControl, _ text: String) {
        switch c {
        case .nameField:
            nameText = text
            dialog = .name(app: .hosting, filled: !text.isEmpty, createEnabled: !text.isEmpty)
        case .scopeSearch: search = text
        case .infoField(let f):
            if case .s2s(let id, _) = address, let a = app(id), !a.infoDisabled { edit(id) { $0.info[f] = text } }
        default: break
        }
    }

    private func missingInfo(_ a: App) -> [String] {
        var out: [String] = []
        if (a.info[.contactName] ?? "").isEmpty { out.append("Developer contact name") }
        if (a.info[.contactEmail] ?? "").isEmpty { out.append("Developer contact email") }
        if (a.info[.companyName] ?? "").isEmpty { out.append("Company name") }
        if (a.info[.shortDescription] ?? "").isEmpty { out.append("Short description") }
        return out
    }

    private func make(_ kind: ZoomApp) {
        counter += 1
        // Key-shaped, distinct per app and per field, so a test can tell them apart.
        let tag = "\(kind.rawValue.prefix(1))\(counter)"
        var a = App(kind: kind, id: "app\(tag)IdIdIdIdIdIdIdId", clientID: "client\(tag)ClientClientCl",
                    secret: "secret\(tag)SecretSecretSecretSecret")
        if kind == .hosting {
            a.accountID = "account\(tag)AccountAccountAc"
            a.info[.appName] = nameText
            a.infoDisabled = accountCannotEditS2S
        }
        apps.append(a)
        dialog = .none
        address = kind == .meeting ? .general(a.id, .information) : .s2s(a.id, .credentials)
    }
}

/// Check Zoom setup against the scripted Zoom: the same lines the real checker fills (ids, details, fix buttons),
/// decided from what the fixture's Zoom holds and what Greenroom has stored.
@MainActor
final class FixtureChecker: ZoomChecker {
    let zoom: FixturePage
    let keys: MemoryKeys
    private(set) var runs = 0
    /// Things Zoom does between checks (a scope revoked, a switch turned off): one is run before each check, in order.
    var beforeRun: [() -> Void] = []
    /// Zoom always answers "no" for the Meeting app (a fault Greenroom cannot fix by pressing things).
    var meetingAlwaysFails = false
    init(zoom: FixturePage, keys: MemoryKeys) { self.zoom = zoom; self.keys = keys }

    func run() async -> [ZoomCheckLine] {
        runs += 1
        if !beforeRun.isEmpty { beforeRun.removeFirst()() }
        let ids = ZoomCheckActionContext()
        func line(_ id: String, _ title: String, _ ok: Bool, _ detail: String, _ problem: ZoomCheckProblem = .nothing) -> ZoomCheckLine {
            let status: ZoomCheckStatus = ok ? .passed : .failed
            return ZoomCheckLine(id: id, title: title, status: status, detail: detail,
                                 actions: ZoomCheckActionRules.buttons(.ownApps, check: id, status: status, problem: problem, ids: ids))
        }
        var lines: [ZoomCheckLine] = []
        let mine = keys.keys(for: .meeting)
        // Zoom answers for whichever app the client ID belongs to.
        let sdk = zoom.apps.first { $0.kind == .meeting && $0.clientID == mine[.clientID] }
        if mine[.clientID] == nil || mine[.clientSecret] == nil {
            lines.append(line("sdk", "Meeting and chat credentials", false, "Add both General App values under Meeting and chat.", .badCredentials))
        } else {
            let ok = !meetingAlwaysFails && sdk != nil && mine[.clientID] == sdk?.clientID && mine[.clientSecret] == sdk?.secret && sdk?.sdkOn == true
            lines.append(line("sdk", "Meeting and chat credentials", ok, ok ? "Zoom accepted the General App credentials." : "Zoom said no. Check the General App credentials and that Meeting SDK is enabled.", .badCredentials))
        }
        let theirs = keys.keys(for: .hosting)
        let s2s = zoom.apps.first { $0.kind == .hosting && $0.clientID == theirs[.clientID] }
        if theirs[.accountID] == nil || theirs[.clientID] == nil || theirs[.clientSecret] == nil {
            lines.append(line("account", "Hosting credentials and app activation", false, "Add all three Server-to-Server app values under Create and host meetings.", .badCredentials))
        } else {
            let ok = s2s != nil && theirs[.accountID] == s2s?.accountID && theirs[.clientID] == s2s?.clientID
                && theirs[.clientSecret] == s2s?.secret && s2s?.activated == true
            lines.append(line("account", "Hosting credentials and app activation", ok, ok ? "Zoom issued an access token. The hosting app is active." : "Zoom said no. Check the three hosting values and activate the app in Zoom.", .notActivated))
            if ok {
                for scope in ZoomScopes.all {
                    let granted = s2s?.scopes.contains(scope.name) == true
                    lines.append(line(scope.key.rawValue, scope.checkTitle, granted, granted ? "Granted." : "Missing \(scope.name).", .missingScopes([scope.name])))
                }
            }
        }
        return lines
    }
}
