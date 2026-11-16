//
//  Fields.swift
//
//  Greenroom's own text field (owner, 2026-11-16: "custom greenroom
//  textboxes", not the macOS bezel). It rests like a choice tile, on
//  `.quinary` with a hairline, at the `md` radius; focus is a 1.5pt
//  `Brand.green` ring instead of the system's thick blue-or-accent halo.
//
//  Click away and the field lets go: `FieldFocusRelease` resigns the text
//  field when a click lands on anything that is not text.
//
import AppKit
import SwiftUI

struct GreenroomFieldStyle: TextFieldStyle {
    // swiftlint:disable:next identifier_name
    func _body(configuration: TextField<Self._Label>) -> some View {
        FieldBody(field: AnyView(configuration))
    }

    private struct FieldBody: View {
        let field: AnyView
        @FocusState private var focused: Bool
        @State private var hovering = false
        @Environment(\.controlSize) private var size
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            field
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .focused($focused)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(minHeight: minHeight)
                .background { shape.fill(hovering && enabled && !focused ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)) }
                .overlay { shape.strokeBorder(Color(nsColor: .separatorColor).opacity(focused ? 0 : 0.6), lineWidth: 0.5) }
                .overlay { shape.strokeBorder(Brand.green, lineWidth: 1.5).opacity(focused ? 1 : 0) }
                .contentShape(shape)
                .simultaneousGesture(TapGesture().onEnded { focused = true })
                .onHover { hovering = $0 }
                .opacity(enabled ? 1 : 0.6)
                .animation(.easeOut(duration: 0.12), value: focused)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var large: Bool { size == .large || size == .extraLarge }
        private var small: Bool { size == .small || size == .mini }
        private var radius: CGFloat { small ? 6 : (large ? 10 : 8) }
        private var fontSize: CGFloat { large ? 14 : (small ? 11 : 13) }
        private var horizontalPadding: CGFloat { large ? 11 : (small ? 6 : 8) }
        private var verticalPadding: CGFloat { large ? 6 : (small ? 2 : 4) }
        private var minHeight: CGFloat { large ? 32 : (small ? 20 : 26) }
    }
}

extension TextFieldStyle where Self == GreenroomFieldStyle {
    /// Greenroom's text field. Use it wherever a field is drawn as a box.
    static var greenroom: GreenroomFieldStyle { GreenroomFieldStyle() }
}

/// Clicking anywhere that is not text takes the focus out of a text field, in
/// every Greenroom window. AppKit keeps a field focused until another control
/// asks for the keyboard; a click on empty space or a label asks for nothing.
enum FieldFocusRelease {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            release(for: event)
            return event
        }
    }

    private static func release(for event: NSEvent) {
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let content = window.contentView else { return }
        let point = content.convert(event.locationInWindow, from: nil)
        let hit = content.hitTest(point)
        // A click in the field itself (or another field) keeps editing.
        var view = hit
        while let current = view {
            if current is NSTextField || current is NSTextView { return }
            view = current.superview
        }
        window.makeFirstResponder(nil)
    }
}
