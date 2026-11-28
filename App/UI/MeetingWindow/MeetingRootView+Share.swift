//
//  MeetingRootView+Share.swift
//  Greenroom
//
//  Shared screens: the stage and the share host, the share chip, the split divider drag.
//
import AppKit
import SwiftUI
import Combine

@MainActor
extension MeetingRootView {

    func dragSplit(toBoundaryX x: CGFloat) {
        splitFraction = MeetingSplit.fraction(forBoundaryX: x, in: lastSideStage)
        relayoutAfterSplit()
    }

    func relayoutAfterSplit() {
        layoutEverything()
        if let provider = lastVideoProvider { attachVideo(provider) }
        attachStage()
    }

    /// Speaker view's picture: one element, handed whoever is on the stage, or a
    /// shared screen when somebody else is sharing. Beside a share the screen has
    /// its own host on the left and the stage keeps the speaker.
    func attachStage() {
        let viewer = ParticipantGridWindowController.sdk?.shareViewer
        let shareTarget: NSView? = shareOnStage ? stageHost : (shareBeside ? shareHost : nil)
        if let viewer, let target = shareTarget {
            drawShare(viewer, in: target)
        } else {
            shareElsewhere.isHidden = true
            if shareVideo != nil {
                shareVideo?.removeFromSuperview()
                shareVideo = nil
            }
            if viewer?.windowOwnsShare != true { viewer?.releaseElement() }
        }
        if shareOnStage {
            // The speaker's 720p stream is given back while a screen is shown.
            if stageVideo != nil {
                stageVideo?.removeFromSuperview()
                stageVideo = nil
                lastReleaseStage?()
            }
            return
        }
        guard isSpeakerMode, let id = stageSpeakerID, let provider = lastStageProvider else {
            stageVideo?.removeFromSuperview()
            stageVideo = nil
            lastReleaseStage?()
            return
        }
        guard !stageHost.bounds.isEmpty else { return }
        guard let view = provider(id, stageHost.bounds) else { return }
        if stageVideo !== view {
            stageVideo?.removeFromSuperview()
            view.autoresizingMask = [.width, .height]
            stageHost.addSubview(view, positioned: .below, relativeTo: stageScrim)
            stageVideo = view
        }
        view.frame = stageHost.bounds
    }

    /// The share in `host`. A share that was drawn in the other host is given
    /// back and made again: an element is not moved while it renders.
    private func drawShare(_ viewer: ShareViewer, in host: NSView) {
        let anchor: NSView = host === stageHost ? stageScrim : shareChrome
        if viewer.windowOwnsShare {
            shareVideo?.removeFromSuperview()
            shareVideo = nil
            if shareElsewhere.superview !== host {
                shareElsewhere.removeFromSuperview()
                host.addSubview(shareElsewhere, positioned: .below, relativeTo: anchor)
            }
            shareElsewhere.isHidden = false
            shareElsewhere.frame = NSRect(x: 12, y: host.bounds.midY - 12,
                                          width: max(0, host.bounds.width - 24), height: 24)
            return
        }
        shareElsewhere.isHidden = true
        if let video = shareVideo, video.superview !== host {
            video.removeFromSuperview()
            shareVideo = nil
            viewer.releaseElement()
        }
        guard !host.bounds.isEmpty, let view = viewer.stageView(frame: host.bounds) else { return }
        if shareVideo !== view {
            shareVideo?.removeFromSuperview()
            view.autoresizingMask = [.width, .height]
            host.addSubview(view, positioned: .below, relativeTo: anchor)
            shareVideo = view
        }
        view.frame = host.bounds
        // Only now, with the view in a visible window: a share asked to draw
        // before that never does (the video stage's lesson).
        viewer.renderIfReady()
    }

    /// A share starting takes the view its layout names (Standard is Speaker with
    /// the share on the stage); its ending puts the view back, unless the person
    /// picked one in between.
    func syncShareMode() {
        let sharing = sharedNow != nil
        if sharing, !shareForcedSpeaker {
            shareForcedSpeaker = true
            userChoseDuringShare = false
            viewBeforeShare = viewMode
            let forced = shareLayout.sideMode ?? .speaker
            if viewMode != forced, !form.isSlot { setViewMode(forced) }
            ZoomMeetingSDKClient.videoLog("Share view: \(shareLayout.menuTitle) (was \(viewBeforeShare?.title ?? "?"))")
        } else if !sharing, shareForcedSpeaker {
            shareForcedSpeaker = false
            if !userChoseDuringShare, let before = viewBeforeShare, before != viewMode, !form.isSlot {
                setViewMode(before)
            }
            viewBeforeShare = nil
            ZoomMeetingSDKClient.videoLog("Share view: share ended, view restored")
        }
    }

    func shareChipPressed() {
        guard let viewer = ParticipantGridWindowController.sdk?.shareViewer else { return }
        if sharedNow == nil {
            // Your own share, in Gallery: the chip is its Stop.
            stopOwnShare()
            return
        }
        let choices = viewer.choices
        if choices.count > 1 {
            let entries: [MenuEntry] = choices.map { choice in
                .item("\(choice.name)\u{2019}s screen", checked: choice.sourceID == viewer.current?.sourceID) { [weak self] in
                    viewer.pick(choice.sourceID)
                    self?.showShareOnStage()
                }
            }
            MeetingMenuBuilder.popUp(entries, above: shareChip, below: true)
        } else if !shareBeside {
            showShareOnStage()
        }
    }

    /// Back to Speaker, where the share is drawn.
    private func showShareOnStage() {
        guard !shareBeside, viewMode != .speaker else { return }
        modeControl.selectedSegment = ViewMode.speaker.segmentIndex
        modeChanged(modeControl)
    }

    func stopOwnShare() {
        Self.perform("Stopped sharing") { $0.stopShare() }
    }

    /// The chip over the stage or gallery, and your own share's card.
    func layoutShareChip(in stage: NSRect) {
        let viewer = ParticipantGridWindowController.sdk?.shareViewer
        var text: String?
        var help = ""
        if let now = sharedNow, let viewer {
            // On the stage the caption already says whose screen it is; the chip
            // is there to choose between several, and in Gallery to bring it back.
            if !shareOnStage && !shareBeside {
                text = "Viewing \(now.name)\u{2019}s screen \u{00B7} Show"
                help = "Show \(now.name)\u{2019}s screen again."
            } else if viewer.selection.hasChoice {
                text = "\(now.name)\u{2019}s screen \u{25BE}"
                help = "Several people are sharing. Choose whose screen to see."
            }
        } else if selfSharingNow, !selfCardShown {
            text = "You are sharing your screen \u{00B7} Stop"
            help = "Stop sharing your screen"
        }
        guard let text else { shareChip.isHidden = true; return }
        shareChip.isHidden = false
        shareChip.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white])
        shareChip.toolTip = help
        shareChip.setAccessibilityLabel(text)
        shareChip.sizeToFit()
        let width = min(stage.width - 24, shareChip.frame.width + 24)
        shareChip.frame = NSRect(x: stage.midX - width / 2, y: stage.maxY - 12 - 26, width: width, height: 26)
    }
}
