//
//  VisibilityIcon.swift
//  Greenroom
//
//  SwiftUI side of the one icon language (VisibilitySymbols.swift, spec R17): the tint
//  tokens as colours, and the small corner badge a camera state can carry (Only me
//  wears the struck eye; "no camera" wears a question mark).
//
import SwiftUI

extension VisibilitySymbol.Tint {
    /// Amber text is `Brand.netText` in the app (DESIGN.md); `MeetingTheme.netNS` is the meeting's AppKit twin.
    var color: Color {
        switch self {
        case .net: return Brand.netText
        case .neutral: return Color.secondary
        case .primary: return Color.primary
        }
    }

    var nsColor: NSColor {
        switch self {
        case .net: return MeetingTheme.netNS
        case .neutral: return .secondaryLabelColor
        case .primary: return .labelColor
        }
    }
}

extension View {
    /// The corner badge of a symbol (nil: none).
    func symbolBadge(_ name: String?, size: CGFloat = 9) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let name {
                Image(systemName: name)
                    .font(.system(size: size, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.primary, Color.secondary)
                    .padding(1)
                    .background(Circle().fill(.background))
                    .offset(x: size * 0.45, y: size * 0.35)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A visibility symbol as an image, with its badge, tinted by its own token unless told otherwise.
struct VisibilityGlyph: View {
    let meaning: VisibilitySymbol
    var size: CGFloat = 14
    var tinted = true

    var body: some View {
        Image(systemName: meaning.name)
            .font(.system(size: size))
            .foregroundStyle(tinted ? meaning.tint.color : Color.primary)
            .symbolBadge(meaning.badge, size: size * 0.6)
            .accessibilityLabel(meaning.words)
    }
}
