// Dry run of "Do this step" (ZoomActorScript) against mock Zoom pages in an off-screen WKWebView: each step end to end,
// asserting the mock's final state, that the denied buttons (Regenerate, Delete app, Deactivate) were never pressed,
// and that the coach moves on after a step. Writes PNGs of the coach before and after. Exit code 1 on any failure.
import SwiftUI
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let mockDir = ProcessInfo.processInfo.environment["ACTOR_MOCKS"] ?? "scripts/render/actor-mocks"
let markURI: String? = FileManager.default.contents(atPath: ProcessInfo.processInfo.environment["COACH_MARK"] ?? "")
    .map { "data:image/png;base64," + $0.base64EncodedString() }
var failures = 0
var lastScan: String?
/// A window macOS never drags back on screen (a titled one at (-4000,-4000) is constrained onto the display).
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func check(_ ok: Bool, _ what: String) { print((ok ? "PASS  " : "FAIL  ") + what); if !ok { failures += 1 } }

@MainActor func load(_ name: String, base: String? = nil) -> (WKWebView, NSWindow) {
    var html = try! String(contentsOfFile: "\(mockDir)/\(name).html", encoding: .utf8)
    let json = String(data: try! JSONSerialization.data(withJSONObject: ZoomScopes.names), encoding: .utf8)!
    html = html.replacingOccurrences(of: "__SCOPES__", with: json)
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 620))
    let win = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = web
    win.hasShadow = false
    win.orderBack(nil)
    web.loadHTMLString(html, baseURL: base.flatMap { URL(string: $0) })
    spin(0.8)
    return (web, win)
}

/// `page`: the mock's own world (its globals); the coach and actor run in the client world, like in the app.
@MainActor func js(_ web: WKWebView, _ code: String, page: Bool = true) -> Any? {
    var out: Any?; var done = false
    web.evaluateJavaScript(code, in: nil, in: page ? .page : .defaultClient) { r in
        if case .success(let v) = r { out = v } else if case .failure(let e) = r { print("script error: \(e)") }
        done = true
    }
    while !done { spin(0.05) }
    return out
}

@MainActor func state(_ web: WKWebView) -> [String: Any] {
    let s = js(web, "JSON.stringify(window.__state)") as? String ?? "{}"
    return (try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? [:]
}

@MainActor func run(_ web: WKWebView, _ step: ZoomActorStep, part: ZoomGuidePart) -> ZoomActorResult {
    var out = ZoomActorResult(code: "error"); var done = false
    web.callAsyncJavaScript(ZoomActorScript.body, arguments: ZoomActorScript.arguments(step, part: part), in: nil, in: .defaultClient) { r in
        switch r {
        case .success(let v): if let s = v as? String, let d = try? JSONDecoder().decode(ZoomActorResult.self, from: Data(s.utf8)) { out = d }
        case .failure(let e): print("actor error: \(e)")
        }
        done = true
    }
    while !done { spin(0.05) }
    return out
}

@MainActor func snap(_ web: WKWebView, _ file: String, coach: ZoomCoach?) {
    _ = js(web, ZoomCoachScript.source, page: false)
    _ = js(web, ZoomCoachScript.call(coach?.json, ring: "rgb(95,168,60)", mark: markURI, fill: "rgb(78,140,48)"), page: false)
    spin(0.7)
    var img: NSImage?; var got = false
    web.takeSnapshot(with: nil) { i, _ in img = i; got = true }
    while !got { spin(0.05) }
    if let t = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    }
}

func coachFor(_ part: ZoomGuidePart, _ page: ZoomMarketplacePage, rows: [String]? = nil) -> ZoomCoach? {
    ZoomCoachRules.offeringAction(ZoomCoachRules.coach(part: part, page: page, keysFilled: false, tipsOn: true, appRows: rows), part: part, page: page)
}

let id = "AbC_123-xyZ789qrstuvw1"

MainActor.assumeIsolated {
    print("-- Created apps: + -> Build -> choose the type -> Create")
    for (part, type) in [(ZoomGuidePart.meetingApp, "General app"), (.hostingApp, "Server to server OAuth app")] {
        let (web, win) = load("created-apps")
        snap(web, "1-created-apps-before-\(part == .meetingApp ? "meeting" : "hosting")", coach: coachFor(part, .createdApps, rows: []))
        let r = run(web, .createApp, part: part); let s = state(web)
        check(r.code == "done", "\(part.title): result done (got \(r.code))")
        check(s["plus"] as? Int == 1 && s["build"] as? Int == 1, "\(part.title): pressed + once and Build once")
        check(s["created"] as? String == type, "\(part.title): chose \(type) and pressed Create")
        check(s["cancel"] as? Int == 0 && s["regen"] as? Int == 0 && s["del"] as? Int == 0, "\(part.title): never Cancel, Regenerate or Delete")
        check(r.log?.contains("click create ok") == true, "\(part.title): log lines use allow-list labels (\(r.log ?? []))")
        win.orderOut(nil)
    }
    // The dialog already open: no + or Build pressed.
    do {
        let (web, win) = load("created-apps")
        _ = js(web, "document.getElementById('plus').click(); document.getElementById('build').click();")
        let r = run(web, .createApp, part: .hostingApp); let s = state(web)
        check(r.code == "done" && s["plus"] as? Int == 1 && s["build"] as? Int == 1, "dialog already open: + and Build not pressed again")
        check(s["created"] as? String == "Server to server OAuth app", "dialog already open: type chosen and Create pressed")
        win.orderOut(nil)
    }

    print("-- Scopes: add the missing ones")
    do {
        let (web, win) = load("scopes")
        snap(web, "2-scopes-before", coach: coachFor(.hostingApp, .s2s(id, .scopes)))
        let r = run(web, .addScopes, part: .hostingApp); let s = state(web)
        check(r.code == "done", "scopes: result done (got \(r.code))")
        check(r.added == 6 && r.total == 6 && (r.notFound ?? []).isEmpty, "scopes: added 6 of 6 missing (got \(r.added ?? -1) of \(r.total ?? -1))")
        let saved = Set(s["saved"] as? [String] ?? [])
        check(Set(ZoomScopes.names).isSubset(of: saved), "scopes: all eight are on the page")
        check((s["ticked"] as? [String])?.count == 6, "scopes: skipped the two already present")
        check(s["otherTicked"] as? Int == 0, "scopes: no other scope ticked")
        check(s["filterEvents"] as? Int ?? 0 >= 6, "scopes: typing reached the page's input handler (React-style, native setter)")
        check(s["regen"] as? Int == 0 && s["del"] as? Int == 0 && s["cancel"] as? Int == 0, "scopes: never Regenerate, Delete app or Cancel")
        check(ZoomActorRules.message(.addScopes, r) == "Added 6 scopes.", "scopes: words: \(ZoomActorRules.message(.addScopes, r))")
        let page = coachFor(.hostingApp, .s2s(id, .scopes))
        snap(web, "3-scopes-after-coach-moves-to-activation", coach: page)
        win.orderOut(nil)
    }
    // A scope the panel never lists: reported, not hidden.
    do {
        let (web, win) = load("scopes")
        _ = js(web, "all = all.filter(function(s){return s !== ALL[3]}); render();")
        let r = run(web, .addScopes, part: .hostingApp)
        check(r.code == "done" && r.notFound == [ZoomScopes.names[3]], "scopes: one unlistable scope is reported by name")
        check(ZoomActorRules.message(.addScopes, r).hasPrefix("Added 5 of 6; couldn\u{2019}t find"), "scopes: words: \(ZoomActorRules.message(.addScopes, r))")
        win.orderOut(nil)
    }
    // Nothing to do.
    do {
        let (web, win) = load("scopes")
        _ = js(web, "st.saved = ALL.slice(); draw();")
        let r = run(web, .addScopes, part: .hostingApp)
        check(r.code == "already" && state(web)["opened"] as? Int == 0, "scopes: all present: the panel is not even opened")
        win.orderOut(nil)
    }
    // No confirm button: stop and say so.
    do {
        let (web, win) = load("scopes")
        _ = js(web, "document.getElementById('done').textContent = 'Close';")
        let r = run(web, .addScopes, part: .hostingApp)
        check(r.code == "no-confirm" && ZoomActorRules.message(.addScopes, r) == "Press Done to save the scopes.", "scopes: no Done/Save/Continue: stops with the plain words")
        win.orderOut(nil)
    }

    print("-- Activation")
    do {
        let (web, win) = load("activation")
        snap(web, "4-activation-before", coach: coachFor(.hostingApp, .s2s(id, .activation)))
        let r = run(web, .activate, part: .hostingApp); let s = state(web)
        check(r.code == "done" && s["activated"] as? Int == 1, "activation: pressed Activate your app, page shows activated (got \(r.code))")
        check(s["deact"] as? Int == 0 && s["regen"] as? Int == 0, "activation: never Deactivate or Regenerate")
        let again = run(web, .activate, part: .hostingApp)
        check(again.code == "already" && state(web)["activated"] as? Int == 1 && state(web)["deact"] as? Int == 0, "activation: a second press does nothing (already) and never Deactivates")
        snap(web, "5-activation-after-coach-moves-to-credentials", coach: coachFor(.hostingApp, .s2s(id, .activation)))
        win.orderOut(nil)
    }

    print("-- Embed: the Meeting SDK switch")
    do {
        let (web, win) = load("embed")
        snap(web, "6-embed-before", coach: coachFor(.meetingApp, .general(id, .embed)))
        let r = run(web, .enableSDK, part: .meetingApp); let s = state(web)
        check(r.code == "done" && s["on"] as? Bool == true && s["toggles"] as? Int == 1, "embed: switch turned on once (got \(r.code))")
        check(s["regen"] as? Int == 0 && s["del"] as? Int == 0, "embed: never Regenerate or Delete app")
        let again = run(web, .enableSDK, part: .meetingApp)
        check(again.code == "already" && state(web)["toggles"] as? Int == 1, "embed: already on: not toggled off")
        snap(web, "7-embed-after-coach-moves-to-basic-information", coach: coachFor(.meetingApp, .general(id, .embed)))
        win.orderOut(nil)
    }

    print("-- Refusals")
    do {
        let (web, win) = load("activation", base: "https://marketplace.zoom.us/develop/apps/AbC_123-xyZ789qrstuvw1/credentials")
        let r = run(web, .activate, part: .hostingApp)
        check(r.code == "refused" && state(web)["activated"] as? Int == 0, "a credentials address is refused: nothing pressed (got \(r.code))")
        win.orderOut(nil)
    }

    print("-- Dialogs: nothing behind an open dialog is pointed at; the name dialog; the part follows the type")
    do {
        let rows = ["server to server oauth", "general app"]
        @MainActor func dialogShot(_ file: String, part: ZoomGuidePart, setup: String, rows: [String] = rows) -> ZoomActorResult? {
            let (web, win) = load("dialogs")
            _ = js(web, setup)
            _ = js(web, "1")
            let coach = coachFor(part, .createdApps, rows: rows)
            snap(web, file, coach: coach)
            // What the dialog scan reports to Swift.
            let scan = js(web, ZoomDialogScript.source, page: false) as? String
            lastScan = scan
            win.orderOut(nil)
            return nil
        }
        _ = dialogShot("8-modal-over-the-app-list", part: .meetingApp, setup: "show('unknown')")
        check(lastScan == "null", "an unknown dialog reports nothing to follow (got \(lastScan ?? "nil"))")
        _ = dialogShot("9-name-dialog-empty", part: .hostingApp, setup: "show('name', 'Create a Server-to-Server OAuth app')")
        check(lastScan?.contains("create a server-to-server oauth app") == true && ZoomCoachRules.partFollowing("create a server-to-server oauth app", nil) == .hostingApp, "name dialog: the part follows its heading (Hosting app)")
        _ = dialogShot("10-name-dialog-filled", part: .hostingApp, setup: "show('name', 'Create a Server-to-Server OAuth app'); fill()")
        _ = dialogShot("11-type-chosen-other-than-the-part", part: .meetingApp, setup: "show('chooser'); pick('Server to server OAuth app')")
        let followed = ZoomCoachRules.partFollowing(lastScan.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["heading"] as? String },
                                                    lastScan.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["chosen"] as? String })
        check(followed == .hostingApp, "type switch: picking Server to server while on the Meeting app moves the part to Hosting (got \(String(describing: followed)))")
        // The coach for the other part then spotlights the matching row inside the dialog.
        _ = dialogShot("12-type-switch-coach-follows", part: .hostingApp, setup: "show('chooser'); pick('Server to server OAuth app')")
    }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
