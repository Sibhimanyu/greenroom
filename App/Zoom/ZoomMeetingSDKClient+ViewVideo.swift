//
//  ZoomMeetingSDKClient+ViewVideo.swift
//  Greenroom
//
//  Render elements for the view windows (.context/meeting-views-plan.md, section 2).
//
//  Each open view window owns its elements, keyed by the window and a slot in it
//  (the stage, a person's tile, a multi-speaker place, your own picture). They
//  are ordinary normal elements (createNormalVideoElement:), made one per slot
//  from the same process-wide container the Meeting window uses, and never shared
//  with it: a view has one superview, and an element belongs to one window for
//  life. The Meeting window keeps its own maps (participantElements and the
//  stage); the budget sees both (VideoBudget).
//
//  The lessons of the Meeting window apply unchanged:
//    - a subscription made before the view is in a VISIBLE window never draws, so
//      the element is made first and subscribed only once `window.isVisible`;
//    - setResolution goes in before subscribing, because the quota is spent at
//      subscribe time, and is asked twice when the SDK refuses it once;
//    - a switch of person on one element is a subscription change and Zoom
//      refuses bursts of them (code 7): two seconds apart per element, half a
//      second apart across elements;
//    - a refusal buys silence (2, 4, 8, 16, 32 s), then the SAME element asks again.
//
//  Everything is logged to Greenroom-video.log with a "View window:" prefix.
//
import AppKit
import Foundation
import ZoomSDK

struct ViewVideoKey: Hashable {
    let view: MeetingView
    let slot: ViewSlot

    var text: String { "\(view.rawValue)/\(slot)" }
}

@MainActor
final class ViewVideoStore {

    final class Entry {
        let key: ViewVideoKey
        let element: ZoomSDKNormalVideoElement
        var userID: UInt32
        var tier: VideoTier
        var lastFrame: NSRect
        var subscribed = false
        var subscribedAt: Date?
        var gotVideo = false
        var nextSwitchAt = Date().addingTimeInterval(2)
        var cooldownUntil = Date.distantPast
        var attempts = 0
        var lastFailure = Date.distantPast
        var warnedNoVideo = false

        init(key: ViewVideoKey, element: ZoomSDKNormalVideoElement, userID: UInt32, tier: VideoTier, frame: NSRect) {
            self.key = key
            self.element = element
            self.userID = userID
            self.tier = tier
            self.lastFrame = frame
        }
    }

    private(set) var entries: [ViewVideoKey: Entry] = [:]
    /// One subscription at a time across all view elements.
    var nextSubscribeAt = Date.distantPast

    func entry(for element: ZoomSDKVideoElement) -> Entry? {
        entries.values.first { $0.element === element }
    }

    func set(_ entry: Entry) { entries[entry.key] = entry }
    func remove(_ key: ViewVideoKey) { entries.removeValue(forKey: key) }

    /// What the view windows hold against the budget: your own picture is free.
    var usage: VideoUsage {
        var usage = VideoUsage()
        for entry in entries.values where entry.key.slot != .selfView { usage.take(entry.tier) }
        return usage
    }

    /// The tier each held slot has, for the allocation's "keep what runs" pass.
    func tier(of key: ViewVideoKey) -> VideoTier? { entries[key]?.tier }
}

@MainActor
extension ZoomMeetingSDKClient {

    static func viewLog(_ message: String) { videoLog("View window: " + message) }

    private static func sdkResolution(_ tier: VideoTier) -> ZoomSDKVideoRenderResolution {
        switch tier {
        case .p90: return ZoomSDKVideoRenderResolution_90p
        case .p180: return ZoomSDKVideoRenderResolution_180p
        case .p360: return ZoomSDKVideoRenderResolution_360p
        case .p720: return ZoomSDKVideoRenderResolution_720p
        }
    }

    // MARK: Who the stage shows

    /// The way the Meeting window picks: spotlight, then a local pin, then whoever
    /// speaks. A 1:1 shows the other person; alone is nil ("Waiting for others").
    func stagePerson() -> RosterEntry? {
        let roster = meetingRoster()
        let others = roster.filter { !$0.isMyself }
        guard !others.isEmpty else { return nil }
        let id = others.first(where: \.isSpotlighted)?.id ?? others.first(where: \.isPinned)?.id ?? speakerToShow()
        return others.first { $0.id == id } ?? others.first
    }

    // MARK: Elements

    /// The video view for one slot, made if it is new and sized to `frame`, and
    /// subscribed once it is in a visible window. nil when the SDK would not make
    /// an element (logged). `tier` comes from VideoBudget.
    func viewVideoView(_ key: ViewVideoKey, userID: UInt32, frame: NSRect, tier: VideoTier) -> NSView? {
        guard didUseCustomUI, frame.width > 0, frame.height > 0 else { return nil }
        if let entry = viewVideo.entries[key] {
            if entry.lastFrame != frame {
                entry.lastFrame = frame
                _ = entry.element.resize(frame)
            }
            if entry.userID != userID, Date() >= entry.nextSwitchAt {
                _ = entry.element.subscribeVideo(false)
                entry.element.userid = userID
                entry.userID = userID
                entry.subscribed = false
                entry.gotVideo = false
                entry.warnedNoVideo = false
                entry.subscribedAt = nil
                entry.nextSwitchAt = Date().addingTimeInterval(2)   // faster risks code 7
                Self.viewLog("\(key.text) -> user=\(userID)")
            }
            subscribeIfReady(entry, tier: tier)
            return entry.element.getVideoView()
        }
        guard let container = ZoomSDK.shared().getMeetingService()?.getVideoContainer() else { return nil }
        adopt(container: container)
        var element = ZoomSDKNormalVideoElement(frame: frame)
        let made = container.createNormalVideoElement(&element)
        guard made == ZoomSDKError_Success else {
            Self.viewLog("FAILED step=createNormalVideoElement code=\(made.rawValue) key=\(key.text)")
            return nil
        }
        element.userid = userID
        let entry = ViewVideoStore.Entry(key: key, element: element, userID: userID, tier: tier, frame: frame)
        viewVideo.set(entry)
        Self.viewLog("created key=\(key.text) user=\(userID) tier=\(tier.rawValue)p"
            + " frame=\(Int(frame.width))x\(Int(frame.height))")
        return element.getVideoView()
    }

    private func subscribeIfReady(_ entry: ViewVideoStore.Entry, tier: VideoTier) {
        guard !entry.subscribed, Date() >= entry.cooldownUntil, Date() >= viewVideo.nextSubscribeAt,
              entry.element.getVideoView().window?.isVisible == true else { return }
        entry.tier = tier
        let asked = Self.sdkResolution(tier)
        var set = entry.element.setResolution(asked)
        if set != ZoomSDKError_Success {
            Self.viewLog("FAILED step=setResolution code=\(set.rawValue) key=\(entry.key.text) (asking again)")
            set = entry.element.setResolution(asked)
        }
        let sub = entry.element.subscribeVideo(true)
        viewVideo.nextSubscribeAt = Date().addingTimeInterval(0.5)
        if sub == ZoomSDKError_Success {
            let shown = entry.element.showVideo(true)
            if shown != ZoomSDKError_Success { Self.viewLog("FAILED step=showVideo code=\(shown.rawValue) key=\(entry.key.text)") }
            entry.subscribed = true
            entry.subscribedAt = Date()
            entry.gotVideo = false
            Self.viewLog("subscribed key=\(entry.key.text) user=\(entry.userID) tier=\(tier.rawValue)p"
                + " setResolution=\(set.rawValue)")
        } else {
            Self.viewLog("FAILED step=subscribeVideo code=\(sub.rawValue) key=\(entry.key.text) user=\(entry.userID)")
            backOff(entry)
        }
    }

    private func backOff(_ entry: ViewVideoStore.Entry) {
        let now = Date()
        entry.attempts = now.timeIntervalSince(entry.lastFailure) < 60 ? entry.attempts + 1 : 1
        entry.lastFailure = now
        entry.subscribed = false
        entry.cooldownUntil = now.addingTimeInterval(min(32, pow(2, Double(min(entry.attempts, 5)))))
    }

    // MARK: Status, for the black-window fallback

    /// How long this slot has been subscribed without a video frame being reported.
    func viewVideoWaiting(_ key: ViewVideoKey) -> TimeInterval? {
        guard let entry = viewVideo.entries[key], entry.subscribed, !entry.gotVideo,
              let at = entry.subscribedAt else { return nil }
        return Date().timeIntervalSince(at)
    }

    func viewVideoSubscribed(_ key: ViewVideoKey) -> Bool { viewVideo.entries[key]?.subscribed ?? false }

    /// Once per slot: the line that says the black window happened.
    func noteViewVideoMissing(_ key: ViewVideoKey) {
        guard let entry = viewVideo.entries[key], !entry.warnedNoVideo else { return }
        entry.warnedNoVideo = true
        Self.viewLog("no video after 6s key=\(key.text) user=\(entry.userID) tier=\(entry.tier.rawValue)p")
    }

    // MARK: Delegate hooks (called from the video container delegate)

    func noteViewVideoFailure(_ element: ZoomSDKVideoElement, code: Int, reason: String) -> Bool {
        guard let entry = viewVideo.entry(for: element) else { return false }
        backOff(entry)
        Self.viewLog("SUBSCRIBE FAIL key=\(entry.key.text) code=\(code) user=\(entry.userID) \(reason)"
            + " \u{2014} backing off \(Int(entry.cooldownUntil.timeIntervalSinceNow.rounded()))s (attempt \(entry.attempts))")
        return true
    }

    func noteViewVideoDataType(_ element: ZoomSDKVideoElement, type: VideoRenderDataType) -> Bool {
        guard let entry = viewVideo.entry(for: element) else { return false }
        let word = type == VideoRenderDataType_Video ? "video" : type == VideoRenderDataType_Avatar ? "avatar" : "none"
        Self.viewLog("render data type key=\(entry.key.text) user=\(entry.userID) type=\(word)")
        if type == VideoRenderDataType_Video {
            if entry.warnedNoVideo, let at = entry.subscribedAt {
                Self.viewLog("video arrived after \(Int(Date().timeIntervalSince(at)))s key=\(entry.key.text)")
            }
            entry.gotVideo = true
        }
        return true
    }

    // MARK: Releasing

    func releaseViewVideo(_ key: ViewVideoKey) {
        guard let entry = viewVideo.entries[key] else { return }
        _ = entry.element.subscribeVideo(false)
        _ = videoContainer?.clean(entry.element)
        entry.element.getVideoView().removeFromSuperview()
        viewVideo.remove(key)
        Self.viewLog("released key=\(key.text)")
    }

    /// Everything one window holds, or only what is not in `keeping`.
    func releaseViewVideo(of view: MeetingView, keeping: Set<ViewVideoKey> = []) {
        for key in viewVideo.entries.keys where key.view == view && !keeping.contains(key) {
            releaseViewVideo(key)
        }
    }

    func releaseAllViewVideo() {
        for key in Array(viewVideo.entries.keys) { releaseViewVideo(key) }
    }

    /// Streams that are not self, for the budget.
    var viewVideoUsage: VideoUsage { viewVideo.usage }
}
