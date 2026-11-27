// Dry run of the Zoom page reader (ZoomPageScript) against mock Zoom pages in an off-screen WKWebView. Each mock is read in
// every state a person (or the page's own script, driven from here) moves it through, and the ZoomPageSnapshot is asserted.
// Reading must change nothing: the mocks count presses, and the focused element must not move. Exit code 1 on any failure.
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let mockDir = ProcessInfo.processInfo.environment["ACTOR_MOCKS"] ?? "scripts/render/actor-mocks"
let coachDir = ProcessInfo.processInfo.environment["COACH_DIR"] ?? "scripts/render"
var failures = 0
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func check(_ ok: Bool, _ what: String) { print((ok ? "PASS  " : "FAIL  ") + what); if !ok { failures += 1 } }

@MainActor func load(_ file: String, base: String) -> (WKWebView, NSWindow) {
    var html = try! String(contentsOfFile: file, encoding: .utf8)
    let json = String(data: try! JSONSerialization.data(withJSONObject: ZoomScopes.names), encoding: .utf8)!
    html = html.replacingOccurrences(of: "__SCOPES__", with: json)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 620))
    let win = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = web; win.hasShadow = false; win.orderBack(nil)
    web.loadHTMLString(html, baseURL: URL(string: base))
    spin(0.8)
    return (web, win)
}
@MainActor func mock(_ name: String, base: String) -> (WKWebView, NSWindow) { load("\(mockDir)/\(name).html", base: base) }

@MainActor func js(_ web: WKWebView, _ code: String, page: Bool = true) -> Any? {
    var out: Any?; var done = false
    web.evaluateJavaScript(code, in: nil, in: page ? .page : .defaultClient) { r in
        if case .success(let v) = r { out = v } else if case .failure(let e) = r { print("script error: \(e)") }
        done = true
    }
    while !done { spin(0.05) }
    return out
}
/// Runs the reader like the app does (client world) and decodes it with the address Swift knows.
@MainActor func read(_ web: WKWebView, _ base: String) -> ZoomPageSnapshot {
    let text = js(web, ZoomPageScript.source, page: false) as? String ?? "nil"
    guard let s = ZoomPageSnapshot.decode(reading: text, address: ZoomMarketplacePages.page(for: URL(string: base)!)) else {
        print("FAIL  reader answered: \(text.prefix(200))"); failures += 1; return ZoomPageSnapshot()
    }
    return s
}
@MainActor func state(_ web: WKWebView) -> [String: Any] {
    let s = js(web, "JSON.stringify(window.__state)") as? String ?? "{}"
    return (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
}
func summary(_ label: String, _ s: ZoomPageSnapshot) {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let text = String(decoding: (try? enc.encode(s.redacted())) ?? Data(), as: UTF8.self)
    print("  [\(label)] \(text.prefix(420))")
}

let id = "AbC_123-xyZ789qrstuvw1"
let zoom = "https://marketplace.zoom.us"
let created = "\(zoom)/user/build"

MainActor.assumeIsolated {
    print("-- Created apps: the + menu, the type dialog, the name dialog (mock created-apps.html)")
    do {
        let (web, win) = mock("created-apps", base: created)
        var s = read(web, created); summary("rest", s)
        check(s.address == .createdApps && s.dialog == .none && s.menuItems.isEmpty, "rest: no dialog, no menu")
        check(s.has(.plus) && !s.has(.buildApp) && !s.has(.create) && !s.has(.nameField), "rest: + is there; Build app, Create and the name field are not")
        let st = state(web)
        check(st["plus"] as? Int == 0 && st["build"] as? Int == 0, "reading pressed nothing")
        _ = js(web, "document.getElementById('plus').click()")
        s = read(web, created); summary("menu open", s)
        check(s.menuItems == ["Build app"] && s.has(.buildApp), "menu open: Build app listed and resolvable")
        _ = js(web, "document.getElementById('build').click()")
        s = read(web, created); summary("type dialog", s)
        check(s.dialog == .appType([.general: false, .serverToServer: false, .webhookOnly: false]), "type dialog: three choices, none picked (\(s.dialog))")
        check(s.has(.typeRadio(.meeting)) && s.has(.typeRadio(.hosting)) && s.has(.create) && s.has(.cancel) && s.has(.closeDialog) == false, "type dialog: radios, Create, Cancel (no close icon in the mock)")
        _ = js(web, "document.querySelectorAll('input[type=radio]')[1].click()")
        s = read(web, created)
        check(s.dialog == .appType([.general: false, .serverToServer: true, .webhookOnly: false]), "picking Server to server shows it picked")
        _ = js(web, "document.getElementById('create').click()")
        s = read(web, created); summary("name dialog", s)
        check(s.dialog == .name(app: .hosting, filled: false, createEnabled: false), "name dialog: Server-to-Server, empty, Create disabled (\(s.dialog))")
        check(s.has(.nameField) && s.has(.create) && !s.has(.typeRadio(.hosting)), "name dialog: name field and Create resolve; the radios are gone")
        _ = js(web, "var i=document.getElementById('nmi'); i.value='Greenroom Hosting'; i.dispatchEvent(new Event('input',{bubbles:true}));")
        s = read(web, created)
        check(s.dialog == .name(app: .hosting, filled: true, createEnabled: true), "name typed: filled, Create enabled")
        check(js(web, "document.activeElement === document.body || document.activeElement === null") as? Bool == true, "reading moved no focus")
        win.orderOut(nil)
    }
    do {
        let (web, win) = mock("created-apps", base: created)
        _ = js(web, "document.getElementById('plus').click(); document.getElementById('build').click(); document.querySelectorAll('input[type=radio]')[0].click(); document.getElementById('create').click();")
        let s = read(web, created)
        check(s.dialog == .name(app: .meeting, filled: false, createEnabled: false), "General app's name dialog reads as meeting")
        win.orderOut(nil)
    }

    print("-- Created apps list: types per row (zoom-coach-created-apps.html table, dialogs.html divs)")
    do {
        let (web, win) = load("\(coachDir)/zoom-coach-created-apps.html", base: created)
        let s = read(web, created); summary("table", s)
        check(s.appList == [.hosting, .meeting], "table: one Server-to-Server then one General app (\(s.appList))")
        check(s.has(.appRow(0)) && s.has(.appRow(1)) && !s.has(.appRow(2)), "table: appRow 0 and 1 resolve")
        check(s.has(.plus), "table: + found by its label")
        win.orderOut(nil)
    }
    do {
        let (web, win) = mock("dialogs", base: created)
        var s = read(web, created)
        check(s.appList == [.hosting, .meeting], "divs fallback: two rows (\(s.appList))")
        _ = js(web, "show('unknown')")
        s = read(web, created)
        check(s.dialog == .other(heading: "something else entirely") && s.has(.closeDialog), "other dialog: heading kept (\(s.dialog))")
        _ = js(web, "show('name','Create a Server-to-Server OAuth app')")
        s = read(web, created)
        check(s.dialog == .name(app: .hosting, filled: false, createEnabled: false), "name dialog by heading")
        win.orderOut(nil)
    }

    print("-- Passkey page: off Marketplace only Try another way is reported")
    do {
        let base = "https://accounts.google.com/v3/signin/challenge/pk/presend"
        let (web, win) = load("\(coachDir)/zoom-coach-passkey.html", base: base)
        let s = read(web, base); summary("passkey", s)
        check(s.address == .passkey && s.controls == [.tryAnotherWay] && s.dialog == .none && s.keys.isEmpty, "passkey: just tryAnotherWay")
        win.orderOut(nil)
    }

    print("-- Scopes: the page, its own search, the Add scopes dialog (mock scopes-page.html)")
    do {
        let base = "\(zoom)/develop/apps/\(id)/scope"
        let (web, win) = mock("scopes-page", base: base)
        var s = read(web, base); summary("rest", s)
        check(s.address == .s2s(id, .scopes) && s.dialog == .none, "rest: Scopes page, no dialog")
        check(Set(s.scopesOnPage) == Set(ZoomScopes.names.prefix(2)), "rest: the two scopes in the table (\(s.scopesOnPage.count))")
        check(s.has(.addScopes) && s.has(.pageScopeSearch) && !s.has(.scopeSearch) && !s.has(.pageScopeAddLink) && s.scopeSearchMatches == nil, "rest: Add scopes and the page search; no dialog search, no result line")
        _ = js(web, "var p=document.getElementById('ps'); p.value='meeting:delete'; p.dispatchEvent(new Event('input',{bubbles:true}));")
        s = read(web, base); summary("page search typed", s)
        check(s.scopeSearchMatches == 1 && s.has(.pageScopeAddLink), "page search: 'Found 1 matching' counted; click here resolves")
        _ = js(web, "document.getElementById('add').click()")
        s = read(web, base); summary("dialog open", s)
        check(s.dialog == .addScopes(searchPresent: true, ticked: []), "dialog: Add scopes, search present, nothing ticked (\(s.dialog))")
        check(s.has(.scopeSearch) && s.has(.scopesDone) && s.has(.pageScopeSearch) && !s.has(.addScopes), "dialog: its search and Done; the page search is still its own control")
        let eight = Set(ZoomScopes.names.map { ZoomControl.scopeCheckbox($0) })
        check(eight.isSubset(of: s.controls), "dialog: a checkbox for each of the eight scopes")
        _ = js(web, "var r=document.querySelector('#list div[role=button][data-s=\"\(ZoomScopes.names[3])\"]'); r.querySelector('input').click();")
        s = read(web, base)
        check(s.dialog == .addScopes(searchPresent: true, ticked: [ZoomScopes.names[3]]), "one ticked shows its scope string")
        check(js(web, "window.__state.filterEvents") as? Int == 0, "the page's search handler never ran because of the reader")
        win.orderOut(nil)
    }

    print("-- Meeting SDK (embed.html)")
    do {
        let base = "\(zoom)/develop/applications/\(id)/features/sdk"
        let (web, win) = mock("embed", base: base)
        var s = read(web, base); summary("off", s)
        check(s.address == .general(id, .embed) && s.meetingSDKOn == false && s.has(.navLink(.embed)), "embed: switch off, Embed link present")
        check((state(web)["toggles"] as? Int) == 0, "reading did not toggle it")
        _ = js(web, "document.getElementById('sw').click()")
        s = read(web, base)
        check(s.meetingSDKOn == true, "embed: switch on after the person turns it on")
        win.orderOut(nil)
    }

    print("-- Activation (activation.html, activation-blocked.html)")
    do {
        let base = "\(zoom)/develop/apps/\(id)/activation"
        var (web, win) = mock("activation", base: base)
        var s = read(web, base); summary("not activated", s)
        check(s.activated == false && s.has(.activate) && s.activationMissing.isEmpty, "activation: not activated, Activate present")
        _ = js(web, "document.getElementById('act').click()")
        s = read(web, base)
        check(s.activated == true && !s.has(.activate), "activation: activated after the person presses it")
        win.orderOut(nil)
        (web, win) = mock("activation-blocked", base: base)
        s = read(web, base); summary("blocked", s)
        check(s.activationMissing == ["Developer contact name", "Developer contact email", "Company name"], "blocked: the three missing items in order (\(s.activationMissing))")
        check(s.activated == false, "blocked: not activated")
        win.orderOut(nil)
    }

    print("-- Information (information-s2s.html, information.html)")
    do {
        let base = "\(zoom)/develop/apps/\(id)/information"
        var (web, win) = mock("information-s2s", base: base)
        let s = read(web, base); summary("info", s)
        check(s.infoFields == [.appName: .filled, .shortDescription: .error, .companyName: .empty, .contactName: .empty, .contactEmail: .filled],
              "info: five fields by state, never their text (\(s.infoFields))")
        check(ZoomInfoField.allCases.allSatisfy { s.has(.infoField($0)) } && s.has(.continue), "info: every field resolves; Continue present")
        check(Set(s.infoEmptyRequired) == ["Short Description", "Company Name", "Name"], "info: empty required labels (\(s.infoEmptyRequired))")
        win.orderOut(nil)
        (web, win) = mock("information", base: base)
        let t = read(web, base)
        check(t.infoEmptyRequired == ["App name", "Company name"] && t.has(.continue), "info (plain mock): two empty required fields")
        win.orderOut(nil)
    }

    print("-- Keys: S2S credentials, the General app card")
    do {
        let base = "\(zoom)/develop/apps/\(id)/credentials"
        let (web, win) = mock("s2s-credentials", base: base)
        var s = read(web, base); summary("s2s", s)
        check(s.keys[.accountID]?.text == "AcctAAAAAAAAAAAAAAAAAA" && s.keys[.clientID]?.text == "ClientBBBBBBBBBBBBBBB"
              && s.keys[.clientSecret]?.text == "SecretCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "s2s: all three values read from the read-only inputs")
        check(s.has(.copy(.accountID)) && s.has(.copy(.clientID)) && s.has(.copy(.clientSecret)), "s2s: three Copy buttons resolve")
        let printed = String(decoding: (try? JSONEncoder().encode(s.redacted())) ?? Data(), as: UTF8.self)
        check(!printed.contains("SecretCCC") && printed.contains("\"fingerprint\""), "s2s: the redacted snapshot holds no value, only length and fingerprint")
        _ = js(web, "blank('s')")
        s = read(web, base)
        check(s.keys[.clientSecret] == .copyable && s.keys[.clientID]?.text != nil, "s2s: a secret that cannot be read is copyable (Copy showing)")
        check((state(web)["copied"] as? [Any])?.count == 0, "reading pressed no Copy")
        win.orderOut(nil)
    }
    do {
        let base = "\(zoom)/develop/applications/\(id)/information"
        let (web, win) = mock("general-card", base: base)
        var s = read(web, base); summary("general", s)
        check(s.keys[.clientID]?.text == "209M70PLQb2LycAbCdEf1" && s.keys[.clientSecret] == .hidden && s.keys[.accountID] == .absent,
              "general: Client ID as plain text, secret hidden, no Account ID")
        check(!s.has(.copy(.clientSecret)), "general: no Copy until hover")
        _ = js(web, "document.getElementById('rs').dispatchEvent(new MouseEvent('mouseover',{bubbles:true}))")
        s = read(web, base)
        check(s.keys[.clientSecret] == .copyable && s.has(.copy(.clientSecret)), "general: after a hover the secret is copyable")
        check((state(web)["copied"] as? Int) == 0 && (state(web)["view"] as? Int) == 0, "general: reading pressed neither Copy nor View")
        win.orderOut(nil)
    }
    do {
        // Keys are read on credentials pages only: the same markup on another path reports none.
        let base = "\(zoom)/develop/apps/\(id)/activation"
        let (web, win) = mock("s2s-credentials", base: base)
        let s = read(web, base)
        check(s.keys.isEmpty, "keys are not read off the credentials pages")
        win.orderOut(nil)
    }
}
print(failures == 0 ? "zoom-page: all passed" : "zoom-page: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
