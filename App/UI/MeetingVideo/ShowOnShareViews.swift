//
//  ShowOnShareViews.swift
//  Greenroom
//
//  The pieces of "Show on my share" that are AppKit: the switch (an eye that
//  says whether the class sees this window). The decisions are in
//  MeetingCollapseRules.swift (ShowOnShare, tested); this file only draws and
//  wires them.
//
import AppKit
import SwiftUI

// MARK: - Show on my share: the switch

enum ShowOnShareSwitch {
    static func make(size: CGFloat, onClick: @escaping () -> Void) -> ClosureButton {
        let button = ClosureButton(onClick)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.setButtonType(.pushOnPushOff)
        button.frame = NSRect(x: 0, y: 0, width: size, height: size)
        return button
    }

    /// Dimmed and off when the share is an app or a window (the tooltip says why);
    /// amber when it is on and really going out.
    /// `showsTitle`: the words "Class sees this" / "Only you" beside the eye (the
    /// title bar has room).
    static func apply(to button: NSButton, on: Bool, kind: ShowOnShare.ShareKind, pointSize: CGFloat = 11,
                      showsTitle: Bool = false, idleTint: NSColor = NSColor.white.withAlphaComponent(0.4),
                      mutedTint: NSColor = NSColor.white.withAlphaComponent(0.25),
                      markedTint: NSColor = MeetingTheme.netNS) {
        let state = ShareSwitchState(on: on, kind: kind)
        let visibility = state.visibility
        let marked = visibility == .classSees
        // An eye, not the Share symbol: it says whether others see this window,
        // and two window-shaped icons side by side read as the same thing.
        button.image = NSImage(systemSymbolName: visibility.symbol, accessibilityDescription: visibility.label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        button.isEnabled = state.isEnabled
        button.state = marked ? .on : .off
        // Quiet when off (barely there, tooltip still says what it does); amber only
        // while the window is really shown, which is the moment it matters (owner, 2026-11-17).
        let tint = marked ? markedTint : (state.isEnabled ? idleTint : mutedTint)
        button.contentTintColor = tint
        if showsTitle {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: visibility.label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: marked ? .medium : .regular), .foregroundColor: tint,
            ])
        }
        button.toolTip = state.help
        button.setAccessibilityLabel(state.accessibilityLabel)
        button.setAccessibilityValue(state.accessibilityValue)
        button.setAccessibilityHelp(state.help)
    }
}
