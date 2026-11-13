//
//  AnnotationToolbar.swift
//  Greenroom
//
//  Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Recording/ScreenAnnotation.swift:
//  `AnnotationToolbarView`). Phase 5 of the Recorditor port.
//
//  Floating tools at the top of the screen being shared. It floats over
//  content, so it is Liquid Glass (DESIGN.md, Glass) and not Recorditor's
//  black capsule; text and symbols use semantic styles so vibrancy works. It
//  is a Greenroom window and never in the picture.
//
import SwiftUI

/// Press feedback for the small round buttons (Recorditor's `PressScaleStyle`,
/// RoomSessionView.swift:152, verbatim).
struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct AnnotationToolbarView: View {
    @ObservedObject var model: ScreenAnnotationModel
    var onWhiteboard: () -> Void
    let onDone: () -> Void
    /// What the picked tool does, under the bar for a few seconds.
    @State private var hint: String?
    @State private var hintTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            bar
            // Space for the hint is kept even when it's gone (the panel's size
            // is fixed); clear pixels let clicks through to what's below.
            Text(hint ?? " ")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .greenroomGlass(in: Capsule())
                .opacity(hint == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: hint)
        }
        .padding(6)
        .onChange(of: model.tool) { _, tool in show(hint(for: tool)) }
        .onChange(of: model.notice) { _, notice in if let notice { show(notice.text) } }
    }

    private func hint(for tool: ScreenAnnotationModel.Tool) -> String {
        switch tool {
        case .pointer:
            "Drawing paused \u{2014} your clicks reach your apps; the drawings stay. Pick a tool to draw again"
        case .pen: "Pen \u{2014} drag to draw. Click it again to pause drawing and use your apps"
        case .highlighter: "Highlighter \u{2014} drag over what matters"
        case .arrow: "Arrow \u{2014} drag from the tail to the tip"
        case .eraser: "Eraser \u{2014} drag over a drawing to rub it out (an arrow goes whole)"
        }
    }

    private func show(_ text: String) {
        hint = text
        hintTask?.cancel()
        hintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { hint = nil }
        }
    }

    private var bar: some View {
        HStack(spacing: 6) {
            // No Select button: clicking the chosen tool again pauses drawing
            // (clicks reach the apps, the marks stay).
            ForEach(ScreenAnnotationModel.Tool.allCases.filter { $0 != .pointer }) { tool in
                toolButton(tool)
            }

            divider

            ForEach(Array(ScreenAnnotationModel.colors.enumerated()), id: \.offset) { _, color in
                let selected = model.color == color
                Button {
                    model.color = color
                    if model.tool == .pointer { model.tool = .pen }
                } label: {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.9 : 0.25), lineWidth: selected ? 2 : 1))
                        .padding(4)
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle(scale: 0.85))
                .help("Ink colour")
                .accessibilityLabel("Ink colour")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }

            divider

            iconButton("rectangle.inset.filled.on.rectangle", help: "Whiteboard (W) \u{2014} switch what you share to a white page, and back",
                       action: onWhiteboard)
            iconButton("arrow.uturn.backward", help: "Undo (\u{2318}Z)") { model.undo() }
                .disabled(!model.canUndo)
            iconButton("trash", help: "Clear the marks on the screen") { model.clear() }
                .disabled(!model.canUndo)

            divider

            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Close the drawing tools and clear the marks (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .fixedSize()
        .greenroomGlass(in: Capsule(), interactive: true)
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.2)).frame(width: 1, height: 24).padding(.horizontal, 2)
    }

    private func toolButton(_ tool: ScreenAnnotationModel.Tool) -> some View {
        let selected = model.tool == tool
        return Button {
            model.tool = selected ? .pointer : tool
        } label: {
            Image(systemName: tool.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(selected ? Brand.green : Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.9))
        .help(selected
              ? "\(tool.title) (\(tool.shortcut)) \u{2014} click again to pause drawing and use your apps"
              : "\(tool.title) (\(tool.shortcut))")
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.9))
        .help(help)
        .accessibilityLabel(help)
    }
}
