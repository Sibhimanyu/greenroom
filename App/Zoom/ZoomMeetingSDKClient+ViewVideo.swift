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
//    - setting `userid` already subscribes (ElementRecovery, SubscribeBackoff.swift):
//      an explicit subscribeVideo(true) on such an element is refused with code
//      7 (88 of 88 on 2026-11-23), so it is made only while dataType is None.
//      A new person is the same element with a new userid; at most two seconds apart per slot,
//      half a second apart across slots, and capped;
//    - a second element asking for a remote user another element already
//      holds is refused (code 7) too: every such subscription on 2026-11-13
//      and 2026-11-16 was. The refusal lines name the other holders.
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
        var watch: ElementWatch
        var subscribed: Bool { watch.subscribed }
        var subscribedAt: Date? { watch.subscribedAt }
        var gotVideo = false
        var nextSwitchAt = Date().addingTimeInterval(2)
        var warnedNoVideo = false

        init(key: ViewVideoKey, element: ZoomSDKNormalVideoElement, userID: UInt32, tier: VideoTier,
             frame: NSRect, notBefore: Date) {
            self.key = key
            self.element = element
            self.userID = userID
            self.tier = tier
            self.lastFrame = frame
            self.watch = ElementWatch(notBefore: notBefore)
        }
    }

    private(set) var entries: [ViewVideoKey: Entry] = [:]
    /// Per slot, across the fresh elements that replace one another.
    var backoffs: [ViewVideoKey: SubscribeBackoff] = [:]
    var rebuilds: [ViewVideoKey: Int] = [:]
    var gaveUp: Set<ViewVideoKey> = []
    var retiredAt: [ViewVideoKey: Date] = [:]

    func forget(_ key: ViewVideoKey) {
        backoffs.removeValue(forKey: key)
        rebuilds.removeValue(forKey: key)
        gaveUp.remove(key)
        retiredAt.removeValue(forKey: key)
    }

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
        guard didInit, frame.width > 0, frame.height > 0 else { return nil }
        guard let entry = viewVideo.entries[key] else { return makeViewElement(key, userID: userID, frame: frame, tier: tier) }
        if entry.lastFrame != frame {
            entry.lastFrame = frame
            _ = entry.element.resize(frame)
        }
        let now = Date()
        if entry.userID != userID, now >= entry.nextSwitchAt {
            // A different person: same element, new userid (that re-subscribes
            // it). No fresh element, so no blank gap. The resolution stays.
            let old = entry.userID
            entry.element.userid = userID
            entry.userID = userID
            var fresh = ElementWatch()
            fresh.resolutionSet = true
            entry.watch = fresh
            entry.gotVideo = false
            entry.warnedNoVideo = false
            entry.nextSwitchAt = now.addingTimeInterval(2)
            viewVideo.forget(key)
            Self.viewLog("switched user \(old) -> \(userID) on same element key=\(key.text) \(Self.tag(entry.element))")
            return entry.element.getVideoView()
        }
        noteRender(entry.element, watch: &entry.watch, label: "View window: \(key.text) user=\(entry.userID)")
        let rebuilds = viewVideo.rebuilds[key] ?? 0
        switch recoveryAction(entry.element, watch: entry.watch, now: now, rebuilds: rebuilds) {
        case .recovered:
            entry.watch.recoveredByVideo()
            viewVideo.backoffs[key]?.reset()
            Self.viewLog("video is showing despite the refusal - keeping this element key=\(key.text) \(Self.tag(entry.element))")
        case .retry:
            entry.watch.readyToRetry()
            Self.viewLog("no video after the wait - one more ask on the same element key=\(key.text) \(Self.tag(entry.element))")
        case .rebuild:
            viewVideo.rebuilds[key] = rebuilds + 1
            retireViewElement(entry, why: "refused; fresh element \(rebuilds + 1) of \(ElementRecovery.maxRebuilds)")
            viewVideo.retiredAt[key] = now
            return makeViewElement(key, userID: entry.userID, frame: frame, tier: tier)
        case .giveUp:
            if viewVideo.gaveUp.insert(key).inserted {
                Self.viewLog("GIVING UP key=\(key.text) user=\(entry.userID) \(Self.tag(entry.element))"
                    + " after \(rebuilds) fresh elements (others holding this user:"
                    + " \(otherHolders(of: entry.userID, except: entry.element))); a camera toggle tries again")
            }
        case .fine, .wait:
            break
        }
        subscribeIfReady(entry, tier: tier)
        return entry.element.getVideoView()
    }

    private func makeViewElement(_ key: ViewVideoKey, userID: UInt32, frame: NSRect, tier: VideoTier) -> NSView? {
        guard let container = ZoomSDK.shared().getMeetingService()?.getVideoContainer() else { return nil }
        adopt(container: container)
        var element = ZoomSDKNormalVideoElement(frame: frame)
        let made = container.createNormalVideoElement(&element)
        guard made == ZoomSDKError_Success else {
            Self.viewLog("FAILED step=createNormalVideoElement code=\(made.rawValue) key=\(key.text)")
            return nil
        }
        element.userid = userID
        let notBefore = (viewVideo.retiredAt[key] ?? .distantPast).addingTimeInterval(ElementRecovery.freshDelay)
        let entry = ViewVideoStore.Entry(key: key, element: element, userID: userID, tier: tier,
                                         frame: frame, notBefore: notBefore)
        viewVideo.set(entry)
        Self.viewLog("created key=\(key.text) user=\(userID) \(Self.tag(element)) tier=\(tier.rawValue)p"
            + " frame=\(Int(frame.width))x\(Int(frame.height))")
        return element.getVideoView()
    }

    /// Unsubscribes and destroys a slot's element; the slot's counters stay.
    private func retireViewElement(_ entry: ViewVideoStore.Entry, why: String) {
        _ = entry.element.subscribeVideo(false)
        _ = videoContainer?.clean(entry.element)
        entry.element.getVideoView().removeFromSuperview()
        viewVideo.remove(entry.key)
        Self.viewLog("retired key=\(entry.key.text) user=\(entry.userID) \(Self.tag(entry.element)) - \(why)")
    }

    private func subscribeIfReady(_ entry: ViewVideoStore.Entry, tier: VideoTier) {
        let now = Date()
        guard ElementRecovery.mayAsk(watch: entry.watch, gaveUp: viewVideo.gaveUp.contains(entry.key), now: now),
              entry.element.getVideoView().window?.isVisible == true else { return }
        entry.tier = tier
        let asked = Self.sdkResolution(tier)
        guard let (setCode, sub, implicit) = paceSubscribe(entry.element, watch: &entry.watch, asked: asked,
                                                 label: "View window: \(entry.key.text)") else { return }
        let others = otherHolders(of: entry.userID, except: entry.element)
        if sub == ZoomSDKError_Success {
            let shown = entry.element.showVideo(true)
            if shown != ZoomSDKError_Success { Self.viewLog("FAILED step=showVideo code=\(shown.rawValue) key=\(entry.key.text)") }
            entry.watch.subscribed = true
            entry.watch.subscribedAt = now
            entry.gotVideo = false
            Self.viewLog((implicit ? "subscribed by userid (no explicit ask) key=" : "subscribed key=")
                + "\(entry.key.text) user=\(entry.userID) \(Self.tag(entry.element))"
                + " tier=\(tier.rawValue)p setResolution=\(setCode) others=\(others)")
        } else {
            Self.viewLog("FAILED step=subscribeVideo code=\(sub.rawValue) key=\(entry.key.text) user=\(entry.userID)")
            backOff(entry, at: now)
        }
    }

    @discardableResult
    private func backOff(_ entry: ViewVideoStore.Entry, at now: Date) -> (attempts: Int, delay: TimeInterval) {
        let step = viewVideo.backoffs[entry.key, default: SubscribeBackoff()].failed(at: now)
        entry.watch.subscribed = false
        entry.watch.refusedUntil = now.addingTimeInterval(ElementRecovery.refusalWait(step.delay))
        entry.watch.lastRefusalAt = now
        return step
    }

    // MARK: Status, for the black-window fallback

    /// How long this slot has been subscribed without a video frame being reported.
    func viewVideoWaiting(_ key: ViewVideoKey) -> TimeInterval? {
        guard let entry = viewVideo.entries[key], entry.subscribed, !entry.gotVideo,
              let at = entry.subscribedAt else { return nil }
        // The SDK only calls onRenderDataTypeChanged when a camera turns on or
        // off, so a window opened while the camera is already on never hears
        // that video arrived (a view window said "Video didn't start" over
        // your own picture, 2026-11-16). Ask the element itself.
        if entry.element.getDataType() == VideoRenderDataType_Video {
            entry.gotVideo = true
            return nil
        }
        return Date().timeIntervalSince(at)
    }

    /// Once per slot: the line that says the black window happened.
    func noteViewVideoMissing(_ key: ViewVideoKey) {
        guard let entry = viewVideo.entries[key], !entry.warnedNoVideo else { return }
        entry.warnedNoVideo = true
        Self.viewLog("no video after 6s key=\(key.text) user=\(entry.userID) tier=\(entry.tier.rawValue)p")
    }

    // MARK: Delegate hooks (called from the video container delegate)

    func noteViewVideoFailure(_ element: ZoomSDKVideoElement, code: Int, reason: String) -> Bool {
        guard let entry = viewVideo.entry(for: element) else { return false }
        let now = Date()
        let head = "SUBSCRIBE FAIL key=\(entry.key.text) code=\(code) user=\(entry.userID) \(Self.tag(element)) \(reason)"
        let others = otherHolders(of: entry.userID, except: element)
        if entry.watch.isRepeatRefusal(at: now) {
            Self.viewLog(head + " - same refusal again, not counted")
            return true
        }
        let step = backOff(entry, at: now)
        Self.viewLog(head + " others=\(others) - code 7 means slow down: waiting \(Int(ElementRecovery.refusalWait(step.delay)))s for video before doing anything to this element"
            + " (refusal \(step.attempts), fresh elements so far \(viewVideo.rebuilds[entry.key] ?? 0)/\(ElementRecovery.maxRebuilds))")
        return true
    }

    func noteViewVideoDataType(_ element: ZoomSDKVideoElement, type: VideoRenderDataType) -> Bool {
        guard let entry = viewVideo.entry(for: element) else { return false }
        let word = type == VideoRenderDataType_Video ? "video" : type == VideoRenderDataType_Avatar ? "avatar" : "none"
        Self.viewLog("render data type key=\(entry.key.text) user=\(entry.userID) \(Self.tag(element)) type=\(word)"
            + " sublayers=\(element.getVideoView().layer?.sublayers?.count ?? -1)")
        if type == VideoRenderDataType_Video {
            if entry.warnedNoVideo, let at = entry.subscribedAt {
                Self.viewLog("video arrived after \(Int(Date().timeIntervalSince(at)))s key=\(entry.key.text)")
            }
            entry.gotVideo = true
            // Not a reason to subscribe again (refused, code 7).
            if viewVideo.gaveUp.remove(entry.key) != nil {
                viewVideo.rebuilds[entry.key] = 0
                viewVideo.backoffs[entry.key]?.reset()
                Self.viewLog("camera came on after giving up - trying again key=\(entry.key.text)")
            }
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
        viewVideo.forget(key)
        Self.viewLog("released key=\(key.text) \(Self.tag(entry.element))")
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
