// Off-screen render of Settings -> YouTube and the upload sheet, per account state. Staged data only.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

@MainActor func shoot<V: View>(_ v: V, _ file: String, dark: Bool, width: CGFloat, height: CGFloat) {
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height), styleMask: [.titled],
                       backing: .buffered, defer: false)
    let host = NSHostingView(rootView: v.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor)))
    win.contentView = host
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.orderBack(nil); spin(1.2)
    host.layoutSubtreeIfNeeded()
    let b = host.bounds
    let rep = host.bitmapImageRepForCachingDisplay(in: b)!
    host.cacheDisplay(in: b, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    print("wrote \(file)")
    win.orderOut(nil)
}

/// A made-up channel picture: a flat disc with initials, written next to the renders.
func sampleAvatar() -> String {
    let size = NSSize(width: 88, height: 88)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor(srgbRed: 0.18, green: 0.38, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = NSAttributedString(string: "SC", attributes: [
            .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.white])
        let t = text.size()
        text.draw(at: NSPoint(x: (rect.width - t.width) / 2, y: (rect.height - t.height) / 2))
        return true
    }
    let path = "\(outDir)/sample-avatar.png"
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    return URL(fileURLWithPath: path).absoluteString
}

let shared = "123-sample.apps.googleusercontent.com"
let placeholder = "PLACEHOLDER.apps.googleusercontent.com"

struct Settings: View {
    var connected = false
    var channel: YouTubeChannel? = nil
    var tokenApp: YouTubeGoogleApp = .shared
    var sharedID = shared
    var signingIn = false
    var status = ""
    @State var mode: YouTubeUploadMode = .ask
    @State var privacy = "unlisted"
    @State var kids: Bool? = false
    @State var ownApp = false
    var clientID = ""
    var secret = ""

    init(connected: Bool = false, channel: YouTubeChannel? = nil, tokenApp: YouTubeGoogleApp = .shared,
         sharedID: String = shared, signingIn: Bool = false, status: String = "",
         mode: YouTubeUploadMode = .ask, kids: Bool? = false, ownApp: Bool = false, ownPasted: Bool = false) {
        self.connected = connected; self.channel = channel; self.tokenApp = tokenApp
        self.sharedID = sharedID; self.signingIn = signingIn; self.status = status
        _mode = State(initialValue: mode); _kids = State(initialValue: kids); _ownApp = State(initialValue: ownApp)
        if ownPasted { clientID = "1234-sample.apps.googleusercontent.com"; secret = "secret" }
    }

    var body: some View {
        let facts = YouTubeAccountFacts(
            route: YouTubeRouteFacts(prefersOwnApp: ownApp, sharedClientID: sharedID, ownClientID: clientID, ownClientSecret: secret),
            signedIn: connected, tokenApp: tokenApp, channelName: channel?.name, signingIn: signingIn)
        YouTubePageContent(uploadMode: $mode, privacy: $privacy, madeForKids: $kids, usesOwnApp: $ownApp,
                           account: facts, channel: channel, uploading: false, status: status,
                           signIn: {}, signOut: {})
    }
}

func sheet(signedIn: Bool, channel: YouTubeChannel?, kids: Bool?, sharedID: String = shared) -> some View {
    let draft = YouTubeUploadDraft(file: URL(fileURLWithPath: "/tmp/sample.mp4"),
                                   title: "Year 8 Science \u{00B7} 26 Nov 2026",
                                   description: "Recorded with Greenroom on 26 November 2026.")
    let route = YouTubeRouteRules.signInRoute(YouTubeRouteFacts(
        prefersOwnApp: false, sharedClientID: sharedID, ownClientID: "", ownClientSecret: ""))
    return YouTubeUploadSheetContent(draft: draft, privacy: "unlisted", madeForKids: kids, signedIn: signedIn,
                                     channel: channel, signingIn: false, route: route, uploading: false,
                                     signIn: {}, upload: { _ in }, openStudio: { _, _ in }, cancel: {})
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
}

MainActor.assumeIsolated {
    let avatar = sampleAvatar()
    let channel = YouTubeChannel(name: "Sample Classroom", avatarURL: avatar)
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        let w: CGFloat = 640, h: CGFloat = 860
        shoot(Settings(), "settings-1-greenroom-not-signed-in-\(tag)", dark: dark, width: w, height: h)
        shoot(Settings(connected: true, channel: channel), "settings-2-greenroom-signed-in-\(tag)", dark: dark, width: w, height: h)
        shoot(Settings(ownApp: true), "settings-3-own-not-set-up-\(tag)", dark: dark, width: w, height: h)
        shoot(Settings(connected: true, channel: channel, tokenApp: .own, ownApp: true, ownPasted: true),
              "settings-4-own-set-up-signed-in-\(tag)", dark: dark, width: w, height: h)
        shoot(Settings(connected: true, channel: channel, tokenApp: .shared, ownApp: true, ownPasted: true),
              "settings-5-own-chosen-signed-in-through-greenroom-\(tag)", dark: dark, width: w, height: h)
        shoot(Settings(signingIn: true), "settings-6-signing-in-\(tag)", dark: dark, width: w, height: h)
        shoot(Settings(sharedID: placeholder), "settings-7-not-available-yet-\(tag)", dark: dark, width: w, height: h)
        shoot(Settings(status: "Not connected: Google refused the sign-in: access_denied."),
              "settings-8-sign-in-failed-\(tag)", dark: dark, width: w, height: h)
        shoot(Settings(connected: true, channel: channel, mode: .automatic, kids: nil),
              "settings-9-automatic-needs-answer-\(tag)", dark: dark, width: w, height: 960)

        let sw: CGFloat = 540, sh: CGFloat = 640
        shoot(sheet(signedIn: true, channel: channel, kids: nil), "sheet-1-signed-in-needs-answer-\(tag)", dark: dark, width: sw, height: sh)
        shoot(sheet(signedIn: true, channel: channel, kids: false), "sheet-2-signed-in-ready-\(tag)", dark: dark, width: sw, height: sh)
        shoot(sheet(signedIn: false, channel: nil, kids: nil), "sheet-3-not-signed-in-\(tag)", dark: dark, width: sw, height: sh)
        shoot(sheet(signedIn: false, channel: nil, kids: nil, sharedID: placeholder),
              "sheet-4-not-available-yet-\(tag)", dark: dark, width: sw, height: sh)
    }
}
