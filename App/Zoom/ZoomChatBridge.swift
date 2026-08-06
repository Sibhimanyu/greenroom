//
//  ZoomChatBridge.swift
//  Greenroom
//
//  Wraps ZoomSDKMeetingChatController as something SwiftUI can bind to.
//  Confirmed against the real header
//  (Vendor/ZoomSDK/ZoomSDK/ZoomSDK.framework/Versions/A/Headers/ZoomSDKMeetingChatController.h) -
//  an earlier draft of this file guessed chat lived on a different class
//  entirely (`ZoomSDKMeetingActionController`) with a simpler
//  `sendChat:toUser:` call; the real API is a builder
//  (`ZoomSDKChatMsgInfoBuilder`) producing a `ZoomSDKChatInfo` that's then
//  passed to `sendChatMsgTo:`. Still unbuilt/unrun - no Xcode compile yet.
//
import Foundation
import SwiftUI
import ZoomSDK

struct ChatMessage: Identifiable {
    let id: String
    let senderName: String
    let content: String
    let isOutgoing: Bool
    let timestamp: Date

    /// Zoom's Meeting SDK exposes no profile pictures for participants -
    /// checked the real headers: the only "avatar" APIs are the 3D
    /// animated-avatar feature and a video render type, nothing that
    /// yields a person's photo. So the chat draws initials avatars, which
    /// is also what a real client falls back to for anyone without a
    /// picture set.
    var initials: String {
        let words = senderName.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
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

    private weak var controller: ZoomSDKMeetingChatController?

    func attach(to controller: ZoomSDKMeetingChatController) {
        self.controller = controller
        controller.delegate = self
    }

    /// Called when a meeting ends - the next meeting starts with a clean
    /// slate instead of the previous meeting's messages.
    func reset() {
        messages.removeAll()
    }

    /// Sends to everyone (`ZoomSDKChatMessageType_To_All`, receiver 0).
    func send(_ content: String) {
        guard let controller, !content.isEmpty else { return }
        // build() and the ZoomSDKChatInfo getters below are all
        // non-optional per the compiler (NS_ASSUME_NONNULL_BEGIN in the
        // real header, no explicit _Nullable) - an earlier draft assumed
        // optionals throughout and didn't compile.
        let message = ZoomSDKChatMsgInfoBuilder()
            .setContent(content)
            .setReceiver(0)
            .setMessageType(ZoomSDKChatMessageType_To_All)
            .build()

        // Deliberately NO optimistic append: the SDK echoes our own sent
        // messages back through onChatMessageNotification, so appending
        // here too showed every message twice (once as "You", once under
        // our real display name). The echo is the single source of truth.
        _ = controller.sendChatMsg(to: message)
    }
}

// MARK: - ZoomSDKMeetingChatControllerDelegate
//
// All five methods here are @required (no @optional marker in the real
// protocol) - the file-transfer ones are no-ops since Greenroom's chat
// window doesn't handle file transfer.

extension ZoomChatBridge: ZoomSDKMeetingChatControllerDelegate {
    func onChatMessageNotification(_ chatInfo: ZoomSDKChatInfo) {
        let id = chatInfo.getMessageID()
        guard !messages.contains(where: { $0.id == id }) else { return } // belt and braces vs. repeat delivery
        let fromMe = isSelf(userID: chatInfo.getSenderUserID())
        messages.append(ChatMessage(
            id: id,
            senderName: fromMe ? "You" : chatInfo.getSenderDisplayName(),
            content: chatInfo.getMsgContent(),
            isOutgoing: fromMe,
            timestamp: Date(timeIntervalSince1970: TimeInterval(chatInfo.getTimeStamp()))
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

    func onChatMessageEditNotification(_ chatInfo: ZoomSDKChatInfo) {
        let id = chatInfo.getMessageID()
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = ChatMessage(
            id: id,
            senderName: messages[index].senderName,
            content: chatInfo.getMsgContent(),
            isOutgoing: messages[index].isOutgoing,
            timestamp: messages[index].timestamp
        )
    }

    func onFileSendStart(_ sender: ZoomSDKFileSender) {}
    func onFileReceived(_ receiver: ZoomSDKFileReceiver) {}
    func onFileTransferProgress(_ info: ZoomSDKFileTransferInfo) {}
}
