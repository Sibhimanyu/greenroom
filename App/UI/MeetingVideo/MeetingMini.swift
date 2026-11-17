//
//  MeetingMini.swift
//  Greenroom
//
//  The pieces of the Mini window and of "Show on my share" that are AppKit:
//  the hover strip (glass, along the bottom), the Show on my share switch, and
//  the amber border with its label. The decisions are in MeetingCollapseRules.swift
//  and MeetingMiniPlan (both tested); this file only draws and wires them.
//
import AppKit
import SwiftUI

// MARK: - What the Mini's buttons do

/// Set by the coordinator; the strip reads and calls these.
struct MeetingMiniActions {
    var toggleMic: () -> Void = {}
    var toggleCamera: () -> Void = {}
    var toMeetingWindow: () -> Void = {}
    var toBar: () -> Void = {}
    var end: () -> Void = {}
    /// End was pressed once and waits for the second press.
    var endArmed: () -> Bool = { false }
    /// The armed End's question and how to answer it, for its callout.
    var endAsk: () -> (title: String, detail: String) = { ("", "") }
    /// Read every second: is the mic muted, is the camera on.
    var state: () -> (muted: Bool, cameraOn: Bool) = { (false, true) }
}

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
    /// title bar has room; the Mini's strip is icon-only and says it on hover).
    static func apply(to button: NSButton, on: Bool, kind: ShowOnShare.ShareKind, pointSize: CGFloat = 13,
                      showsTitle: Bool = false, idleTint: NSColor = .white,
                      mutedTint: NSColor = MeetingTheme.secondaryTextNS) {
        let state = ShareSwitchState(on: on, kind: kind)
        let visibility = state.visibility
        let marked = visibility == .classSees
        // An eye, not the Share symbol: it says whether others see this window,
        // and two window-shaped icons side by side read as the same thing.
        button.image = NSImage(systemSymbolName: visibility.symbol, accessibilityDescription: visibility.label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        button.isEnabled = state.isEnabled
        button.state = marked ? .on : .off
        let tint = marked ? MeetingTheme.netNS : (state.isEnabled ? idleTint : mutedTint)
        button.contentTintColor = tint
        if showsTitle {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(string: visibility.label, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: tint,
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
        let text = ShowOnShare.borderLabel as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: amber,
        ]
        let size = text.size(withAttributes: attributes)
        let capsule = NSRect(x: 10, y: 8, width: size.width + 14, height: size.height + 6)
        MeetingTheme.capsuleNS.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
        text.draw(at: NSPoint(x: capsule.minX + 7, y: capsule.minY + 3), withAttributes: attributes)
    }
}

// MARK: - The hover strip

/// Mic, camera, Show on my share, to the Meeting window, to the Control bar, and
/// End: a glass strip along the bottom of the Mini that fades in on hover.
@MainActor
final class MeetingMiniChrome: NSView {
    static let height: CGFloat = 34
    var actions = MeetingMiniActions() { didSet { refresh() } }
    var onToggleShare: (() -> Void)?

    private let backing: NSView
    private let host: NSView
    private lazy var mic = iconButton("mic.fill", "Mute") { [weak self] in self?.actions.toggleMic(); self?.refresh() }
    private lazy var camera = iconButton("video.fill", "Turn camera off") { [weak self] in self?.actions.toggleCamera(); self?.refresh() }
    private(set) lazy var share = ShowOnShareSwitch.make(size: 26) { [weak self] in self?.onToggleShare?() }
    // The Mini is the middle size: one button grows it, one shrinks it, drawn as
    // the familiar expand and collapse arrows so the pair reads as bigger / smaller.
    private lazy var toWindow = iconButton("arrow.up.left.and.arrow.down.right", "Bigger: back to the Meeting window") { [weak self] in self?.actions.toMeetingWindow() }
    private lazy var toBar = iconButton("arrow.down.right.and.arrow.up.left", "Smaller: shrink to the Control bar") { [weak self] in self?.actions.toBar() }
    private lazy var end = ClosureButton { [weak self] in self?.actions.end(); self?.refresh(); self?.watchArm() }
    private var armWatch: Timer?
    private var callout: NSPopover?

    /// While End is armed, look again every half second, so a timeout or Esc
    /// turns Confirm back into End.
    private func watchArm() {
        armWatch?.invalidate()
        guard actions.endArmed() else { return }
        armWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.refresh()
                if !self.actions.endArmed() { timer.invalidate(); self.armWatch = nil }
            }
        }
    }

    override init(frame: NSRect) {
        backing = GreenroomGlassAppKit.makeBacking(cornerRadius: 12)
        host = GreenroomGlassAppKit.host(of: backing)
        super.init(frame: frame)
        wantsLayer = true
        addSubview(backing)
        for button in [mic, camera, share, toWindow, toBar] as [NSView] { host.addSubview(button) }
        end.title = "End"
        end.isBordered = false
        end.font = .systemFont(ofSize: 11, weight: .semibold)
        end.contentTintColor = .white
        end.wantsLayer = true
        end.layer?.backgroundColor = MeetingTheme.endNS.cgColor
        end.layer?.cornerRadius = 9
        end.toolTip = "End or leave the meeting\u{2026}"
        end.setAccessibilityLabel("End meeting")
        host.addSubview(end)
        alphaValue = 0
        setAccessibilityLabel("Mini window controls")
    }

    required init?(coder: NSCoder) { nil }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> ClosureButton {
        let b = ClosureButton(action)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        b.contentTintColor = .white
        b.toolTip = label
        b.setAccessibilityLabel(label)
        return b
    }

    /// The strip sits along the bottom with a little air; hidden, it lets clicks through.
    func place(in bounds: NSRect) {
        let inset: CGFloat = 8
        frame = NSRect(x: inset, y: inset, width: max(0, bounds.width - inset * 2), height: Self.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        alphaValue < 0.05 ? nil : super.hitTest(point)
    }

    override func layout() {
        super.layout()
        backing.frame = bounds
        host.frame = backing.bounds
        let size: CGFloat = 26, gap: CGFloat = 4, endWidth: CGFloat = 50
        let icons: [NSView] = [mic, camera, share, toWindow, toBar]
        let total = CGFloat(icons.count) * size + CGFloat(icons.count - 1) * gap + gap * 2 + endWidth
        var x = max(6, (bounds.width - total) / 2)
        let y = (bounds.height - size) / 2
        for icon in icons {
            icon.frame = NSRect(x: x, y: y, width: size, height: size)
            x += size + gap
        }
        end.frame = NSRect(x: x + gap, y: y + 3, width: endWidth, height: size - 6)
    }

    func refresh() {
        let s = actions.state()
        mic.image = NSImage(systemSymbolName: s.muted ? "mic.slash.fill" : "mic.fill", accessibilityDescription: "Microphone")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        mic.contentTintColor = s.muted ? MeetingTheme.redNS : .white
        mic.toolTip = s.muted ? "Unmute" : "Mute"
        mic.setAccessibilityLabel(mic.toolTip)
        camera.image = NSImage(systemSymbolName: s.cameraOn ? "video.fill" : "video.slash.fill", accessibilityDescription: "Camera")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        camera.contentTintColor = s.cameraOn ? .white : MeetingTheme.redNS
        camera.toolTip = s.cameraOn ? "Turn camera off" : "Turn camera on"
        camera.setAccessibilityLabel(camera.toolTip)
        // End asks in place: pressed once it reads Confirm until pressed again,
        // Esc, or 15 seconds.
        let armed = actions.endArmed()
        end.title = armed ? "Confirm" : "End"
        end.layer?.borderWidth = armed ? 1.5 : 0
        end.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        end.toolTip = armed ? "Press again to end. Esc keeps going." : "End or leave the meeting"
        end.setAccessibilityLabel(armed ? "Confirm end meeting" : "End meeting")
        // Asked where you press: a callout right above End, never the island.
        if armed, callout == nil, end.window != nil {
            let ask = actions.endAsk()
            let pop = NSPopover()
            pop.behavior = .applicationDefined
            pop.animates = true
            pop.contentViewController = NSHostingController(rootView: ConfirmCallout(title: ask.title, detail: ask.detail))
            pop.show(relativeTo: end.bounds, of: end, preferredEdge: end.isFlipped ? .minY : .maxY)
            callout = pop
        } else if !armed, let pop = callout {
            pop.close()
            callout = nil
        }
    }

    func setVisible(_ visible: Bool) {
        if visible { refresh() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = visible ? 1 : 0
        }
    }
}
