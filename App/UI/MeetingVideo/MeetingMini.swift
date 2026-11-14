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

// MARK: - What the Mini's buttons do

/// Set by the coordinator; the strip reads and calls these.
struct MeetingMiniActions {
    var toggleMic: () -> Void = {}
    var toggleCamera: () -> Void = {}
    var toMeetingWindow: () -> Void = {}
    var toBar: () -> Void = {}
    var end: () -> Void = {}
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
    static func apply(to button: NSButton, on: Bool, kind: ShowOnShare.ShareKind, pointSize: CGFloat = 13) {
        let available = ShowOnShare.isAvailable(kind)
        let marked = ShowOnShare.marksWindow(on: on, kind: kind)
        button.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: ShowOnShare.label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))
        button.isEnabled = available
        button.state = marked ? .on : .off
        button.contentTintColor = marked ? MeetingTheme.netNS : (available ? .white : MeetingTheme.secondaryTextNS)
        button.toolTip = ShowOnShare.help(kind: kind, on: on)
        button.setAccessibilityLabel(ShowOnShare.label)
        button.setAccessibilityValue(marked ? "on" : "off")
        button.setAccessibilityHelp(ShowOnShare.help(kind: kind, on: on))
    }
}

// MARK: - Show on my share: the amber border

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
    private lazy var toWindow = iconButton("arrow.up.right.square", "Meeting window") { [weak self] in self?.actions.toMeetingWindow() }
    private lazy var toBar = iconButton("arrow.down.right.square", "Control bar") { [weak self] in self?.actions.toBar() }
    private lazy var end = ClosureButton { [weak self] in self?.actions.end() }

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
        let size: CGFloat = 26, gap: CGFloat = 4, endWidth: CGFloat = 38
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
    }

    func setVisible(_ visible: Bool) {
        if visible { refresh() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = visible ? 1 : 0
        }
    }
}
