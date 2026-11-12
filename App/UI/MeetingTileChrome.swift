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
//  MeetingVideoLayout is the same idea for geometry: where the tiles go in
//  Gallery and in Speaker view's top strip, as pure arithmetic.
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

/// Where tiles go. AppKit coordinates (origin bottom left); index 0 is the top
/// left. Pure, so the render and the window share it.
enum MeetingVideoLayout {

    /// The grid that gives 16:9 tiles the most area. Tiles are 16:9 like the
    /// pictures they hold, packed with `gap` between them and centred in `size`,
    /// the last row centred too.
    static func gallery(count: Int, in size: NSSize, gap: CGFloat = MeetingTheme.tileGap) -> [NSRect] {
        guard count > 0, size.width > 0, size.height > 0 else { return [] }
        var best: (cols: Int, rows: Int, w: CGFloat, h: CGFloat) = (1, count, 0, 0)
        for cols in 1...count {
            let rows = Int(ceil(Double(count) / Double(cols)))
            let maxW = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let maxH = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            guard maxW > 0, maxH > 0 else { continue }
            let w = min(maxW, maxH * 16 / 9), h = w * 9 / 16
            if w * h > best.w * best.h { best = (cols, rows, w, h) }
        }
        let gridHeight = CGFloat(best.rows) * best.h + CGFloat(best.rows - 1) * gap
        let top = (size.height + gridHeight) / 2
        var out: [NSRect] = []
        for index in 0..<count {
            let row = index / best.cols, column = index % best.cols
            let inRow = min(best.cols, count - row * best.cols)
            let rowWidth = CGFloat(inRow) * best.w + CGFloat(inRow - 1) * gap
            let x = (size.width - rowWidth) / 2 + CGFloat(column) * (best.w + gap)
            let y = top - CGFloat(row + 1) * best.h - CGFloat(row) * gap
            out.append(NSRect(x: x.rounded(), y: y.rounded(), width: best.w.rounded(), height: best.h.rounded()))
        }
        return out
    }

    /// Speaker view's strip: one row of 16:9 tiles along the top of `size`,
    /// centred, leaving `reservedRight` free at the right end.
    static func strip(count: Int, in size: NSSize, tileHeight: CGFloat, reservedRight: CGFloat = 0,
                      gap: CGFloat = MeetingTheme.tileGap) -> [NSRect] {
        guard count > 0 else { return [] }
        let width = (tileHeight * 16 / 9).rounded()
        let total = CGFloat(count) * width + CGFloat(count - 1) * gap
        let room = max(0, size.width - reservedRight)
        let start = max(0, ((room - total) / 2).rounded())
        return (0..<count).map { index in
            NSRect(x: start + CGFloat(index) * (width + gap), y: size.height - tileHeight, width: width, height: tileHeight)
        }
    }

    /// How many strip tiles fit in `width`.
    static func stripCapacity(width: CGFloat, tileHeight: CGFloat, gap: CGFloat = MeetingTheme.tileGap) -> Int {
        let tile = (tileHeight * 16 / 9).rounded() + gap
        return min(8, max(1, Int((width + gap) / tile)))
    }
}
