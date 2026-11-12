//
//  MeetingPeopleView.swift
//  Greenroom
//
//  The Participants panel, in Zoom's dark style (MeetingTheme records why): a
//  search field, the waiting room on top (Admit, Deny, Admit all), then raised
//  hands in the order they went up, then everyone, each row an initials circle,
//  a name with "(Host, me)" style tags and the microphone and camera on the
//  right. A host's footer has Invite, Mute All and "...". A row opens that
//  person's inspector; the panel itself does no work, so every action keeps its
//  one definition in the window.
//
//  The drawing is MeetingParticipantsPanel, a SwiftUI view of plain values; this
//  class is the NSView the window embeds, with the same `apply` it always had.
//
import AppKit
import SwiftUI

struct MeetingParticipantRow: Equatable, Identifiable {
    var id: UInt32
    var name: String
    /// "Host", "Co-host", "me" and the like, written after the name in brackets.
    var tags: [String] = []
    /// A second line: "spotlit".
    var detail = ""
    var handUp = false
    /// Joined audio and muted.
    var muted = false
    var hasAudio = true
    var cameraOff = false
    var selected = false
}

struct MeetingWaitingRow: Equatable, Identifiable {
    var id: UInt32
    var name: String
}

struct MeetingParticipantsContent: Equatable {
    var waiting: [MeetingWaitingRow] = []
    var canDeny = false
    var isHost = false
    var hands: [MeetingParticipantRow] = []
    var everyone: [MeetingParticipantRow] = []
    var total = 0
}

struct MeetingParticipantsActions {
    var select: (UInt32) -> Void = { _ in }
    var admit: (UInt32) -> Void = { _ in }
    var deny: (UInt32) -> Void = { _ in }
    var admitAll: () -> Void = {}
    var invite: () -> Void = {}
    var muteAll: () -> Void = {}
    var askAllToUnmute: () -> Void = {}
}

struct MeetingParticipantsPanel: View {
    let content: MeetingParticipantsContent
    let actions: MeetingParticipantsActions
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            search
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !waiting.isEmpty { waitingSection }
                    if !hands.isEmpty {
                        sectionHeader("Raised hands (\(hands.count))")
                        ForEach(hands) { row($0) }
                    }
                    ForEach(everyone) { row($0) }
                    if matches.isEmpty && !query.isEmpty {
                        Text("No one matches \u{201C}\(query)\u{201D}")
                            .font(.system(size: 12)).foregroundStyle(MeetingTheme.secondaryText)
                            .padding(16)
                    }
                }
                .padding(.bottom, 8)
            }
            footer
        }
        .background(MeetingTheme.window)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Filtering

    private var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }
    private func keep(_ name: String) -> Bool { needle.isEmpty || name.lowercased().contains(needle) }
    private var waiting: [MeetingWaitingRow] { content.waiting.filter { keep($0.name) } }
    private var hands: [MeetingParticipantRow] { content.hands.filter { keep($0.name) } }
    private var everyone: [MeetingParticipantRow] { content.everyone.filter { keep($0.name) } }
    private var matches: [Int] { waiting.map(\.id.hashValue) + hands.map(\.id.hashValue) + everyone.map(\.id.hashValue) }

    // MARK: Pieces

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(MeetingTheme.secondaryText)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(MeetingTheme.secondaryText)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(MeetingTheme.raised, in: RoundedRectangle(cornerRadius: MeetingTheme.controlRadius))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private func sectionHeader(_ title: String, trailing: (String, () -> Void)? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(MeetingTheme.secondaryText)
            Spacer()
            if let trailing {
                Button(trailing.0, action: trailing.1)
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
    }

    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Waiting room (\(content.waiting.count))",
                          trailing: content.waiting.count > 1 ? ("Admit all", actions.admitAll) : nil)
            ForEach(waiting) { person in
                HStack(spacing: 10) {
                    Avatar(name: person.name)
                    Text(person.name).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 4)
                    if content.canDeny {
                        pill("Deny", fill: MeetingTheme.raised) { actions.deny(person.id) }
                            .accessibilityLabel("Deny \(person.name)")
                    }
                    pill("Admit", fill: Color(nsColor: NSColor(srgbRed: 0x0E / 255, green: 0x71 / 255, blue: 0xEB / 255, alpha: 1))) {
                        actions.admit(person.id)
                    }
                    .accessibilityLabel("Admit \(person.name)")
                }
                .padding(.horizontal, 16).frame(height: 46)
            }
            Rectangle().fill(MeetingTheme.hairline).frame(height: 1).padding(.top, 6).padding(.horizontal, 12)
        }
    }

    private func pill(_ title: String, fill: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 24)
                .background(fill, in: RoundedRectangle(cornerRadius: MeetingTheme.controlRadius))
        }.buttonStyle(.plain)
    }

    private func row(_ person: MeetingParticipantRow) -> some View {
        ParticipantRowView(person: person) { actions.select(person.id) }
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(MeetingTheme.hairline).frame(height: 1)
            HStack(spacing: 8) {
                footerButton("Invite", action: actions.invite)
                if content.isHost {
                    footerButton("Mute All", action: actions.muteAll)
                    Menu {
                        Button("Ask All to Unmute", action: actions.askAllToUnmute)
                    } label: {
                        Text("\u{2026}").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 34, height: 28)
                            .background(MeetingTheme.raised, in: RoundedRectangle(cornerRadius: MeetingTheme.controlRadius))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("More")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 48)
        }
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 28)
                .background(MeetingTheme.raised, in: RoundedRectangle(cornerRadius: MeetingTheme.controlRadius))
        }.buttonStyle(.plain)
    }
}

/// An initials circle.
struct Avatar: View {
    let name: String
    var size: CGFloat = 32
    var body: some View {
        Circle().fill(MeetingTheme.avatarColor(for: name))
            .frame(width: size, height: size)
            .overlay(Text(MeetingTheme.initials(name))
                .font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

private struct ParticipantRowView: View {
    let person: MeetingParticipantRow
    let tap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Avatar(name: person.name)
                VStack(alignment: .leading, spacing: 1) {
                    (Text(person.name).foregroundColor(.white)
                     + Text(person.tags.isEmpty ? "" : " (\(person.tags.joined(separator: ", ")))")
                        .foregroundColor(Color.white.opacity(0.62)))
                        .font(.system(size: 13)).lineLimit(1)
                    if !person.detail.isEmpty {
                        Text(person.detail).font(.system(size: 11)).foregroundStyle(MeetingTheme.secondaryText)
                    }
                }
                Spacer(minLength: 4)
                if person.handUp {
                    Image(systemName: "hand.raised.fill").font(.system(size: 13)).foregroundStyle(MeetingTheme.hand)
                }
                Image(systemName: person.hasAudio && !person.muted ? "mic" : "mic.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(person.hasAudio && !person.muted ? Color.white : (person.hasAudio ? MeetingTheme.red : MeetingTheme.secondaryText))
                    .frame(width: 18)
                Image(systemName: person.cameraOff ? "video.slash" : "video")
                    .font(.system(size: 13))
                    .foregroundStyle(person.cameraOff ? MeetingTheme.red : Color.white)
                    .frame(width: 20)
            }
            .padding(.horizontal, 16).frame(height: 46)
            .background(person.selected || hovering ? MeetingTheme.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel([person.name, person.tags.isEmpty ? nil : person.tags.joined(separator: ", "),
                             person.handUp ? "hand up" : nil, person.muted ? "muted" : nil,
                             person.cameraOff ? "camera off" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - The view the window embeds

@MainActor
final class MeetingPeopleView: NSView {

    typealias Row = MeetingParticipantRow
    typealias WaitingRow = MeetingWaitingRow

    var onSelect: ((UInt32) -> Void)?
    var onAdmit: ((UInt32) -> Void)?
    var onDeny: ((UInt32) -> Void)?
    var onAdmitAll: (() -> Void)?
    var onInvite: (() -> Void)?
    var onMuteAll: (() -> Void)?
    var onAskAllToUnmute: (() -> Void)?

    private final class Box: ObservableObject {
        @Published var content = MeetingParticipantsContent()
    }
    private struct Root: View {
        @ObservedObject var box: Box
        let actions: MeetingParticipantsActions
        var body: some View { MeetingParticipantsPanel(content: box.content, actions: actions) }
    }
    /// The panel is non-activating and rarely key; without this the first click
    /// on any row is spent making it key and does nothing.
    private final class Host: NSHostingView<Root> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let box = Box()
    private var host: Host?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let actions = MeetingParticipantsActions(
            select: { [weak self] in self?.onSelect?($0) },
            admit: { [weak self] in self?.onAdmit?($0) },
            deny: { [weak self] in self?.onDeny?($0) },
            admitAll: { [weak self] in self?.onAdmitAll?() },
            invite: { [weak self] in self?.onInvite?() },
            muteAll: { [weak self] in self?.onMuteAll?() },
            askAllToUnmute: { [weak self] in self?.onAskAllToUnmute?() })
        let host = Host(rootView: Root(box: box, actions: actions))
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
        self.host = host
    }

    required init?(coder: NSCoder) { nil }

    /// `total` counts everyone in the meeting, you included, which is the number
    /// Zoom's own Participants button shows.
    func apply(waiting: [WaitingRow] = [], canDeny: Bool = false, isHost: Bool = false,
               hands: [Row], everyone: [Row], total: Int) {
        let next = MeetingParticipantsContent(waiting: waiting, canDeny: canDeny, isHost: isHost,
                                              hands: hands, everyone: everyone, total: total)
        if box.content != next { box.content = next }
    }

    override func layout() {
        super.layout()
        host?.frame = bounds
    }
}

/// The brand fill for chrome drawn in AppKit, read from the asset catalogue like
/// `Brand.green`, so it is never typed in twice.
enum ParticipantGridWindowAccent {
    static var color: NSColor { NSColor(named: "AccentColor") ?? .systemGreen }
}
