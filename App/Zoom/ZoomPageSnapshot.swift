//
//  ZoomPageSnapshot.swift
//  Greenroom
//
//  Everything the setup flow needs to know about a Zoom Marketplace page, as plain data
//  (docs/specs/zoom-setup-flow.md, "ZoomPage"): the address kind, whether the person is
//  signed in, the open dialog and its state, visible menu items, the app list's types,
//  the Meeting SDK switch, the scopes on the page, activation, Information's empty
//  required fields, each key as value / copyable / hidden / absent, and which known
//  controls are present (`ZoomControl`, stable IDs, never labels).
//
//  Key values live in memory only. `redacted()` swaps each for its length and a short
//  non-reversible fingerprint, so a recording shows that Zoom changed a key between pages
//  without ever holding it. Pure: Foundation and CryptoKit only.
//
import Foundation
import CryptoKit

// MARK: - Small vocabularies

/// Which of the person's two apps a thing belongs to; `.other` for anything else.
enum ZoomAppKind: String, Equatable, Hashable, Codable, CaseIterable { case meeting, hosting, other }

/// The choices in Zoom's "What kind of app are you creating" dialog.
enum ZoomAppChoice: String, Equatable, Hashable, Codable, CaseIterable { case general, serverToServer, webhookOnly, other }

/// Zoom's left-nav links and wizard tabs, by what they open.
enum ZoomNavLink: String, Equatable, Hashable, Codable, CaseIterable {
    // A General app's left nav.
    case basicInformation, access, surface, embed, connect, customForm, scopes
    // A Server-to-Server app's tabs.
    case information, appCredentials, feature, activation

    /// The link's visible text (matched case-insensitively, exactly).
    var label: String {
        switch self {
        case .basicInformation: return "Basic information"
        case .access: return "Access"
        case .surface: return "Surface"
        case .embed: return "Embed"
        case .connect: return "Connect"
        case .customForm: return "Custom Form"
        case .scopes: return "Scopes"
        case .information: return "Information"
        case .appCredentials: return "App Credentials"
        case .feature: return "Feature"
        case .activation: return "Activation"
        }
    }
}

/// The five Information fields a Server-to-Server app needs (Basic Information, Developer Contact Information).
enum ZoomInfoField: String, Equatable, Hashable, Codable, CaseIterable {
    case appName, shortDescription, companyName, contactName, contactEmail

    /// The label on Zoom's page (the contact ones sit under "Developer Contact Information").
    var label: String {
        switch self {
        case .appName: return "App Name"
        case .shortDescription: return "Short Description"
        case .companyName: return "Company Name"
        case .contactName: return "Name"
        case .contactEmail: return "Email"
        }
    }
}

/// What one Information field shows; never its text. `error`: empty with Zoom's red border or "This field cannot be empty".
/// `disabled`: Zoom's input is switched off (the account may lack the Server-to-Server edit permission).
enum ZoomInfoState: String, Equatable, Hashable, Codable { case empty, filled, error, disabled }

extension ZoomKeyField {
    /// The row's label on Zoom's pages.
    var label: String {
        switch self {
        case .accountID: return "Account ID"
        case .clientID: return "Client ID"
        case .clientSecret: return "Client Secret"
        }
    }
}

// MARK: - Controls

/// A control the flow may name. IDs are stable strings; one finder (ZoomPageScript) resolves each.
enum ZoomControl: Hashable {
    case plus, buildApp
    case typeRadio(ZoomAppKind)
    case create, cancel, nameField
    case addScopes, scopeSearch
    case scopeCheckbox(String)
    case scopesDone, activate
    case `continue`
    case copy(ZoomKeyField)
    case navLink(ZoomNavLink)
    case appRow(Int)
    case signIn, tryAnotherWay, closeDialog
    /// The Scopes PAGE's own search field and the "click here" in its "Found N matching scopes" line
    /// (distinct from `scopeSearch`, the field inside the Add scopes dialog).
    case pageScopeSearch, pageScopeAddLink
    /// The Meeting SDK switch on a General app's Embed page (live run, 2026-11-27).
    case meetingSDKSwitch
    /// A key's row on a credentials page (hover it to show a hover-only copy control).
    case keyRow(ZoomKeyField)
    case infoField(ZoomInfoField)

    var id: String {
        switch self {
        case .plus: return "plus"
        case .buildApp: return "buildApp"
        case .typeRadio(let a): return "typeRadio.\(a.rawValue)"
        case .create: return "create"
        case .cancel: return "cancel"
        case .nameField: return "nameField"
        case .addScopes: return "addScopes"
        case .scopeSearch: return "scopeSearch"
        case .scopeCheckbox(let s): return "scopeCheckbox:\(s)"
        case .scopesDone: return "scopesDone"
        case .activate: return "activate"
        case .continue: return "continue"
        case .copy(let f): return "copy.\(f.rawValue)"
        case .navLink(let n): return "navLink.\(n.rawValue)"
        case .appRow(let i): return "appRow.\(i)"
        case .signIn: return "signIn"
        case .tryAnotherWay: return "tryAnotherWay"
        case .closeDialog: return "closeDialog"
        case .pageScopeSearch: return "pageScopeSearch"
        case .pageScopeAddLink: return "pageScopeAddLink"
        case .meetingSDKSwitch: return "meetingSDKSwitch"
        case .keyRow(let f): return "keyRow.\(f.rawValue)"
        case .infoField(let f): return "infoField.\(f.rawValue)"
        }
    }

    init?(id: String) {
        func suffix(_ p: String) -> String? { id.hasPrefix(p) ? String(id.dropFirst(p.count)) : nil }
        switch id {
        case "plus": self = .plus
        case "buildApp": self = .buildApp
        case "create": self = .create
        case "cancel": self = .cancel
        case "nameField": self = .nameField
        case "addScopes": self = .addScopes
        case "scopeSearch": self = .scopeSearch
        case "scopesDone": self = .scopesDone
        case "activate": self = .activate
        case "continue": self = .continue
        case "signIn": self = .signIn
        case "tryAnotherWay": self = .tryAnotherWay
        case "closeDialog": self = .closeDialog
        case "pageScopeSearch": self = .pageScopeSearch
        case "pageScopeAddLink": self = .pageScopeAddLink
        case "meetingSDKSwitch": self = .meetingSDKSwitch
        default:
            if let s = suffix("typeRadio."), let a = ZoomAppKind(rawValue: s) { self = .typeRadio(a) }
            else if let s = suffix("scopeCheckbox:"), !s.isEmpty { self = .scopeCheckbox(s) }
            else if let s = suffix("copy."), let f = ZoomKeyField(rawValue: s) { self = .copy(f) }
            else if let s = suffix("keyRow."), let f = ZoomKeyField(rawValue: s) { self = .keyRow(f) }
            else if let s = suffix("navLink."), let n = ZoomNavLink(rawValue: s) { self = .navLink(n) }
            else if let s = suffix("infoField."), let f = ZoomInfoField(rawValue: s) { self = .infoField(f) }
            else if let s = suffix("appRow."), let i = Int(s), i >= 0 { self = .appRow(i) }
            else { return nil }
        }
    }

    /// Every control whose ID has no parameter (the script resolves each by name).
    static let fixedIDs: [String] = ["plus", "buildApp", "create", "cancel", "nameField", "addScopes", "scopeSearch",
                                     "scopesDone", "activate", "continue", "signIn", "tryAnotherWay", "closeDialog",
                                     "pageScopeSearch", "pageScopeAddLink", "meetingSDKSwitch"]
}

extension ZoomControl: Codable {
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = ZoomControl(id: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown control \(s)"))
        }
        self = c
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }
}

// MARK: - Dialog and keys

enum ZoomDialog: Equatable {
    case none
    /// "What kind of app are you creating": each choice and whether it is picked.
    case appType([ZoomAppChoice: Bool])
    /// "Create a General app" / "Create a Server-to-Server OAuth app".
    case name(app: ZoomAppKind, filled: Bool, createEnabled: Bool)
    case addScopes(searchPresent: Bool, ticked: [String])
    case other(heading: String)
}

extension ZoomDialog: Codable {
    /// Enum-keyed dictionaries would encode as arrays; the recording wants objects.
    static func keyed<E: RawRepresentable & Hashable, V>(_ d: [String: V]) -> [E: V] where E.RawValue == String {
        var out: [E: V] = [:]
        for (k, v) in d { if let e = E(rawValue: k) { out[e] = v } }
        return out
    }
    static func named<E: RawRepresentable, V>(_ d: [E: V]) -> [String: V] where E.RawValue == String {
        Dictionary(uniqueKeysWithValues: d.map { ($0.key.rawValue, $0.value) })
    }
    private enum K: String, CodingKey { case kind, choices, app, filled, createEnabled, searchPresent, ticked, heading }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "none": self = .none
        case "appType": self = .appType(Self.keyed(try c.decodeIfPresent([String: Bool].self, forKey: .choices) ?? [:]))
        case "name":
            self = .name(app: try c.decodeIfPresent(ZoomAppKind.self, forKey: .app) ?? .other,
                         filled: try c.decodeIfPresent(Bool.self, forKey: .filled) ?? false,
                         createEnabled: try c.decodeIfPresent(Bool.self, forKey: .createEnabled) ?? false)
        case "addScopes":
            self = .addScopes(searchPresent: try c.decodeIfPresent(Bool.self, forKey: .searchPresent) ?? false,
                              ticked: try c.decodeIfPresent([String].self, forKey: .ticked) ?? [])
        default: self = .other(heading: try c.decodeIfPresent(String.self, forKey: .heading) ?? "")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .none: try c.encode("none", forKey: .kind)
        case .appType(let choices):
            try c.encode("appType", forKey: .kind); try c.encode(Self.named(choices), forKey: .choices)
        case .name(let app, let filled, let enabled):
            try c.encode("name", forKey: .kind); try c.encode(app, forKey: .app)
            try c.encode(filled, forKey: .filled); try c.encode(enabled, forKey: .createEnabled)
        case .addScopes(let search, let ticked):
            try c.encode("addScopes", forKey: .kind); try c.encode(search, forKey: .searchPresent); try c.encode(ticked, forKey: .ticked)
        case .other(let heading):
            try c.encode("other", forKey: .kind); try c.encode(heading, forKey: .heading)
        }
    }
}

/// What the page shows for one key.
enum KeyReading: Equatable {
    /// Readable text (held in memory only).
    case value(String)
    /// Not readable, but a Copy control is showing.
    case copyable
    /// Shown as dots with no visible Copy control (hover-only).
    case hidden
    /// No such row on this page.
    case absent
    /// For recordings: a value's length and a short non-reversible fingerprint.
    case redacted(length: Int, fingerprint: String)
}

extension KeyReading: Codable {
    private enum K: String, CodingKey { case kind, value, length, fingerprint }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "value": self = .value(try c.decode(String.self, forKey: .value))
        case "copyable": self = .copyable
        case "hidden": self = .hidden
        case "redacted":
            self = .redacted(length: try c.decode(Int.self, forKey: .length),
                             fingerprint: try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? "")
        default: self = .absent
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .value(let v): try c.encode("value", forKey: .kind); try c.encode(v, forKey: .value)
        case .copyable: try c.encode("copyable", forKey: .kind)
        case .hidden: try c.encode("hidden", forKey: .kind)
        case .absent: try c.encode("absent", forKey: .kind)
        case .redacted(let n, let f):
            try c.encode("redacted", forKey: .kind); try c.encode(n, forKey: .length); try c.encode(f, forKey: .fingerprint)
        }
    }

    /// First four hex characters of the value's SHA-256: enough to see that a key changed, useless for finding it.
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(2).map { String(format: "%02x", $0) }.joined()
    }

    /// The text, when this reading holds it.
    var text: String? { if case .value(let v) = self { return v } else { return nil } }
}

// MARK: - The address, as data

extension ZoomMarketplacePage: Codable {
    private enum K: String, CodingKey { case kind, id }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        let parts = kind.split(separator: ".").map(String.init)
        switch (parts.first ?? "", parts.count > 1 ? parts[1] : "") {
        case ("createdApps", _): self = .createdApps
        case ("chooseType", _): self = .chooseType(id)
        case ("signIn", _): self = .signIn
        case ("passkey", _): self = .passkey
        case ("s2s", let t):
            let tab: ZoomS2STab
            switch t {
            case "credentials": tab = .credentials
            case "feature": tab = .feature
            case "scopes": tab = .scopes
            case "activation": tab = .activation
            default: tab = .information
            }
            self = .s2s(id, tab)
        case ("general", let t):
            let tab: ZoomGeneralTab
            switch t {
            case "embed": tab = .embed
            case "scopes": tab = .scopes
            case "other": tab = .other
            default: tab = .information
            }
            self = .general(id, tab)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown page \(kind)"))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(kindName, forKey: .kind)
        if let id = appID { try c.encode(id, forKey: .id) }
    }
}

// MARK: - The snapshot

struct ZoomPageSnapshot: Equatable {
    /// Which Marketplace page the address is (nil: not one of ours). Set by Swift from the web view's URL.
    var address: ZoomMarketplacePage?
    /// Header says Sign In (false) or shows an account (true); nil when the page says neither.
    var signedIn: Bool?
    var dialog: ZoomDialog
    /// Visible menu items (the + menu's "Build app" ...), in order.
    var menuItems: [String]
    /// The Created apps list, one entry per row.
    var appList: [ZoomAppKind]
    /// The Embed page's Meeting SDK switch; nil off that page.
    var meetingSDKOn: Bool?
    /// Scope strings shown on the page itself (not inside the Add scopes dialog).
    var scopesOnPage: [String]
    /// The Activation page's state; nil off that page or when it says neither.
    var activated: Bool?
    /// Labels of required Information fields still empty.
    var infoEmptyRequired: [String]
    /// The five Information fields' states (never their text); empty off the Information page.
    var infoFields: [ZoomInfoField: ZoomInfoState]
    /// The Scopes page's "Found N matching scopes you can add" count; nil when that line isn't showing.
    var scopeSearchMatches: Int?
    /// Activation's "can not be activated yet" list (item texts, in order).
    var activationMissing: [String]
    var keys: [ZoomKeyField: KeyReading]
    var controls: Set<ZoomControl>

    init(address: ZoomMarketplacePage? = nil, signedIn: Bool? = nil, dialog: ZoomDialog = .none, menuItems: [String] = [],
         appList: [ZoomAppKind] = [], meetingSDKOn: Bool? = nil, scopesOnPage: [String] = [], activated: Bool? = nil,
         infoEmptyRequired: [String] = [], infoFields: [ZoomInfoField: ZoomInfoState] = [:], scopeSearchMatches: Int? = nil,
         activationMissing: [String] = [], keys: [ZoomKeyField: KeyReading] = [:], controls: Set<ZoomControl> = []) {
        self.address = address; self.signedIn = signedIn; self.dialog = dialog; self.menuItems = menuItems
        self.appList = appList; self.meetingSDKOn = meetingSDKOn; self.scopesOnPage = scopesOnPage; self.activated = activated
        self.infoEmptyRequired = infoEmptyRequired; self.infoFields = infoFields; self.scopeSearchMatches = scopeSearchMatches
        self.activationMissing = activationMissing; self.keys = keys; self.controls = controls
    }

    /// The same snapshot with every key value replaced by its length and fingerprint (for recordings).
    func redacted() -> ZoomPageSnapshot {
        var copy = self
        copy.keys = keys.mapValues { reading in
            if case .value(let v) = reading { return .redacted(length: v.count, fingerprint: KeyReading.fingerprint(v)) }
            return reading
        }
        return copy
    }

    func has(_ control: ZoomControl) -> Bool { controls.contains(control) }

    /// Decodes what `ZoomPageScript` returns; the script cannot know the address, so Swift supplies it.
    static func decode(reading json: String, address: ZoomMarketplacePage?) -> ZoomPageSnapshot? {
        guard let data = json.data(using: .utf8), var s = try? JSONDecoder().decode(ZoomPageSnapshot.self, from: data) else { return nil }
        s.address = address
        return s
    }
}

extension ZoomPageSnapshot: Codable {
    private enum K: String, CodingKey {
        case address, signedIn, dialog, menuItems, appList, meetingSDKOn, scopesOnPage, activated, infoEmptyRequired, infoFields, scopeSearchMatches, activationMissing, keys, controls
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        address = try c.decodeIfPresent(ZoomMarketplacePage.self, forKey: .address)
        signedIn = try c.decodeIfPresent(Bool.self, forKey: .signedIn)
        dialog = try c.decodeIfPresent(ZoomDialog.self, forKey: .dialog) ?? .none
        menuItems = try c.decodeIfPresent([String].self, forKey: .menuItems) ?? []
        appList = try c.decodeIfPresent([ZoomAppKind].self, forKey: .appList) ?? []
        meetingSDKOn = try c.decodeIfPresent(Bool.self, forKey: .meetingSDKOn)
        scopesOnPage = try c.decodeIfPresent([String].self, forKey: .scopesOnPage) ?? []
        activated = try c.decodeIfPresent(Bool.self, forKey: .activated)
        infoEmptyRequired = try c.decodeIfPresent([String].self, forKey: .infoEmptyRequired) ?? []
        infoFields = ZoomDialog.keyed(try c.decodeIfPresent([String: ZoomInfoState].self, forKey: .infoFields) ?? [:])
        scopeSearchMatches = try c.decodeIfPresent(Int.self, forKey: .scopeSearchMatches)
        activationMissing = try c.decodeIfPresent([String].self, forKey: .activationMissing) ?? []
        keys = ZoomDialog.keyed(try c.decodeIfPresent([String: KeyReading].self, forKey: .keys) ?? [:])
        // Unknown control IDs (a newer reader) are skipped, never fatal.
        let ids = try c.decodeIfPresent([String].self, forKey: .controls) ?? []
        controls = Set(ids.compactMap(ZoomControl.init(id:)))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(address, forKey: .address)
        try c.encodeIfPresent(signedIn, forKey: .signedIn)
        try c.encode(dialog, forKey: .dialog)
        try c.encode(menuItems, forKey: .menuItems)
        try c.encode(appList, forKey: .appList)
        try c.encodeIfPresent(meetingSDKOn, forKey: .meetingSDKOn)
        try c.encode(scopesOnPage, forKey: .scopesOnPage)
        try c.encodeIfPresent(activated, forKey: .activated)
        try c.encode(infoEmptyRequired, forKey: .infoEmptyRequired)
        try c.encode(ZoomDialog.named(infoFields), forKey: .infoFields)
        try c.encodeIfPresent(scopeSearchMatches, forKey: .scopeSearchMatches)
        try c.encode(activationMissing, forKey: .activationMissing)
        try c.encode(ZoomDialog.named(keys), forKey: .keys)
        try c.encode(controls.map(\.id).sorted(), forKey: .controls)
    }
}

// MARK: - Recording lines

/// One JSON line per recorded fact (DEBUG recorder writes them; pure so tests cover them).
enum ZoomRecordingLine {
    private static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    private static func encode(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `{"snapshot":{...},"ts":"..."}`; the snapshot is redacted here, so a caller cannot forget.
    static func snapshot(_ s: ZoomPageSnapshot, at date: Date) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = (try? enc.encode(s.redacted())).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "{\"snapshot\":\(body),\"ts\":\"\(iso(date))\"}"
    }

    /// A click: the resolved control ID, else the clicked thing's role and short text (token-like runs scrubbed).
    static func click(control: String?, role: String?, text: String?, at date: Date) -> String {
        var o: [String: Any] = ["event": "click", "ts": iso(date)]
        if let control, !control.isEmpty { o["control"] = scrub(control) }
        else {
            if let role, !role.isEmpty { o["role"] = scrub(String(role.prefix(30))) }
            if let text, !text.isEmpty { o["text"] = scrub(String(text.prefix(40))) }
        }
        return encode(o)
    }

    /// Any run of 16+ letters, digits, `_` or `-` becomes `[token N]`.
    static func scrub(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "[A-Za-z0-9_\\-]{16,}") else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: "[token \(m.range.length)]")
        }
        return out
    }
}
