// Off-screen render of the Zoom window's coach (ZoomCoachScript, a renderer of a CoachDrawing) on a mock Zoom page
// (scripts/render/actor-mocks/created-apps.html). The real script runs in a WKWebView in a far-off-screen window:
// a ring around a control with the card, a card alone, a card beside an open dialog; light and dark. Asserts that
// the card's words come only from the CoachDrawing JSON (never from the page) and that the card's buttons post
// 'act' and 'hide' to window.webkit.messageHandlers.coach. Exits 1 on a failed assertion. Nothing is opened or focused.
import SwiftUI
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let mockDir = ProcessInfo.processInfo.environment["ACTOR_MOCKS"] ?? "scripts/render/actor-mocks"
func mock(_ name: String) -> String { try! String(contentsOfFile: "\(mockDir)/\(name).html", encoding: .utf8) }
let markURI: String? = {
    let path = ProcessInfo.processInfo.environment["COACH_MARK"] ?? "Branding/greenroom-mark/png/App-icon-64.png"
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return "data:image/png;base64," + d.base64EncodedString()
}()
/// A window macOS never drags back on screen (a titled one at (-4000,-4000) is constrained onto the display).
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func hex(_ c: Color) -> String {
    let n = NSColor(c).usingColorSpace(.sRGB)!
    return String(format: "#%02X%02X%02X", Int((n.redComponent * 255).rounded()), Int((n.greenComponent * 255).rounded()), Int((n.blueComponent * 255).rounded()))
}
let ringColor = hex(Brand.green), fillColor = hex(Brand.buttonFill)
var failures = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }

final class Messages: NSObject, WKScriptMessageHandler {
    var got: [String] = []
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { got.append("\(m.body)") }
}

@MainActor func eval(_ web: WKWebView, _ js: String) -> Any? {
    var result: Any?
    var done = false
    web.evaluateJavaScript(js, in: nil, in: .defaultClient) { r in
        switch r { case .success(let v): result = v; case .failure(let e): print("script error: \(e)") }
        done = true
    }
    while !done { spin(0.05) }
    return result
}

/// Records the coach's closed shadow root so the harness can read the card's text.
let spyRoots = "(function(){var o=Element.prototype.attachShadow;Element.prototype.attachShadow=function(i){var r=o.call(this,i);(window.__roots=window.__roots||[]).push(r);return r;};})();"
let cardText = "(function(){var r=window.__roots&&window.__roots[window.__roots.length-1];if(!r)return null;var c=r.querySelector('.card');if(!c||c.style.display==='none')return null;return JSON.stringify({count:r.querySelector('.count').textContent,title:r.querySelector('.title').textContent,why:r.querySelector('.why').textContent,status:r.querySelector('.status').style.display==='none'?null:r.querySelector('.status').textContent,button:r.querySelector('.do').style.display==='none'?null:r.querySelector('.do').textContent,spot:r.querySelector('.spot').style.display!=='none'});})()"
let click = { (cls: String) in "(function(){var r=window.__roots[window.__roots.length-1];r.querySelector('.\(cls)').click();return 'ok';})()" }

@MainActor func shoot(_ drawing: CoachDrawing, file: String, dark: Bool, openDialog: String? = nil, expectRing: Bool, width: CGFloat = 1000, height: CGFloat = 620) {
    let handler = Messages()
    let config = WKWebViewConfiguration()
    config.userContentController.add(handler, contentWorld: .defaultClient, name: "coach")
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: config)
    let win = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = web
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.hasShadow = false
    win.orderBack(nil)
    web.loadHTMLString(mock("created-apps"), baseURL: URL(string: "https://marketplace.zoom.us/user/build"))
    spin(1.0)
    if let d = openDialog { _ = eval(web, "document.getElementById('\(d)').style.display='block';") }
    _ = eval(web, spyRoots)
    _ = eval(web, ZoomCoachScript.source)
    let status = eval(web, ZoomCoachScript.call(ZoomCoachScript.json(drawing), ring: ringColor, mark: markURI, fill: fillColor))
    check(status as? String == "drawn", "\(file): coach drawn (\(status as? String ?? "?"))")
    spin(0.8)

    // The card's words are the drawing's, and only the drawing's.
    if let json = eval(web, cardText) as? String, let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
        let wantCount = drawing.counter.isEmpty ? "" : " \u{00B7} " + drawing.counter
        check(o["count"] as? String == wantCount && o["title"] as? String == drawing.title && o["why"] as? String == drawing.why
              && o["status"] as? String == drawing.status && o["button"] as? String == drawing.button,
              "\(file): card text equals the CoachDrawing exactly")
        check((o["spot"] as? Bool) == expectRing, "\(file): ring \(expectRing ? "drawn around the control" : "not drawn")")
    } else { check(false, "\(file): card found") }

    if drawing.button != nil {
        _ = eval(web, click("do")); spin(0.1)
        check(handler.got == ["act"], "\(file): the card button posts 'act' (\(handler.got))")
    }
    var snap: NSImage?
    var got = false
    web.takeSnapshot(with: nil) { image, _ in snap = image; got = true }
    while !got { spin(0.05) }
    if let tiff = snap?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    }
    _ = eval(web, click("hide")); spin(0.1)
    check(handler.got.last == "hide", "\(file): Hide tips posts 'hide'")
    check(eval(web, "window.__roots[window.__roots.length-1].host.isConnected") as? Bool == false, "\(file): Hide tips removes the coach")
    win.orderOut(nil)
}

MainActor.assumeIsolated {
    let plusUse = CoachDrawing(control: .plus, counter: "Step 1 of 8", title: "Create the meeting app", why: "It lets Greenroom join and run meetings.",
                               status: "Press the + button, then Build app.", button: nil)
    let ringButton = CoachDrawing(control: .plus, counter: "Step 4 of 8", title: "Create the hosting app", why: "It lets Greenroom create and start your meetings as host.",
                                  status: nil, button: "Do this step")
    let alone = CoachDrawing(control: nil, counter: "Step 2 of 8", title: "Turn on Meeting SDK", why: "Without it Zoom won't let the app join meetings.",
                             status: nil, button: "Open Embed")
    let blocker = CoachDrawing(control: nil, counter: "Step 5 of 8", title: "Ask your Zoom admin for permission", why: "Zoom asks for a contact before it turns the app on.",
                               status: "Your Zoom account can\u{2019}t edit this app. Ask your Zoom admin to allow \u{2018}Server-to-Server OAuth app: Edit\u{2019} (User Management \u{2192} Roles \u{2192} Role Settings \u{2192} Advanced features), then Check again.", button: "Check again")
    let inDialog = CoachDrawing(control: .create, counter: "Step 1 of 8", title: "Create the meeting app", why: "It lets Greenroom join and run meetings.",
                                status: "Press Create.", button: nil)
    let finalCard = CoachDrawing(control: nil, counter: "", title: "Zoom is set up", why: "Makes sure both apps really work.", status: nil, button: "Back to Greenroom")
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        shoot(plusUse, file: "1-ring-plus-status-\(tag)", dark: dark, expectRing: true)
        shoot(ringButton, file: "2-ring-plus-button-\(tag)", dark: dark, expectRing: true)
        shoot(alone, file: "3-card-alone-\(tag)", dark: dark, expectRing: false)
        shoot(blocker, file: "4-card-alone-long-status-\(tag)", dark: dark, expectRing: false)
        shoot(plusUse, file: "5-card-beside-dialog-\(tag)", dark: dark, openDialog: "dlg", expectRing: false)
        shoot(inDialog, file: "6-ring-in-dialog-\(tag)", dark: dark, openDialog: "dlg", expectRing: true)
        shoot(finalCard, file: "7-card-no-counter-\(tag)", dark: dark, expectRing: false)
    }
    print(failures == 0 ? "zoom-coach: all passed" : "zoom-coach: \(failures) FAILED")
    if failures > 0 { exit(1) }
}
