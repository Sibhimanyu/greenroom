//
//  VideoTiles.swift
//  Greenroom
//
//  The tile every view window draws: a video view with Zoom's tile chrome
//  (MeetingTileChrome) over it, and a right-click that says "Spotlight in window".
//  A tile of the owner (the Self view window) wears the "You" tile's look from the
//  same rule (SelfViewRules.tile): the camera state's corner mark, or the name and
//  "Video stopped" while video is stopped.
//
//  No SDK in here. The window hands the tile a video view (the SDK's render
//  element's view, or a coloured stand-in in the off-screen render) and the
//  person it shows as plain values.
//
import AppKit

/// One person as a view window draws them: plain values, no SDK objects.
struct MeetingViewPerson: Equatable, Identifiable {
    var id: UInt32
    var name: String
    var isMe = false
    /// Joined audio and muted.
    var muted = false
    var hasAudio = true
    var videoOn = true
    var speaking = false
    var handUp = false
    var isHost = false
    var isCoHost = false
    var isSpotlighted = false

    var tile: MeetingTileModel {
        MeetingTileModel(name: name, isMe: isMe, muted: muted && hasAudio, videoOn: videoOn,
                         speaking: speaking, handUp: handUp, selected: false)
    }
}

@MainActor
final class MeetingVideoTile: NSView {

    private(set) var person: MeetingViewPerson?
    /// "Spotlight in window", on a right-click.
    var onSpotlight: ((MeetingViewPerson) -> Void)?

    private var video: NSView?
    private let chrome = MeetingTileChrome(frame: .zero)
    private let mark = SelfViewMarkView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = MeetingTheme.tileNS.cgColor
        layer?.cornerRadius = MeetingTheme.tileRadius
        layer?.masksToBounds = true
        addSubview(chrome)
        addSubview(mark)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
    var videoBounds: NSRect { NSRect(origin: .zero, size: bounds.size) }

    /// `you` is the owner's look (CoordinatorController.selfViewLook); it changes only the owner's tile.
    func apply(_ person: MeetingViewPerson, model: MeetingTileModel? = nil, you: SelfViewRules.Look? = nil) {
        self.person = person
        let look = SelfViewRules.tile(isMe: person.isMe, zoomVideoOn: person.videoOn, you: you)
        var tile = model ?? person.tile
        tile.videoOn = tile.videoOn && look.videoOn
        chrome.apply(tile)
        mark.apply(look.mark)
        needsLayout = true
    }

    /// The SDK draws into a view it owns; the tile only parents it, and only when
    /// it changes (re-parenting a live video view every pass would flicker).
    func attach(video newVideo: NSView?) {
        guard video !== newVideo else { return }
        video?.removeFromSuperview()
        video = newVideo
        guard let newVideo else { return }
        newVideo.autoresizingMask = [.width, .height]
        newVideo.frame = videoBounds
        addSubview(newVideo, positioned: .below, relativeTo: chrome)
    }

    func detachVideo() {
        video?.removeFromSuperview()
        video = nil
    }

    override func layout() {
        super.layout()
        video?.frame = videoBounds
        chrome.frame = bounds
        // Top left as on the "You" tile, after the hand badge when the hand is up (MeetingTileChrome's place).
        let small = bounds.height < 150
        let inset: CGFloat = small ? 5 : 8
        mark.place(in: bounds, inset: inset, after: person?.handUp == true ? (small ? 20 : 26) + 4 : 0)
    }

    /// The whole tile is one click target, as in the meeting window: the SDK's
    /// own view would otherwise swallow the right-click.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Right-click: our own panel, since an NSMenu shows nothing while Greenroom is inactive.
    override func rightMouseDown(with event: NSEvent) {
        guard let person, !person.isMe, onSpotlight != nil else { return }
        MeetingMenuPanel.show([.item("Spotlight in window") { [weak self] in
            if let person = self?.person { self?.onSpotlight?(person) }
        }], for: event)
    }
}
