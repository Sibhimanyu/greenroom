//
//  ChatWindow.swift
//  Greenroom
//
//  A standalone window for the Meeting SDK chat bridge - independent of
//  Greenroom's main window, and independent of Zoom's own UI (this reads
//  Meeting SDK callbacks, not Zoom's window - there's nothing to pop out
//  of Zoom itself here).
//
import SwiftUI
import AppKit

struct ChatWindowView: View {
    @ObservedObject var chat: ZoomChatBridge
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if chat.messages.isEmpty {
                // Empty state: a blank pane read as "broken or not
                // connected?" (Codex design audit #16).
                VStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Connected \u{2014} no messages yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                            MessageRow(message: message, showsHeader: startsGroup(at: index))
                                .id(message.id)
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                }
                .onChange(of: chat.messages.count) { _ in
                    guard let last = chat.messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            }

            Divider()

            HStack(spacing: 8) {
                MessageField(text: $draft, placeholder: "Message everyone", onSend: send)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: Capsule())

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .help("Send message")
                .accessibilityLabel("Send message")
                .disabled(draft.isEmpty)
                .foregroundStyle(draft.isEmpty
                    ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                    : AnyShapeStyle(Color.accentColor))
            }
            .padding(10)
        }
        .frame(minWidth: 300, minHeight: 380)
    }

    /// A message starts a new visual group when it's from a different
    /// sender than the one before it, or more than 3 minutes later -
    /// consecutive messages from the same person then read as one block,
    /// the way real chat clients do it.
    private func startsGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = chat.messages[index]
        let previous = chat.messages[index - 1]
        if previous.senderName != current.senderName { return true }
        return current.timestamp.timeIntervalSince(previous.timestamp) > 180
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        DispatchQueue.main.async { chat.send(text) }
    }
}

/// AppKit-backed message field. SwiftUI's TextField on macOS would NOT
/// reliably push a cleared binding back into the focused field editor -
/// the sent text visibly stayed in the box (reported twice, including
/// after an async-clear workaround). Owning the NSTextField lets the
/// clear be imperative and unconditional:
/// - Enter is intercepted via insertNewline (not target/action, which
///   also fires on focus loss and would send when clicking away),
/// - after sending, `stringValue = ""` resets both the field and its
///   live field editor, deterministically,
/// - the send BUTTON path clears through updateNSView, which pushes a
///   changed binding into the view (and never fights in-progress typing
///   because it only writes when the values differ).
private struct MessageField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSend: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        // Focus ring stays ON: removing it left keyboard users with no
        // visible focus state (Codex design audit #3).
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setAccessibilityLabel(placeholder)
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MessageField
        init(_ parent: MessageField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSend()
            control.stringValue = "" // the imperative clear - field AND field editor
            parent.text = ""
            return true
        }
    }
}

/// One message: initials avatar + name + time on the first message of a
/// group, then just bubbles for the rest. Outgoing messages sit right,
/// tinted; incoming sit left, neutral.
private struct MessageRow: View {
    let message: ChatMessage
    let showsHeader: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isOutgoing { Spacer(minLength: 32) }

            if !message.isOutgoing {
                // Invisible placeholder keeps grouped messages aligned
                // with the avatar above them.
                avatar.opacity(showsHeader ? 1 : 0)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if showsHeader {
                    HStack(spacing: 6) {
                        Text(message.senderName).font(.caption.bold())
                        Text(message.timestamp, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        message.isOutgoing
                            ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                            : AnyShapeStyle(HierarchicalShapeStyle.quaternary.opacity(0.6)),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }

            if !message.isOutgoing { Spacer(minLength: 32) }
        }
        .padding(.top, showsHeader ? 8 : 0)
    }

    private var avatar: some View {
        Circle()
            .fill(message.avatarColor.gradient)
            .frame(width: 26, height: 26)
            .overlay(
                Text(message.initials)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// Owns the single floating chat window - `show` just refocuses it if
/// it's already open rather than making a second one.
@MainActor
enum ChatWindowController {
    private static var window: NSWindow?

    /// `layout`, if given, slots the chat window into whatever slice of
    /// the screen the main pane *isn't* using (e.g. Left ¾ leaves the
    /// chat window the right quarter) - repositioned on every call, not
    /// just window creation, so it stays in sync if the layout settings
    /// change later. `nil` (or the chat toggled out of the side column)
    /// leaves size/position as-is (just the default centered window on
    /// first creation).
    static func show(chat: ZoomChatBridge, layout: WorkspaceLayout? = nil) {
        let targetWindow: NSWindow
        if let window {
            targetWindow = window
        } else {
            let hosting = NSHostingController(rootView: ChatWindowView(chat: chat).tint(Brand.green))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Meeting Chat"
            newWindow.setContentSize(NSSize(width: 340, height: 460))
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.isReleasedWhenClosed = false // ARC + close() below manage its lifetime
            window = newWindow
            targetWindow = newWindow
        }

        if let layout, layout.sideShowsChat, var rect = layout.sideColumnNSFrame() {
            // Leave the top of the column free for Zoom's meeting window -
            // but only when the tile is enabled AND the Accessibility
            // grant exists to actually put it there; otherwise the chat
            // takes the full column rather than leaving a hole nothing
            // will fill. This is the planned slot; adjustBelowZoom()
            // refines it once Zoom's window is actually parked (Zoom may
            // clamp to a larger minimum size).
            if layout.sideShowsZoomTile, ZoomWindowManager.hasAccessibilityPermission {
                rect.size.height -= rect.height * layout.effectiveZoomSlotRatio
            }
            targetWindow.setFrame(rect, display: true)
        }

        // Visible without stealing focus - in the session flow the user
        // should end up working in Chrome, with the chat alongside, not
        // yanked into Greenroom.
        targetWindow.orderFrontRegardless()
    }

    static var isOpen: Bool { window?.isVisible ?? false }

    /// Whether a given window is the chat window - the ghost-window hider
    /// needs to tell ours apart from the SDK's (whose titles also contain
    /// "Meeting").
    static func owns(_ candidate: NSWindow) -> Bool { candidate == window }

    static func close() {
        window?.close()
        window = nil
    }

    /// The slot above the chat window where Zoom's meeting window gets
    /// parked - in TOP-LEFT-origin (AX) coordinates, since that's what
    /// the Accessibility calls speak. Full column width, top
    /// `effectiveZoomSlotRatio` of the column's height (the whole column
    /// when the chat is toggled off; nil when the tile itself is off).
    static func zoomWindowAXFrame(for layout: WorkspaceLayout) -> CGRect? {
        guard layout.sideShowsZoomTile, let screen = NSScreen.main,
              let column = layout.sideColumnNSFrame() else { return nil }
        let topY = screen.frame.height - (column.origin.y + column.height)
        let height = column.height * layout.effectiveZoomSlotRatio
        return CGRect(x: column.origin.x, y: topY, width: column.width, height: height)
    }

    /// Same slot in NSWindow (bottom-left-origin) coordinates - for the
    /// all-in-one mode, whose meeting window is our own and parks via
    /// plain setFrame instead of the Accessibility API.
    static func zoomSlotNSFrame(for layout: WorkspaceLayout) -> CGRect? {
        guard layout.sideShowsZoomTile, let column = layout.sideColumnNSFrame() else { return nil }
        let height = column.height * layout.effectiveZoomSlotRatio
        return CGRect(x: column.origin.x, y: column.maxY - height, width: column.width, height: height)
    }

    /// Re-tucks the chat window to start exactly below Zoom's ACTUAL
    /// parked frame (AX coordinates) - Zoom clamps resizes to its minimum
    /// window size, so the planned slot and reality can differ.
    /// The chat expanded to the FULL side column - the speaker-tile
    /// quick-hide (\u{2303}\u{2325}\u{2318}Z) gives the chat the tile's
    /// vertical space while the tile is hidden.
    static func fillSideColumn(layout: WorkspaceLayout) {
        guard layout.sideShowsChat, let window, let column = layout.sideColumnNSFrame() else { return }
        window.setFrame(column, display: true)
    }

    static func adjustBelowZoom(actualZoomFrameAX zoomFrame: CGRect, layout: WorkspaceLayout) {
        guard layout.sideShowsChat, let window, let screen = NSScreen.main,
              let column = layout.sideColumnNSFrame() else { return }
        let zoomBottomNS = screen.frame.height - (zoomFrame.origin.y + zoomFrame.height)
        let height = max(zoomBottomNS - column.origin.y, 200) // never collapse the chat entirely
        window.setFrame(CGRect(x: column.origin.x, y: column.origin.y, width: column.width, height: height), display: true)
    }
}
