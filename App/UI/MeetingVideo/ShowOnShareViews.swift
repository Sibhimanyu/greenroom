//
//  ShowOnShareViews.swift
//  Greenroom
//
//  The pieces of "Show on my share" that are AppKit: the switch (an eye that
//  says whether the class sees this window), the one-time explaining toast,
//  and the amber border with its label. The decisions are in
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

// MARK: - Show on my share: telling the person once

/// Remembers what one window was, and the first time on this Mac that it goes
/// from hidden to seen or back, says so on the island. Never again after that.
@MainActor
final class ShareVisibilityAnnouncer {
    private var last = ShareVisibility.onlyYou
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func update(marked: Bool) {
        let now = ShareVisibility(marked: marked)
        defer { last = now }
        guard let words = ShareVisibilityExplainer.toast(
            was: last, now: now, alreadyExplained: ShareVisibilityExplainer.hasExplained(defaults)) else { return }
        ShareVisibilityExplainer.markExplained(defaults)
        ToastController.show(words)
    }
}

// MARK: - Show on my share: the amber edge (every window the class can see)

/// A click-through panel laid over a window while it is going out on the share.
/// It is a separate window of ours that is NOT in the share's exceptions, so the
/// border is for the teacher only and never in the picture others see.
@MainActor
final class ShareBorderOverlay {
    private let panel: NSPanel
    private weak var parent: NSWindow?

    init(parent: NSWindow) {
        self.parent = parent
        panel = NSPanel(contentRect: parent.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = parent.level
        panel.collectionBehavior = parent.collectionBehavior
        panel.contentView = ShareBorderView(frame: NSRect(origin: .zero, size: parent.frame.size))
        panel.setAccessibilityElement(false)
    }

    func show(_ on: Bool) {
        guard let parent else { return }
        if on {
            panel.setFrame(parent.frame, display: true)
            if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
            if parent.isVisible { panel.orderFront(nil) }
        } else if panel.parent != nil {
            parent.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    /// The parent moved or was resized.
    func sync() {
        guard let parent, panel.parent != nil else { return }
        if panel.frame != parent.frame { panel.setFrame(parent.frame, display: true) }
    }

    func close() {
        parent?.removeChildWindow(panel)
        panel.close()
    }
}

private final class ShareBorderView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let amber = MeetingTheme.netNS
        let frame = bounds.insetBy(dx: 1, dy: 1)
        amber.setStroke()
        let path = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        path.stroke()

        // The label sits on a dark capsule so amber 11pt text stays legible over any picture.
        // Bottom-left: the top-left corner belongs to the traffic lights (owner, 2026-11-17).
        let text = ShowOnShare.borderLabel as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: amber,
        ]
        let size = text.size(withAttributes: attributes)
        let capsuleHeight = size.height + 6
        let capsule = NSRect(x: 10, y: bounds.height - capsuleHeight - 8,
                             width: size.width + 14, height: capsuleHeight)
        MeetingTheme.capsuleNS.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
        text.draw(at: NSPoint(x: capsule.minX + 7, y: capsule.minY + 3), withAttributes: attributes)
    }
}
