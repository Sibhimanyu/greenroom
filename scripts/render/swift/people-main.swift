// Off-screen render of the Participants list (MeetingParticipantsPanel) with sample data:
// the panel as a host sees it, rows under the pointer (hover Mute and "..."), and the
// person menu and footer menu as ParticipantActionRules builds them. The menus are drawn
// as plain lists here (the real one is an AppKit panel); their content is the real list.
import SwiftUI
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let host = ViewerFacts(role: .host, waitingRoomAvailable: true, renameAllowed: true)
func row(_ id: UInt32, _ name: String, tags: [String] = [], facts: PersonFacts) -> MeetingParticipantRow {
    MeetingParticipantRow(id: id, name: name, tags: tags, handUp: facts.handUp, muted: facts.muted,
                          hasAudio: facts.hasAudio, cameraOff: !facts.videoOn,
                          quick: ParticipantActionRules.quick(person: facts, viewer: host).map(ParticipantActionRules.shortTitle),
                          hasMore: !ParticipantActionRules.actions(person: facts, viewer: host).isEmpty)
}
let me = PersonFacts(isMe: true, isHost: true)
let ana = PersonFacts()
let ben = PersonFacts(muted: true, videoOn: false, handUp: true)
let cy = PersonFacts(hasAudio: false)
let rows = [row(1, "Sibhimanyu V", tags: ["Host", "me"], facts: me), row(2, "Ana Ruiz", facts: ana),
            row(3, "Ben Okafor", facts: ben), row(4, "Cy Tran", facts: cy)]

func save(_ view: some View, _ size: NSSize, _ name: String) {
    let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
        .background(MeetingTheme.window).environment(\.colorScheme, .dark))
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

struct MenuSample: View {
    let title: String
    let entries: [MenuEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(MeetingTheme.secondaryText).padding(8)
            ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                switch e.kind {
                case .separator: Divider().padding(.vertical, 3)
                case .header: Text(e.title).font(.system(size: 11)).foregroundStyle(MeetingTheme.secondaryText).padding(.horizontal, 10).padding(.vertical, 2)
                default:
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).opacity(e.checked ? 1 : 0)
                        Text(e.title).font(.system(size: 13)).foregroundStyle(e.enabled ? .white : MeetingTheme.secondaryText)
                    }.padding(.horizontal, 8).padding(.vertical, 3)
                }
            }
        }
        .padding(4)
        .background(MeetingTheme.raised, in: RoundedRectangle(cornerRadius: 8))
    }
}

let actions = MeetingParticipantsActions()
// 1. The panel at the Participants window's width, as a host sees it.
save(MeetingParticipantsPanel(content: MeetingParticipantsContent(isHost: true, hands: [rows[2]],
                                                                   everyone: [rows[0], rows[1], rows[3]], total: 4),
                              actions: actions), NSSize(width: 320, height: 440), "people-panel")
// 2. Each row under the pointer: hover Mute / Ask to unmute and "...", none on your own Mute.
save(VStack(spacing: 0) { ForEach(rows) { MeetingParticipantRowView(person: $0, actions: actions, hovering: true) } },
     NSSize(width: 320, height: 46 * 4), "people-rows-hover")
// 3. The menus: Ana's, yours, and the footer's "...".
var hostState = ParticipantsHostMenuState()
hostState.muteOnEntryAvailable = true
hostState.handsUp = 1
hostState.waitingRoomOn = true
save(HStack(alignment: .top, spacing: 12) {
    MenuSample(title: "Ana (attendee)", entries: ParticipantActionRules.menu(ParticipantActionRules.actions(person: ana, viewer: host)) { _ in })
    MenuSample(title: "You (host)", entries: ParticipantActionRules.menu(ParticipantActionRules.actions(person: me, viewer: host)) { _ in })
    MenuSample(title: "Footer \u{2026}", entries: MeetingMenus.participantsHost(hostState, ParticipantsHostMenuActions()))
}.padding(12), NSSize(width: 720, height: 420), "people-menus")
