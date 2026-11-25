import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

struct SampleRow: Identifiable { var id: String; var symbol: String }

struct HomeSample: View {
    @State var name = ""
    var body: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12).fill(Color.black).frame(height: 150)
                .overlay(Text("LIVE PREVIEW (sample)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
            TextField("Green 2026-11-26 10.00", text: $name).textFieldStyle(.greenroom).controlSize(.large).frame(height: 36)
            HStack(spacing: 0) {
                ForEach([("video", "Look", false, false), ("rectangle.on.rectangle", "Whole screen", false, false), ("person.2", "Everyone", false, false),
                         ("mic", "MacBook Mic", false, true), ("rectangle.split.2x1", "Raj", false, false), ("record.circle", "Auto-rec", true, false), ("ellipsis", "More", false, false)], id: \.1) { t in
                    Button {} label: { DockFace(symbol: t.0, value: t.1, lit: t.2, warn: t.3, meter: nil) }.buttonStyle(DockButtonStyle())
                }
            }
            HStack { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green); Text("Ready").foregroundStyle(.secondary); Spacer(); Text("All sessions (3)").foregroundStyle(Brand.text) }.font(.system(size: 12))
            Text("Start Meeting").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 40).background(Capsule().fill(Brand.buttonFill))
        }.padding(24).frame(width: 592)
    }
}
struct CameraSample: View {
    @State var mirror = true; @State var switching = true
    var body: some View {
        HomeTilePanel(title: "Camera", summary: "Which camera you appear on.", value: "MacBook Pro", moreTitle: "More camera settings\u{2026}", onMore: {}) {
            HomeTileSection(title: "Who sees my camera") {
                HomeTileChoiceRow(choices: CameraState.allCases.map {
                    HomeTileChoice(id: $0.raw, title: $0.name, symbol: VisibilitySymbol.camera($0).name, selected: $0 == .everyoneAndMe, badge: VisibilitySymbol.camera($0).badge) }, labelLines: 2, pick: { _ in })
            }
            HomeTileSection(title: "Cameras") {
                let rows = [("MacBook Pro Camera", "laptopcomputer"), ("Studio Display Camera", "display")].map { SampleRow(id: $0.0, symbol: $0.1) }
                HomeTileList(rows: rows, selected: { $0.id == rows[0].id }, pick: { _ in }) { row, keyed in
                    HomeTileListRow(symbol: row.symbol, title: row.id, selected: row.id == rows[0].id, keyFocused: keyed) {} }
            }
            HomeTileToggleRow(title: "Mirror my camera", isOn: $mirror)
        }
    }
}
struct ScreenSample: View {
    @State var follow = true
    var body: some View {
        HomeTilePanel(title: "Screen", summary: "What everyone sees behind you.", value: "Whole screen", moreTitle: "More screen settings\u{2026}", onMore: {}) {
            HomeTileSection(title: "Share") {
                HomeTileChoiceRow(choices: [("Whole screen", "rectangle.on.rectangle"), ("A window", "macwindow"), ("Whiteboard", "scribble"), ("Just me", "person.crop.rectangle")]
                    .enumerated().map { HomeTileChoice(id: "\($0.offset)", title: $0.element.0, symbol: $0.element.1, selected: $0.offset == 0) }, pick: { _ in })
            }
            HomeTileToggleRow(title: "Follow slide shows", isOn: $follow)
        }
    }
}

/// Real window, real WindowFrost; capture the frame view so the frost / solid sheet is in the picture.
@MainActor func shoot<V: View>(_ v: V, _ file: String, dark: Bool, solid: Bool, switchedAfterInstall: Bool = false, width: CGFloat = 640) {
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: v)
    win.contentView = host
    let want = NSAppearance(named: dark ? .darkAqua : .aqua)
    // switchedAfterInstall: install under the OTHER appearance, as when the Mac flips after launch.
    NSAppearance.current = switchedAfterInstall ? NSAppearance(named: dark ? .aqua : .darkAqua) : want
    win.appearance = switchedAfterInstall ? NSAppearance(named: dark ? .aqua : .darkAqua) : want
    win.orderBack(nil); spin(0.4)
    WindowFrost.install(in: win, solid: .windowBackgroundColor, backdrop: solid ? .solid : .frosted)
    win.appearance = want
    NSAppearance.current = want
    spin(0.8)
    host.layoutSubtreeIfNeeded()
    let fit = host.fittingSize
    win.setContentSize(NSSize(width: max(fit.width, width), height: fit.height)); spin(0.5)
    let frame = win.contentView!.superview!
    // Stand-in for the wallpaper under a frosted window (offscreen windows cannot blur what is behind them).
    let b = host.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = b.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    want!.performAsCurrentDrawingAppearance {
        frame.subviews.first { $0.identifier?.rawValue == "greenroom.window.solid" }.map { _ in () }
    }
    NSGraphicsContext.restoreGraphicsState()
    for sub in frame.subviews { sub.layoutSubtreeIfNeeded() }
    // Draw back to front: frost/solid sheets, then content.
    frame.cacheDisplay(in: NSRect(x: 0, y: 0, width: b.width, height: b.height), to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    print("wrote \(file)")
    win.orderOut(nil)
}

MainActor.assumeIsolated {
for dark in [false, true] {
    for solid in [false, true] {
        let tag = "\(dark ? "dark" : "light")-\(solid ? "solid" : "frosted")"
        shoot(HomeSample(), "home-\(tag)", dark: dark, solid: solid, width: 592)
        shoot(HStack(alignment: .top, spacing: 16) { CameraSample(); ScreenSample() }.padding(16), "popouts-\(tag)", dark: dark, solid: solid, width: 760)
    }
    shoot(HomeSample(), "home-\(dark ? "dark" : "light")-solid-switchedAfterInstall", dark: dark, solid: true, switchedAfterInstall: true, width: 592)
}
}
