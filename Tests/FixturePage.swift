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
        var activated = false
        var info: [ZoomInfoField: String] = [:]
        var infoDisabled = false
    }

    var apps: [App] = []
    var address: ZoomMarketplacePage = .createdApps
    var signedIn = true
    /// Every action the page performed, in order (a press, a type, a navigation), for tests that watch for forbidden ones.
    private(set) var log: [ZoomPageAction] = []
    /// Texts an element would show when pressed, by control (the deny-list reads these).
    var elementText: [ZoomControl: String] = [:]
    /// The account lacks Server-to-Server edit permission: new Hosting apps have disabled Information fields.
    var accountCannotEditS2S = false

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
        guard signedIn else { return ZoomPageSnapshot(address: address, signedIn: false) }
        var s = ZoomPageSnapshot(address: address, signedIn: true, dialog: dialog)
        func nav(_ links: [ZoomNavLink]) { links.forEach { s.controls.insert(.navLink($0)) } }
        switch address {
        case .createdApps:
            s.appList = apps.map(\.kind)
            s.controls.insert(.plus)
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
                    s.infoFields[f] = a.infoDisabled ? .disabled : ((a.info[f] ?? "").isEmpty ? .empty : .filled)
                    s.controls.insert(.infoField(f))
                }
                s.controls.insert(.continue)
            case .feature: s.controls.insert(.continue)
            case .scopes:
                s.scopesOnPage = a.scopes.sorted()
                if case .addScopes = dialog {
                    s.controls.formUnion([.scopeSearch, .scopesDone])
                    for n in ZoomScopes.names where !search.isEmpty && n.contains(search) { s.controls.insert(.scopeCheckbox(n)) }
                    s.dialog = .addScopes(searchPresent: true, ticked: ticked.sorted())
                } else {
                    s.controls.insert(.addScopes)
                }
            case .activation:
                s.activated = a.activated
                s.activationMissing = missingInfo(a)
                if !a.activated { s.controls.insert(.activate) }
            }
        default: break
        }
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
            }
        case .addScopes: dialog = .addScopes(searchPresent: true, ticked: []); search = ""; ticked = []
        case .scopeCheckbox(let n): if ticked.contains(n) { ticked.remove(n) } else { ticked.insert(n) }
        case .scopesDone:
            if case .s2s(let id, _) = address { edit(id) { $0.scopes.formUnion(ticked) } }
            dialog = .none
        case .activate:
            if case .s2s(let id, _) = address, let a = app(id), missingInfo(a).isEmpty { edit(id) { $0.activated = true } }
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
    init(zoom: FixturePage, keys: MemoryKeys) { self.zoom = zoom; self.keys = keys }

    func run() async -> [ZoomCheckLine] {
        runs += 1
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
            let ok = sdk != nil && mine[.clientID] == sdk?.clientID && mine[.clientSecret] == sdk?.secret && sdk?.sdkOn == true
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
