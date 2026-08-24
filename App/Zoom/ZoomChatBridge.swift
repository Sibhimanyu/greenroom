//
//  ZoomChatBridge.swift
//  Greenroom
//
//  Wraps ZoomSDKMeetingChatController as something SwiftUI can bind to.
//  Confirmed against the real header
//  (Vendor/ZoomSDK/ZoomSDK.framework/Versions/A/Headers/ZoomSDKMeetingChatController.h) -
//  an earlier draft of this file guessed chat lived on a different class
//  entirely (`ZoomSDKMeetingActionController`) with a simpler
//  `sendChat:toUser:` call; the real API is a builder
//  (`ZoomSDKChatMsgInfoBuilder`) producing a `ZoomSDKChatInfo` that's then
//  passed to `sendChatMsgTo:`.
//
//  What the SDK offers and this now uses: text, message edits, file transfer
//  both ways, threads, and quote ranges. What it does NOT offer, so Greenroom
//  cannot match Zoom's own client no matter how the UI is drawn: emoji
//  reactions ON a chat message, message recall, GIF search, read receipts, and
//  profile pictures. Emoji themselves need nothing - they are ordinary text.
//
import Foundation
import SwiftUI
import ZoomSDK

/// Where a file has got to. Receiving is deliberately not automatic: the SDK
/// hands over a `ZoomSDKFileReceiver` and waits for `startReceive(path)`, so
/// nothing a pupil sends reaches the teacher's disk until the teacher says so.
enum ChatAttachmentState: Equatable {
    /// Arrived, waiting for the teacher to accept it.
    case offered
    case receiving(Int)
    case sending(Int)
    case saved(URL)
    case sent
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .receiving, .sending: return true
        default: return false
        }
    }
    var percent: Int {
        switch self {
        case .receiving(let value), .sending(let value): return value
        case .saved, .sent: return 100
        default: return 0
        }
    }
}

struct ChatAttachment: Equatable {
    var name: String
    var sizeBytes: Int
    var state: ChatAttachmentState

    /// Only what AppKit can actually draw a thumbnail of. Anything else is
    /// shown as a file row, which is honest rather than a broken image well.
    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "bmp", "webp"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    /// The saved file, once there is one.
    var url: URL? {
        if case .saved(let url) = state { return url }
        return nil
    }
}

/// The message a reply is answering, resolved for display.
struct ChatQuote: Equatable {
    var sender: String
    var snippet: String
}

struct ChatMessage: Identifiable {
    let id: String
    let senderName: String
    var content: String
    let isOutgoing: Bool
    let timestamp: Date
    var attachment: ChatAttachment?
    var quote: ChatQuote?
    /// Nil when the message went to everyone. Set to the recipient's name for
    /// a private one, because "did the whole class see that" is a question a
    /// teacher needs answered at a glance.
    var privateTo: String?
    /// The message this one replies to, when the SDK reported a thread.
    var threadID: String?

    var isFile: Bool { attachment != nil }

    /// Zoom's Meeting SDK exposes no profile pictures for participants -
    /// checked the real headers: the only "avatar" APIs are the 3D
    /// animated-avatar feature and a video render type, nothing that
    /// yields a person's photo. So the chat draws initials avatars, which
    /// is also what a real client falls back to for anyone without a
    /// picture set.
    var initials: String {
        // First LETTER of each word, not first character: class names like
        // "Sibhi -8A" put a dash-word second, and taking characters rendered
        // the avatar as "S-". Words with no letter at all are skipped.
        let words = senderName.split(separator: " ")
        let letters = words.compactMap { word in
            word.first(where: { $0.isLetter }).map(String.init)
        }.prefix(2)
        if letters.isEmpty {
            return senderName.first.map { String($0).uppercased() } ?? "?"
        }
        return letters.joined().uppercased()
    }

    /// Stable per-person colour, derived from the name so the same person
    /// always gets the same swatch across sessions.
    /// SwiftUI-qualified: the ZoomSDK module exports a `Color` of its own,
    /// so the bare name is ambiguous in this file.
    var avatarColor: SwiftUI.Color {
        let palette: [SwiftUI.Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
        let hash = senderName.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return palette[hash % palette.count]
    }
}

@MainActor
final class ZoomChatBridge: NSObject, ObservableObject {

    @Published private(set) var messages: [ChatMessage] = []
    /// Set while a file is on its way out, so the composer can show it.
    @Published private(set) var lastError: String?

    /// Where accepted files are written. The coordinator points this at the
    /// session folder, so a lesson's attachments end up beside its recording
    /// and clips rather than loose in Downloads.
    var saveDirectory: URL?

    private weak var controller: ZoomSDKMeetingChatController?
    /// Receivers held until the teacher accepts. The SDK gives one object per
    /// offered file and it is the only handle to that transfer.
    private var pendingReceivers: [String: ZoomSDKFileReceiver] = [:]

    var fileTransferEnabled: Bool { controller?.isFileTransferEnabled() ?? false }
    var maxFileBytes: UInt64 { controller?.getMaxTransferFileSizeBytes() ?? 0 }
    /// Comma-separated per the header. Nil means the SDK would not say, which
    /// is not the same as "everything allowed".
    var allowedFileTypes: [String] {
        (controller?.getTransferFileTypeAllowList() ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    func attach(to controller: ZoomSDKMeetingChatController) {
        self.controller = controller
        controller.delegate = self
    }

    /// Called when a meeting ends - the next meeting starts with a clean
    /// slate instead of the previous meeting's messages.
    func reset() {
        messages.removeAll()
        pendingReceivers.removeAll()
        lastError = nil
    }

    // MARK: Sending

    /// Sends to everyone (`ZoomSDKChatMessageType_To_All`, receiver 0).
    ///
    /// A reply carries two things: the SDK's own thread ID, so Zoom clients
    /// thread it properly, and a quoted first line marked with
    /// `setQuotePosition` so it reads as a reply in clients that do not thread.
    /// The quote range is measured in UTF-16 units because that is what the
    /// builder's positions count, and a name with an emoji in it would
    /// otherwise shift every offset after it.
    func send(_ content: String, replyingTo parent: ChatMessage? = nil) {
        guard let controller else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var body = trimmed
        var quoteRange: (start: UInt32, end: UInt32)?
        if let parent {
            let quoted = "\(parent.senderName): \(Self.snippet(of: parent))\n"
            body = quoted + trimmed
            quoteRange = (0, UInt32(quoted.utf16.count))
        }

        let builder = ZoomSDKChatMsgInfoBuilder()
            .setContent(body)
            .setReceiver(0)
            .setMessageType(ZoomSDKChatMessageType_To_All)
        if let parent { _ = builder.setThreadId(parent.threadID ?? parent.id) }
        if let quoteRange {
            _ = builder.setQuotePosition(quoteRange.start, positionEnd: quoteRange.end)
        }

        // Deliberately NO optimistic append: the SDK echoes our own sent
        // messages back through onChatMessageNotification, so appending
        // here too showed every message twice (once as "You", once under
        // our real display name). The echo is the single source of truth.
        _ = controller.sendChatMsg(to: builder.build())
    }

    /// Sends a file to everyone. Checked against the SDK's own limits first,
    /// because a refusal from the far side arrives as a silent failure.
    func sendFile(_ url: URL) {
        guard let controller else { return }
        guard controller.isFileTransferEnabled() else {
            lastError = "File sharing is switched off for this meeting."
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let limit = controller.getMaxTransferFileSizeBytes()
        if limit > 0, UInt64(size) > limit {
            lastError = "\(url.lastPathComponent) is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) \u{2014} the limit is \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
            return
        }
        let allowed = allowedFileTypes
        let ext = url.pathExtension.lowercased()
        if !allowed.isEmpty, !allowed.contains(ext) {
            lastError = ".\(ext) files can't be shared in this meeting."
            return
        }
        lastError = nil
        let result = controller.transferFile(toAll: url.path)
        if result != ZoomSDKError_Success {
            lastError = "Couldn't send \(url.lastPathComponent)."
        }
    }

    /// Accepts an offered file and starts writing it.
    ///
    /// The teacher's decision, one file at a time. Nothing is written before
    /// this: the people sending are children, and the SDK's allow-list keeps
    /// out executables but very little else.
    func accept(_ message: ChatMessage) {
        guard let receiver = pendingReceivers[message.id],
              let attachment = message.attachment else { return }
        let folder = saveDirectory ?? FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = Self.uniqueURL(in: folder, named: attachment.name)

        update(message.id) { $0.attachment?.state = .receiving(0) }
        if receiver.startReceive(destination.path) != ZoomSDKError_Success {
            update(message.id) { $0.attachment?.state = .failed("Couldn't start the download.") }
            return
        }
        // Remembered so onFileTransferProgress can resolve the final path.
        acceptedDestinations[message.id] = destination
    }

    func declineFile(_ message: ChatMessage) {
        pendingReceivers[message.id]?.cancelReceive()
        pendingReceivers[message.id] = nil
        update(message.id) { $0.attachment?.state = .failed("Declined.") }
    }

    private var acceptedDestinations: [String: URL] = [:]

    // MARK: Helpers

    private func update(_ id: String, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    /// A short version of a message, for the quoted line of a reply.
    private static func snippet(of message: ChatMessage) -> String {
        if let attachment = message.attachment { return attachment.name }
        let flat = message.content.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= 80 ? flat : String(flat.prefix(79)) + "\u{2026}"
    }

    /// Never overwrite. Two pupils sending `photo.png` is the ordinary case,
    /// not an edge one.
    private static func uniqueURL(in folder: URL, named name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }
}

// MARK: - ZoomSDKMeetingChatControllerDelegate
//
// All five methods are @required (no @optional marker in the real protocol).

extension ZoomChatBridge: ZoomSDKMeetingChatControllerDelegate {

    func onChatMessageNotification(_ chatInfo: ZoomSDKChatInfo) {
        let id = chatInfo.getMessageID()
        guard !messages.contains(where: { $0.id == id }) else { return } // belt and braces vs. repeat delivery
        let fromMe = isSelf(userID: chatInfo.getSenderUserID())
        let type = chatInfo.getChatMessageType()
        let isPrivate = type == ZoomSDKChatMessageType_To_Individual
            || type == ZoomSDKChatMessageType_To_Individual_Panelist

        let threadID = chatInfo.getThreadID()
        let parent = threadID.isEmpty ? nil : messages.first { $0.id == threadID }

        messages.append(ChatMessage(
            id: id,
            senderName: fromMe ? "You" : chatInfo.getSenderDisplayName(),
            content: chatInfo.getMsgContent(),
            isOutgoing: fromMe,
            timestamp: Date(timeIntervalSince1970: TimeInterval(chatInfo.getTimeStamp())),
            quote: parent.map { ChatQuote(sender: $0.senderName, snippet: Self.snippet(of: $0)) },
            privateTo: isPrivate ? chatInfo.getReceiverDisplayName() : nil,
            threadID: threadID.isEmpty ? nil : threadID
        ))
    }

    /// Whether a sender ID is this SDK connection - true for messages we
    /// sent ourselves. Works in both modes: the all-in-one client is the
    /// user, and the hybrid mode's hidden participant is likewise "us".
    private func isSelf(userID: UInt32) -> Bool {
        guard let action = ZoomSDK.shared().getMeetingService()?.getMeetingActionController(),
              let info = action.getUserByUserID(userID) else { return false }
        return info.isMySelf()
    }

    /// A participant's name, for a file transfer - the receiver reports only a
    /// user ID. Same lookup shape as `isSelf` above, which is the one the
    /// compiler agreed with.
    private func displayName(userID: UInt32) -> String? {
        guard let action = ZoomSDK.shared().getMeetingService()?.getMeetingActionController(),
              let info = action.getUserByUserID(userID) else { return nil }
        return info.getUserName()
    }

    func onChatMessageEditNotification(_ chatInfo: ZoomSDKChatInfo) {
        update(chatInfo.getMessageID()) { $0.content = chatInfo.getMsgContent() }
    }

    // MARK: File transfer

    func onFileSendStart(_ sender: ZoomSDKFileSender) {
        let info = sender.transferInfo
        guard !messages.contains(where: { $0.id == info.messageId }) else { return }
        messages.append(ChatMessage(
            id: info.messageId,
            senderName: "You",
            content: "",
            isOutgoing: true,
            timestamp: Date(timeIntervalSince1970: TimeInterval(info.timeStamp)),
            attachment: ChatAttachment(name: info.fileName,
                                       sizeBytes: Int(info.fileSizeBytes),
                                       state: .sending(0)),
            privateTo: info.isSendToAll ? nil : "one person"
        ))
    }

    /// Images small enough to be a photo download themselves, so the chat
    /// shows a real preview instead of an Accept button - a picture a student
    /// sends is the thing the class is about to talk about, and a permission
    /// prompt in that moment reads as the app being broken. Everything else
    /// (documents, archives, oversized files) keeps the teacher's explicit
    /// Accept: the senders are children and the SDK's allow-list stops
    /// executables but very little else.
    private static let autoDownloadImageLimit = 25 * 1024 * 1024

    func onFileReceived(_ receiver: ZoomSDKFileReceiver) {
        let info = receiver.transferInfo
        pendingReceivers[info.messageId] = receiver
        guard !messages.contains(where: { $0.id == info.messageId }) else { return }
        let attachment = ChatAttachment(name: info.fileName,
                                        sizeBytes: Int(info.fileSizeBytes),
                                        state: .offered)
        let message = ChatMessage(
            id: info.messageId,
            senderName: displayName(userID: receiver.senderUserId) ?? "Someone",
            content: "",
            isOutgoing: false,
            timestamp: Date(timeIntervalSince1970: TimeInterval(info.timeStamp)),
            attachment: attachment,
            privateTo: info.isSendToAll ? nil : "you"
        )
        messages.append(message)
        if attachment.isImage, attachment.sizeBytes <= Self.autoDownloadImageLimit {
            accept(message)
        }
    }

    func onFileTransferProgress(_ info: ZoomSDKFileTransferInfo) {
        update(info.messageId) { message in
            guard var attachment = message.attachment else { return }
            let outgoing = message.isOutgoing
            switch info.transferStatus {
            case ZoomSDKFileTransferStatus_Transfering:
                let percent = Int(info.completePercentage)
                attachment.state = outgoing ? .sending(percent) : .receiving(percent)
            case ZoomSDKFileTransferStatus_TransferDone:
                if outgoing {
                    attachment.state = .sent
                } else if let destination = acceptedDestinations[info.messageId] {
                    attachment.state = .saved(destination)
                } else {
                    attachment.state = .sent
                }
                pendingReceivers[info.messageId] = nil
            case ZoomSDKFileTransferStatus_TransferFailed:
                attachment.state = .failed("Transfer failed.")
                pendingReceivers[info.messageId] = nil
            default:
                break
            }
            message.attachment = attachment
        }
    }
}
