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

extension View {
    /// The editor's card: the shared quinary tile fill (DESIGN.md, "Cards and
    /// tiles") with the hairline, not a bespoke box.
    func editorCard(padding: CGFloat = 16, cornerRadius: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.quinary)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)))
    }

    /// Round transport button: a `.glass` circle on macOS 26, the old flat
    /// circle before.
    @ViewBuilder
    func editorRoundControl() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
        } else {
            self.buttonStyle(EditorRoundControlButtonStyle())
        }
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
