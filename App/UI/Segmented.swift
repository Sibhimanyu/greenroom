//
//  Segmented.swift
//
//  The one segmented switcher (DESIGN.md, "Segmented switchers"): the native
//  `Picker` with `.segmented` style, with the app's green selection removed so
//  the system draws it. On macOS 26 that is a Liquid Glass piece that slides
//  between segments; on 14 and 15 the standard raised segment.
//
//  WHY NOT `.tint(nil)`: `tint(nil)` means "use the default tint", and the
//  default is the app's accent, which is `AccentColor.colorset` (Brand.green),
//  or the user's System Settings accent. So it would fall straight back to a
//  green (or blue) selection and is not neutral. GreenroomApp.swift applies
//  `.tint(Brand.green)` at every scene root so Start does not turn blue; a
//  segmented control tinted that way fills its selected segment with the tint.
//  We therefore give the picker an explicit neutral tint, `Self.neutral`, on
//  this one view only, so Start, links and toggles stay green. Being an
//  explicit colour it behaves the same on 14, 15 and 26 and ignores the user's
//  accent.
//
//  NOT yet checked by eye on 14/15/26 (no app launch was allowed when this
//  was written, and an off-screen render does not draw an active segmented
//  control). Look at it once; if it reads too dark or too light, change
//  `neutral` here and nowhere else.
//
//  Never hand-build a segmented control. `GlassSegmented` (icons over captions,
//  unusual sizes) is specified in .context/glass-audit.md §7 and not built
//  until a call site needs it.
//
import SwiftUI

struct GreenroomSegmented<Value: Hashable, Label: View>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    @ViewBuilder let label: (Value) -> Label

    init(_ title: String,
         selection: Binding<Value>,
         options: [Value],
         @ViewBuilder label: @escaping (Value) -> Label) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    /// The selection colour: a quiet system grey, not the accent.
    static var neutral: Color { Color(nsColor: .systemGray) }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                label(option).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .tint(Self.neutral)
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
