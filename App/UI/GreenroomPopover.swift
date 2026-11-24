import AppKit
import SwiftUI

/// Greenroom's one popover. It always opens below its button (arrow on top),
/// and its content is capped to the room left under the button on the
/// current screen, scrolling inside instead of letting AppKit flip the
/// popover to another side. Never use a bare `.popover` for a button.
extension View {
    func greenroomPopover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(GreenroomPopover(isPresented: isPresented, popoverContent: content))
    }
}

private struct GreenroomPopover<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let popoverContent: () -> PopoverContent

    /// Points from the anchor's bottom edge down to the screen's usable edge, less a margin.
    @State private var room: CGFloat = 600
    @State private var contentHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .background(PopoverRoomReader(room: $room))
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ScrollView {
                    popoverContent()
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: PopoverContentHeightKey.self, value: proxy.size.height)
                        })
                }
                .onPreferenceChange(PopoverContentHeightKey.self) { contentHeight = $0 }
                // An explicit height always: a ScrollView with only a maximum collapses to
                // zero inside a popover. 300 is a stand-in for the first pass only.
                .frame(height: min(contentHeight ?? 300, max(room, 120)))
            }
    }
}

private struct PopoverContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Reads the anchor's place on screen and reports the space below it.
private struct PopoverRoomReader: NSViewRepresentable {
    @Binding var room: CGFloat
    static let margin: CGFloat = 12

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { value in
            if abs(value - room) > 0.5 { room = value }
        }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = { value in
            if abs(value - room) > 0.5 { room = value }
        }
        view.report()
    }

    final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification, object: window, queue: .main
                ) { [weak self] _ in self?.report() }
            }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func report() {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let onScreen = window.convertToScreen(convert(bounds, to: nil))
            let value = onScreen.minY - screen.visibleFrame.minY - PopoverRoomReader.margin
            DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
        }
    }
}
