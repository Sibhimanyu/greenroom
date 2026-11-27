// Off-screen render of the Greenroom bar (ZoomBarView) in its states at 900pt (the window's minimum) and 1400pt.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

struct Holder: View {
    let step: SetupStep?
    var signedIn: Bool? = true
    var working = false
    var autopilot: String? = nil
    var copied = false
    var failed = false
    @State var tips = true
    var body: some View {
        ZoomBarView(step: step, signedIn: signedIn, working: working, canGoBack: true, canGoForward: false, tipsOn: $tips, loadFailed: failed, copied: copied, autopilot: autopilot)
    }
}

@MainActor func shoot(_ step: SetupStep?, _ file: String, width: CGFloat, dark: Bool, signedIn: Bool? = true, working: Bool = false, autopilot: String? = nil, copied: Bool = false, failed: Bool = false) {
    let v = Holder(step: step, signedIn: signedIn, working: working, autopilot: autopilot, copied: copied, failed: failed).frame(width: width, height: ZoomBarView.height)
        .background(Color(nsColor: .windowBackgroundColor))
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: ZoomBarView.height), styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: v)
    win.contentView = host
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.orderBack(nil); spin(0.6)
    host.layoutSubtreeIfNeeded()
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    print("wrote \(file)")
    win.orderOut(nil)
}

let mid = "AbC_123-xyZ789qrstuvw1", hid = "ZzZ_999-aaBBcc1122"
func st(_ n: Int?, _ title: String, _ why: String, _ cta: CallToAction, app: ZoomApp? = nil, place: ZoomMarketplacePage? = nil, status: String? = nil) -> SetupStep {
    SetupStep(number: n, title: title, app: app, why: why, place: place, status: status, cta: cta)
}
let plan = ActionPlan(app: .meeting, effect: .createsApp, steps: [])
let cases: [(String, SetupStep, Bool?, Bool, String?, Bool)] = [
    ("1-do-this-step", st(1, "Create the meeting app", "It lets Greenroom join and run meetings.", .doThisStep(plan), app: .meeting, place: .createdApps), true, false, nil, false),
    ("2-go-to", st(2, "Turn on Meeting SDK", "Without it Zoom won't let the app join meetings.", .goTo(.general(mid, .embed), "Open Embed"), app: .meeting), true, false, nil, false),
    ("3-working", st(3, "Copy its keys", "Greenroom signs in to meetings with them.", .doThisStep(plan), app: .meeting), true, true, nil, false),
    ("5-fill", st(5, "Fill in Information", "Zoom asks for a contact.", .fill(.infoField(.contactName), "Type your name here. Greenroom fills in the rest."), app: .hosting), true, false, nil, false),
    ("5-blocker", st(5, "Ask your Zoom admin for permission", "Zoom asks for a contact before it turns the app on.", .checkAgain, app: .hosting, status: "Your Zoom account can\u{2019}t edit this app. Ask your Zoom admin to allow \u{2018}Server-to-Server OAuth app: Edit\u{2019}, then Check again."), true, false, nil, false),
    ("signin", st(nil, "Sign in to Zoom", "Greenroom works in your own Zoom account.", .press(.signIn, "Sign in to Zoom. Greenroom carries on after.")), false, false, nil, false),
    ("6-copy-scopes", st(6, "Add the permissions", "These eight let Greenroom create, list, start and end meetings.", .goTo(.s2s(hid, .scopes), "Open Scopes"), app: .hosting), true, false, nil, false),
    ("6-copied", st(6, "Add the permissions", "These eight let Greenroom create, list, start and end meetings.", .goTo(.s2s(hid, .scopes), "Open Scopes"), app: .hosting), true, false, nil, true),
    ("done", st(nil, "Zoom is set up", "Makes sure both apps really work.", .backToGreenroom), true, false, nil, false),
    ("checking", st(nil, "Check your setup", "Makes sure both apps really work.", .wait("Checking\u{2026}")), true, false, nil, false),
    ("autopilot", st(4, "Create the hosting app", "It lets Greenroom create and start your meetings as host.", .doThisStep(plan), app: .hosting), true, false, "Step 4 of 8 \u{00B7} Create the hosting app\u{2026}", false),
    ("press-instruction", st(1, "Create the meeting app", "It lets Greenroom join and run meetings.", .press(.appRow(0), "Use this app"), app: .meeting), true, false, nil, false),
    ("long-title-6", st(6, "Add the permissions", "x", .doThisStep(plan), app: .hosting), true, false, nil, false),
]
MainActor.assumeIsolated {
  for dark in [false, true] {
      for width in [900.0, 1400.0] {
          for c in cases {
              if width == 1400, !["1-do-this-step", "5-blocker", "autopilot"].contains(c.0) { continue }
              shoot(c.1, "bar-\(c.0)-\(Int(width))-\(dark ? "dark" : "light")", width: width, dark: dark, signedIn: c.2, working: c.3, autopilot: c.4, copied: c.5)
          }
      }
  }
  shoot(cases[0].1, "bar-load-failed-900-light", width: 900, dark: false, failed: true)
}
