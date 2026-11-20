//
//  Segmented.swift
//
//  The one segmented switcher (DESIGN.md, "Segmented switchers"): a row of
//  plain buttons with ONE selection capsule, Brand green with a white label,
//  that slides between segments via `matchedGeometryEffect` with a spring, on
//  every macOS version. No Liquid Glass here: glass inside the row blurred
//  the labels, and a crisp readable control beats the morph. Reduce Motion
//  swaps the slide for a 150ms crossfade. Never use a native tinted Picker
//  (it jumps) and never hand-build another switcher. The one exception, the
//  session panel's `GreenroomUnderlineTabs`, is at the end of this file.
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
    /// In a window toolbar: draws its own track (a glass capsule on macOS 26,
    /// whose system background the toolbar item hides) with one exact inset
    /// (`SegmentedMath.inset`) on all four sides of the green selection, plain
    /// primary labels, and the same solid green selection.
    var toolbar = false
    /// A tooltip for one segment, or nil.
    var segmentTips: (Value) -> String? = { _ in nil }
    @ViewBuilder let label: (Value) -> Label

    @Namespace private var ns
    @State private var hovered: Value?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Read so the glass track is rebuilt when the appearance flips.
    @Environment(\.colorScheme) private var scheme

    init(_ title: String,
         selection: Binding<Value>,
         options: [Value],
         toolbar: Bool = false,
         @ViewBuilder label: @escaping (Value) -> Label) {
        self.title = title
        self._selection = selection
        self.options = options
        self.toolbar = toolbar
        self.label = label
    }

    private var height: CGFloat { toolbar ? SegmentedMath.toolbarPillHeight : 22 }
    private var hPadding: CGFloat { toolbar ? 14 : 10 }

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.85)
    }

    var body: some View {
        row
            .fixedSize()
            // Focusable only with Full Keyboard Access on, as a native
            // segmented control is. Always-focusable made it take the
            // window's first focus and wear a green focus ring on open.
            .focusable(NSApplication.shared.isFullKeyboardAccessEnabled)
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

    /// Adds a tooltip to the segments that have one.
    func segmentHelp(_ help: @escaping (Value) -> String?) -> Self {
        var copy = self
        copy.segmentTips = help
        return copy
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard let i = options.firstIndex(of: selection) else { return .ignored }
        let n = SegmentedMath.step(from: i, by: delta, count: options.count)
        guard n != i else { return .handled }
        withAnimation(motion) { selection = options[n] }
        return .handled
    }

    private var row: some View {
        EqualWidthRow {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(toolbar ? SegmentedMath.inset : 2)
        .background { if toolbar { toolbarTrack } else { Capsule().fill(.quinary) } }
        // Lay out by the selection pill's edges, not the track's: the faint
        // track spills 2pt past them, so the green pill lines up with the
        // leading edge of the text and fields around it.
        .padding(toolbar ? 0 : -2)
    }

    /// The toolbar's capsule. Glass on macOS 26 to match the Sessions button;
    /// the faint track before that.
    @ViewBuilder
    private var toolbarTrack: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: Capsule()).id(scheme) // GLASS-TRACK
        } else {
            Capsule().fill(.quinary)
        }
    }

    private func segment(_ option: Value) -> some View {
        let on = option == selection
        return Button {
            withAnimation(motion) { selection = option }
        } label: {
            label(option)
                .fontWeight(on ? .semibold : .regular)
                .foregroundStyle(on ? AnyShapeStyle(Color.white)
                                    : AnyShapeStyle(toolbar || hovered == option ? .primary : .secondary))
                .lineLimit(1)
                .padding(.horizontal, hPadding)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(segmentTips(option) ?? "")
        .onHover { inside in
            if inside { hovered = option } else if hovered == option { hovered = nil }
        }
        .background { selectionCapsule(on: on) }
    }

    /// Solid Brand green, in every style: no gradient, highlight, stroke or
    /// transparency, so nothing blends it into the glass behind.
    private var pill: some View { Capsule().fill(Brand.buttonFill) }

    @ViewBuilder
    private func selectionCapsule(on: Bool) -> some View {
        if reduceMotion {
            // No slide: each segment fades its own capsule in and out.
            pill.opacity(on ? 1 : 0)
        } else if on {
            pill.matchedGeometryEffect(id: "selection", in: ns)
        }
    }
}

// MARK: - Underline tabs

/// The session panel's tab row (DESIGN.md, "Segmented switchers", the one
/// exception): plain labels sharing the panel's full width in equal parts, the
/// selected one primary and semibold, a 2pt Brand green underline that slides
/// between tabs (`matchedGeometryEffect`, 250ms ease-in-out; Reduce Motion
/// crossfades in 150ms) and a hairline under the whole row. Hover lifts a
/// resting label from secondary to primary. VoiceOver hears the same segmented
/// Picker as `GreenroomSegmented`; left/right arrows move the selection.
/// Same call shape as `GreenroomSegmented`. Use it only for a reading pane's
/// tabs; every other switcher stays `GreenroomSegmented`.
struct GreenroomUnderlineTabs<Value: Hashable, Label: View>: View {
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

    private var motion: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.25)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in tab(option) }
        }
        .background(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
        .focusable(NSApplication.shared.isFullKeyboardAccessEnabled)
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

    private func tab(_ option: Value) -> some View {
        let on = option == selection
        return Button {
            withAnimation(motion) { selection = option }
        } label: {
            label(option)
                .fontWeight(on ? .semibold : .regular)
                .foregroundStyle(on || hovered == option ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = option } else if hovered == option { hovered = nil }
        }
        .overlay(alignment: .bottom) { underline(on: on) }
    }

    @ViewBuilder
    private func underline(on: Bool) -> some View {
        let bar = Rectangle().fill(Brand.green).frame(height: 2)
        if reduceMotion {
            bar.opacity(on ? 1 : 0)
        } else if on {
            bar.matchedGeometryEffect(id: "underline", in: ns)
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
