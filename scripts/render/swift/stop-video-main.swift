// Off-screen render of Stop video (R49): the bar's camera button per camera state x video stopped,
// the camera menus drawn from their entries, the Meeting toolbar, and the "You" tile. Staged data only.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

@MainActor func write(_ view: NSView, _ file: String) {
    view.layoutSubtreeIfNeeded()
    let b = view.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = b.size
    view.cacheDisplay(in: b, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    print("wrote \(file)")
}

@MainActor func shoot<V: View>(_ v: V, _ file: String, dark: Bool, width: CGFloat = 1200) {
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: width, height: 200), styleMask: [.titled],
                       backing: .buffered, defer: false)
    let host = NSHostingView(rootView: v)
    win.contentView = host
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.orderBack(nil); spin(0.6)
    win.setContentSize(host.fittingSize); spin(0.3)
    write(host, file)
    win.orderOut(nil)
}

/// A menu drawn from its entries, as AppKit would lay it out: tick, title, quieter note, dividers.
struct MenuDrawing: View {
    let title: String
    let entries: [MenuEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                    switch e.kind {
                    case .separator: Divider().padding(.vertical, 4)
                    case .header:
                        Text(e.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 22).padding(.vertical, 2)
                    default:
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(e.checked ? 1 : 0)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.system(size: 13)).foregroundStyle(e.enabled ? .primary : .tertiary)
                                if let note = e.note {
                                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                    }
                }
            }
            .padding(6)
            .frame(width: 330, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        }
        .padding(12)
    }
}

MainActor.assumeIsolated {
    // 1. The floating bar: one row per camera state, video going out and stopped.
    for dark in [false, true] {
        let wall: Color = dark ? Color(white: 0.18) : Color(white: 0.80)
        let wash: Color = dark ? Color.white.opacity(0.10) : Color.white.opacity(0.55)
        let board = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(CameraState.allCases.enumerated()), id: \.offset) { _, state in
                ForEach([false, true], id: \.self) { stopped in
                    HStack(spacing: 12) {
                        Text("\(state.name)\(stopped ? ", video stopped" : "")")
                            .font(.system(size: 12, weight: .medium)).frame(width: 190, alignment: .leading)
                        let snap: MeetingBarSnapshot = {
                            var s = MeetingBarSnapshot(); s.cameraState = state; s.videoStopped = stopped
                            s.participants = 4; s.classSeconds = 754; return s
                        }()
                        MeetingBarContent(s: snap, bindings: ShortcutBindings(), a: MeetingBarActions(),
                                          grip: AnyView(Color.clear.frame(width: 14)))
                            .padding(6).background(RoundedRectangle(cornerRadius: 30).fill(wash))
                    }
                }
            }
        }
        .padding(14).background(wall)
        shoot(board, "bar-camera-states-\(dark ? "dark" : "light")", dark: dark, width: 1300)
    }

    // 2. The camera menus, drawn from the entries the app pops up.
    let cameras = MeetingMenus.video(cameras: [.init(id: "a", name: "FaceTime HD Camera"), .init(id: "b", name: "Desk camera")],
                                     selected: "a", pick: { _ in })
    let menus = HStack(alignment: .top, spacing: 0) {
        MenuDrawing(title: "Bar, Everyone & me",
                    entries: MeetingBarModel.cameraMenu(current: .everyoneAndMe, noCameraAllowed: true, videoStopped: false,
                                                        pick: { _ in }, toggleVideo: {}))
        MenuDrawing(title: "Bar, Off, video stopped",
                    entries: MeetingBarModel.cameraMenu(current: .off, noCameraAllowed: true, videoStopped: true,
                                                        pick: { _ in }, toggleVideo: {}))
        MenuDrawing(title: "Meeting toolbar, Only the meeting",
                    entries: MeetingBarModel.cameraMenu(current: .onlyEveryone, noCameraAllowed: true, videoStopped: false,
                                                        cameras: cameras, pick: { _ in }, toggleVideo: {}))
    }
    shoot(menus, "camera-menus-light", dark: false, width: 1100)

    // 3. The Meeting toolbar, every caption the camera cell wears (the four states, and Start video),
    // at the window's minimum width (760pt) and at a normal one (1100pt).
    let toolbarCases: [(CameraState, Bool)] = CameraState.allCases.map { ($0, false) } + [(.everyoneAndMe, true)]
    for barWidth in [CGFloat(760), 1100] {
        let toolbars = VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(toolbarCases.enumerated()), id: \.offset) { _, pair in
                let s: MeetingToolbarState = {
                    var t = MeetingToolbarState(); t.cameraState = pair.0; t.videoStopped = pair.1; t.participants = 4
                    t.isHost = true; t.clock = "12:34"; return t
                }()
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pair.0.name)\(pair.1 ? ", video stopped" : ""), \(Int(barWidth))pt").font(.system(size: 11)).foregroundStyle(.white)
                    MeetingToolbarBar(state: s, menus: MeetingToolbarMenus(), actions: MeetingToolbarActions())
                        .frame(width: barWidth, height: MeetingToolbarBar.height)
                        .background(MeetingTheme.window)
                }
            }
        }
        .padding(10).background(MeetingTheme.window)
        shoot(toolbars, barWidth == 1100 ? "meeting-toolbar-dark" : "meeting-toolbar-\(Int(barWidth))-dark",
              dark: true, width: barWidth + 40)
    }

    // 4. The "You" tile: Off (what everyone sees, Off's mark) beside video stopped (the name, Stop video's mark).
    final class StagedScreen: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 0.22, alpha: 1).setFill(); bounds.fill()
            let win = bounds.insetBy(dx: bounds.width * 0.12, dy: bounds.height * 0.14)
            NSColor(white: 0.96, alpha: 1).setFill(); NSBezierPath(roundedRect: win, xRadius: 4, yRadius: 4).fill()
        }
    }
    let tile = NSSize(width: 240, height: 135), gap: CGFloat = 16
    let cases: [(CameraState, Bool, String)] = [(.off, false, "Off"), (.off, true, "Off, video stopped"),
                                                (.everyoneAndMe, true, "Everyone & me, video stopped")]
    let board = NSView(frame: NSRect(x: 0, y: 0, width: gap + (tile.width + gap) * CGFloat(cases.count), height: gap * 2 + tile.height + 20))
    board.wantsLayer = true
    board.layer?.backgroundColor = MeetingTheme.windowNS.cgColor
    for (i, c) in cases.enumerated() {
        let x = gap + CGFloat(i) * (tile.width + gap)
        let view = SelfPreviewView(frame: NSRect(x: x, y: gap, width: tile.width, height: tile.height))
        view.videoHost.addSubview(StagedScreen(frame: NSRect(origin: .zero, size: tile)))
        let inPicture = c.0.everyoneSees
        view.apply(muted: false, camera: c.0, videoStopped: c.1,
                   content: SelfViewRules.content(cameraInPicture: inPicture, videoStopped: c.1), name: "Raj Kumar",
                   mark: SelfViewRules.mark(state: c.0, cameraInPicture: inPicture, videoStopped: c.1), level: 0)
        view.layoutSubtreeIfNeeded()
        board.addSubview(view)
        let caption = NSTextField(labelWithString: c.2)
        caption.font = .systemFont(ofSize: 12, weight: .medium); caption.textColor = .white
        caption.frame = NSRect(x: x, y: gap + tile.height + 2, width: tile.width, height: 16)
        board.addSubview(caption)
    }
    let window = NSWindow(contentRect: board.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = board
    board.subviews.forEach { $0.layoutSubtreeIfNeeded() }
    write(board, "you-tile-stopped")
}
