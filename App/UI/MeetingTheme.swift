//
//  MeetingTheme.swift
//  Greenroom
//
//  The meeting window's colours, sizes and type, in one place.
//
//  DECISION (owner, 2026-11-12, recorded in DESIGN.md): Greenroom's own meeting
//  window looks like Zoom's meeting window on macOS, so teachers and students
//  feel at home in it. That overrides DESIGN.md's earlier "do not imitate Zoom's
//  look" note for this one window. It is a decision about familiarity, not
//  copying: the hard line is that nothing here is Zoom's logo, the word "Zoom"
//  as branding, or Zoom's icon artwork. Every glyph is an SF Symbol that reads
//  the same. Layout, colours, spacing and behaviour follow Zoom's dark window.
//
//  Zoom's meeting window is dark whatever the system appearance, so the window
//  is forced to dark aqua and these are fixed values, not adaptive ones. The
//  app accent (`Brand.green`) is untouched elsewhere; the greens below are for
//  this window's Zoom-familiar cues only (the info shield, Share, the speaker
//  ring).
//
//  Pure values (AppKit, CoreGraphics, SwiftUI): the off-screen render in
//  .context/mt compiles this file with the views.
//
import AppKit
import SwiftUI

enum MeetingTheme {

    // MARK: Hex

    private static func ns(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // MARK: Surfaces

    /// The window, the top bar and the toolbar.
    static let windowNS = ns(0x1A1A1A)
    /// A video tile behind its picture, and an avatar-less tile.
    static let tileNS = ns(0x232323)
    /// Raised surfaces: a hovered control, a search field, an input.
    static let raisedNS = ns(0xFFFFFF, alpha: 0.10)
    static let hoverNS = ns(0xFFFFFF, alpha: 0.09)
    static let hairlineNS = ns(0xFFFFFF, alpha: 0.10)
    /// The name capsule over a tile.
    static let capsuleNS = ns(0x000000, alpha: 0.55)

    // MARK: Text

    static let textNS = ns(0xFFFFFF)
    static let secondaryTextNS = ns(0xFFFFFF, alpha: 0.62)

    // MARK: Cues

    /// The shield, Share, and the speaking ring: Zoom's green (#23D959 family).
    /// The shield and the icon use the vivid one; the ring a touch deeper so it
    /// does not glare against a picture.
    static let zoomGreenNS = ns(0x23D959)
    static let speakerRingNS = ns(0x23D959)
    /// Zoom's red: muted microphone, stopped camera, recording, End.
    static let redNS = ns(0xE02828)
    static let endNS = ns(0xE02828)
    /// The raised hand.
    static let handNS = ns(0xFFC107)

    // MARK: SwiftUI mirrors

    static let window = Color(nsColor: windowNS)
    static let tile = Color(nsColor: tileNS)
    static let raised = Color(nsColor: raisedNS)
    static let hover = Color(nsColor: hoverNS)
    static let hairline = Color(nsColor: hairlineNS)
    static let capsule = Color(nsColor: capsuleNS)
    static let text = Color.white
    static let secondaryText = Color(nsColor: secondaryTextNS)
    static let zoomGreen = Color(nsColor: zoomGreenNS)
    static let red = Color(nsColor: redNS)
    static let end = Color(nsColor: endNS)
    static let hand = Color(nsColor: handNS)

    // MARK: Metrics

    static let tileRadius: CGFloat = 8
    static let tileGap: CGFloat = 4
    static let topBarHeight: CGFloat = 36
    static let toolbarHeight: CGFloat = 64
    static let controlRadius: CGFloat = 6
    static let speakerRingWidth: CGFloat = 2
    static let sidePanelWidth: CGFloat = 320
    /// Speaker view's strip of small tiles along the top.
    static let stripHeight: CGFloat = 104

    // MARK: Avatars

    /// Stable per-person colours for initials circles, muted enough to sit on
    /// #232323 without shouting.
    static func avatarColor(for name: String) -> Color {
        let palette: [Color] = [
            Color(nsColor: ns(0x2F6FDB)), Color(nsColor: ns(0x7B4FD1)), Color(nsColor: ns(0xC24A8A)),
            Color(nsColor: ns(0xD98324)), Color(nsColor: ns(0x2E9E6B)), Color(nsColor: ns(0x1F9AA8)),
            Color(nsColor: ns(0x5A5FCF)), Color(nsColor: ns(0xC8503C)),
        ]
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return palette[hash % palette.count]
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").compactMap { $0.first(where: { $0.isLetter }).map(String.init) }.prefix(2)
        if letters.isEmpty { return name.first.map { String($0).uppercased() } ?? "?" }
        return letters.joined().uppercased()
    }
}
