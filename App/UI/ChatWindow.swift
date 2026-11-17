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
//  chat message, message recall, GIF search and read receipts. None of those
//  exist in ZoomSDKMeetingChatController, so they are absent rather than faked.
//  Profile pictures do exist (`ZoomSDKUserInfo.getAvatarPath`) and are drawn by
//  ParticipantAvatar; the layout rules live in ChatGrouping.
//
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// True where the chat sits inside the meeting window: Zoom's dark style
/// (MeetingTheme records why) instead of the standalone window's.
private struct MeetingZoomChatKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var meetingZoomChat: Bool {
        get { self[MeetingZoomChatKey.self] }
        set { self[MeetingZoomChatKey.self] = newValue }
    }
}

struct ChatWindowView: View {
    @ObservedObject var chat: ZoomChatBridge
    @Environment(\.meetingZoomChat) private var zoom
    @Environment(\.controlActiveState) private var activeState

    @Environment(\.colorScheme) private var colorScheme
    @State private var draft = ""
    @State private var replyingTo: ChatMessage?
    @State private var dropTargeted = false
    /// Index of the first message that arrived while the window was not the
    /// key window. The chat usually sits in a side column while the teacher
    /// works in Chrome, so "what did I miss" is the normal question.
    @State private var firstUnreadID: String?

    var body: some View {
        content
        // The meeting window's smallest height leaves its side panel about 376pt.
        .frame(minWidth: 300, minHeight: 300)
        .background(zoom ? MeetingTheme.window : Color.clear)
        .environment(\.colorScheme, zoom ? .dark : (colorScheme))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Brand.green, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Brand.green.opacity(0.06))
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

    /// The meeting form is the docked column it always was (2026-11-12). The
    /// standalone chat floats a glass capsule composer over the transcript.
    @ViewBuilder private var content: some View {
        if zoom {
            VStack(spacing: 0) {
                transcript
                if let error = chat.lastError { errorBar(error) }
                if let replyingTo { replyBar(replyingTo) }
                Rectangle().fill(MeetingTheme.hairline).frame(height: 1)
                composer
            }
        } else {
            transcript
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if let error = chat.lastError { errorBar(error) }
                        if let replyingTo { replyBar(replyingTo) }
                        composer
                    }
                }
        }
    }

    // MARK: Transcript

    @ViewBuilder private var transcript: some View {
        if chat.messages.isEmpty {
            Text("No messages yet. Say hello to the class.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    let rows = ChatGrouping.rows(chat.messages.map(\.line))
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(zip(chat.messages, rows).enumerated()), id: \.element.0.id) { index, pair in
                            let (message, row) = pair
                            if let day = daySeparator(at: index) { DayDivider(label: day) }
                            if message.id == firstUnreadID { UnreadDivider() }
                            MessageRow(message: message,
                                       row: row,
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
        .foregroundStyle(Brand.netText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Brand.net.opacity(0.12))
    }

    /// The message being answered, shown above the composer so it is obvious
    /// what will be quoted before it is sent.
    private func replyBar(_ message: ChatMessage) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Brand.green).frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(message.privateTo != nil ? "Replying privately to \(message.senderName)" : "Replying to \(message.senderName)")
                    .font(.caption2.bold())
                    .foregroundStyle(Brand.text)
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

    /// Set when the message being answered was private: the answer goes back
    /// to that one person, never to the class.
    private var privateRecipient: (id: UInt32, name: String)? {
        guard let message = replyingTo, message.privateTo != nil, message.privatePartnerID != 0 else { return nil }
        return (message.privatePartnerID, message.isOutgoing ? (message.privateTo ?? "them") : message.senderName)
    }

    /// A quiet line of who will see it, then the box: Return sends, Shift-Return
    /// is a new line.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ChatGrouping.audienceNote(privateTo: privateRecipient?.name))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: pickFile) {
                    Image(systemName: "paperclip").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(chat.fileTransferEnabled ? AnyShapeStyle(HierarchicalShapeStyle.secondary)
                                                          : AnyShapeStyle(HierarchicalShapeStyle.quaternary))
                .disabled(!chat.fileTransferEnabled)
                .frame(height: 28)
                .help(chat.fileTransferEnabled
                      ? "Share a file with everyone\u{2026}"
                      : "File sharing is switched off for this meeting")
                .accessibilityLabel("Share a file")

                ChatMessageField(text: $draft,
                                 placeholder: ChatGrouping.placeholder(privateTo: privateRecipient?.name,
                                                                       replying: replyingTo != nil),
                                 onSend: send,
                                 onPasteFiles: share)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(zoom ? AnyShapeStyle(MeetingTheme.raised) : AnyShapeStyle(Color.primary.opacity(0.07)),
                                in: RoundedRectangle(cornerRadius: 10))

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .frame(height: 28)
                .help("Send message")
                .accessibilityLabel("Send message")
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? AnyShapeStyle(HierarchicalShapeStyle.tertiary)
                    : AnyShapeStyle(Brand.green))
            }
        }
        .padding(12)
    }

    // MARK: Behaviour

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
        let recipient = privateRecipient?.id ?? 0
        draft = ""
        replyingTo = nil
        DispatchQueue.main.async { chat.send(text, replyingTo: parent, privatelyTo: recipient) }
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
            Rectangle().fill(Brand.green.opacity(0.6)).frame(height: 1)
            Text("NEW")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Brand.text)
            Rectangle().fill(Brand.green.opacity(0.6)).frame(height: 1)
        }
        .padding(.vertical, 6)
    }
}

/// One message: the shared layout in ChatMessageRow, with this message's
/// quote and file card inside the bubble.
private struct MessageRow: View {
    let message: ChatMessage
    let row: ChatGrouping.Row
    let onReply: () -> Void
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ChatMessageRow(row: row,
                       userID: message.senderUserID,
                       text: message.content,
                       hasExtra: message.quote != nil || message.attachment != nil,
                       onReply: onReply) {
            if let quote = message.quote { quoteBlock(quote) }
            if let attachment = message.attachment {
                AttachmentView(attachment: attachment, onAccept: onAccept, onDecline: onDecline)
            }
        }
    }

    private func quoteBlock(_ quote: ChatQuote) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Brand.green.opacity(0.7)).frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.sender).font(.caption2.bold()).foregroundStyle(.secondary)
                Text(quote.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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

    /// `frame` (AppKit coordinates), if given, is where the layout's Chat piece
    /// goes - applied on every call, not just window creation, so it stays in
    /// step if the layout changes later. `nil` leaves size/position as-is (just
    /// the default centred window on first creation).
    static func show(chat: ZoomChatBridge, frame: NSRect? = nil) {
        let targetWindow: NSWindow
        if let window {
            targetWindow = window
        } else {
            let hosting = NSHostingController(rootView: ChatWindowView(chat: chat).tint(Brand.green))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Meeting Chat"
            newWindow.setContentSize(NSSize(width: 340, height: 460))
            newWindow.center() // opened on demand with no layout, it must not land in a corner
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.isReleasedWhenClosed = false // ARC + close() below manage its lifetime
            // Opens on the desktop you are on. Without this a chat window left
            // on another Space stayed there, and the bar's Chat button raised
            // it out of sight (owner, 2026-11-15). `.fullScreenAuxiliary` lets
            // it be there over a full-screen app: without it macOS sends you to
            // another desktop instead (owner, 2026-11-16).
            newWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            // Only you see the chat: a frosted background, opaque messages.
            WindowFrost.install(in: newWindow, solid: .windowBackgroundColor)
            window = newWindow
            targetWindow = newWindow
        }

        if let frame { targetWindow.setFrame(frame, display: true) }

        // Left on another desktop: off that one first, so it lands on this one.
        if MeetingSurfaces.comesHereFirst(visible: targetWindow.isVisible, onActiveSpace: targetWindow.isOnActiveSpace) {
            targetWindow.orderOut(nil)
        }
        // Visible without stealing focus - in the session flow the user
        // should end up working in Chrome, with the chat alongside, not
        // yanked into Greenroom.
        targetWindow.orderFrontRegardless()
    }

    static var isOpen: Bool { window?.isVisible ?? false }

    /// Open and on the desktop you are looking at. Open on another Space it is
    /// not "here", and the Chat button brings it over instead of closing it.
    static var isOpenHere: Bool { isOpen && (window?.isOnActiveSpace ?? false) }

    /// Whether a given window is the chat window - the ghost-window hider
    /// needs to tell ours apart from the SDK's (whose titles also contain
    /// "Meeting").
    static func owns(_ candidate: NSWindow) -> Bool { candidate == window }

    /// Brings the chat forward without rebuilding it, for the Chat button on the
    /// participant panel's toolbar. Zoom's toolbar has one; Greenroom's chat
    /// lives in its own window, so the button raises that rather than opening a
    /// panel inside the meeting view.
    static func reveal() {
        guard let window else { return }
        // Left on another desktop: off that one first, so it lands on this one.
        if MeetingSurfaces.comesHereFirst(visible: window.isVisible, onActiveSpace: window.isOnActiveSpace) {
            window.orderOut(nil)
        }
        window.orderFrontRegardless()
    }

    /// Moves the open chat window; no-op when it is closed.
    static func setFrame(_ frame: NSRect) {
        window?.setFrame(frame, display: true)
    }

    static func close() {
        window?.close()
        window = nil
    }
}


private extension ChatMessage {
    /// What ChatGrouping needs to know.
    var line: ChatLine {
        ChatLine(id: id,
                 senderKey: senderUserID != 0 ? "\(senderUserID)" : senderName,
                 senderName: senderName,
                 isOutgoing: isOutgoing,
                 timestamp: timestamp,
                 privateTo: privateTo,
                 isFile: isFile)
    }
}
