//
//  Toast.swift
//  Greenroom
//
//  A short confirmation, low and centred on screen.
//
//  Clipping already posted a system notification, and a system notification is
//  the wrong instrument for this: it lands in the top-right corner of whichever
//  display macOS decides, it is silently suppressed in Do Not Disturb and in
//  most screen-sharing setups, and it needs a permission the teacher may never
//  have granted. A teacher mid-class pressing a hotkey needs to know it landed
//  right now, on the screen they are looking at, without turning their head.
//
//  Deliberately not the readiness HUD. That one is centred, sticks around for
//  the length of a start and reports progress; this appears for two seconds and
//  says one thing.
//
import AppKit

enum ToastController {

    enum Kind {
        case working, success, failure

        var symbol: String {
            switch self {
            case .working: return "hourglass"
            case .success: return "checkmark.circle.fill"
            case .failure: return "exclamationmark.triangle.fill"
            }
        }
        var tint: NSColor {
            switch self {
            case .working: return .secondaryLabelColor
            case .success: return NSColor(named: "AccentColor") ?? .systemGreen
            case .failure: return .systemRed
            }
        }
    }

    private final class ToastPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static var panel: ToastPanel?
    private static var icon: NSImageView?
    private static var titleLabel: NSTextField?
    private static var detailLabel: NSTextField?
    private static var dismissTask: Task<Void, Never>?

    private static let width: CGFloat = 340
    private static let padding: CGFloat = 14

    /// Shows, or updates whatever is already showing.
    ///
    /// Updating rather than stacking is the point: "Saving the last 5 min" and
    /// then "Clipped the last 5 min" are two states of one event, and two cards
    /// sliding over each other would read as two things happening.
    ///
    /// - Parameter dismissAfter: nil keeps it up, for a step that is still
    ///   running and will be replaced by its own result.
    static func show(_ title: String,
                     detail: String? = nil,
                     kind: Kind = .success,
                     dismissAfter: TimeInterval? = 2.6) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        dismissTask?.cancel()
        dismissTask = nil

        let hosting = panel ?? make(on: screen)
        hosting.alphaValue = 1

        icon?.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        icon?.contentTintColor = kind.tint
        titleLabel?.stringValue = title
        detailLabel?.stringValue = detail ?? ""
        detailLabel?.isHidden = (detail ?? "").isEmpty

        let height = layout(in: hosting)
        let area = screen.visibleFrame
        // Low and centred: out of the way of the shared content, which sits in
        // the upper two thirds, but nowhere near the corner where a system
        // notification would have gone unnoticed.
        hosting.setFrame(NSRect(x: (area.midX - width / 2).rounded(),
                                y: (area.minY + max(120, area.height * 0.14)).rounded(),
                                width: width, height: height),
                         display: true)
        hosting.orderFrontRegardless()

        guard let dismissAfter else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(dismissAfter * 1_000_000_000))
            guard !Task.isCancelled, let hosting = panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25          // DESIGN.md, ease-in leaving
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                hosting.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in hide() }
            }
        }
    }

    static func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.close()
        panel = nil
        icon = nil
        titleLabel = nil
        detailLabel = nil
    }

    /// Places the contents and returns the height they need.
    @discardableResult
    private static func layout(in hosting: ToastPanel) -> CGFloat {
        guard let icon, let titleLabel, let detailLabel else { return 56 }
        let textWidth = width - padding * 3 - 22
        titleLabel.preferredMaxLayoutWidth = textWidth
        detailLabel.preferredMaxLayoutWidth = textWidth
        let titleHeight = titleLabel.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let detailHeight = detailLabel.isHidden
            ? 0 : detailLabel.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height + 2
        let height = padding * 2 + max(22, titleHeight + detailHeight)

        hosting.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        icon.frame = NSRect(x: padding, y: height - padding - 20, width: 22, height: 20)
        let textX = padding * 2 + 22
        titleLabel.frame = NSRect(x: textX, y: height - padding - titleHeight,
                                  width: textWidth, height: titleHeight)
        detailLabel.frame = NSRect(x: textX, y: height - padding - titleHeight - detailHeight,
                                   width: textWidth, height: max(0, detailHeight - 2))
        return height
    }

    private static func make(on screen: NSScreen) -> ToastPanel {
        let created = ToastPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 56),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false, screen: screen)
        created.isReleasedWhenClosed = false
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        created.ignoresMouseEvents = true      // a readout, nothing to click

        let backing = NSVisualEffectView()
        backing.material = .hudWindow
        backing.blendingMode = .behindWindow
        backing.state = .active
        backing.wantsLayer = true
        backing.layer?.cornerRadius = 14       // DESIGN.md radius-lg
        backing.layer?.masksToBounds = true
        backing.autoresizingMask = [.width, .height]
        created.contentView = backing

        let image = NSImageView()
        image.imageScaling = .scaleProportionallyDown
        backing.addSubview(image)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        backing.addSubview(title)

        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingMiddle
        backing.addSubview(detail)

        panel = created
        icon = image
        titleLabel = title
        detailLabel = detail
        return created
    }
}
