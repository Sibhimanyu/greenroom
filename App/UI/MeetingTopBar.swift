//
//  MeetingTopBar.swift
//  Greenroom
//
//  The meeting window's slim top bar, in the title-bar area (see MeetingTheme
//  for the Zoom-familiarity decision): a green shield that opens meeting info,
//  the meeting's name and clock in the middle, and on the right a control that
//  shrinks the meeting to the floating bar and a "View" button.
//
//  AppKit, not SwiftUI: the bar sits where the title bar is, and a plain
//  non-opaque NSView lets the empty parts of it drag the window while its
//  buttons still take clicks. A hosting view cannot promise that.
//
import AppKit
import SwiftUI

struct MeetingTopBarState: Equatable {
    var title = "Meeting"
    var clock = ""
    var recording = false
    var mode: MeetingViewMode = .gallery
    var isFullscreen = false
    var canShrink = true
    /// The bound combination's glyphs for the shrink action, for the tip and the hover help.
    var shrinkShortcut = ""
}

/// A flat button with Zoom's hover wash: a lighter rounded rectangle.
@MainActor
final class MeetingBarButton: NSButton {
    private let body: () -> Void
    private var hovering = false { didSet { layer?.backgroundColor = hovering ? MeetingTheme.hoverNS.cgColor : NSColor.clear.cgColor } }

    init(_ body: @escaping () -> Void) {
        self.body = body
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = MeetingTheme.controlRadius
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func fire() { body() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

@MainActor
final class MeetingTopBarView: NSView {

    struct Actions {
        var showInfo: (NSView) -> Void = { _ in }
        var viewMenu: () -> [MenuEntry] = { [] }
        var shrink: () -> Void = {}
        /// The one-time tip was closed with its x.
        var tipClosed: () -> Void = {}
    }

    var actions = Actions()
    private(set) var state = MeetingTopBarState()

    private lazy var shield: MeetingBarButton = MeetingBarButton { [weak self] in
        guard let self else { return }
        self.actions.showInfo(self.shield)
    }
    private lazy var viewButton: MeetingBarButton = MeetingBarButton { [weak self] in
        guard let self else { return }
        MeetingMenuBuilder.popUp(self.actions.viewMenu(), above: self.viewButton, below: true)
    }
    private lazy var shrinkButton: MeetingBarButton = MeetingBarButton { [weak self] in
        self?.dismissTip(persist: true)
        self?.actions.shrink()
    }
    private var tip: MeetingShrinkTipView?
    private let titleLabel = NSTextField(labelWithString: "")
    private let recordingDot = NSView()
    private let recordingLabel = NSTextField(labelWithString: "Recording")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = MeetingTheme.windowNS.cgColor

        shield.image = NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: "Meeting info")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        shield.imagePosition = .imageOnly
        shield.contentTintColor = MeetingTheme.zoomGreenNS
        shield.toolTip = "Meeting information"
        shield.setAccessibilityLabel("Meeting information")

        // Icon and words, styled like View beside it: an unlabelled icon was not
        // discoverable. "Control bar" names where it goes, as View names what it
        // changes; "Shrink" alone would not say to what.
        shrinkButton.image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        shrinkButton.imagePosition = .imageLeading
        shrinkButton.imageHugsTitle = true
        shrinkButton.attributedTitle = NSAttributedString(string: " Control bar", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
        shrinkButton.contentTintColor = .white
        shrinkButton.toolTip = Self.shrinkHelp(shortcut: "\u{2318}M")
        shrinkButton.setAccessibilityLabel("Shrink to the control bar")

        viewButton.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        viewButton.imagePosition = .imageLeading
        viewButton.imageHugsTitle = true
        viewButton.attributedTitle = NSAttributedString(string: " View", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.white])
        viewButton.contentTintColor = .white
        viewButton.toolTip = "Change the video layout"
        viewButton.setAccessibilityLabel("View")

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = MeetingTheme.secondaryTextNS
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        recordingDot.wantsLayer = true
        recordingDot.layer?.backgroundColor = MeetingTheme.redNS.cgColor
        recordingDot.layer?.cornerRadius = 4
        recordingLabel.font = .systemFont(ofSize: 11)
        recordingLabel.textColor = MeetingTheme.secondaryTextNS

        for view in [shield, titleLabel, recordingDot, recordingLabel, shrinkButton, viewButton] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { false }

    func apply(_ state: MeetingTopBarState) {
        self.state = state
        titleLabel.stringValue = state.clock.isEmpty ? state.title : "\(state.title)   \(state.clock)"
        recordingDot.isHidden = !state.recording
        recordingLabel.isHidden = !state.recording
        shrinkButton.isHidden = !state.canShrink
        shrinkButton.toolTip = Self.shrinkHelp(shortcut: state.shrinkShortcut)
        updateTip()
        needsLayout = true
    }

    static func shrinkHelp(shortcut: String) -> String {
        "Shrink the meeting to the control bar so you can get back to your slides"
            + (shortcut.isEmpty ? "" : " (\(shortcut))")
    }

    // MARK: One-time tip

    /// Shows the tip while it is due (first meeting window on this Mac, not shrunk
    /// or closed since) and takes it away once it is not.
    private func updateTip() {
        let due = MeetingShrinkTip.shouldShow(canShrink: state.canShrink) && !isHidden
        if due, tip == nil, let host = superview {
            let created = MeetingShrinkTipView(message: MeetingShrinkTip.message(shortcut: state.shrinkShortcut)) { [weak self] in
                self?.dismissTip(persist: true)
                self?.actions.tipClosed()
            }
            host.addSubview(created, positioned: .above, relativeTo: nil)
            tip = created
        } else if !due, tip != nil {
            dismissTip(persist: false)
        }
        tip?.message = MeetingShrinkTip.message(shortcut: state.shrinkShortcut)
    }

    private func dismissTip(persist: Bool) {
        if persist { MeetingShrinkTip.markDone() }
        tip?.removeFromSuperview()
        tip = nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { dismissTip(persist: false) } else { updateTip() }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        // Clear the traffic lights: the bar sits where the title bar is.
        let left: CGFloat = 78
        shield.frame = NSRect(x: left, y: (h - 26) / 2, width: 30, height: 26)

        viewButton.sizeToFit()
        let viewWidth = viewButton.frame.width + 14
        viewButton.frame = NSRect(x: bounds.width - 10 - viewWidth, y: (h - 26) / 2, width: viewWidth, height: 26)
        var rightEdge = viewButton.frame.minX - 4
        shrinkButton.sizeToFit()
        let shrinkWidth = shrinkButton.frame.width + 14
        shrinkButton.frame = NSRect(x: rightEdge - shrinkWidth, y: (h - 26) / 2, width: shrinkWidth, height: 26)
        if !shrinkButton.isHidden { rightEdge = shrinkButton.frame.minX - 4 }

        var leftEdge = shield.frame.maxX + 12
        recordingDot.frame = NSRect(x: leftEdge, y: (h - 8) / 2, width: 8, height: 8)
        recordingLabel.sizeToFit()
        recordingLabel.frame.origin = NSPoint(x: leftEdge + 14, y: (h - recordingLabel.frame.height) / 2)
        if !recordingDot.isHidden { leftEdge = recordingLabel.frame.maxX + 12 }

        // Centred on the window when there is room, otherwise between the ends.
        let room = min(bounds.width / 2 - leftEdge, rightEdge - bounds.width / 2)
        let width = max(0, min(360, room * 2))
        titleLabel.sizeToFit()
        titleLabel.frame = NSRect(x: (bounds.width - width) / 2, y: (h - titleLabel.frame.height) / 2,
                                  width: width, height: titleLabel.frame.height)
        titleLabel.isHidden = width < 60

        // The tip hangs under the button, right edges level, in the superview's
        // space so it can sit over the stage without taking the bar's hit area.
        if let tip, let host = superview {
            // Tiles and the stage are added to the same host after the tip, and
            // later rebuilds add more, so keep it on top: front of the subview
            // list, and a layer z above any sibling layer (render surfaces too).
            if host.subviews.last !== tip { host.addSubview(tip, positioned: .above, relativeTo: nil) }
            tip.sizeToFitWidth(maxWidth: min(300, host.bounds.width - 20))
            let anchor = convert(shrinkButton.frame, to: host)
            let x = min(max(10, anchor.maxX - tip.frame.width), host.bounds.width - tip.frame.width - 10)
            tip.setFrameOrigin(NSPoint(x: x, y: frame.minY - tip.frame.height - 2))
            tip.isHidden = shrinkButton.isHidden || isHidden
        }
    }
}

/// The first-time callout: a small glass card with the sentence and a close x.
/// A subview of the window's content view, sized to its own text, so a click
/// anywhere outside it goes to whatever is underneath.
@MainActor
final class MeetingShrinkTipView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let close: MeetingBarButton
    private let backing: NSView
    private let host: NSView
    private static let pad: CGFloat = 12, closeSize: CGFloat = 20

    var message: String {
        get { label.stringValue }
        set { if label.stringValue != newValue { label.stringValue = newValue } }
    }

    init(message: String, onClose: @escaping () -> Void) {
        close = MeetingBarButton(onClose)
        backing = GreenroomGlassAppKit.makeBacking(cornerRadius: 12)
        host = GreenroomGlassAppKit.host(of: backing)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.zPosition = 1000
        label.stringValue = message
        label.font = .systemFont(ofSize: 12)
        label.textColor = MeetingTheme.textNS
        label.isSelectable = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tip")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        close.imagePosition = .imageOnly
        close.contentTintColor = MeetingTheme.secondaryTextNS
        close.toolTip = "Close this tip"
        close.setAccessibilityLabel("Close tip")
        addSubview(backing)
        for view in [label, close] as [NSView] { host.addSubview(view) }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tip")
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    func sizeToFitWidth(maxWidth: CGFloat) {
        let textWidth = maxWidth - Self.pad * 2 - Self.closeSize - 6
        label.preferredMaxLayoutWidth = textWidth
        let text = label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        let height = max(text.height, Self.closeSize) + Self.pad * 2 - 4
        setFrameSize(NSSize(width: min(maxWidth, ceil(text.width) + Self.pad * 2 + Self.closeSize + 6), height: ceil(height)))
        backing.frame = bounds
        let h = bounds.height
        close.frame = NSRect(x: bounds.width - Self.pad - Self.closeSize + 4, y: h - Self.pad + 2 - Self.closeSize + 4,
                             width: Self.closeSize, height: Self.closeSize)
        label.frame = NSRect(x: Self.pad, y: (h - ceil(text.height)) / 2,
                             width: ceil(text.width), height: ceil(text.height))
    }
}

/// Meeting info as a popover: the meeting ID, the passcode and the invite link,
/// each with a copy button.
struct MeetingInfoView: View {
    let title: String
    let facts: MeetingMenus.MeetingFacts
    var copy: (String, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill").foregroundStyle(MeetingTheme.zoomGreen)
                Text(title.isEmpty ? "Meeting information" : title)
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            if !facts.number.isEmpty { row("Meeting ID", MeetingMenus.spaced(facts.number), copying: facts.number) }
            if !facts.passcode.isEmpty { row("Passcode", facts.passcode, copying: facts.passcode) }
            if !facts.joinURL.isEmpty { row("Invite link", MeetingMenus.abbreviated(facts.joinURL, limit: 38), copying: facts.joinURL) }
            if !facts.hasInvite {
                Text("Meeting details are not available yet.").font(.system(size: 12)).foregroundStyle(MeetingTheme.secondaryText)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .foregroundStyle(MeetingTheme.text)
        .background(MeetingTheme.window)
    }

    private func row(_ label: String, _ value: String, copying: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11)).foregroundStyle(MeetingTheme.secondaryText)
                Text(value).font(.system(size: 13)).lineLimit(1).textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button { copy(copying, label) } label: {
                Text("Copy").font(.system(size: 12))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(MeetingTheme.raised, in: RoundedRectangle(cornerRadius: MeetingTheme.controlRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy \(label)")
        }
    }
}
