// Off-screen render of Settings -> Zoom's top: the "Start uses" line per route. Staged data only.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

@MainActor func shoot<V: View>(_ v: V, _ file: String, dark: Bool, width: CGFloat = 640, height: CGFloat = 560) {
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height), styleMask: [.titled],
                       backing: .buffered, defer: false)
    let host = NSHostingView(rootView: v.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
    win.contentView = host
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.orderBack(nil); spin(0.8)
    host.layoutSubtreeIfNeeded()
    let b = host.bounds
    let rep = host.bitmapImageRepForCachingDisplay(in: b)!
    host.cacheDisplay(in: b, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    print("wrote \(file)")
    win.orderOut(nil)
}

struct Page: View {
    let route: ZoomRoute
    let both: Bool
    let signedIn: Bool
    let ownAppsOpen: Bool
    var note: String? = nil
    @State var sdkID = ""
    @State var sdkSecret = ""
    @State var acct = ""
    @State var s2sID = ""
    @State var s2sSecret = ""
    @State var name = "Sample Host"
    @State var hide = false

    init(route: ZoomRoute, both: Bool, signedIn: Bool, ownApps: Bool, ownAppsOpen: Bool = false, note: String? = nil) {
        self.route = route; self.both = both; self.signedIn = signedIn; self.ownAppsOpen = ownAppsOpen; self.note = note
        if ownApps {
            _sdkID = State(initialValue: "SampleClientID9z7Q"); _sdkSecret = State(initialValue: "secret")
            _acct = State(initialValue: "SampleAccount"); _s2sID = State(initialValue: "SampleS2S")
            _s2sSecret = State(initialValue: "secret")
        }
    }

    var body: some View {
        ZoomPageContent(
            sdkClientID: $sdkID, sdkClientSecret: $sdkSecret, s2sAccountID: $acct, s2sClientID: $s2sID,
            s2sClientSecret: $s2sSecret, displayName: $name, hideSelfView: $hide,
            signIn: ZoomSignInSection(
                signedIn: signedIn ? ZoomSignInInfo(name: "Sample Host", email: "host@example.com") : nil,
                signingIn: false, error: nil, setupNote: nil,
                onSignIn: {}, onCancel: {}, onSignOut: { true }),
            route: ZoomRouteRow(route: route, bothSetUp: both, note: note, onSwitch: {}),
            ownAppsOpen: ownAppsOpen)
    }
}

MainActor.assumeIsolated {
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        shoot(Page(route: .greenroomApp(account: "Sample Host"), both: false, signedIn: true, ownApps: false),
              "1-signed-in-\(tag)", dark: dark)
        shoot(Page(route: .ownApps(sdkClientID: "SampleClientID9z7Q"), both: false, signedIn: false, ownApps: true),
              "2-own-apps-\(tag)", dark: dark)
        shoot(Page(route: .greenroomApp(account: "Sample Host"), both: true, signedIn: true, ownApps: true),
              "3-both-sign-in-wins-\(tag)", dark: dark)
        shoot(Page(route: .ownApps(sdkClientID: "SampleClientID9z7Q"), both: true, signedIn: true, ownApps: true),
              "4-both-own-apps-win-\(tag)", dark: dark)
        shoot(Page(route: .none(.notSetUp), both: false, signedIn: false, ownApps: false),
              "5-nothing-\(tag)", dark: dark)
        let refused = ZoomRefusalRules.settingsNote(route: .greenroomApp(account: "Sample Host"), accountID: "b", refused: ["b"])
        shoot(Page(route: .greenroomApp(account: "Sample Host"), both: false, signedIn: true, ownApps: false,
                   ownAppsOpen: true, note: refused),
              "6-refused-own-apps-open-\(tag)", dark: dark, height: 1100)
    }
}
