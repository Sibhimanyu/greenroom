// Off-screen render of Preview: Everyone (R37), real LayoutCanvas, sample data.
import SwiftUI
import AppKit

struct EHost: View {
    let pieces: [LayoutPiece]
    let share: Visibility.Target
    let title: String
    let size: CGSize
    @State var sel: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, design: .monospaced))
            LayoutCanvas(
                pieces: .constant(pieces), selection: $sel,
                display: LayoutDisplaySpace(name: "Built-in Display", size: size),
                look: { p in LayoutPieceLook(name: p.kind.app?.bundleID == "com.apple.Safari" ? "Safari" : (p.kind.isChat ? "Chat" : "Meeting window"), icon: nil, symbol: "square") },
                accepts: { _ in true }, onActivate: {}, onNotice: { _ in },
                showsHeader: false,
                camera: LayoutCameraModel(box: PresenceBox(), shape: .circle, onStep: { _ in }, onCommit: { _ in }),
                share: share, previewEveryone: true)
                .frame(width: 520)
        }
    }
}

let outDir = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let safari = LayoutPiece(kind: .app(AppPiece(bundleID: "com.apple.Safari", url: "", opensAtStart: false, closesOnStop: false, opensMinimised: false)),
                         rect: UnitRect(x: 0, y: 0, w: 0.75, h: 1))
let chat = LayoutPiece(kind: .chat, rect: UnitRect(x: 0.75, y: 0, w: 0.25, h: 1))
let display = CGSize(width: 1512, height: 884)

struct Grid: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                EHost(pieces: [safari, chat], share: .window(bundleID: "com.apple.Safari"), title: "One window: Safari 1134x884 on 1512x884", size: display)
                EHost(pieces: [safari, chat], share: .wholeScreen, title: "Whole screen", size: display)
            }
            HStack(alignment: .top, spacing: 16) {
                EHost(pieces: [safari, chat], share: .whiteboard, title: "Whiteboard", size: display)
                EHost(pieces: [safari, chat], share: .justMe, title: "Just me", size: display)
            }
        }
        .padding(16)
        .background(Color.white)
        .frame(width: 1120)
    }
}
let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1120, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
let host = NSHostingView(rootView: Grid())
win.contentView = host
win.appearance = NSAppearance(named: .aqua)
win.orderBack(nil)
RunLoop.main.run(until: Date().addingTimeInterval(1.2))
host.layoutSubtreeIfNeeded()
let fit = host.fittingSize.height
win.setContentSize(NSSize(width: 1120, height: fit))
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
host.layoutSubtreeIfNeeded()
let b = host.bounds
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = b.size
host.cacheDisplay(in: b, to: rep)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/everyone.png"))
print("wrote everyone.png")
