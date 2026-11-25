import SwiftUI
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
// Real glass cannot render off-screen; the stand-in is a translucent wash over a wallpaper-like grey, per appearance.
@MainActor func shoot(dark: Bool, snap: MeetingBarSnapshot, file: String) {
    let content = MeetingBarContent(s: snap, bindings: ShortcutBindings(), a: MeetingBarActions(), grip: AnyView(Color.clear.frame(width: 14)))
    let wall: Color = dark ? Color(white: 0.18) : Color(white: 0.80)
    let wash: Color = dark ? Color.white.opacity(0.10) : Color.white.opacity(0.55)
    let v = content.padding(10).background(RoundedRectangle(cornerRadius: 30).fill(wash)).padding(12).background(wall)
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: v); win.contentView = host
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); win.orderBack(nil); spin(0.8)
    let fit = host.fittingSize; win.setContentSize(fit); spin(0.4); host.layoutSubtreeIfNeeded()
    let b = host.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = b.size; host.cacheDisplay(in: b, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png")); print("wrote \(file)")
    win.orderOut(nil)
}
MainActor.assumeIsolated {
    for dark in [false, true] {
        var s = MeetingBarSnapshot(); s.phase = .recording; s.classSeconds = 754; s.participants = 4; s.notesOpen = true; s.chatOpen = true
        shoot(dark: dark, snap: s, file: "meetingbar-\(dark ? "dark" : "light")-frosted")
    }
}
