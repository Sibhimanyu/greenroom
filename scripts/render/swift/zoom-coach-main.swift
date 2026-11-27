// Off-screen render of the Zoom window's coach (ZoomCoachScript) on static mocks of Zoom's pages
// (scripts/render/zoom-coach*.html). The real scripts and the real card text from ZoomCoachRules run in a
// WKWebView in a hidden window; the Created apps mocks go through the real row scan. Nothing is opened or focused.
import SwiftUI
import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let mockDir = ProcessInfo.processInfo.environment["COACH_DIR"] ?? "scripts/render"
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

let ringColor: String = {
    let c = NSColor(Brand.green).usingColorSpace(.sRGB)!
    return String(format: "rgb(%d,%d,%d)", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
}()

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

@MainActor func shoot(html: String, part: ZoomGuidePart, page: ZoomMarketplacePage, dark: Bool, file: String, needsApp: Bool = false,
                      width: CGFloat = 1000, height: CGFloat = 620) {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    let win = OffscreenWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = web
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.hasShadow = false
    win.orderBack(nil)
    web.loadHTMLString(mock(html), baseURL: nil)
    spin(1.0)
    var rows: [String]? = nil
    if page == .createdApps {
        if let json = eval(web, ZoomAppListScript.source) as? String, let data = json.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rows = list.compactMap { $0["typeText"] as? String }
        }
        print("scan rows: \(rows ?? [])")
    }
    let coach = ZoomCoachRules.coach(part: part, page: page, keysFilled: false, tipsOn: true, needsApp: needsApp, appRows: rows)
    _ = eval(web, ZoomCoachScript.source)
    let status = eval(web, ZoomCoachScript.call(coach?.json, ring: ringColor, mark: markURI))
    print("\(file): coach \(status as? String ?? "?")")
    spin(0.8)
    var snap: NSImage?
    var got = false
    web.takeSnapshot(with: nil) { image, _ in snap = image; got = true }
    while !got { spin(0.05) }
    if let tiff = snap?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    }
    win.orderOut(nil)
}

MainActor.assumeIsolated {
    let choose = ZoomMarketplacePage.chooseType("AbC_123-xyZ789qrstuvw1")
    shoot(html: "zoom-coach-page", part: .hostingApp, page: choose, dark: false, file: "1-coach-hosting-light")
    shoot(html: "zoom-coach-page", part: .hostingApp, page: choose, dark: true, file: "2-coach-hosting-dark")
    shoot(html: "zoom-coach-page", part: .meetingApp, page: choose, dark: false, file: "3-coach-meeting-light")
    // Created apps: the real row scan decides.
    shoot(html: "zoom-coach-created-apps", part: .meetingApp, page: .createdApps, dark: false, file: "4-created-apps-meeting-light")
    shoot(html: "zoom-coach-created-apps", part: .hostingApp, page: .createdApps, dark: false, file: "5-created-apps-hosting-light")
    shoot(html: "zoom-coach-created-apps", part: .hostingApp, page: .createdApps, dark: true, file: "6-created-apps-hosting-dark")
    shoot(html: "zoom-coach-no-match", part: .meetingApp, page: .createdApps, dark: false, file: "7-created-apps-no-match-light")
    shoot(html: "zoom-coach-no-match", part: .hostingApp, page: .createdApps, dark: true, file: "8-created-apps-no-match-dark")
    // Passkeys cannot work in this window.
    shoot(html: "zoom-coach-passkey", part: .hostingApp, page: .passkey, dark: false, file: "9-passkey-light")
    shoot(html: "zoom-coach-passkey", part: .hostingApp, page: .passkey, dark: true, file: "10-passkey-dark")
}
