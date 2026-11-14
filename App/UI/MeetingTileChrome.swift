//
//  MeetingTileChrome.swift
//  Greenroom
//
//  What a tile in the meeting window shows on top of its video, in Zoom's
//  macOS style (see MeetingTheme for why): the name on a dark capsule at the
//  bottom left, a red slashed microphone before it when muted, a green ring
//  round whoever is speaking, a yellow hand badge top left, and, when the
//  camera is off, the name centred in large type on the tile colour.
//
//  Plain values in, no SDK: the real TileView hosts one of these over the
//  video element, and the off-screen render in .context/mt draws it over
//  placeholder colour.
//
//  Where the tiles go is MeetingViewRules.swift (MeetingVideoLayout).
//
import AppKit

struct MeetingTileModel: Equatable {
    var name: String
    var isMe = false
    /// Joined audio and muted. A person with no audio at all is not "muted".
    var muted = false
    var videoOn = true
    var speaking = false
    var handUp = false
    /// The teacher's own selection (the inspector's target), a white ring.
    var selected = false

    /// Zoom writes "Name (me)" on your own tile.
    var label: String { isMe ? "\(name) (me)" : name }
}

@MainActor
final class MeetingTileChrome: NSView {

    private let offCover = NSView()
    private let offName = NSTextField(labelWithString: "")
    private let capsule = NSView()
    private let micIcon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let handBadge = NSView()
    private let handIcon = NSImageView()
    private let ring = NSView()
    private var model = MeetingTileModel(name: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        offCover.wantsLayer = true
        offCover.layer?.backgroundColor = MeetingTheme.tileNS.cgColor
        offName.font = .systemFont(ofSize: 22, weight: .medium)
        offName.textColor = .white
        offName.alignment = .center
        offName.lineBreakMode = .byTruncatingTail
        offCover.addSubview(offName)
        addSubview(offCover)

        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = MeetingTheme.capsuleNS.cgColor
        micIcon.image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Muted")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        micIcon.contentTintColor = MeetingTheme.redNS
        nameLabel.font = .systemFont(ofSize: 12, weight: .regular)
        nameLabel.textColor = .white
        nameLabel.lineBreakMode = .byTruncatingTail
        capsule.addSubview(micIcon)
        capsule.addSubview(nameLabel)
        addSubview(capsule)

        handBadge.wantsLayer = true
        handBadge.layer?.backgroundColor = MeetingTheme.capsuleNS.cgColor
        handIcon.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Hand raised")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        handIcon.contentTintColor = MeetingTheme.handNS
        handBadge.addSubview(handIcon)
        addSubview(handBadge)

        ring.wantsLayer = true
        ring.layer?.cornerRadius = MeetingTheme.tileRadius
        ring.layer?.borderWidth = 0
        addSubview(ring)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ model: MeetingTileModel) {
        self.model = model
        offCover.isHidden = model.videoOn
        offName.stringValue = model.label
        nameLabel.stringValue = model.label
        micIcon.isHidden = !model.muted
        handBadge.isHidden = !model.handUp
        // Selection outranks speaking: the next click acts on the selection.
        if model.selected {
            ring.layer?.borderWidth = MeetingTheme.speakerRingWidth + 1
            ring.layer?.borderColor = NSColor.white.cgColor
        } else if model.speaking {
            ring.layer?.borderWidth = MeetingTheme.speakerRingWidth
            ring.layer?.borderColor = MeetingTheme.speakerRingNS.cgColor
        } else {
            ring.layer?.borderWidth = 0
        }
        setAccessibilityElement(true)
        setAccessibilityLabel([model.label, model.muted ? "muted" : nil, model.handUp ? "hand raised" : nil,
                               model.videoOn ? nil : "camera off"].compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    /// Never takes a click: the tile under it does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let small = bounds.height < 150
        offCover.frame = bounds
        offName.font = .systemFont(ofSize: small ? 13 : min(28, max(16, bounds.height * 0.085)), weight: .medium)
        offName.sizeToFit()
        offName.frame = NSRect(x: 12, y: (bounds.height - offName.frame.height) / 2,
                               width: max(0, bounds.width - 24), height: offName.frame.height)

        let inset: CGFloat = small ? 5 : 8
        let height: CGFloat = small ? 18 : 22
        nameLabel.font = .systemFont(ofSize: small ? 11 : 12)
        nameLabel.sizeToFit()
        let icon: CGFloat = micIcon.isHidden ? 0 : 16
        let want = 8 + icon + nameLabel.frame.width + 8
        let width = min(want, max(0, bounds.width - inset * 2))
        capsule.frame = NSRect(x: inset, y: inset, width: width, height: height)
        capsule.layer?.cornerRadius = height / 2
        var x: CGFloat = 8
        if !micIcon.isHidden {
            micIcon.frame = NSRect(x: x, y: (height - 14) / 2, width: 14, height: 14)
            x += 16
        }
        nameLabel.frame = NSRect(x: x, y: (height - nameLabel.frame.height) / 2,
                                 width: max(0, width - x - 8), height: nameLabel.frame.height)
        capsule.isHidden = model.name.isEmpty

        let badge: CGFloat = small ? 20 : 26
        handBadge.frame = NSRect(x: inset, y: bounds.height - inset - badge, width: badge, height: badge)
        handBadge.layer?.cornerRadius = badge / 2
        handIcon.frame = handBadge.bounds.insetBy(dx: 3, dy: 3)
        ring.frame = bounds
    }
}
