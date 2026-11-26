// Off-screen render of the setup guide's YouTube step, per state. Staged data only.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

@MainActor func shoot<V: View>(_ v: V, _ file: String, dark: Bool, width: CGFloat = 632, height: CGFloat) {
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: height), styleMask: [.titled],
                       backing: .buffered, defer: false)
    let host = NSHostingView(rootView: v.padding(24).frame(width: width, height: height, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)))
    win.contentView = host
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.orderBack(nil); spin(1.0)
    host.layoutSubtreeIfNeeded()
    let b = host.bounds
    let rep = host.bitmapImageRepForCachingDisplay(in: b)!
    host.cacheDisplay(in: b, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    print("wrote \(file)")
    win.orderOut(nil)
}

func sampleAvatar() -> String {
    let image = NSImage(size: NSSize(width: 88, height: 88), flipped: false) { rect in
        NSColor(srgbRed: 0.18, green: 0.38, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = NSAttributedString(string: "SC", attributes: [
            .font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.white])
        let t = text.size()
        text.draw(at: NSPoint(x: (rect.width - t.width) / 2, y: (rect.height - t.height) / 2))
        return true
    }
    let path = "\(outDir)/sample-avatar.png"
    try! NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
    return URL(fileURLWithPath: path).absoluteString
}

struct Guide: View {
    var signedIn = false
    var tokenApp: YouTubeGoogleApp = .shared
    var channel: YouTubeChannel? = nil
    var jumpTo: YouTubeGuideSpot? = nil
    var openCard: YouTubeGuideCard? = nil
    @State var ownApp = false
    @State var clientID = ""
    @State var secret = ""
    @State var mode: YouTubeUploadMode = .ask
    @State var kids: Bool? = nil
    @State var jump: YouTubeGuideSpot? = nil

    init(signedIn: Bool = false, tokenApp: YouTubeGoogleApp = .shared, channel: YouTubeChannel? = nil,
         ownApp: Bool = false, mode: YouTubeUploadMode = .ask, kids: Bool? = nil, jumpTo: YouTubeGuideSpot? = nil,
         openCard: YouTubeGuideCard? = nil) {
        self.openCard = openCard
        self.signedIn = signedIn; self.tokenApp = tokenApp; self.channel = channel; self.jumpTo = jumpTo
        _ownApp = State(initialValue: ownApp); _mode = State(initialValue: mode); _kids = State(initialValue: kids)
        _jump = State(initialValue: jumpTo)
    }

    var body: some View {
        let facts = YouTubeAccountFacts(
            route: YouTubeRouteFacts(prefersOwnApp: ownApp, sharedClientID: "123-sample.apps.googleusercontent.com",
                                     ownClientID: clientID, ownClientSecret: secret),
            signedIn: signedIn, tokenApp: tokenApp, channelName: channel?.name, signingIn: false)
        YouTubeGuideStep(usesOwnApp: $ownApp, clientID: $clientID, clientSecret: $secret, uploadMode: $mode,
                         madeForKids: $kids, account: facts, channel: channel, jump: $jump, initiallyOpen: openCard)
    }
}

MainActor.assumeIsolated {
    let channel = YouTubeChannel(name: "Sample Classroom", avatarURL: sampleAvatar())
    for dark in [false, true] {
        let tag = dark ? "dark" : "light"
        shoot(Guide(), "guide-1-not-signed-in-\(tag)", dark: dark, height: 640)
        shoot(Guide(signedIn: true, channel: channel), "guide-2-signed-in-greenroom-\(tag)", dark: dark, height: 640)
        shoot(Guide(signedIn: true, channel: channel, openCard: .account),
              "guide-2b-signed-in-greenroom-open-\(tag)", dark: dark, height: 640)
        shoot(Guide(ownApp: true, jumpTo: .ownApp), "guide-3-own-app-not-set-up-\(tag)", dark: dark, height: 900)
        shoot(Guide(signedIn: true, channel: channel, mode: .automatic, kids: nil),
              "guide-4-upload-automatically-\(tag)", dark: dark, height: 640)
    }
}
