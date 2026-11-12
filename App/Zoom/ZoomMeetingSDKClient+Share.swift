//
//  ZoomMeetingSDKClient+Share.swift
//  Greenroom
//
//  Seeing other people's shared screens (phase 2 of .context/meeting-window-plan.md).
//
//  In custom UI Zoom draws nothing, so a share has to be asked for and given a
//  view: the ASController's delegate says who started and stopped sharing, the
//  share container makes an element for one source, and that element's view goes
//  on the stage.
//
//  SDK path, each step against the vendored headers:
//    - delegate                ZoomSDKASController.h:271 (`delegate`), protocol :194, all @optional
//    - status events           onSharingStatusChanged: :203; ZoomSDKShareStatus_OtherBegin / _OtherEnd
//                              / _SelfBegin / _SelfEnd, ZoomSDKErrors.h:490-498
//    - shares already running  getViewableSharingUserList :311, getSharingSourceInfoList: :318
//    - container               getShareContainer :372
//    - element                 createShareElement: ZoomSDKShareContainer.h:106; sharingID :42,
//                              viewMode :46 (ViewShareMode_LetterBox, ZoomSDKErrors.h:1051-1054),
//                              shareView :50, resize: :65, ShowShareRender: :71
//    - teardown                cleanShareElement: ZoomSDKShareContainer.h:112
//    - the share rule changing onShareSettingTypeChanged: ZoomSDKASController.h:234
//
//  The lesson from the video stage applies here too: a view the SDK renders into
//  draws only once it sits in a visible window. So the element is created and its
//  view handed to the window first, and ShowShareRender: is called only when the
//  view is in a visible window (`renderIfReady`), retried each pass until it is.
//
//  Everything is logged to Greenroom-video.log with a "Share view:" prefix.
//
import AppKit
import Foundation
import ZoomSDK

@MainActor
final class ShareViewer: NSObject, ZoomSDKASControllerDelegate, ZoomSDKShareContainerDelegate,
                         ZoomSDKShareElementDelegate {

    /// Which other person's share the stage shows, and the shares to choose from.
    private(set) var selection = ShareStageSelection()
    /// You are sharing a screen (through Zoom, not the camera picture).
    private(set) var selfSharing = false
    /// The rule last reported by the SDK, nil until it says.
    private(set) var reportedRule: ShareRule?

    /// A share began or ended: redraw now rather than at the next poll.
    var onChange: (() -> Void)?
    /// A user's name, for the chip. Set by the client.
    var nameFor: (UInt32) -> String? = { _ in nil }

    /// sourceID -> the user sharing it.
    private var users: [UInt32: UInt32] = [:]
    private var element: ZoomSDKShareElement?
    private var elementSource: UInt32?
    private var rendering = false
    private var lastFrame: NSRect = .zero
    private var lastRenderLogged = false

    static func log(_ message: String) { ZoomMeetingSDKClient.videoLog("Share view: \(message)") }

    // MARK: Wiring

    /// Called once the meeting exists. Picks up shares that were already running
    /// when this Mac joined, which no event will announce.
    func install(on service: ZoomSDKMeetingService) {
        let controller = service.getASController()
        controller.delegate = self
        Self.log("delegate wired")
        for case let number as NSNumber in controller.getViewableSharingUserList() ?? [] {
            let userID = number.uint32Value
            for info in controller.getSharingSourceInfoList(userID) ?? [] {
                note(info, began: true)
            }
        }
        onChange?()
    }

    /// Leaving the meeting, or the window closing.
    func reset() {
        releaseElement()
        selection.removeAll()
        users = [:]
        selfSharing = false
        reportedRule = nil
    }

    // MARK: What the window reads

    /// The user and source on the stage, if somebody else is sharing.
    var current: (sourceID: UInt32, userID: UInt32, name: String)? {
        guard let id = selection.current else { return nil }
        let user = users[id] ?? 0
        return (id, user, nameFor(user) ?? "Someone")
    }

    /// Every share to choose from, newest last.
    var choices: [(sourceID: UInt32, name: String)] {
        selection.order.map { ($0, nameFor(users[$0] ?? 0) ?? "Someone") }
    }

    func pick(_ sourceID: UInt32) {
        selection.pick(sourceID)
        Self.log("picked source=\(sourceID)")
        onChange?()
    }

    // MARK: The view

    /// The stage's view for the current share, sized to `frame`. Nil when nobody
    /// else is sharing, or the SDK would not make an element.
    func stageView(frame: NSRect) -> NSView? {
        guard let id = selection.current else { releaseElement(); return nil }
        if elementSource != id { releaseElement() }
        if element == nil {
            guard let container = ZoomSDK.shared().getMeetingService()?.getASController().getShareContainer() else {
                Self.log("no share container for source=\(id)")
                return nil
            }
            container.delegate = self
            var made: ZoomSDKShareElement? = ZoomSDKShareElement(frame: frame)
            let result = container.createShareElement(&made)
            guard result == ZoomSDKError_Success else {
                Self.log("createShareElement failed code=\(result.rawValue) source=\(id)")
                return nil
            }
            guard let made else { return nil }
            made.sharingID = id
            // The whole screen visible, never cropped: a teacher reads the text.
            made.viewMode = ViewShareMode_LetterBox
            made.delegate = self
            made.shareView?.wantsLayer = true
            element = made
            elementSource = id
            rendering = false
            lastFrame = frame
            Self.log("created source=\(id) user=\(users[id] ?? 0) frame=\(Int(frame.width))x\(Int(frame.height))")
        }
        guard let element else { return nil }
        if lastFrame != frame {
            lastFrame = frame
            _ = element.resize(frame)
        }
        return element.shareView
    }

    /// Starts drawing once the view is in a visible window. Called by the window
    /// after it has put the view in place; harmless to call every pass.
    func renderIfReady() {
        guard let element, !rendering, let view = element.shareView,
              view.window?.isVisible == true else { return }
        let result = element.showShareRender(true)
        rendering = result == ZoomSDKError_Success
        Self.log("ShowShareRender source=\(elementSource ?? 0) code=\(result.rawValue)")
    }

    /// Gallery view, no sharer, or the meeting ending: give the element back.
    func releaseElement() {
        guard let element else { return }
        Self.log("release source=\(elementSource ?? 0)")
        _ = element.showShareRender(false)
        element.shareView?.removeFromSuperview()
        _ = ZoomSDK.shared().getMeetingService()?.getASController().getShareContainer()?.clean(element)
        self.element = nil
        elementSource = nil
        rendering = false
        lastFrame = .zero
    }

    // MARK: Bookkeeping

    private func note(_ info: ZoomSDKSharingSourceInfo, began: Bool) {
        let id = info.shareSourceID
        if began {
            users[id] = info.userID
            selection.began(id)
        } else {
            selection.ended(id)
            users.removeValue(forKey: id)
        }
    }

    private static func name(of status: ZoomSDKShareStatus) -> String {
        switch status {
        case ZoomSDKShareStatus_None: return "none"
        case ZoomSDKShareStatus_SelfBegin: return "selfBegin"
        case ZoomSDKShareStatus_SelfEnd: return "selfEnd"
        case ZoomSDKShareStatus_OtherBegin: return "otherBegin"
        case ZoomSDKShareStatus_OtherEnd: return "otherEnd"
        case ZoomSDKShareStatus_ViewOther: return "viewOther"
        case ZoomSDKShareStatus_Pause: return "pause"
        case ZoomSDKShareStatus_Resume: return "resume"
        case ZoomSDKShareStatus_ContentTypeChange: return "contentTypeChange"
        case ZoomSDKShareStatus_Disconnected: return "disconnected"
        default: return "status\(status.rawValue)"
        }
    }

    // MARK: ZoomSDKASControllerDelegate (all optional; only what the stage needs)

    func onSharingStatusChanged(_ shareInfo: ZoomSDKSharingSourceInfo!) {
        guard let shareInfo else { return }
        // contentType can read UNKNOWN for a moment after a start
        // (ZoomSDKASController.h:199-202); it is only logged, never acted on.
        Self.log("status=\(Self.name(of: shareInfo.status)) source=\(shareInfo.shareSourceID)"
                 + " user=\(shareInfo.userID) contentType=\(shareInfo.contentType.rawValue)")
        switch shareInfo.status {
        case ZoomSDKShareStatus_SelfBegin: selfSharing = true
        case ZoomSDKShareStatus_SelfEnd: selfSharing = false
        case ZoomSDKShareStatus_OtherBegin: note(shareInfo, began: true)
        case ZoomSDKShareStatus_OtherEnd: note(shareInfo, began: false)
        case ZoomSDKShareStatus_Disconnected:
            selection.removeAll()
            users = [:]
            selfSharing = false
        default: break
        }
        onChange?()
    }

    func onShareContentChanged(_ shareInfo: ZoomSDKSharingSourceInfo!) {
        guard let shareInfo else { return }
        Self.log("content changed source=\(shareInfo.shareSourceID) contentType=\(shareInfo.contentType.rawValue)")
        onChange?()
    }

    func onFailedToStartShare() {
        Self.log("failed to start share")
        onChange?()
    }

    func onShareSettingTypeChanged(_ type: ZoomSDKShareSettingType) {
        reportedRule = ShareRule(sdkRaw: Int(type.rawValue))
        Self.log("share setting type=\(type.rawValue)")
        onChange?()
    }

    // MARK: ZoomSDKShareElementDelegate (ZoomSDKShareContainer.h:13-24)

    func onShareContentStartReceiving() { Self.log("content receiving source=\(elementSource ?? 0)") }
    func onShareSourceNotify(_ sharingID: UInt32) { Self.log("source notify id=\(sharingID)") }

    // MARK: ZoomSDKShareContainerDelegate (ZoomSDKShareContainer.h:79-85)

    func onShareElementDestroy(_ element: ZoomSDKShareElement!) {
        Self.log("element destroyed by the SDK")
        if element === self.element {
            self.element = nil
            elementSource = nil
            rendering = false
        }
    }
}
