//
//  SelfViewMarkView.swift
//  Greenroom
//
//  The small corner mark on the owner's own video (R6.9, R49.7): the camera state's icon while
//  the camera is out of everyone's picture (Off, Only me), or Stop video's red icon while video
//  is stopped. Its name is the tooltip and the VoiceOver label. What it shows comes from
//  SelfViewRules.mark; this view only draws it. One view for every place the owner's video
//  shows: the Meeting window's "You" tile (SelfPreviewView) and a view window's tile of the
//  owner (MeetingVideoTile, the Self view window).
//
import AppKit

final class SelfViewMarkView: NSView {

    static let height: CGFloat = 18

    private let icon = NSImageView()
    private let corner = NSImageView()
    private(set) var mark: SelfViewRules.Mark?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = MeetingTheme.capsuleNS.cgColor
        layer?.cornerRadius = Self.height / 2
        icon.contentTintColor = .white
        corner.contentTintColor = .white
        addSubview(icon)
        addSubview(corner)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    /// Its width: wider when the symbol has a badge (Only me's struck eye).
    var width: CGFloat { corner.isHidden ? 22 : 28 }

    /// Hidden when `next` is nil. Returns true when the width may have changed.
    @discardableResult
    func apply(_ next: SelfViewRules.Mark?) -> Bool {
        guard next != mark else { return false }
        mark = next
        isHidden = next == nil
        guard let next else { return true }
        icon.image = NSImage(systemSymbolName: next.symbol.name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        // Stop video's mark keeps Zoom's red; the camera states' marks stay white.
        icon.contentTintColor = next.symbol.tint == .stopped ? MeetingTheme.redNS : .white
        corner.image = next.symbol.badge.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
        }
        corner.isHidden = corner.image == nil
        toolTip = next.label
        setAccessibilityLabel(next.label)
        needsLayout = true
        return true
    }

    /// Top left of `bounds` with `inset` (and `after` points to the right, clear of a hand badge).
    func place(in bounds: NSRect, inset: CGFloat, after: CGFloat = 0) {
        frame = NSRect(x: bounds.minX + inset + after, y: bounds.maxY - Self.height - inset,
                       width: width, height: Self.height)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 4, y: 2, width: 14, height: 14)
        corner.frame = NSRect(x: 17, y: 2, width: 9, height: 9)
    }
}
