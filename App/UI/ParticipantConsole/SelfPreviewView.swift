//
//  SelfPreviewView.swift
//  Greenroom
//
//  You, in the corner of the class.
//
//  Phase 3 of docs/participant-window-redesign-plan.md. The self view used to
//  own a column at the front of the window - on a 1432pt panel it took 628pt,
//  44% of the width, permanently, for a picture the teacher glances at. It is
//  occasionally useful rather than continuously primary, so it becomes an
//  overlay: 240pt wide, laid out AFTER the grid and over the top of it, so the
//  grid's cell arithmetic never sees it. The plan asks that the preview not
//  alter the grid; being unable to is better than remembering not to.
//
//  Mute me and Stop my video live here rather than in the header, because they
//  are about you. Putting them next to the picture they change is the whole
//  argument - a control that mutes you belongs on the thing that shows you.
//
import AppKit

final class SelfPreviewView: NSView {

    struct Actions {
        var toggleMute: () -> Void = {}
        var toggleVideo: () -> Void = {}
    }

    var actions = Actions()

    /// Where the SDK's self-video render lands.
    let videoHost = NSView()
    private let caption = NSTextField(labelWithString: "You")
    private let meter = LevelMeterView()
    private lazy var muteButton = ClosureButton { [weak self] in self?.actions.toggleMute() }
    private lazy var videoButton = ClosureButton { [weak self] in self?.actions.toggleVideo() }
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        layer?.backgroundColor = NSColor.black.cgColor

        videoHost.wantsLayer = true
        addSubview(videoHost)

        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .white
        caption.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 3
            return shadow
        }()
        addSubview(caption)

        addSubview(meter)

        for (button, symbol, label) in [(muteButton, "mic.slash.fill", "Mute me"),
                                        (videoButton, "video.slash.fill", "Stop my video")] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            button.contentTintColor = .white
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            button.isHidden = true
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Titles and tints follow the live state, so the glyph says what pressing
    /// it will do rather than what is currently true.
    func apply(muted: Bool, videoOn: Bool, level: Double) {
        muteButton.image = NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill",
                                   accessibilityDescription: muted ? "Unmute me" : "Mute me")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        muteButton.contentTintColor = muted ? .systemRed : .white
        muteButton.toolTip = muted ? "Unmute me" : "Mute me"
        videoButton.image = NSImage(systemSymbolName: videoOn ? "video.fill" : "video.slash.fill",
                                    accessibilityDescription: videoOn ? "Stop my video" : "Start my video")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        videoButton.contentTintColor = videoOn ? .white : .systemRed
        videoButton.toolTip = videoOn ? "Stop my video" : "Start my video"
        meter.level = level
        // Muted is the state worth seeing without hovering: a teacher talking
        // to a muted room is the failure this whole panel exists to prevent.
        muteButton.isHidden = !(hovering || muted)
        videoButton.isHidden = !(hovering || !videoOn)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsLayout = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsLayout = true }

    override func layout() {
        super.layout()
        videoHost.frame = bounds
        for subview in videoHost.subviews { subview.frame = videoHost.bounds }
        caption.sizeToFit()
        caption.frame = NSRect(x: 8, y: 6, width: caption.frame.width, height: caption.frame.height)
        // A thin level strip along the very bottom: present enough to read at a
        // glance, quiet enough not to compete with a student's face beside it.
        meter.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 3)
        let side: CGFloat = 24
        muteButton.frame = NSRect(x: bounds.width - side * 2 - 12, y: bounds.height - side - 8,
                                  width: side, height: side)
        videoButton.frame = NSRect(x: bounds.width - side - 8, y: bounds.height - side - 8,
                                   width: side, height: side)
        muteButton.isHidden = !(hovering || muteButton.contentTintColor == .systemRed)
        videoButton.isHidden = !(hovering || videoButton.contentTintColor == .systemRed)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
