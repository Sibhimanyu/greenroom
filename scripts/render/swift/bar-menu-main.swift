// Off-screen render of the bar's camera menu (MeetingMenuPanel.content, the panel's own rows and
// size) placed by MenuPanelPlacement above a floating bar near the bottom of a staged screen.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

MainActor.assumeIsolated {
    // The bottom of a 1512pt-wide screen's visible frame, cropped to 760pt tall.
    let area = CGRect(x: 0, y: 0, width: 1100, height: 760)
    for (stopped, file) in [(false, "bar-camera-menu-off"), (true, "bar-camera-menu-off-stopped")] {
        let board = NSView(frame: area)
        board.wantsLayer = true
        board.layer?.backgroundColor = NSColor(white: 0.86, alpha: 1).cgColor

        var snap = MeetingBarSnapshot()
        snap.cameraState = .off; snap.videoStopped = stopped; snap.participants = 2; snap.classSeconds = 259
        let bar = NSHostingView(rootView: MeetingBarContent(s: snap, bindings: ShortcutBindings(), a: MeetingBarActions(),
                                                            grip: AnyView(Color.clear.frame(width: 14)))
            .padding(6).background(Capsule().fill(Color(white: 0.55))).environment(\.colorScheme, .dark))
        bar.setFrameSize(bar.fittingSize)
        bar.setFrameOrigin(NSPoint(x: 120, y: 24))
        board.addSubview(bar)

        // The camera cell's arrow: about a third of the way along the bar, as in the screenshot.
        let arrow = CGRect(x: bar.frame.minX + bar.frame.width * 0.36, y: bar.frame.minY + 6, width: 20, height: bar.frame.height - 12)
        let entries = MeetingBarModel.cameraMenu(current: .off, noCameraAllowed: true, videoStopped: stopped,
                                                 pick: { _ in }, toggleVideo: {})
        let menu = MeetingMenuPanel.content(entries)
        let placed = MenuPanelPlacement.place(size: menu.frame.size, anchor: arrow, area: area, below: false)
        print("\(file): menu \(menu.frame.size), placed \(placed.frame), scrolls \(placed.scrolls), last row \(entries.last?.title ?? "")")
        // Glass does not draw off screen: a dark plate stands in for it, at exactly the panel's frame,
        // so a row cut off by the panel's size would show as text past the plate's edge.
        let plate = NSView(frame: placed.frame)
        plate.wantsLayer = true
        plate.layer?.backgroundColor = NSColor(white: 0.22, alpha: 0.96).cgColor
        plate.layer?.cornerRadius = 10
        board.addSubview(plate)
        menu.frame = placed.frame
        board.addSubview(menu)

        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: area.width, height: area.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = board
        window.orderBack(nil); spin(0.6)
        board.layoutSubtreeIfNeeded()
        let rep = board.bitmapImageRepForCachingDisplay(in: board.bounds)!
        board.cacheDisplay(in: board.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
        print("wrote \(file)")
        window.orderOut(nil)
    }
}
