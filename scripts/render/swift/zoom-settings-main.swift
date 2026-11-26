// Off-screen render of Settings -> Zoom's top: the choice and the chosen way's section, per route state. Staged data only.
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

/// Sample check results: every check passed, so the row reads "N of N checks passed".
func passed(_ titles: [String]) -> [ZoomCheckLine] {
    titles.enumerated().map { ZoomCheckLine(id: "\($0.offset)", title: $0.element, status: .passed, detail: "") }
}
let setupLines = passed(Array(repeating: "check", count: 11))
let signInLines = passed(Array(repeating: "check", count: 6))

struct Page: View {
    let choice: ZoomRouteChoice
    let signedIn: Bool
    /// Sample results only where the sample setup would pass them.
    let ownReady: Bool
    let signInReady: Bool
    var note: String? = nil
    @State var prefersSignIn: Bool
    @State var sdkID = ""
    @State var sdkSecret = ""
    @State var acct = ""
    @State var s2sID = ""
    @State var s2sSecret = ""
    @State var name = "Sample Host"
    @State var hide = false

    /// `sdk`/`s2s`: that app's keys are all in; `sdkHalf`: only the Meeting SDK's Client ID.
    init(prefersSignIn: Bool, signedIn: Bool = false, endpointSet: Bool = true, signingIn: Bool = false,
         sdk: Bool = false, s2s: Bool = false, sdkHalf: Bool = false, note: String? = nil) {
        self.signedIn = signedIn; self.note = note
        ownReady = sdk && s2s; signInReady = signedIn && endpointSet
        _prefersSignIn = State(initialValue: prefersSignIn)
        if sdk || sdkHalf { _sdkID = State(initialValue: "SampleClientID9z7Q") }
        if sdk { _sdkSecret = State(initialValue: "secret") }
        if s2s {
            _acct = State(initialValue: "SampleAccount"); _s2sID = State(initialValue: "SampleS2S")
            _s2sSecret = State(initialValue: "secret")
        }
        choice = ZoomRouteChoiceRules.choice(ZoomRouteChoiceFacts(
            route: ZoomRouteFacts(signedIn: signedIn, accountName: "Sample Host", accountEmail: "host@example.com",
                                  endpointSet: endpointSet, ownSDKComplete: sdk, ownS2SComplete: s2s,
                                  sdkClientID: "SampleClientID9z7Q", prefersSignIn: prefersSignIn),
            ownSDKStarted: sdk || sdkHalf, ownS2SStarted: s2s, signingIn: signingIn))
    }

    var body: some View {
        ZoomPageContent(
            sdkClientID: $sdkID, sdkClientSecret: $sdkSecret, s2sAccountID: $acct, s2sClientID: $s2sID,
            s2sClientSecret: $s2sSecret, displayName: $name, hideSelfView: $hide,
            prefersSignIn: $prefersSignIn, choice: choice,
            signIn: ZoomSignInSection(
                signedIn: signedIn ? ZoomSignInInfo(name: "Sample Host", email: "host@example.com") : nil,
                signingIn: false, error: nil, setupNote: nil,
                check: signedIn ? ZoomSignInCheckRow(lines: signInReady ? signInLines : []) : nil,
                onSignIn: {}, onCancel: {}, onSignOut: { true }, compact: true),
            setupCheck: ZoomSetupCheckRow(lines: ownReady ? setupLines : []),
            refusedNote: note)
    }
}

MainActor.assumeIsolated {
    let tall: CGFloat = 1180, short: CGFloat = 600
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        shoot(Page(prefersSignIn: false, signedIn: true, sdk: true, s2s: true),
              "1-both-own-apps-in-use-\(tag)", dark: dark, height: tall)
        shoot(Page(prefersSignIn: true, signedIn: true, sdk: true, s2s: true),
              "2-both-sign-in-in-use-\(tag)", dark: dark, height: short)
        shoot(Page(prefersSignIn: true, signedIn: true),
              "3-only-sign-in-\(tag)", dark: dark, height: short)
        shoot(Page(prefersSignIn: false, sdk: true, s2s: true),
              "4-only-own-apps-\(tag)", dark: dark, height: tall)
        shoot(Page(prefersSignIn: false),
              "5-neither-own-apps-chosen-\(tag)", dark: dark, height: tall)
        shoot(Page(prefersSignIn: true),
              "6-neither-sign-in-chosen-\(tag)", dark: dark, height: short)
        shoot(Page(prefersSignIn: false, signedIn: true),
              "7-only-sign-in-but-own-apps-chosen-\(tag)", dark: dark, height: tall)
        shoot(Page(prefersSignIn: false, sdk: true),
              "8-own-apps-half-filled-\(tag)", dark: dark, height: tall)
        shoot(Page(prefersSignIn: true, signedIn: true, endpointSet: false),
              "9-sign-in-not-finished-\(tag)", dark: dark, height: short)
        let refused = ZoomRefusalRules.settingsNote(route: .greenroomApp(account: "Sample Host"), accountID: "b", refused: ["b"])
        shoot(Page(prefersSignIn: true, signedIn: true, note: refused),
              "10-sign-in-refused-\(tag)", dark: dark, height: short)
    }
    // The sign-in check: the shared button row and results panel, every step outcome kind.
    let lines: [ZoomCheckLine] = [
        ZoomSignInCheckRules.line(.token, .ok("")),
        ZoomSignInCheckRules.line(.profile, .ok("Sample Host \u{00B7} host@example.com")),
        ZoomSignInCheckRules.line(.scopes, .ok("")),
        ZoomSignInCheckRules.line(.zak, .ok("")),
        ZoomSignInCheckRules.line(.signature, .ok("\u{2026}9z7Q")),
        ZoomSignInCheckRules.line(.create, .atStart),
        ZoomSignInCheckRules.line(.account, .refused(account: "Sample Host")),
    ]
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        shoot(ZoomCheckPanel(subject: "Zoom sign-in", lines: lines, isRunning: false,
                             footnote: "Tries what Start needs from your sign-in, in Start\u{2019}s order. No meeting is created or started.",
                             onAgain: {}, onDone: {}),
              "11-sign-in-check-\(tag)", dark: dark, width: 580, height: 640)
        shoot(ZoomCheckButtonRow(title: "Check sign-in", lines: lines, isRunning: false, onCheck: {}, onView: {}).padding(20),
              "12-sign-in-check-row-\(tag)", dark: dark, width: 580, height: 80)
    }
}
