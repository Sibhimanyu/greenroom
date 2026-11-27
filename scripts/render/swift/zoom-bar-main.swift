// Off-screen render of the Greenroom bar (ZoomBarView) in its states at 900pt (the window's minimum) and 1400pt.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

struct Holder: View {
    let bar: ZoomBar
    var copied = false
    var failed = false
    @State var tips = true
    var body: some View {
        ZoomBarView(bar: bar, canGoBack: true, canGoForward: false, tipsOn: $tips, loadFailed: failed, copied: copied)
    }
}

@MainActor func shoot(_ bar: ZoomBar, _ file: String, width: CGFloat, dark: Bool, copied: Bool = false, failed: Bool = false) {
    let v = Holder(bar: bar, copied: copied, failed: failed).frame(width: width, height: ZoomBarView.height)
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
func make(_ part: ZoomGuidePart, _ page: ZoomMarketplacePage?, meeting: Bool = false, hosting: Bool = false,
          signIn: ZoomSignInState = .signedIn, ids: ZoomAppIDs = ZoomAppIDs()) -> ZoomBar {
    ZoomBarRules.bar(ZoomBarFacts(part: part, page: page, ids: ids, meetingComplete: meeting, hostingComplete: hosting, signIn: signIn))
}

MainActor.assumeIsolated {
    for width: CGFloat in [900, 1400] {
        for dark in [false, true] {
            let tag = "\(Int(width))-\(dark ? "dark" : "light")"
            shoot(make(.hostingApp, .s2s(hid, .scopes)), "1-scopes-copy-scopes-\(tag)", width: width, dark: dark)
            shoot(make(.hostingApp, .s2s(hid, .scopes)), "2-scopes-copied-\(tag)", width: width, dark: dark, copied: true)
            shoot(make(.hostingApp, .s2s(hid, .credentials), hosting: true), "3-set-up-next-meeting-app-\(tag)", width: width, dark: dark)
            shoot(make(.meetingApp, .general(mid, .information), meeting: true, hosting: true), "4-both-done-back-to-greenroom-\(tag)", width: width, dark: dark)
            shoot(make(.hostingApp, .createdApps, signIn: .signedOut), "5-sign-in-\(tag)", width: width, dark: dark)
            // The widest case: every button showing, and a failed load.
            shoot(make(.meetingApp, .general(mid, .information), meeting: true), "6-widest-\(tag)", width: width, dark: dark, failed: true)
        }
    }
}
