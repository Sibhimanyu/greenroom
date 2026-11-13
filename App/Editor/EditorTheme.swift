//
//  EditorTheme.swift
//  Greenroom
//
//  Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Support/Theme.swift).
//  Re-pointed at Greenroom's tokens (DESIGN.md): Brand.green for fills and
//  tints, Brand.text for green text, system colours for chrome.
//
import SwiftUI

enum EditorTheme {
    /// Accent for fills, strokes and icons (Brand.green, the AccentColor).
    static let accent = Brand.green
    /// Primary-button fill. Same token: Greenroom has one accent.
    static let accentDeep = Brand.green
    /// Green that may carry words (section headers).
    static let accentText = Brand.text
    static let danger = Color(nsColor: .systemRed)
    static let dangerDeep = Color(nsColor: .systemRed)
    static let thread = accent
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let card = surface
    static let cardStroke = border

    /// Was a blue gradient; a flat accent fill now (DESIGN.md: no gradients).
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent], startPoint: .top, endPoint: .bottom)
    }
}

struct EditorCardStyle: ViewModifier {
    var padding: CGFloat
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(EditorTheme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(EditorTheme.cardStroke, lineWidth: 1)))
    }
}

extension View {
    func editorCard(padding: CGFloat = 16, cornerRadius: CGFloat = 12) -> some View {
        modifier(EditorCardStyle(padding: padding, cornerRadius: cornerRadius))
    }
}

/// Round icon button used for the transport controls.
struct EditorRoundControlButtonStyle: ButtonStyle {
    var diameter: CGFloat = 44
    var tint: Color = .primary.opacity(0.1)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: diameter * 0.36, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(tint))
            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Section header: uppercase, letter-spaced, in the text green.
struct EditorPanelHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(EditorTheme.accentText)
    }
}

/// Text buttons: solid accent for the main action, outlined for secondary,
/// red for destructive.
struct EditorButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind = .secondary
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, kind: kind, height: height)
    }

    private struct Face: View {
        let configuration: Configuration
        let kind: Kind
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var fill: Color {
            switch kind {
            case .primary: EditorTheme.accentDeep
            case .danger: EditorTheme.danger
            case .secondary: Color.primary.opacity(hovering ? 0.12 : 0.06)
            }
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            configuration.label
                .font(.caption.weight(.semibold))
                .foregroundStyle(kind == .secondary ? Color.primary.opacity(hovering ? 1 : 0.88) : Color.white)
                .padding(.horizontal, kind == .secondary ? 11 : 14)
                .frame(minHeight: height)
                .background(shape.fill(fill).brightness(kind != .secondary && hovering ? 0.08 : 0))
                .overlay(shape.stroke(Color.primary.opacity(kind == .secondary ? 0.16 : 0), lineWidth: 1))
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

extension ButtonStyle where Self == EditorButtonStyle {
    static var editorPrimary: EditorButtonStyle { EditorButtonStyle(kind: .primary) }
    static var editorSecondary: EditorButtonStyle { EditorButtonStyle(kind: .secondary) }
    static var editorDanger: EditorButtonStyle { EditorButtonStyle(kind: .danger) }
}

/// Single-choice segmented control.
struct EditorSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var fontSize: CGFloat = 13
    var height: CGFloat = 32
    @Namespace private var selectionSpace
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: fontSize, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.white : (hovered == option ? EditorTheme.textPrimary : EditorTheme.textSecondary))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(EditorTheme.accentDeep)
                                    .matchedGeometryEffect(id: "selection", in: selectionSpace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
                .overlay(alignment: .leading) {
                    if index > 0, !selected, options[index - 1] != selection {
                        Rectangle().fill(EditorTheme.border).frame(width: 1, height: height * 0.5)
                    }
                }
            }
        }
        .padding(4)
        .frame(height: height + 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(EditorTheme.border, lineWidth: 1))
    }
}
