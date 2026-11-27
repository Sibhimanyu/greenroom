// Off-screen render of Home's Scheduled picker (ScheduledPickerField) and its menu's lines,
// with and without the personal room, light and dark. Sample data only (no real names or numbers).
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let room = ZoomPersonalRoom(number: 3542471135, joinURL: "https://zoom.us/j/3542471135", hostName: "Sample Host")
let weekly = ZoomServerToServerClient.ScheduledMeeting(
    id: 81234567890, topic: "Weekly review", startTime: Date(timeIntervalSince1970: 1_796_000_000),
    isRecurring: true, joinURL: "https://zoom.us/j/81234567890")
let oneOff = ZoomServerToServerClient.ScheduledMeeting(
    id: 89876543210, topic: "Partner call", startTime: Date(timeIntervalSince1970: 1_796_300_000),
    isRecurring: false, joinURL: "https://zoom.us/j/89876543210")

/// The menu's lines as HomeView builds them (stand-in look; the real menu is macOS's).
struct MenuLines: View {
    let entries: [ScheduledEntry]
    let chosen: ScheduledEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .opacity(chosen?.id == entry.id ? 1 : 0)
                    Text(ScheduledListRules.label(entry)).font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .help(entry.canEdit ? "" : ZoomPersonalRoom.help)
                if !entry.canEdit {
                    Text(ZoomPersonalRoom.note).font(.system(size: 13)).foregroundStyle(.secondary)
                        .padding(.leading, 23).padding(.vertical, 3)
                    if entries.count > 1 { Divider().padding(.vertical, 4) }
                }
            }
            Divider().padding(.vertical, 4)
            Text("Refresh").font(.system(size: 13)).padding(.leading, 23).padding(.vertical, 3)
            Text("Meetings scheduled on your Zoom account. To join someone else\u{2019}s meeting, use the Zoom app.")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.leading, 23).padding(.vertical, 3)
        }
        .padding(8)
        .frame(width: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct Sheet: View {
    let title: String
    let entries: [ScheduledEntry]
    let chosen: ScheduledEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            ScheduledPickerField(chosen: chosen, placeholder: "Choose a scheduled meeting").frame(width: 360)
            ScheduledPickerField(chosen: chosen, placeholder: "Choose a scheduled meeting").frame(width: 460)
            MenuLines(entries: entries, chosen: chosen)
        }
        .padding(20)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func shoot<V: View>(_ v: V, _ file: String, dark: Bool) {
    let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: v)
    win.contentView = host
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.orderBack(nil)
    spin(0.8)
    win.setContentSize(host.fittingSize); spin(0.4); host.layoutSubtreeIfNeeded()
    let b = host.bounds
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = b.size
    host.cacheDisplay(in: b, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(file).png"))
    print("wrote \(file) \(Int(b.width))x\(Int(b.height))")
    win.orderOut(nil)
}

let withRoom = ScheduledListRules.entries(room: room, meetings: [weekly, oneOff])
let withoutRoom = ScheduledListRules.entries(room: nil, meetings: [weekly, oneOff])
for dark in [false, true] {
    let tag = dark ? "dark" : "light"
    shoot(Sheet(title: "With your personal room, it chosen", entries: withRoom, chosen: withRoom.first), "with-room-chosen-\(tag)", dark: dark)
    shoot(Sheet(title: "With your personal room, a meeting chosen", entries: withRoom, chosen: withRoom[1]), "with-room-meeting-\(tag)", dark: dark)
    shoot(Sheet(title: "Without it (no scope or no PMI)", entries: withoutRoom, chosen: nil), "without-room-\(tag)", dark: dark)
    shoot(Sheet(title: "Only the personal room", entries: ScheduledListRules.entries(room: room, meetings: []), chosen: nil), "room-only-\(tag)", dark: dark)
}
