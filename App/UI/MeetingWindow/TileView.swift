//
//  TileView.swift
//  Greenroom
//
//  One person's tile: their video, name capsule, badges and speaking ring.
//
import AppKit
import SwiftUI
import Combine

/// A video view plus the state that video cannot show.
///
/// Zoom draws its own name label into the video it renders, but nothing else:
/// whether a microphone is off, whether a hand is up, whether this is the
/// student currently being spotlighted. Those are the facts a teacher scans for,
/// so they are drawn here rather than inferred.
@MainActor
final class TileView: NSView {

    let userID: UInt32
    var onSelect: ((UInt32) -> Void)?
    /// Right-click: this person, large, in a window of their own.
    var onSpotlightInWindow: ((UInt32) -> Void)?

    private var video: NSView?
    private let scrim = NSView()
    /// An emoji someone just sent, for three seconds (the SDK's reaction event),
    /// and the yes / no / slow down badge that stays until it is cancelled.
    private let reactionLabel = NSTextField(labelWithString: "")
    private let feedbackLabel = NSTextField(labelWithString: "")
    private let chrome = MeetingTileChrome(frame: .zero)

    init(userID: UInt32) {
        self.userID = userID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = MeetingTheme.tileNS.cgColor
        layer?.cornerRadius = MeetingTheme.tileRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0

        // Only an anchor for the video to sit below; the chrome draws the name.
        scrim.isHidden = true
        addSubview(scrim)
        // Above the video (which goes below the scrim), below the reaction badges.
        addSubview(chrome)

        reactionLabel.font = .systemFont(ofSize: 28)
        reactionLabel.isHidden = true
        addSubview(reactionLabel)
        feedbackLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        feedbackLabel.textColor = .white
        feedbackLabel.alignment = .center
        feedbackLabel.wantsLayer = true
        feedbackLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        feedbackLabel.layer?.cornerRadius = 9          // a pill: DESIGN.md `pill`, status badges
        feedbackLabel.isHidden = true
        addSubview(feedbackLabel)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }

    var videoBounds: NSRect { NSRect(origin: .zero, size: bounds.size) }
    private var lastLoggedSublayers = -2

    func attach(video newVideo: NSView?) {
        // The common case by far - the poll runs at 1Hz and the view rarely
        // changes. It used to log a full view-state line here, which meant a
        // synchronous open/seek/write/close per tile per second on the main
        // thread: 571 of 632 lines in one session's log, and the reason the
        // panel felt sluggish. The probe had already done its job (it proved
        // the views were on screen and correctly sized, which is what pointed
        // the investigation at subscriptions instead).
        guard video !== newVideo else {
            // Change-only render probe. A rendering element grows its layer
            // tree (1 sublayer bare, 4 once the SDK wires the surface up); one
            // that reports dataType=Video but never leaves 1 is accepting data
            // and drawing none of it - the exact state under investigation.
            let sublayers = video?.layer?.sublayers?.count ?? -1
            if sublayers != lastLoggedSublayers {
                lastLoggedSublayers = sublayers
                ZoomMeetingSDKClient.videoLog("render user=\(userID) sublayers=\(sublayers)"
                    + " size=\(Int(bounds.width))x\(Int(bounds.height))")
            }
            return
        }
        video?.removeFromSuperview()
        video = newVideo
        guard let newVideo else {
            ZoomMeetingSDKClient.videoLog("attach user=\(userID) provider returned nil")
            return
        }
        newVideo.autoresizingMask = [.width, .height]
        newVideo.frame = videoBounds
        addSubview(newVideo, positioned: .below, relativeTo: scrim)
        ZoomMeetingSDKClient.videoLog(Self.viewState("attached", userID: userID,
                                                     video: newVideo, tile: self))
    }

    /// TEMPORARY QA INSTRUMENTATION - remove once the tiles are confirmed.
    private static func viewState(_ stage: String, userID: UInt32,
                                  video: NSView?, tile: NSView) -> String {
        guard let video else { return "\(stage) user=\(userID) video=nil" }
        let layerInfo: String
        if let layer = video.layer {
            layerInfo = "layer=yes sublayers=\(layer.sublayers?.count ?? 0) "
                + "opaque=\(layer.isOpaque) hidden=\(layer.isHidden)"
        } else {
            layerInfo = "layer=NONE"
        }
        return "\(stage) user=\(userID)"
            + " videoFrame=\(Int(video.frame.width))x\(Int(video.frame.height))"
            + " tileBounds=\(Int(tile.bounds.width))x\(Int(tile.bounds.height))"
            + " superview=\(video.superview == nil ? "NONE" : "ok")"
            + " window=\(video.window == nil ? "NONE" : (video.window!.isVisible ? "visible" : "hidden"))"
            + " hidden=\(video.isHidden) alpha=\(String(format: "%.2f", video.alphaValue))"
            + " subviews=\(video.subviews.count) \(layerInfo)"
            + " tileInWindow=\(tile.window == nil ? "NONE" : "ok")"
    }

    func detachVideo() {
        video?.removeFromSuperview()
        video = nil
    }

    func apply(entry: ZoomMeetingSDKClient.RosterEntry, isSelected: Bool,
               reaction: String? = nil, feedback: String? = nil) {
        reactionLabel.stringValue = reaction ?? ""
        reactionLabel.isHidden = reaction == nil
        feedbackLabel.stringValue = feedback ?? ""
        feedbackLabel.isHidden = feedback == nil
        reactionLabel.setAccessibilityLabel(reaction.map { "Reaction \($0)" })
        feedbackLabel.setAccessibilityLabel(feedback.map { "Feedback: \($0)" })

        chrome.apply(MeetingTileModel(name: entry.name, isMe: entry.isMyself,
                                      muted: entry.isMuted && entry.hasJoinedAudio, videoOn: entry.videoOn,
                                      speaking: entry.isTalking, handUp: entry.isRaisingHand,
                                      selected: isSelected))
        needsLayout = true
        layoutStates()
    }

    override func layout() {
        super.layout()
        video?.frame = videoBounds
        layoutStates()
    }

    private func layoutStates() {
        // The chrome draws the name, the badges and the ring; only the
        // reaction emoji and the feedback pill are laid out here.
        chrome.frame = bounds
        layoutReactions(inset: 8)
        layer?.borderWidth = 0
    }

    /// Top-right: the feedback badge, with a fresh emoji to its left.
    private func layoutReactions(inset: CGFloat) {
        var badgeRight = bounds.width - inset
        if !feedbackLabel.isHidden {
            feedbackLabel.sizeToFit()
            let w = feedbackLabel.frame.width + 14
            feedbackLabel.frame = NSRect(x: badgeRight - w, y: bounds.height - inset - 18, width: w, height: 18)
            badgeRight -= w + 6
        }
        if !reactionLabel.isHidden {
            reactionLabel.sizeToFit()
            reactionLabel.frame = NSRect(x: badgeRight - reactionLabel.frame.width,
                                         y: bounds.height - inset - reactionLabel.frame.height + 2,
                                         width: reactionLabel.frame.width, height: reactionLabel.frame.height)
        }
    }

    /// The whole tile is one click target. Without this the SDK's own video
    /// view sits on top and may consume the click, so selecting a student would
    /// work on some tiles and not others depending on what Zoom is rendering.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Accept the very first click.
    ///
    /// AppKit swallows the click that brings a non-key window forward unless the
    /// view under the cursor opts in, and this panel is deliberately
    /// non-activating so it never steals focus from the main screen - so it is
    /// almost never key. Without this, EVERY control needed two clicks: one
    /// discarded to make the panel key, one to act. Found live on a three-display
    /// setup; the second click worked, which is what identified it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onSelect?(userID) }

    /// Right-click: our own panel, since an NSMenu shows nothing while Greenroom is inactive.
    override func rightMouseDown(with event: NSEvent) {
        guard let onSpotlightInWindow, MeetingViewPieces.enabled else { return }
        let id = userID
        MeetingMenuPanel.show([.item("Spotlight in window") { onSpotlightInWindow(id) }], for: event)
    }
}


// ClosureButton lives in App/UI/ClosureButton.swift now - the Cues cards
// share it. See TileView.acceptsFirstMouse for why it exists.
