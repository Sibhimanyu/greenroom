// Off-screen render of the "You" tile in the four camera states. The video is a staged picture of a
// shared screen (no camera, no person): what Zoom's self render shows when the camera is out.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

/// A stand-in for Zoom's render of the Stage: a desktop with one window on it.
final class StagedScreen: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.22, alpha: 1).setFill(); bounds.fill()
        let win = bounds.insetBy(dx: bounds.width * 0.12, dy: bounds.height * 0.14)
        NSColor(white: 0.96, alpha: 1).setFill(); NSBezierPath(roundedRect: win, xRadius: 4, yRadius: 4).fill()
        NSColor(white: 0.75, alpha: 1).setFill()
        for i in 0..<4 { NSRect(x: win.minX + 10, y: win.maxY - 22 - CGFloat(i) * 14, width: win.width * (i == 0 ? 0.5 : 0.75), height: 6).fill() }
    }
}

let tile = NSSize(width: 240, height: 135), gap: CGFloat = 16, label: CGFloat = 20
let board = NSView(frame: NSRect(x: 0, y: 0, width: gap + (tile.width + gap) * 4, height: gap * 2 + tile.height + label))
board.wantsLayer = true
board.layer?.backgroundColor = MeetingTheme.windowNS.cgColor
for (i, state) in CameraState.allCases.enumerated() {
    let x = gap + CGFloat(i) * (tile.width + gap)
    let view = SelfPreviewView(frame: NSRect(x: x, y: gap, width: tile.width, height: tile.height))
    let screen = StagedScreen(frame: NSRect(origin: .zero, size: tile))
    view.videoHost.addSubview(screen)
    // Whole-screen share: the camera is in the picture unless Off or Only me (as Visibility.cameraEveryoneSees says).
    let inPicture = state.everyoneSees
    view.apply(muted: false, camera: state, mark: SelfViewRules.mark(state: state, cameraInPicture: inPicture), level: 0)
    view.layoutSubtreeIfNeeded()
    board.addSubview(view)
    let caption = NSTextField(labelWithString: state.name)
    caption.font = .systemFont(ofSize: 12, weight: .medium)
    caption.textColor = .white
    caption.frame = NSRect(x: x, y: gap + tile.height + 2, width: tile.width, height: 16)
    board.addSubview(caption)
}

let window = NSWindow(contentRect: board.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = board
board.layoutSubtreeIfNeeded()
board.subviews.forEach { $0.layoutSubtreeIfNeeded() }
guard let rep = board.bitmapImageRepForCachingDisplay(in: board.bounds) else { exit(1) }
board.cacheDisplay(in: board.bounds, to: rep)
let url = URL(fileURLWithPath: outDir).appendingPathComponent("self-view-states.png")
try rep.representation(using: .png, properties: [:])!.write(to: url)
print("wrote \(url.path)")
