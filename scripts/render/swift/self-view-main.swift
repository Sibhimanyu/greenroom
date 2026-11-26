// Off-screen render of the "You" tile in the four camera states, and below it the Self view window's
// tile (MeetingVideoTile, a view window's tile of the owner) in the same states plus video stopped.
// The video is a staged picture of a shared screen (no camera, no person): what Zoom's self render
// shows when the camera is out.
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

func write(_ board: NSView, _ file: String) throws {
    let window = NSWindow(contentRect: board.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = board
    board.layoutSubtreeIfNeeded()
    board.subviews.forEach { $0.layoutSubtreeIfNeeded() }
    guard let rep = board.bitmapImageRepForCachingDisplay(in: board.bounds) else { exit(1) }
    board.cacheDisplay(in: board.bounds, to: rep)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(file)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path)")
}
try write(board, "self-view-states.png")

// The Self view window's tile: the person is the owner as Zoom's roster has them; the look is the
// coordinator's (SelfViewRules.look). Zoom's flag lags a stop, so the stopped case keeps videoOn.
let viewTile = NSSize(width: 320, height: 180)
let cases: [(CameraState, Bool)] = CameraState.allCases.map { ($0, false) } + [(.off, true)]
let views = NSView(frame: NSRect(x: 0, y: 0, width: gap + (viewTile.width + gap) * CGFloat(cases.count),
                                 height: gap * 2 + viewTile.height + label))
views.wantsLayer = true
views.layer?.backgroundColor = MeetingTheme.windowNS.cgColor
MainActor.assumeIsolated {
for (i, c) in cases.enumerated() {
    let x = gap + CGFloat(i) * (viewTile.width + gap)
    let tile = MeetingVideoTile(frame: NSRect(x: x, y: gap, width: viewTile.width, height: viewTile.height))
    let me = MeetingViewPerson(id: 1, name: "Raj Kumar", isMe: true, videoOn: true)
    let you = SelfViewRules.look(state: c.0, cameraInPicture: c.0.everyoneSees, videoStopped: c.1)
    tile.apply(me, you: you)
    tile.attach(video: StagedScreen(frame: NSRect(origin: .zero, size: viewTile)))
    tile.layoutSubtreeIfNeeded()
    views.addSubview(tile)
    let caption = NSTextField(labelWithString: "Self view window: \(c.0.name)\(c.1 ? ", video stopped" : "")")
    caption.font = .systemFont(ofSize: 12, weight: .medium)
    caption.textColor = .white
    caption.frame = NSRect(x: x, y: gap + viewTile.height + 2, width: viewTile.width, height: 16)
    views.addSubview(caption)
}
}
try write(views, "self-view-window-states.png")
