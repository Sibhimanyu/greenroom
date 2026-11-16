//
//  ParticipantAvatarStore.swift
//  Greenroom
//
//  People's Zoom profile photos. The SDK keeps each one as a file on disk
//  (`ZoomSDKUserInfo.getAvatarPath`) and says when one changes
//  (`onInMeetingUserAvatarPathUpdated`). This loads the file once, keeps the
//  picture, and tells SwiftUI when a new one lands.
//
import AppKit
import SwiftUI
#if canImport(ZoomSDK)
import ZoomSDK
#endif

@MainActor
final class ParticipantAvatarStore: ObservableObject {
    static let shared = ParticipantAvatarStore()

    /// Bumped whenever any photo changes; views that read `image(for:)` redraw.
    @Published private(set) var revision = 0

    /// Where a user's photo file lives. Swappable so a render or a test never
    /// touches the SDK.
    var pathProvider: (UInt32) -> String? = { userID in
        #if canImport(ZoomSDK)
        return ZoomSDK.shared().getMeetingService()?.getMeetingActionController()
            .getUserByUserID(userID)?.getAvatarPath()
        #else
        return nil
        #endif
    }

    /// A miss (no path, or a file that would not load) is cached as nil so a
    /// row that redraws does not hit the disk again until the SDK says so.
    private var cache: [UInt32: NSImage?] = [:]

    /// The photo, or nil when there is none and the initials should show.
    func image(for userID: UInt32) -> NSImage? {
        guard userID != 0 else { return nil }
        if let hit = cache[userID] { return hit }
        var loaded: NSImage?
        if let path = pathProvider(userID), !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            loaded = NSImage(contentsOfFile: path)
        }
        cache[userID] = .some(loaded)
        return loaded
    }

    /// The SDK says this person's photo changed: forget it and redraw.
    func avatarPathUpdated(userID: UInt32) {
        cache[userID] = nil
        revision += 1
    }

    /// A meeting ended: user IDs are not stable across meetings.
    func reset() {
        cache.removeAll()
        revision += 1
    }
}
