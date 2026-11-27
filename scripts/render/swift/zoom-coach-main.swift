// Off-screen render of the Zoom window's coach (ZoomCoachScript) on a static mock of Zoom's
// "What kind of app" page (scripts/render/zoom-coach-page.html). The real script and the real
// card text from ZoomCoachRules run in a WKWebView in a hidden window; nothing is opened or focused.
import SwiftUI
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let htmlPath = ProcessInfo.processInfo.environment["COACH_HTML"] ?? "scripts/render/zoom-coach-page.html"
let html = try! String(contentsOfFile: htmlPath, encoding: .utf8)
let markURI: String? = {
    let path = ProcessInfo.processInfo.environment["COACH_MARK"] ?? "Branding/greenroom-mark/png/App-icon-64.png"
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return "data:image/png;base64," + d.base64EncodedString()
}()
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

let ringColor: String = {
    let c = NSColor(Brand.green).usingColorSpace(.sRGB)!
    return String(format: "rgb(%d,%d,%d)", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
}()

@MainActor func shoot(part: ZoomGuidePart, dark: Bool, file: String, page: ZoomMarketplacePage = .chooseType("AbC_123-xyZ789qrstuvw1"), needsApp: Bool = false) {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 620))
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = web
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.orderBack(nil)
    web.loadHTMLString(html, baseURL: nil)
    spin(1.0)
    let coach = ZoomCoachRules.coach(part: part, page: page, keysFilled: false, tipsOn: true, needsApp: needsApp)
    var done = false
    web.evaluateJavaScript(ZoomCoachScript.source, in: nil, in: .defaultClient) { r in
        if case .failure(let e) = r { print("source error: \(e)") }
        web.evaluateJavaScript(ZoomCoachScript.call(coach?.json, ring: ringColor, mark: markURI), in: nil, in: .defaultClient) { r in
            if case .failure(let e) = r { print("call error: \(e)") }
            done = true
        }
    }
    while !done { spin(0.05) }
    var probed = false
    web.evaluateJavaScript("document.querySelectorAll('[data-greenroom-coach]').length + ' ' + typeof window.__grCoachSet", in: nil, in: .defaultClient) { r in
        print("probe: \(r)"); probed = true
    }
    while !probed { spin(0.05) }
    spin(0.8)
    var snap: NSImage?
    var got = false
    web.takeSnapshot(with: nil) { image, _ in snap = image; got = true }
    while !got { spin(0.05) }
    if let tiff = snap?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
        print("wrote \(file)")
    }
    win.orderOut(nil)
}

MainActor.assumeIsolated {
    shoot(part: .hostingApp, dark: false, file: "1-coach-hosting-light")
    shoot(part: .hostingApp, dark: true, file: "2-coach-hosting-dark")
    shoot(part: .meetingApp, dark: false, file: "3-coach-meeting-light")
    shoot(part: .hostingApp, dark: true, file: "4-coach-find-my-app-dark", page: .createdApps, needsApp: true)
}
