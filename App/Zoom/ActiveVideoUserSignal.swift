//
//  ActiveVideoUserSignal.swift
//  Greenroom
//
//  Who Zoom's active-video element is drawing, as the SDK reports it.
//
//  The Active Speaker window cannot ask its element who it is rendering -
//  ZoomSDKActiveVideoElement has no user accessor, because Zoom switches the
//  participant internally. The only honest source is the action controller's
//  events, and the action controller has one delegate: ZoomMeetingSDKClient.
//  So the delegate forwards the events here, and the window listens.
//
//  Deliberately NOT speakerToShow(). That is the featured tile's sticky pick,
//  with self excluded and a poll fallback; a name bar that followed it would
//  label the video with someone Zoom is not drawing. Following the same events
//  Zoom switches on keeps the caption and the picture on the same person.
//
import Foundation

@MainActor
enum ActiveVideoUserSignal {

    /// Posted whenever `currentUserID` changes, or a name may have. Always on
    /// the main thread - the SDK delegate is main-actor already.
    static let didChange = Notification.Name("GreenroomActiveVideoUserDidChange")

    /// The user the active-video element is drawing, or nil when unknown.
    /// Kept, not just posted: the window is only built once three people are
    /// in, and the event that named the speaker usually fired before that.
    private(set) static var currentUserID: UInt32?

    /// Once onActiveVideoUserChanged has fired it is the only source trusted.
    /// Its header wording ("video of active user") is the element's own
    /// subject; onActiveSpeakerVideoUserChanged can name a different person
    /// (e.g. with a pin in effect), and alternating between the two would make
    /// the caption flicker against a picture that did not move.
    private static var sawActiveVideoEvent = false

    static func noteActiveVideoUser(_ id: UInt32) {
        sawActiveVideoEvent = true
        set(id)
    }

    static func noteActiveSpeakerVideoUser(_ id: UInt32) {
        guard !sawActiveVideoEvent else { return }
        set(id)
    }

    /// The captioned person left. Clear rather than keep: a name over a
    /// picture of someone else - or of nobody - is worse than no name, and
    /// Zoom will name the next person as soon as it switches.
    static func noteUsersLeft(_ ids: [UInt32]) {
        guard let current = currentUserID, ids.contains(current) else { return }
        set(nil)
    }

    /// A rename changes the caption without changing the person.
    static func noteNamesChanged() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Meeting over. A stale id from the last class would otherwise caption
    /// the first frame of the next one.
    static func reset() {
        sawActiveVideoEvent = false
        set(nil)
    }

    private static func set(_ id: UInt32?) {
        // 0 is the SDK's "nobody", not a user.
        let id = id == 0 ? nil : id
        guard id != currentUserID else { return }
        currentUserID = id
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
