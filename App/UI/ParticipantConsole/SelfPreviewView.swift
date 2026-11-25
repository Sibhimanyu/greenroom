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
    /// Top left, quiet: the camera state's icon while the camera is out of everyone's picture
    /// (Off, Only me). The tile itself keeps showing what everyone sees (SelfViewRules).
    private let markBadge = NSView()
    private let markIcon = NSImageView()
    private let markCorner = NSImageView()
    private var mark: SelfViewRules.Mark?
    /// Zoom's video-off look while video is stopped (R49): the owner's name, centred on the tile
    /// colour, as every other video-off tile in the window (MeetingTileChrome's cover) and as everyone
    /// in the meeting sees the owner.
    private let offCover = NSView()
    private let offName = NSTextField(labelWithString: "")
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
        offCover.wantsLayer = true
        offCover.layer?.backgroundColor = MeetingTheme.tileNS.cgColor
        offName.textColor = .white
        offName.alignment = .center
        offName.lineBreakMode = .byTruncatingTail
        offCover.addSubview(offName)
        offCover.isHidden = true
        addSubview(offCover)

        addSubview(caption)

        addSubview(meter)

        markBadge.wantsLayer = true
        markBadge.layer?.backgroundColor = MeetingTheme.capsuleNS.cgColor
        markBadge.layer?.cornerRadius = 9
        markIcon.contentTintColor = .white
        markCorner.contentTintColor = .white
        markBadge.addSubview(markIcon)
        markBadge.addSubview(markCorner)
        markBadge.setAccessibilityElement(true)
        markBadge.setAccessibilityRole(.image)
        markBadge.isHidden = true
        addSubview(markBadge)

        for (button, symbol, label) in [(muteButton, "mic.slash.fill", "Mute me"),
                                        (videoButton, VisibilitySymbol.cameraOff.name, "Stop my video")] {
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
    /// `content` is SelfViewRules.content: `.placeholder` (video stopped) draws the name over the video.
    func apply(muted: Bool, camera: CameraState, videoStopped: Bool = false, content: SelfViewContent = .everyoneSees,
               name: String = "You", mark: SelfViewRules.Mark?, level: Double) {
        applyMark(mark)
        let covered = content == .placeholder
        if offCover.isHidden == covered || offName.stringValue != name {
            offCover.isHidden = !covered
            offName.stringValue = name
            needsLayout = true
        }
        muteButton.image = NSImage(systemSymbolName: muted ? "mic.slash.fill" : "mic.fill",
                                   accessibilityDescription: muted ? "Unmute me" : "Mute me")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        muteButton.contentTintColor = muted ? .systemRed : .white
        muteButton.toolTip = muted ? "Unmute me" : "Mute me"
        // The camera button's own icon and words (R6.6, R17.3): a click turns the camera off, or back
        // to the last on state; while video is stopped, starts it again (R49).
        let cell = StopVideoRules.cell(state: camera, videoStopped: videoStopped)
        videoButton.image = NSImage(systemSymbolName: cell.symbol, accessibilityDescription: cell.spoken)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        videoButton.contentTintColor = Self.tint(cell.tint)
        videoButton.toolTip = cell.help
        videoButton.setAccessibilityLabel(cell.spoken)
        meter.level = level
        // Muted is the state worth seeing without hovering: a teacher talking
        // to a muted room is the failure this whole panel exists to prevent.
        muteButton.isHidden = !(hovering || muted)
        // The camera's state is the corner mark; the button itself waits for the hover, so Off
        // does not show two struck cameras.
        videoButton.isHidden = !hovering
    }

    /// A colour token on the tile's dark picture.
    static func tint(_ tint: VisibilitySymbol.Tint) -> NSColor {
        switch tint {
        case .stopped: return MeetingTheme.redNS
        case .neutral: return MeetingTheme.secondaryTextNS
        case .net: return MeetingTheme.netNS
        case .primary: return .white
        }
    }

    private func applyMark(_ next: SelfViewRules.Mark?) {
        guard next != mark else { return }
        mark = next
        markBadge.isHidden = next == nil
        guard let next else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        markIcon.image = NSImage(systemSymbolName: next.symbol.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        // Stop video's mark keeps Zoom's red; the camera states' marks stay white.
        markIcon.contentTintColor = next.symbol.tint == .stopped ? MeetingTheme.redNS : .white
        markCorner.image = next.symbol.badge.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        }
        markCorner.isHidden = markCorner.image == nil
        markBadge.toolTip = next.label
        markBadge.setAccessibilityLabel(next.label)
        needsLayout = true
    }

    /// The meter alone, fed at the mic monitor's rate between the one-second
    /// `apply` calls.
    func setLevel(_ level: Double) { meter.level = level }

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
        offCover.frame = bounds
        offName.font = .systemFont(ofSize: bounds.height < 150 ? 15 : 18, weight: .medium)
        offName.sizeToFit()
        offName.frame = NSRect(x: 12, y: (bounds.height - offName.frame.height) / 2,
                               width: max(0, bounds.width - 24), height: offName.frame.height)
        caption.sizeToFit()
        caption.frame = NSRect(x: 8, y: 6, width: caption.frame.width, height: caption.frame.height)
        // A thin level strip along the very bottom: present enough to read at a
        // glance, quiet enough not to compete with a student's face beside it.
        meter.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 3)
        // Top left, clear of the "You" caption (bottom left) and the two buttons (top right).
        let badgeWidth: CGFloat = markCorner.isHidden ? 22 : 28
        markBadge.frame = NSRect(x: 6, y: bounds.height - 18 - 6, width: badgeWidth, height: 18)
        markIcon.frame = NSRect(x: 4, y: 2, width: 14, height: 14)
        markCorner.frame = NSRect(x: 17, y: 2, width: 9, height: 9)
        let side: CGFloat = 24
        muteButton.frame = NSRect(x: bounds.width - side * 2 - 12, y: bounds.height - side - 8,
                                  width: side, height: side)
        videoButton.frame = NSRect(x: bounds.width - side - 8, y: bounds.height - side - 8,
                                   width: side, height: side)
        muteButton.isHidden = !(hovering || muteButton.contentTintColor == .systemRed)
        videoButton.isHidden = !hovering
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
