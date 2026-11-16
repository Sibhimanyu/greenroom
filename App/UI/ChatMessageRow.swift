//
//  ChatMessageRow.swift
//  Greenroom
//
//  One chat message in the modern layout: a 28pt photo on the left; above the
//  bubble a row with the sender and the time; the words in a rounded, softly
//  filled bubble. A message that continues a group draws only its bubble.
//  Colours are semantic (primary / secondary / tertiary) plus `Brand.green`
//  for your own, so it reads the same in the standalone chat and in the
//  meeting window's forced-dark one.
//
import SwiftUI

struct ChatMessageRow<Extra: View>: View {
    let row: ChatGrouping.Row
    let userID: UInt32
    let text: String
    /// True when `extra` (a quote, a file card) has something to draw.
    var hasExtra: Bool = false
    var onReply: (() -> Void)?
    @ViewBuilder var extra: () -> Extra

    @State private var hovering = false

    static var avatarSize: CGFloat { 28 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if row.startsGroup {
                    ParticipantAvatar(userID: userID, name: row.displayName, size: Self.avatarSize)
                } else {
                    Color.clear
                }
            }
            .frame(width: Self.avatarSize, height: Self.avatarSize)

            VStack(alignment: .leading, spacing: 4) {
                if row.startsGroup { header }
                if hasExtra || !text.isEmpty { bubble }
            }
            Spacer(minLength: 16)
        }
        .padding(.top, row.startsGroup ? 12 : 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(row.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let label = row.privateLabel {
                Label(label, systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if hovering, let onReply {
                Button(action: onReply) {
                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reply to this message")
                .accessibilityLabel("Reply")
            }
            Spacer(minLength: 8)
            Text(row.line.timestamp, style: .time)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(height: 16)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            extra()
            if !text.isEmpty {
                // Bare URLs become links through Text's markdown handling;
                // selection stays on so a meeting code can be copied.
                Text(.init(text))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(row.line.isOutgoing ? Brand.green.opacity(0.20) : Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10))
    }
}
