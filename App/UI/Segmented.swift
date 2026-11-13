//
//  Segmented.swift
//
//  The one segmented switcher (DESIGN.md, "Segmented switchers"): a row of
//  plain buttons with ONE selection capsule, Brand green with a white label,
//  that slides between segments. On macOS 26 the capsule is tinted Liquid
//  Glass inside a GlassEffectContainer and morphs via `glassEffectID`; before
//  26 it is a filled capsule moved with `matchedGeometryEffect`. Reduce Motion
//  swaps the slide for a 150ms crossfade. Never use a native tinted Picker
//  (it jumps) and never hand-build another switcher.
//
//  VoiceOver hears a real segmented Picker (`accessibilityRepresentation`);
//  left/right arrows move the selection when the control has focus.
//
import SwiftUI

/// Lays out children at one shared width: the widest child's ideal width.
private struct EqualWidthRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let h = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: w * CGFloat(subviews.count), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let w = bounds.width / CGFloat(subviews.count)
        for (i, v) in subviews.enumerated() {
            v.place(at: CGPoint(x: bounds.minX + w * CGFloat(i), y: bounds.minY),
                    anchor: .topLeading, proposal: ProposedViewSize(width: w, height: bounds.height))
        }
    }
}

struct GreenroomSegmented<Value: Hashable, Label: View>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    @ViewBuilder let label: (Value) -> Label

    @Namespace private var ns
    @State private var hovered: Value?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String,
         selection: Binding<Value>,
         options: [Value],
         @ViewBuilder label: @escaping (Value) -> Label) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    private static var height: CGFloat { 22 }
    private static var hPadding: CGFloat { 10 }

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    var body: some View {
        row
            .fixedSize()
            .focusable()
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
            .accessibilityRepresentation {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        label(option).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard let i = options.firstIndex(of: selection) else { return .ignored }
        let n = SegmentedMath.step(from: i, by: delta, count: options.count)
        guard n != i else { return .handled }
        withAnimation(motion) { selection = options[n] }
        return .handled
    }

    @ViewBuilder
    private var row: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 0) { segments(glass: true) }
        } else {
            segments(glass: false)
        }
    }

    private func segments(glass: Bool) -> some View {
        EqualWidthRow {
            ForEach(options, id: \.self) { option in
                segment(option, glass: glass)
            }
        }
        .padding(2)
        .background { track(glass: glass) }
    }

    @ViewBuilder
    private func track(glass: Bool) -> some View {
        if #available(macOS 26, *), glass {
            Color.clear.glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(.quinary)
        }
    }

    private func segment(_ option: Value, glass: Bool) -> some View {
        let on = option == selection
        return Button {
            withAnimation(motion) { selection = option }
        } label: {
            label(option)
                .fontWeight(on ? .semibold : .regular)
                .foregroundStyle(on ? AnyShapeStyle(Color.white)
                                    : AnyShapeStyle(hovered == option ? .primary : .secondary))
                .lineLimit(1)
                .padding(.horizontal, Self.hPadding)
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = option } else if hovered == option { hovered = nil }
        }
        .background { selectionCapsule(on: on, glass: glass) }
    }

    @ViewBuilder
    private func selectionCapsule(on: Bool, glass: Bool) -> some View {
        if reduceMotion {
            // No slide: each segment fades its own capsule in and out.
            Capsule().fill(Brand.green).opacity(on ? 1 : 0)
        } else if on {
            if #available(macOS 26, *), glass {
                Color.clear
                    .glassEffect(.regular.tint(Brand.green).interactive(), in: Capsule())
                    .glassEffectID("selection", in: ns)
            } else {
                Capsule().fill(Brand.green)
                    .matchedGeometryEffect(id: "selection", in: ns)
            }
        }
    }
}

#Preview("Segmented") {
    struct Demo: View {
        enum Mode: String, CaseIterable { case new = "New", join = "Join", record = "Record" }
        @State private var mode = Mode.join
        var body: some View {
            VStack(spacing: 16) {
                GreenroomSegmented("Mode", selection: $mode, options: Mode.allCases) { Text($0.rawValue) }
                GreenroomSegmented("Mode", selection: $mode, options: Mode.allCases) {
                    Label($0.rawValue, systemImage: "circle")
                }
            }
            .padding(24)
            .tint(Brand.green)
        }
    }
    return Demo()
}
