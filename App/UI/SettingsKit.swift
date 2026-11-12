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
//  - Collapsible / Binding.animatedCollapse: the house rule for a switch and
//    what hangs off it. When a toggle (or a mode) is off, the settings that
//    depend on it HIDE, they are not greyed out. See the notes on Collapsible.
//
import SwiftUI
import AppKit

// MARK: - Collapsing dependent settings

/// How a collapse moves: DESIGN.md's 250ms `snappy` layout move, or nothing
/// at all under Reduce Motion.
enum Collapse {
    static var animation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .snappy(duration: 0.25)
    }
    static var seconds: Double { animation == nil ? 0 : 0.3 }

    static func animate(_ change: () -> Void) { withAnimation(animation, change) }
}

extension Binding {
    /// The same binding, but a write animates, so whatever is wrapped in a
    /// `Collapsible` (or an `if` inside a Form) opens and closes smoothly
    /// when the toggle that drives it is flipped.
    func animatedCollapse() -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { value in Collapse.animate { wrappedValue = value } })
    }
}

/// Height scales with `progress`, the content is laid out at full size and
/// clipped by the caller. `progress` is animatable, so the container grows
/// and shrinks with the transaction.
private struct CollapseLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let size = first.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * progress)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        first.place(at: bounds.origin, anchor: .topLeading,
                    proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Settings that only mean something while a switch is on.
///
/// - Height and opacity move together over 250ms; Reduce Motion is instant.
/// - Once closed the content is REMOVED (no row, no divider, no spacing left
///   behind in a grouped Form), and it is out of the accessibility tree and
///   the key-view loop while it closes.
/// - Only the view is removed. The values live with the caller, so turning
///   the switch back on finds them as they were.
/// - Flip the switch through `Binding.animatedCollapse()` so the rest of the
///   form moves with it.
///
/// Put the whole dependent block in ONE `Collapsible` so a Form sees one row.
struct Collapsible<Content: View>: View {
    let hidden: Bool
    @ViewBuilder let content: () -> Content
    @State private var present: Bool
    @State private var progress: CGFloat

    init(hidden: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.hidden = hidden
        self.content = content
        _present = State(initialValue: !hidden)
        _progress = State(initialValue: hidden ? 0 : 1)
    }

    var body: some View {
        Group {
            if present {
                CollapseLayout(progress: progress) {
                    content().opacity(Double(progress))
                }
                .clipped()
                .accessibilityHidden(hidden)
                .disabled(hidden)
            }
        }
        .onChange(of: hidden) { _, nowHidden in
            if nowHidden {
                Collapse.animate { progress = 0 }
                DispatchQueue.main.asyncAfter(deadline: .now() + Collapse.seconds) {
                    guard hidden else { return }
                    Collapse.animate { present = false }
                }
            } else {
                present = true
                DispatchQueue.main.async { Collapse.animate { progress = 1 } }
            }
        }
    }
}

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
