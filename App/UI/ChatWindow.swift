//
//  ChatWindow.swift
//  Greenroom
//
//  A standalone window for the Meeting SDK chat bridge - independent of
//  Greenroom's main window, and independent of Zoom's own UI (this reads
//  Meeting SDK callbacks, not Zoom's window - there's nothing to pop out
//  of Zoom itself here).
//
//  What is here matches what the SDK actually exposes: text, emoji (ordinary
//  characters, nothing special needed), file transfer both ways, threads and
//  quoted replies. What Zoom's own client has and this cannot: reactions on a
//  chat message, message recall, GIF search, read receipts and profile
//  pictures. None of those exist in ZoomSDKMeetingChatController, so they are
//  absent rather than faked.
//
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChatWindowView: View {
    @ObservedObject var chat: ZoomChatBridge
    @Environment(\.controlActiveState) private var activeState

    @State private var draft = ""
    @State private var replyingTo: ChatMessage?
    @State private var dropTargeted = false
    /// Index of the first message that arrived while the window was not the
    /// key window. The chat usually sits in a side column while the teacher
    /// works in Chrome, so "what did I miss" is the normal question.
    @State private var firstUnreadID: String?

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if let error = chat.lastError { errorBar(error) }
            if let replyingTo { replyBar(replyingTo) }
            Divider()
            composer
        }
        .frame(minWidth: 300, minHeight: 380)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.06))
                    .overlay(Label("Drop to share with everyone", systemImage: "paperclip"))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            attach(from: providers)
        }
        .onChange(of: chat.messages.count) { _ in noteArrival() }
        .onChange(of: activeState) { state in
            if state == .key { firstUnreadID = nil }
        }
    }

    // MARK: Transcript

    @ViewBuilder private var transcript: some View {
        if chat.messages.isEmpty {
            // Empty state: a blank pane read as "broken or not connected?"
            // (Codex design audit #16).
            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("Connected \u{2014} no messages yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(chat.fileTransferEnabled
                     ? "Type below, or drag a file in to share it with the class."
                     : "Type below. File sharing is switched off for this meeting.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                            if let day = daySeparator(at: index) { DayDivider(label: day) }
                            if message.id == firstUnreadID { UnreadDivider() }
                            MessageRow(message: message,
                                       showsHeader: startsGroup(at: index),
                                       onReply: { replyingTo = message },
                                       onAccept: { chat.accept(message) },
                                       onDecline: { chat.declineFile(message) })
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
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.caption)
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    /// The message being answered, shown above the composer so it is obvious
    /// what will be quoted before it is sent.
    private func replyBar(_ message: ChatMessage) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor).frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(message.senderName)")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.accentColor)
                Text(message.isFile ? (message.attachment?.name ?? "") : message.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel reply")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: 40)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(spacing: 8) {
            Button(action: pickFile) {
                Image(systemName: "paperclip").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(chat.fileTransferEnabled ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                                      : AnyShapeStyle(HierarchicalShapeStyle.quaternary))
            .disabled(!chat.fileTransferEnabled)
            .help(chat.fileTransferEnabled
                  ? "Share a file with everyone\u{2026}"
                  : "File sharing is switched off for this meeting")
            .accessibilityLabel("Share a file")

            MessageField(text: $draft,
                         placeholder: replyingTo == nil ? "Message everyone" : "Write your reply",
                         onSend: send,
                         onPasteFiles: share)
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

    // MARK: Behaviour

    /// A message starts a new visual group when it's from a different
    /// sender than the one before it, or more than 3 minutes later -
    /// consecutive messages from the same person then read as one block,
    /// the way real chat clients do it.
    private func startsGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let current = chat.messages[index]
        let previous = chat.messages[index - 1]
        if previous.senderName != current.senderName { return true }
        if current.isFile || previous.isFile { return true }
        return current.timestamp.timeIntervalSince(previous.timestamp) > 180
    }

    /// "Today", "Yesterday" or a date, on the first message of each day. A
    /// class that runs over two sessions otherwise reads as one long morning.
    private func daySeparator(at index: Int) -> String? {
        let current = chat.messages[index].timestamp
        if index > 0 {
            let previous = chat.messages[index - 1].timestamp
            guard !Calendar.current.isDate(current, inSameDayAs: previous) else { return nil }
        }
        if Calendar.current.isDateInToday(current) { return "Today" }
        if Calendar.current.isDateInYesterday(current) { return "Yesterday" }
        return current.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func noteArrival() {
        guard activeState != .key else { firstUnreadID = nil; return }
        guard firstUnreadID == nil, let last = chat.messages.last, !last.isOutgoing else { return }
        firstUnreadID = last.id
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let parent = replyingTo
        draft = ""
        replyingTo = nil
        DispatchQueue.main.async { chat.send(text, replyingTo: parent) }
    }

    private func share(_ urls: [URL]) {
        for url in urls { chat.sendFile(url) }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Share"
        panel.message = "Share with everyone in the meeting"
        guard panel.runModal() == .OK else { return }
        share(panel.urls)
    }

    private func attach(from providers: [NSItemProvider]) -> Bool {
        guard chat.fileTransferEnabled else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in chat.sendFile(url) }
            }
        }
        return true
    }
}

/// A dated rule between days.
private struct DayDivider: View {
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.vertical, 10)
    }
}

/// Where the teacher stopped reading.
private struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.6)).frame(height: 1)
            Text("NEW")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            Rectangle().fill(Color.accentColor.opacity(0.6)).frame(height: 1)
        }
        .padding(.vertical, 6)
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
///
/// It also owns paste. ⌘V with a file or an image on the pasteboard shares
/// it rather than pasting a path string, which is what a teacher copying a
/// picture actually means - and when the pasteboard holds plain text it
/// falls straight through to normal pasting.
private struct MessageField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSend: () -> Void
    var onPasteFiles: ([URL]) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextField {
        let field = PastingTextField()
        field.onPasteFiles = onPasteFiles
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
        (field as? PastingTextField)?.onPasteFiles = onPasteFiles
        field.placeholderString = placeholder
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

    /// Intercepts ⌘V only when the pasteboard actually holds files or image
    /// data. Text paste is left completely alone - hijacking it would be a far
    /// worse bug than the feature is worth.
    final class PastingTextField: NSTextField {
        var onPasteFiles: ([URL]) -> Void = { _ in }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return super.performKeyEquivalent(with: event)
            }
            let board = NSPasteboard.general
            if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
               !urls.isEmpty, urls.allSatisfy(\.isFileURL) {
                onPasteFiles(urls)
                return true
            }
            // An image copied from Preview or a browser has no file behind it,
            // so it is written out before it can be shared.
            if let image = NSImage(pasteboard: board), let url = Self.writeTemporary(image) {
                onPasteFiles([url])
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        private static func writeTemporary(_ image: NSImage) -> URL? {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Pasted image.png")
            try? png.write(to: url, options: .atomic)
            return url
        }
    }
}

/// One message: initials avatar + name + time on the first message of a
/// group, then just bubbles for the rest. Outgoing messages sit right,
/// tinted; incoming sit left, neutral.
private struct MessageRow: View {
    let message: ChatMessage
    let showsHeader: Bool
    let onReply: () -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.isOutgoing { Spacer(minLength: 32) }
            if !message.isOutgoing {
                // Invisible placeholder keeps grouped messages aligned
                // with the avatar above them.
                avatar.opacity(showsHeader ? 1 : 0)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                if showsHeader { header }
                bubble
            }

            if !message.isOutgoing { Spacer(minLength: 32) }
        }
        .padding(.top, showsHeader ? 8 : 0)
        .onHover { hovering = $0 }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(message.senderName).font(.caption.bold())
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let privateTo = message.privateTo {
                Label("private to \(privateTo)", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            if hovering {
                Button(action: onReply) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reply to this message")
            }
        }
    }

    @ViewBuilder private var bubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let quote = message.quote { quoteBlock(quote) }
            if let attachment = message.attachment {
                AttachmentView(attachment: attachment,
                               onAccept: onAccept,
                               onDecline: onDecline)
            }
            if !message.content.isEmpty {
                // Links are made tappable by Text's markdown handling of bare
                // URLs; selection stays on so a meeting code can be copied.
                Text(.init(message.content))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            message.isOutgoing
                ? AnyShapeStyle(Color.accentColor.opacity(0.22))
                : AnyShapeStyle(HierarchicalShapeStyle.quaternary.opacity(0.6)),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func quoteBlock(_ quote: ChatQuote) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color.accentColor.opacity(0.7)).frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.sender).font(.caption2.bold()).foregroundStyle(Color.accentColor)
                Text(quote.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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

/// A file in the transcript: a thumbnail once an image is on disk, a row with
/// its name and size otherwise, and the accept decision when one is pending.
private struct AttachmentView: View {
    let attachment: ChatAttachment
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = attachment.url, attachment.isImage, let image = NSImage(contentsOf: url) {
                // The picture IS the message: preview first, details beneath.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .help("Click to open")
            } else if attachment.isImage, attachment.state.isBusy {
                // Downloading: hold the picture's place instead of showing a
                // bare progress row that looks like a permission prompt.
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(width: 220, height: 140)
                    .overlay {
                        VStack(spacing: 6) {
                            ProgressView(value: Double(attachment.state.percent), total: 100)
                                .controlSize(.small)
                                .frame(width: 120)
                            Text("Receiving photo\u{2026}")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
            }

            HStack(spacing: 8) {
                Image(systemName: attachment.isImage ? "photo" : "doc")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.name).font(.caption.bold()).lineLimit(1).truncationMode(.middle)
                    Text(statusLine).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                controls
            }

            if attachment.state.isBusy, !attachment.isImage {
                ProgressView(value: Double(attachment.state.percent), total: 100)
                    .controlSize(.small)
            }
        }
        .frame(minWidth: 190, alignment: .leading)
    }

    @ViewBuilder private var controls: some View {
        switch attachment.state {
        case .offered:
            // Nothing is written to disk until this is pressed. The senders
            // are children and the SDK's allow-list stops executables and
            // little else, so the teacher makes the call.
            HStack(spacing: 4) {
                Button("Accept", action: onAccept).controlSize(.small)
                Button("Decline", role: .destructive, action: onDecline).controlSize(.small)
            }
        case .saved(let url):
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var statusLine: String {
        switch attachment.state {
        case .offered:     return attachment.isImage
            ? "\(attachment.sizeLabel) \u{2014} too large to preview automatically"
            : "\(attachment.sizeLabel) \u{2014} waiting for you to accept"
        case .receiving:   return "Downloading\u{2026} \(attachment.state.percent)%"
        case .sending:     return "Sending\u{2026} \(attachment.state.percent)%"
        case .saved:       return "\(attachment.sizeLabel) \u{2014} saved with this class"
        case .sent:        return "\(attachment.sizeLabel) \u{2014} sent"
        case .failed(let why): return why
        }
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

    /// Brings the chat forward without rebuilding it, for the Chat button on the
    /// participant panel's toolbar. Zoom's toolbar has one; Greenroom's chat
    /// lives in its own window, so the button raises that rather than opening a
    /// panel inside the meeting view.
    static func reveal(layout: WorkspaceLayout) {
        guard let window else { return }
        if let slot = zoomSlotNSFrame(for: layout), window.frame == .zero {
            window.setFrame(slot, display: true)
        }
        window.orderFrontRegardless()
    }

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
        guard layout.sideShowsZoomTile, let screen = DisplayResolver.mainDisplayScreen(),
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
    /// quick-hide (\u{2325}\u{2318}Z) gives the chat the tile's
    /// vertical space while the tile is hidden.
    static func fillSideColumn(layout: WorkspaceLayout) {
        guard layout.sideShowsChat, let window, let column = layout.sideColumnNSFrame() else { return }
        window.setFrame(column, display: true)
    }

    static func adjustBelowZoom(actualZoomFrameAX zoomFrame: CGRect, layout: WorkspaceLayout) {
        guard layout.sideShowsChat, let window, let screen = DisplayResolver.mainDisplayScreen(),
              let column = layout.sideColumnNSFrame() else { return }
        let zoomBottomNS = screen.frame.height - (zoomFrame.origin.y + zoomFrame.height)
        let height = max(zoomBottomNS - column.origin.y, 200) // never collapse the chat entirely
        window.setFrame(CGRect(x: column.origin.x, y: column.origin.y, width: column.width, height: height), display: true)
    }
}
