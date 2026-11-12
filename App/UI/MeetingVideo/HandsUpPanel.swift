//
//  HandsUpPanel.swift
//  Greenroom
//
//  The Hands up window's list, in the meeting window's dark style: the waiting
//  room on top (Admit, Deny, Admit all), then raised hands in the order they went
//  up, each with Lower hand and, for someone who is muted, Ask to unmute. No
//  video. Plain values in, closures out; the window does the work.
//
import AppKit
import SwiftUI

struct HandsUpContent: Equatable {
    var waiting: [MeetingWaitingRow] = []
    var canDeny = false
    var hands: [HandRow] = []
}

struct HandsUpActions {
    var admit: (UInt32) -> Void = { _ in }
    var deny: (UInt32) -> Void = { _ in }
    var admitAll: () -> Void = {}
    var lower: (UInt32) -> Void = { _ in }
    var askToUnmute: (UInt32) -> Void = { _ in }
}

struct HandsUpPanel: View {
    let content: HandsUpContent
    let actions: HandsUpActions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !content.waiting.isEmpty { waitingSection }
                header("Raised hands (\(content.hands.count))")
                if content.hands.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "hand.raised").font(.system(size: 22)).foregroundStyle(MeetingTheme.secondaryText)
                        Text("No hands up").font(.system(size: 13)).foregroundStyle(MeetingTheme.secondaryText)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                } else {
                    ForEach(Array(content.hands.enumerated()), id: \.element.id) { index, hand in
                        handRow(index + 1, hand)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .background(MeetingTheme.window)
        .environment(\.colorScheme, .dark)
    }

    private func header(_ title: String, trailing: (String, () -> Void)? = nil) -> some View {
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
            header("Waiting room (\(content.waiting.count))",
                   trailing: content.waiting.count > 1 ? ("Admit all", actions.admitAll) : nil)
            ForEach(content.waiting) { person in
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

    private func handRow(_ position: Int, _ hand: HandRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("\(position)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(MeetingTheme.hand).frame(width: 16)
                Avatar(name: hand.name)
                Text(hand.name).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                (Text("up ") + Text(hand.raisedAt, style: .timer)).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(MeetingTheme.secondaryText).fixedSize()
            }
            HStack(spacing: 8) {
                if hand.muted {
                    pill("Ask to unmute", fill: MeetingTheme.raised) { actions.askToUnmute(hand.id) }
                        .accessibilityLabel("Ask \(hand.name) to unmute")
                }
                pill("Lower hand", fill: MeetingTheme.raised) { actions.lower(hand.id) }
                    .accessibilityLabel("Lower \(hand.name)\u{2019}s hand")
            }
            .padding(.leading, 68)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    private func pill(_ title: String, fill: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 10).frame(height: 24)
                .background(fill, in: RoundedRectangle(cornerRadius: MeetingTheme.controlRadius))
        }.buttonStyle(.plain).fixedSize()
    }
}

/// The NSView the window embeds. Answers the first click: the panel is
/// non-activating and rarely key.
@MainActor
final class HandsUpView: NSView {
    var actions = HandsUpActions() { didSet { rebuild() } }
    private final class Box: ObservableObject { @Published var content = HandsUpContent() }
    private struct Root: View {
        @ObservedObject var box: Box
        let actions: HandsUpActions
        var body: some View { HandsUpPanel(content: box.content, actions: actions) }
    }
    private final class Host: NSHostingView<Root> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    private let box = Box()
    private var host: Host?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    private func rebuild() {
        host?.removeFromSuperview()
        let host = Host(rootView: Root(box: box, actions: actions))
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
        self.host = host
    }

    func apply(_ content: HandsUpContent) {
        if box.content != content { box.content = content }
    }

    override func layout() {
        super.layout()
        host?.frame = bounds
    }
}
