import AppKit
// Off screen (x -4000), never activated: no focus taken.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

final class Centred: NSView {
    override func layout() {
        super.layout()
        guard let b = subviews.first else { return }
        b.frame.origin = NSPoint(x: 0, y: ((bounds.height - b.frame.height) / 2).rounded())
    }
}

@MainActor func shoot(width: CGFloat, slot: Bool, file: String) {
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 120),
                       styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                       backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .darkAqua)
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden
    win.backgroundColor = MeetingTheme.windowNS
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
    win.contentView = root
    let bar = MeetingTopBarView(frame: NSRect(x: 0, y: 120 - MeetingTheme.topBarHeight, width: width, height: MeetingTheme.topBarHeight))
    bar.autoresizingMask = [.width, .minYMargin]
    root.addSubview(bar)
    var state = MeetingTopBarState(); state.title = "Weekly class"; state.clock = "12:34"; state.canShrink = !slot
    bar.apply(state)
    // The eye, as WindowShareController.addTitleAccessory adds it.
    let size: CGFloat = 24
    let eye = ShowOnShareSwitch.make(size: size) {}
    ShowOnShareSwitch.apply(to: eye, on: true, kind: .display, pointSize: 11)
    let barHeight = max(28, win.frame.height - win.contentLayoutRect.height)
    let host = Centred(frame: NSRect(x: 0, y: 0, width: size + 12, height: barHeight))
    host.addSubview(eye)
    let acc = NSTitlebarAccessoryViewController(); acc.view = host; acc.layoutAttribute = .trailing
    win.addTitlebarAccessoryViewController(acc)
    win.contentView?.needsLayout = true
    win.orderBack(nil); spin(0.6)
    bar.needsLayout = true; bar.layoutSubtreeIfNeeded(); spin(0.2)
    // Overlap check in window coordinates.
    let eyeRect = eye.convert(eye.bounds, to: nil)
    for b in bar.subviews where b is NSButton && !b.isHidden {
        let r = b.convert(b.bounds, to: nil)
        print("\(file): \((b as! NSButton).accessibilityLabel() ?? "?") \(Int(r.minX))-\(Int(r.maxX)) eye \(Int(eyeRect.minX))-\(Int(eyeRect.maxX)) \(r.intersects(eyeRect) ? "OVERLAP" : "clear")")
    }
    guard let frame = win.contentView?.superview else { return }
    let b = frame.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = b.size; frame.cacheDisplay(in: b, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png")); print("wrote \(file)")
    win.orderOut(nil)
}
MainActor.assumeIsolated {
    shoot(width: 760, slot: false, file: "topbar-760-min")
    shoot(width: 1280, slot: false, file: "topbar-1280")
    shoot(width: 320, slot: true, file: "topbar-320-slot-min")
}
