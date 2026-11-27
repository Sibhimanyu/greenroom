//
//  ZoomSetupFlow.swift
//  Greenroom
//
//  The ONE module that knows the Zoom setup steps (docs/specs/zoom-setup-flow.md, ADR 0003).
//  Two functions: `absorb(snapshot, into:)` turns what a page proves into evidence, and
//  `step(for:)` returns the first step of the spec's table that is not done, with exactly one
//  call to action (`CallToAction` has no passive case, so a step with nothing to do cannot be
//  written). The guide, the bar, the coach and Set up for me only render or run what this says.
//  Pure: Foundation only.
//
import Foundation

// MARK: - Vocabulary

/// Server-to-Server steps use `.hosting`, General app steps `.meeting`.
typealias ZoomApp = ZoomAppKind

enum ZoomCondition: Equatable {
    case dialogOpen
    case dialogIs(Kind)
    case hasControl(ZoomControl)
    case onApp(ZoomApp)
    case sdkOn
    case activated
    case createEnabled
    case scopesOnPage([String])
    case infoFilled(ZoomInfoField)
    case scopeTicked(String)

    enum Kind: Equatable { case appType, name(ZoomApp), addScopes }

    func holds(in s: ZoomPageSnapshot) -> Bool {
        switch self {
        case .dialogOpen: return s.dialog != .none
        case .dialogIs(let k):
            switch (k, s.dialog) {
            case (.appType, .appType), (.addScopes, .addScopes): return true
            case (.name(let a), .name(let b, _, _)): return a == b
            default: return false
            }
        case .hasControl(let c): return s.has(c)
        case .onApp(let a): return s.address?.zoomApp == a
        case .sdkOn: return s.meetingSDKOn == true
        case .activated: return s.activated == true
        case .createEnabled:
            if case .name(_, _, let enabled) = s.dialog { return enabled }
            return false
        case .scopesOnPage(let names): return names.allSatisfy(s.scopesOnPage.contains)
        case .infoFilled(let f): return s.infoFields[f] == .filled
        case .scopeTicked(let n):
            if case .addScopes(_, let ticked) = s.dialog { return ticked.contains(n) }
            return false
        }
    }
}

extension ZoomMarketplacePage {
    /// A General app's pages (including the page right after Create) are the meeting app; Server-to-Server pages the hosting app.
    var zoomApp: ZoomApp? {
        switch self {
        case .general, .chooseType: return .meeting
        case .s2s: return .hosting
        default: return nil
        }
    }
}

extension ZoomPageSnapshot {
    var isSignedOut: Bool { signedIn == false || address?.isSignIn == true }
}

enum ZoomPlanStep: Equatable {
    /// `unless`: skip the press when this already holds (never toggle something that is already right).
    case press(ZoomControl, unless: ZoomCondition? = nil)
    case pressDeep(ZoomControl)
    case hover(ZoomControl)
    case type(ZoomControl, String)
    case waitFor(ZoomCondition)
    /// Read the key from the page, or copy it with Zoom's own Copy control and take it from the copy hook.
    case capture(ZoomKeyField)
}

/// What a finished plan means for the evidence.
enum ZoomPlanEffect: Equatable {
    case createsApp, changesSettings, copiesKeys, nothing
}

struct ActionPlan: Equatable {
    var app: ZoomApp?
    var effect: ZoomPlanEffect
    var steps: [ZoomPlanStep]
}

enum CallToAction: Equatable {
    case goTo(ZoomMarketplacePage, String)
    case doThisStep(ActionPlan)
    case press(ZoomControl, String)
    case fill(ZoomControl, String)
    case wait(String)
    case checkAgain
    case backToGreenroom
}

struct SetupStep: Equatable {
    /// 1 to 8; nil for sign-in and the final check.
    var number: Int?
    static let total = 8
    var title: String
    var app: ZoomApp?
    var why: String
    var place: ZoomMarketplacePage?
    var status: String?
    var cta: CallToAction
}

extension CallToAction {
    /// The label of the one button the bar and the card show; nil when the person acts on Zoom's page (nothing to press here).
    var buttonLabel: String? {
        switch self {
        case .goTo(_, let text): return text
        case .doThisStep: return "Do this step"
        case .checkAgain: return "Check again"
        case .backToGreenroom: return "Back to Greenroom"
        case .press, .fill, .wait: return nil
        }
    }

    /// The control the person is asked to use (the coach rings it).
    var control: ZoomControl? {
        switch self {
        case .press(let c, _), .fill(let c, _): return c
        default: return nil
        }
    }

    /// What to say when the person (not Greenroom) is the one acting.
    var instruction: String? {
        switch self {
        case .press(_, let text), .fill(_, let text), .wait(let text): return text
        default: return nil
        }
    }
}

extension SetupStep {
    var isSignIn: Bool { number == nil && cta.control == .signIn }

    /// "Step 3 of 8"; empty for sign-in and the final check.
    var counter: String { number.map { "Step \($0) of \(Self.total)" } ?? "" }

    /// The bar's left side: "Step 3 of 8 \u{00B7} Copy its keys".
    var barTitle: String { number == nil ? title : counter + " \u{00B7} " + title }

    /// What the coach draws for this step.
    var coach: CoachDrawing {
        CoachDrawing(control: cta.control, counter: counter, title: title, why: why, status: status ?? cta.instruction, button: cta.buttonLabel)
    }
}

// MARK: - Evidence

struct AppEvidence: Equatable {
    var id: String?
    /// The Client ID the app's page showed (compared with the stored one; never persisted).
    var clientID: String?
    var sdkOn: Bool?
    /// The Information page last showed every required field filled (nil: not seen), and Zoom's Activation page
    /// last listed these as missing (nil: not seen).
    var infoFilled: Bool?
    var infoMissing: [String]?
    /// Every Information field is disabled: the Zoom account may not edit this app.
    var infoLocked = false
    var scopes: Set<String> = []
    var activated: Bool?
    /// When (on the evidence clock) something in the app's settings last changed, and when its keys were last copied.
    var lastChange = 0
    var keysAt: Int?
}

struct Evidence: Equatable {
    var tick = 0
    var signedIn: Bool?
    var apps: [ZoomApp: AppEvidence] = [:]

    func app(_ a: ZoomApp) -> AppEvidence { apps[a] ?? AppEvidence() }

    /// A plan changed an app's settings: keys copied earlier are stale.
    mutating func settingsChanged(_ a: ZoomApp) {
        tick += 1
        apps[a, default: AppEvidence()].lastChange = tick
    }

    /// The keys were copied now (after the last settings change).
    mutating func keysCopied(_ a: ZoomApp, clientID: String?) {
        tick += 1
        apps[a, default: AppEvidence()].keysAt = tick
        if let clientID { apps[a, default: AppEvidence()].clientID = clientID }
    }
}

/// What the person confirmed for Information (step 5). The description is Greenroom's; name and email come from
/// the Zoom profile or the Mac account; the company is the person's name unless they change it.
struct InfoValues: Equatable {
    var name = ""
    var email = ""
    var company = ""
    var description = "Lets Greenroom create, start and host my Zoom meetings."

    var companyOrName: String { company.isEmpty ? name : company }

    func value(for f: ZoomInfoField) -> String {
        switch f {
        case .shortDescription: return description
        case .companyName: return companyOrName
        case .contactName: return name
        case .contactEmail: return email
        case .appName: return ""
        }
    }
}

struct SetupAnswers: Equatable {
    var info = InfoValues()
    /// Apps the person wants built new even though Created apps already lists one of that type.
    var buildNew: Set<ZoomApp> = []
}

struct SetupFacts: Equatable {
    var evidence = Evidence()
    /// The keys Greenroom holds now (in memory; never logged).
    var stored: [ZoomApp: [ZoomKeyField: String]] = [:]
    /// The latest Check Zoom setup, per app (valid only if nothing changed in the app since it ran).
    var checks: [ZoomApp: AppCheck] = [:]
    var checkRunning = false
    var snapshot: ZoomPageSnapshot?
    var answers = SetupAnswers()
}

/// What Check Zoom setup says to fix in one app, in the places Zoom keeps them.
enum SetupFix: Equatable, Hashable { case keys, embed, scopes, activation }

struct AppCheck: Equatable {
    var passed: Bool
    var fixes: [SetupFix]
    /// The evidence clock when the check started.
    var at: Int
}

// MARK: - The module

enum ZoomSetupFlow {
    static func absorb(_ s: ZoomPageSnapshot, into old: Evidence) -> Evidence {
        var e = old
        e.tick += 1
        if s.isSignedOut { e.signedIn = false }
        else if let signedIn = s.signedIn { e.signedIn = signedIn }
        else if s.address != nil { e.signedIn = true }
        if let page = s.address, let app = page.zoomApp, let id = page.appID, e.app(app).id != id {
            e.apps[app] = AppEvidence(id: id)
        }
        if let page = s.address, let app = page.zoomApp {
            if app == .meeting, let on = s.meetingSDKOn {
                if on, e.app(app).sdkOn != true { e.apps[app, default: AppEvidence()].lastChange = e.tick }
                e.apps[app, default: AppEvidence()].sdkOn = on
            }
            if app == .meeting, case .general(_, .information) = page, let v = s.keys[.clientID]?.text {
                e.apps[app, default: AppEvidence()].clientID = v
            }
        }
        if let page = s.address, case .s2s(_, let tab) = page {
            if tab == .information, !s.infoFields.isEmpty {
                let locked = s.infoFields.values.allSatisfy { $0 == .disabled }
                e.apps[.hosting, default: AppEvidence()].infoLocked = locked
                e.apps[.hosting, default: AppEvidence()].infoFilled = locked ? nil : requiredInfo.allSatisfy { s.infoFields[$0] == .filled }
            }
            if tab == .activation {
                e.apps[.hosting, default: AppEvidence()].infoMissing = s.activationMissing
                if let on = s.activated {
                    if on, e.app(.hosting).activated != true { e.apps[.hosting, default: AppEvidence()].lastChange = e.tick }
                    e.apps[.hosting, default: AppEvidence()].activated = on
                }
            }
            if tab == .scopes, s.dialog == .none {
                let now = Set(s.scopesOnPage).intersection(ZoomScopes.names)
                if !now.isSubset(of: e.app(.hosting).scopes) { e.apps[.hosting, default: AppEvidence()].lastChange = e.tick }
                e.apps[.hosting, default: AppEvidence()].scopes = now
            }
        }
        return e
    }

    /// Zoom's required Information fields (the app name is Zoom's own, filled when the app is made).
    static let requiredInfo: [ZoomInfoField] = [.shortDescription, .companyName, .contactName, .contactEmail]

    // MARK: The checks

    /// Sorts Check Zoom setup's lines into one verdict per app. `at` is the evidence clock when the check started.
    static func checks(from lines: [ZoomCheckLine], at: Int) -> [ZoomApp: AppCheck] {
        guard !lines.isEmpty else { return [:] }
        var out: [ZoomApp: AppCheck] = [:]
        if let sdk = lines.first(where: { $0.id == "sdk" }) {
            // "Add both ..." says the keys are missing; any other failure after keys are in is the app itself:
            // make sure Meeting SDK is on, then copy the keys again.
            let fixes: [SetupFix] = sdk.status != .failed ? [] : sdk.detail.hasPrefix("Add ") ? [.keys] : [.embed, .keys]
            out[.meeting] = AppCheck(passed: sdk.status == .passed, fixes: fixes, at: at)
        }
        let hosting = lines.filter { $0.id != "sdk" }
        if let account = hosting.first(where: { $0.id == "account" }) {
            var fixes: [SetupFix] = []
            if account.status == .failed { fixes.append(account.detail.hasPrefix("Add ") ? .keys : .activation) }
            if hosting.contains(where: { $0.status == .failed && $0.actions.contains { if case .copyScope = $0.action { return true } else { return false } } }) {
                fixes.append(.scopes)
            }
            out[.hosting] = AppCheck(passed: account.status == .passed && !hosting.contains { $0.status == .failed }, fixes: fixes, at: at)
        }
        return out
    }

    // MARK: The table

    private static func app(ofStep n: Int) -> ZoomApp { n <= 3 ? .meeting : .hosting }

    /// The check for an app, if nothing in the app has changed since it started.
    private static func validCheck(_ f: SetupFacts, _ app: ZoomApp) -> AppCheck? {
        guard !f.checkRunning, let c = f.checks[app] else { return nil }
        let a = f.evidence.app(app)
        return c.at >= max(a.lastChange, a.keysAt ?? 0) ? c : nil
    }

    private static func fix(ofStep n: Int) -> SetupFix? {
        switch n {
        case 2: return .embed
        case 3, 8: return .keys
        case 6: return .scopes
        case 7: return .activation
        default: return nil
        }
    }

    private static func isDone(_ n: Int, _ f: SetupFacts) -> Bool {
        let e = f.evidence, app = app(ofStep: n)
        if let c = validCheck(f, app) {
            if c.passed { return true }
            if let fix = fix(ofStep: n), c.fixes.contains(fix) { return false }
        }
        let a = e.app(app)
        switch n {
        case 1: return a.id != nil
        case 2: return a.sdkOn == true
        case 3: return keysDone(f, .meeting, fields: [.clientID, .clientSecret])
        case 4: return a.id != nil
        case 5: return a.activated == true || (a.infoFilled == true && (a.infoMissing ?? []).isEmpty)
        case 6: return Set(ZoomScopes.names).isSubset(of: a.scopes)
        case 7: return a.activated == true
        default: return keysDone(f, .hosting, fields: [.accountID, .clientID, .clientSecret])
        }
    }

    private static func keysDone(_ f: SetupFacts, _ app: ZoomApp, fields: [ZoomKeyField]) -> Bool {
        let a = f.evidence.app(app), mine = f.stored[app] ?? [:]
        guard fields.allSatisfy({ !(mine[$0] ?? "").isEmpty }), let at = a.keysAt, at > a.lastChange else { return false }
        return a.clientID == nil || a.clientID == mine[.clientID]
    }

    /// At the step's place the action is the plan; anywhere else it is a trip there.
    private static func act(on f: SetupFacts, at place: ZoomMarketplacePage, _ goText: String, _ plan: ActionPlan) -> CallToAction {
        f.snapshot?.address == place ? .doThisStep(plan) : .goTo(place, goText)
    }

    static func step(for f: SetupFacts) -> SetupStep {
        if f.evidence.signedIn == false {
            return SetupStep(number: nil, title: "Sign in to Zoom", app: nil, why: "Greenroom works in your own Zoom account.",
                             place: nil, status: nil, cta: .press(.signIn, "Sign in to Zoom. Greenroom carries on after."))
        }
        for n in 1...SetupStep.total where !isDone(n, f) { return build(n, f) }
        return finalStep(f)
    }

    private static func build(_ n: Int, _ f: SetupFacts) -> SetupStep {
        let e = f.evidence
        let mid = e.app(.meeting).id ?? "", hid = e.app(.hosting).id ?? ""
        func step(_ title: String, _ why: String, _ place: ZoomMarketplacePage?, _ cta: CallToAction, status: String? = nil) -> SetupStep {
            SetupStep(number: n, title: title, app: app(ofStep: n), why: why, place: place, status: status, cta: cta)
        }
        let keysWhy = "Copied last, so they're the final ones."
        switch n {
        case 1:
            return step("Create the meeting app", "It lets Greenroom join and run meetings.", .createdApps,
                        createOrUse(.meeting, f))
        case 2:
            let place = ZoomMarketplacePage.general(mid, .embed)
            return step("Turn on Meeting SDK", "Without it Zoom won't let the app join meetings.", place,
                        act(on: f, at: place, "Open Embed", sdkPlan))
        case 3:
            let place = ZoomMarketplacePage.general(mid, .information)
            return step("Copy its keys", "Greenroom signs in to meetings with them. " + keysWhy, place,
                        act(on: f, at: place, "Open Basic information", keysPlan(.meeting, [.clientID, .clientSecret])))
        case 4:
            return step("Create the hosting app", "It lets Greenroom create and start your meetings as host.", .createdApps,
                        createOrUse(.hosting, f))
        case 5:
            let place = ZoomMarketplacePage.s2s(hid, .information)
            if e.app(.hosting).infoLocked {
                return step("Ask your Zoom admin for permission", "Zoom asks for a contact before it turns the app on.", place,
                            .checkAgain, status: "Your Zoom account can\u{2019}t edit this app. Ask your Zoom admin to allow \u{2018}Server-to-Server OAuth app: Edit\u{2019} (User Management \u{2192} Roles \u{2192} Role Settings \u{2192} Advanced features), then Check again.")
            }
            return infoStep(step("Fill in Information", "Zoom asks for a contact before it turns the app on.", place, .goTo(place, "Open Information")), f, place)
        case 6:
            let place = ZoomMarketplacePage.s2s(hid, .scopes)
            let have = f.snapshot?.scopesOnPage ?? []
            return step("Add the permissions", "These eight let Greenroom create, list, start and end meetings.", place,
                        act(on: f, at: place, "Open Scopes", scopesPlan(missing: ZoomScopes.names.filter { !have.contains($0) })))
        case 7:
            let place = ZoomMarketplacePage.s2s(hid, .activation)
            return step("Turn it on", "Zoom only answers an app that's switched on.", place,
                        act(on: f, at: place, "Open Activation", activatePlan))
        default:
            let place = ZoomMarketplacePage.s2s(hid, .credentials)
            return step("Copy its keys", "Greenroom uses them to talk to Zoom for you. " + keysWhy, place,
                        act(on: f, at: place, "Open App Credentials", keysPlan(.hosting, [.accountID, .clientID, .clientSecret])))
        }
    }

    /// Every step is done: the check decides.
    private static func finalStep(_ f: SetupFacts) -> SetupStep {
        let why = "Makes sure both apps really work."
        func final(_ title: String, _ cta: CallToAction, status: String? = nil) -> SetupStep {
            SetupStep(number: nil, title: title, app: nil, why: why, place: nil, status: status, cta: cta)
        }
        if f.checkRunning { return final("Check your setup", .wait("Checking\u{2026}")) }
        if let m = validCheck(f, .meeting), let h = validCheck(f, .hosting), m.passed, h.passed {
            return final("Zoom is set up", .backToGreenroom)
        }
        return final("Check your setup", .checkAgain)
    }

    /// On Created apps, a row of the needed type is "Use this app" (unless the person wants a new one); else build it.
    private static func createOrUse(_ app: ZoomApp, _ f: SetupFacts) -> CallToAction {
        if let s = f.snapshot, s.address == .createdApps, !f.answers.buildNew.contains(app),
           let row = s.appList.firstIndex(of: app), s.has(.appRow(row)) {
            return .press(.appRow(row), "Use this app")
        }
        return act(on: f, at: .createdApps, "Open Created apps", createPlan(app))
    }

    // MARK: Plans

    static let hostingAppName = "Greenroom Hosting"

    static func createPlan(_ app: ZoomApp) -> ActionPlan {
        var steps: [ZoomPlanStep] = [
            .press(.plus, unless: .dialogOpen), .waitFor(.hasControl(.buildApp)),
            .press(.buildApp, unless: .dialogIs(.appType)), .waitFor(.dialogIs(.appType)),
            .press(.typeRadio(app)), .press(.create),
        ]
        if app == .hosting {
            steps += [.waitFor(.dialogIs(.name(.hosting))), .type(.nameField, hostingAppName), .waitFor(.createEnabled), .press(.create)]
        }
        steps.append(.waitFor(.onApp(app)))
        return ActionPlan(app: app, effect: .createsApp, steps: steps)
    }

    /// Step 5 at its page: type only the empty required fields from the confirmed values, then Continue.
    private static func infoStep(_ base: SetupStep, _ f: SetupFacts, _ place: ZoomMarketplacePage) -> SetupStep {
        guard let s = f.snapshot, s.address == place else { return base }
        var step = base
        let empty = requiredInfo.filter { s.infoFields[$0] != .filled }
        let wanted = empty.map { ($0, f.answers.info.value(for: $0)) }
        if let missing = wanted.first(where: { $0.1.isEmpty }) {
            step.cta = .fill(.infoField(missing.0), "Type your \(missing.0 == .contactEmail ? "email" : "name") here. Greenroom fills in the rest.")
            return step
        }
        var steps: [ZoomPlanStep] = wanted.map { .type(.infoField($0.0), $0.1) }
        steps += wanted.map { .waitFor(.infoFilled($0.0)) }
        steps.append(.press(.continue))
        step.cta = .doThisStep(ActionPlan(app: .hosting, effect: .changesSettings, steps: steps))
        return step
    }

    static let sdkPlan = ActionPlan(app: .meeting, effect: .changesSettings,
                                    steps: [.press(.meetingSDKSwitch, unless: .sdkOn), .waitFor(.sdkOn)])

    static let activatePlan = ActionPlan(app: .hosting, effect: .changesSettings,
                                         steps: [.press(.activate, unless: .activated), .waitFor(.activated)])

    static func keysPlan(_ app: ZoomApp, _ fields: [ZoomKeyField]) -> ActionPlan {
        ActionPlan(app: app, effect: .copiesKeys, steps: fields.map { .capture($0) })
    }

    /// Add scopes: open the dialog, then for each missing scope search it and tick it, press Done, and wait for all on the page.
    static func scopesPlan(missing: [String]) -> ActionPlan {
        var steps: [ZoomPlanStep] = [.press(.addScopes, unless: .dialogIs(.addScopes)), .waitFor(.dialogIs(.addScopes))]
        for name in missing {
            steps += [.type(.scopeSearch, name), .waitFor(.hasControl(.scopeCheckbox(name))), .press(.scopeCheckbox(name), unless: .scopeTicked(name))]
        }
        steps += [.press(.scopesDone), .waitFor(.scopesOnPage(ZoomScopes.names))]
        return ActionPlan(app: .hosting, effect: .changesSettings, steps: steps)
    }
}
