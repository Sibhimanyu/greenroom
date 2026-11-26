// Off-screen render of Settings -> Zoom: the choice (Sign in with Zoom Coming soon) and the own-apps summary, per route state. Staged data only.
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
    let entry: ZoomSetupEntry
    var note: String? = nil
    @State var prefersSignIn: Bool
    @State var name = "Sample Host"
    @State var hide = false

    /// `sdk`/`s2s`: that app's keys are all in; `sdkHalf`: only the Meeting SDK's Client ID.
    init(prefersSignIn: Bool, signedIn: Bool = false, endpointSet: Bool = true, signingIn: Bool = false,
         sdk: Bool = false, s2s: Bool = false, sdkHalf: Bool = false, note: String? = nil, comingSoon: Bool = true) {
        self.signedIn = signedIn; self.note = note
        ownReady = sdk && s2s; signInReady = signedIn && endpointSet
        _prefersSignIn = State(initialValue: prefersSignIn)
        choice = ZoomRouteChoiceRules.choice(ZoomRouteChoiceFacts(
            route: ZoomRouteFacts(signedIn: signedIn, accountName: "Sample Host", accountEmail: "host@example.com",
                                  endpointSet: endpointSet, ownSDKComplete: sdk, ownS2SComplete: s2s,
                                  sdkClientID: "SampleClientID9z7Q", prefersSignIn: prefersSignIn,
                                  signInComingSoon: comingSoon),
            ownSDKStarted: sdk || sdkHalf, ownS2SStarted: s2s, signingIn: signingIn))
        entry = ZoomGuideFlowRules.setupEntry(ZoomGuideFlowFacts(sdkFilled: sdk ? 2 : (sdkHalf ? 1 : 0),
                                                                 s2sFilled: s2s ? 3 : 0, check: ownReady ? .passed : .notRun))
    }

    var body: some View {
        ZoomPageContent(
            displayName: $name, hideSelfView: $hide,
            prefersSignIn: $prefersSignIn, choice: choice,
            signIn: ZoomSignInSection(
                signedIn: signedIn ? ZoomSignInInfo(name: "Sample Host", email: "host@example.com") : nil,
                signingIn: false, error: nil, setupNote: nil,
                check: signedIn ? ZoomSignInCheckRow(lines: signInReady ? signInLines : []) : nil,
                onSignIn: {}, onCancel: {}, onSignOut: { true }, compact: true),
            setupCheck: ZoomSetupCheckRow(lines: ownReady ? setupLines : []),
            setupEntry: entry,
            refusedNote: note)
    }
}

MainActor.assumeIsolated {
    let h: CGFloat = 600
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        // Sign in with Zoom coming soon (the shipped switch).
        shoot(Page(prefersSignIn: false), "1-no-own-apps-\(tag)", dark: dark, height: h)
        shoot(Page(prefersSignIn: false, sdkHalf: true), "2-own-apps-half-set-up-\(tag)", dark: dark, height: h)
        shoot(Page(prefersSignIn: false, sdk: true, s2s: true), "3-own-apps-ready-\(tag)", dark: dark, height: h)
        shoot(Page(prefersSignIn: true, signedIn: true), "4-signed-in-before-no-own-apps-\(tag)", dark: dark, height: h)
        shoot(Page(prefersSignIn: true, signedIn: true, sdk: true, s2s: true),
              "5-signed-in-before-own-apps-ready-\(tag)", dark: dark, height: h)
        // The switch off (after Zoom approves, or the DEBUG override): both ways open.
        shoot(Page(prefersSignIn: true, signedIn: true, comingSoon: false), "6-open-sign-in-chosen-\(tag)", dark: dark, height: h)
        shoot(Page(prefersSignIn: false, signedIn: true, comingSoon: false),
              "7-open-own-apps-chosen-signed-in-\(tag)", dark: dark, height: h)
        let refused = ZoomRefusalRules.settingsNote(route: .greenroomApp(account: "Sample Host"), accountID: "b", refused: ["b"])
        shoot(Page(prefersSignIn: true, signedIn: true, note: refused, comingSoon: false),
              "10-open-sign-in-refused-\(tag)", dark: dark, height: h)
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
    // Check Zoom setup with failures: every line's buttons and the fix bar.
    let ids = ZoomCheckActionContext(sdkClientID: "SampleClientID9z7Q", s2sClientID: "SampleS2Sk3Rw")
    func own(_ id: String, _ title: String, _ status: ZoomCheckStatus, _ detail: String,
             _ problem: ZoomCheckProblem = .nothing) -> ZoomCheckLine {
        ZoomCheckLine(id: id, title: title, status: status, detail: detail,
                      actions: ZoomCheckActionRules.buttons(.ownApps, check: id, status: status, problem: problem, ids: ids))
    }
    func missingScope(_ id: String, _ title: String, _ scope: String) -> ZoomCheckLine {
        own(id, title, .failed, "Missing \(scope). Add it in the Server-to-Server app\u{2019}s Scopes page, save, and check again.",
            .missingScopes([scope]))
    }
    let scopesMissing: [ZoomCheckLine] = [
        own("sdk", "Meeting and chat credentials", .passed, ""),
        own("account", "Hosting credentials and app activation", .passed, ""),
        own("create", "Permission to create meetings", .passed, ""),
        own("list", "Permission to list meetings", .passed, ""),
        own("details", "Permission to read meeting details", .passed, ""),
        missingScope("update", "Permission to edit scheduled meetings", "meeting:update:meeting:admin"),
        missingScope("delete", "Permission to delete scheduled meetings", "meeting:delete:meeting:admin"),
        own("host", "Permission to get the hosting token", .passed, ""),
        own("end", "Permission to end meetings", .passed, ""),
        own("meetings", "Scheduled meetings API", .passed, ""),
        own("hostToken", "Hosting token API", .passed, ""),
    ]
    let skip = "Hosting authentication failed. Fix it, then check again."
    let badKeys: [ZoomCheckLine] = [
        own("sdk", "Meeting and chat credentials", .failed,
            "Zoom rejected the key. Check the General App credentials and that Meeting SDK is enabled.", .badCredentials),
        own("account", "Hosting credentials and app activation", .failed,
            "Couldn\u{2019}t get a Zoom API token: This app is not activated. Check the three hosting values and activate the app in Zoom.", .notActivated),
        own("create", "Permission to create meetings", .skipped, skip),
        own("list", "Permission to list meetings", .skipped, skip),
        own("meetings", "Scheduled meetings API", .skipped, skip),
        own("hostToken", "Hosting token API", .skipped, skip),
    ]
    let offline: [ZoomCheckLine] = [
        own("sdk", "Meeting and chat credentials", .passed, ""),
        own("account", "Hosting credentials and app activation", .failed,
            "The Internet connection appears to be offline. Check the three hosting values and activate the app in Zoom.", .network),
        own("create", "Permission to create meetings", .skipped, skip),
    ]
    let footnote = "Scope checks read Zoom\u{2019}s granted permissions. Creating, joining and ending a real meeting are still tested when you start a meeting."
    let signInBad: [ZoomCheckLine] = [
        ZoomSignInCheckRules.line(.token, .ok("")),
        ZoomSignInCheckRules.line(.profile, .ok("Sample Host \u{00B7} host@example.com")),
        ZoomSignInCheckRules.line(.scopes, .missingScopes(["meeting:update:meeting"])),
        ZoomSignInCheckRules.line(.zak, .failed("The request timed out."), error: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
        ZoomSignInCheckRules.line(.signature, .ok("\u{2026}9z7Q")),
        ZoomSignInCheckRules.line(.create, .atStart),
        ZoomSignInCheckRules.line(.account, .ownerUnknown(account: "Sample Host")),
    ]
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        shoot(ZoomCheckPanel(subject: "Zoom setup", lines: scopesMissing, isRunning: false, footnote: footnote, ids: ids,
                             onAgain: {}, onDone: {}),
              "13-setup-check-missing-scopes-\(tag)", dark: dark, width: 580, height: 640)
        shoot(ZoomCheckPanel(subject: "Zoom setup", lines: badKeys, isRunning: false, footnote: footnote, ids: ids,
                             onAgain: {}, onDone: {}),
              "14-setup-check-bad-keys-\(tag)", dark: dark, width: 580, height: 640)
        shoot(ZoomCheckPanel(subject: "Zoom setup", lines: offline, isRunning: false, footnote: footnote, ids: ids,
                             onAgain: {}, onDone: {}),
              "15-setup-check-offline-\(tag)", dark: dark, width: 580, height: 640)
        shoot(ZoomCheckPanel(subject: "Zoom sign-in", lines: signInBad, isRunning: false,
                             footnote: "Tries what Start needs from your sign-in, in Start\u{2019}s order. No meeting is created or started.",
                             onAgain: {}, onDone: {}),
              "16-sign-in-check-failures-\(tag)", dark: dark, width: 580, height: 640)
    }
}
