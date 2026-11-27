//
//  ScheduledPickerField.swift
//  Greenroom
//
//  The face of Home's My Meetings picker (the closed menu): calendar symbol, the
//  chosen entry or the placeholder, and a chevron, in the field's own look.
//  When the personal room is chosen a small "Always the same link" note sits
//  after its number. Split out of HomeView so scripts/render/scheduled.sh can
//  draw it without the coordinator.
//
import SwiftUI

struct ScheduledPickerField: View {
    /// The chosen entry, or nil for the placeholder.
    let chosen: ScheduledEntry?
    let placeholder: String
    var height: CGFloat = 32

    private var isPersonalRoom: Bool {
        if case .personalRoom = chosen { return true }
        return false
    }

    private var label: some View {
        Text(chosen.map(ScheduledListRules.label) ?? placeholder)
            .font(.system(size: 14))
            .foregroundStyle(chosen == nil ? .secondary : .primary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 8) {
            Image(systemName: isPersonalRoom ? "person.crop.square" : "calendar")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            // The note shows only when it fits whole; a cut-off "Alway…" says nothing.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    label.fixedSize()
                    if isPersonalRoom {
                        Text(ZoomPersonalRoom.note)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                label
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background { shape.fill(.quinary) }
        .overlay { shape.strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5) }
        .contentShape(shape)
    }
}
