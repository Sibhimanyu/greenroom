//
//  SettingsKit.swift
//  Greenroom
//
//  The pieces Settings tabs share, so every tab speaks the same visual
//  language as Webcam: choices drawn as pictures, short names, explanations
//  in hover help (`.help`) rather than captions.
//
//  - ChoiceTile: a selectable card with a picture and a short name. Use a row
//    of them instead of a segmented control or picker when the options can be
//    drawn (a glyph, an SF Symbol, a thumbnail).
//  - PictureChip: a small dark capsule laid over a picture (LIVE, a warning).
//  - StatusBadge: a one-line state with a coloured symbol (Connected, Not set
//    up). Green is local and fine; amber (`--net`) is reserved by DESIGN.md
//    for things that leave the Mac.
//
import SwiftUI

/// A compact picture-and-label choice. Keep the visual beside the name so
/// repeated choices do not each add another row to the Settings page.
struct ChoiceTile<Picture: View>: View {
    let title: String
    let selected: Bool
    let badge: String?
    @ViewBuilder let picture: () -> Picture
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                picture()
                    .fixedSize()
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .padding(.trailing, badge == nil ? 0 : 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(minHeight: 40)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Brand.green.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Brand.green : Color.secondary.opacity(0.25),
                              lineWidth: selected ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(selected ? Brand.green : Color.secondary)
                        .padding(6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}


/// A small dark capsule laid over a picture: LIVE, Can't see you.
struct PictureChip: View {
    let text: String
    var symbol: String? = nil
    var dot: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.72), in: Capsule())
        .foregroundStyle(.white)
    }
}

/// A one-line state: a coloured symbol and a few words.
struct StatusBadge: View {
    enum Tone { case good, waiting, problem }
    let text: String
    let tone: Tone

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout)
    }

    private var symbol: String {
        switch tone {
        case .good: return "checkmark.circle.fill"
        case .waiting: return "circle.dashed"
        case .problem: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .good: return Brand.green
        case .waiting: return .secondary
        case .problem: return .orange
        }
    }
}
