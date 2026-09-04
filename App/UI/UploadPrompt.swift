//
//  UploadPrompt.swift
//  Greenroom
//
//  The one question the YouTube feature asks: "Upload this recording?" A
//  small floating card with two buttons, in the toast's family and place -
//  low and centred, above the layout, on the screen the teacher is looking
//  at. Not an NSAlert: a modal would hold Greenroom's own main loop hostage
//  while the class teardown is still running behind it, and would drag the
//  main window to the front to be seen. This card blocks nothing and takes
//  no focus; ignoring it for two minutes is a "Not now".
//
import AppKit

@MainActor
enum UploadPromptCard {

    private final class PromptPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private static var panel: PromptPanel?
    private static var onUpload: (() -> Void)?
    private static var onDismiss: (() -> Void)?
    private static var timeoutTask: Task<Void, Never>?

    private static let width: CGFloat = 380
    private static let padding: CGFloat = 16

    /// Shows the card. `onUpload` runs on Upload; `onDismiss` on Not now or
    /// after `timeout` seconds with no answer. Showing again replaces the
    /// previous card (its dismiss handler is called first).
    static func show(title: String, detail: String, timeout: TimeInterval = 120,
                     onUpload upload: @escaping () -> Void,
                     onDismiss dismiss: @escaping () -> Void) {
        hide(answered: false)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { dismiss(); return }
        onUpload = upload
        onDismiss = dismiss

        let created = make(on: screen, title: title, detail: detail)
        panel = created
        created.orderFrontRegardless()

        timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            hide(answered: false)
        }
    }

    /// Takes the card down. `answered` false means the dismiss handler runs
    /// (Not now, timeout, replaced); true means a button already handled it.
    static func hide(answered: Bool) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let dismiss = onDismiss
        onUpload = nil
        onDismiss = nil
        panel?.close()
        panel = nil
        if !answered { dismiss?() }
    }

    @MainActor private final class Actions: NSObject {
        static let shared = Actions()
        @objc func upload(_ sender: Any?) {
            let handler = UploadPromptCard.onUpload
            UploadPromptCard.hide(answered: true)
            handler?()
        }
        @objc func notNow(_ sender: Any?) {
            UploadPromptCard.hide(answered: false)
        }
    }

    private static func make(on screen: NSScreen, title: String, detail: String) -> PromptPanel {
        let created = PromptPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false, screen: screen)
        created.isReleasedWhenClosed = false
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let backing = NSVisualEffectView()
        backing.material = .hudWindow
        backing.blendingMode = .behindWindow
        backing.state = .active
        backing.wantsLayer = true
        backing.layer?.cornerRadius = 14       // DESIGN.md radius-lg
        backing.layer?.masksToBounds = true
        created.contentView = backing

        let icon = NSImageView(image: NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: nil)!)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = NSColor(named: "AccentColor") ?? .systemGreen

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 3

        let uploadButton = NSButton(title: "Upload", target: Actions.shared, action: #selector(Actions.upload(_:)))
        uploadButton.bezelStyle = .rounded
        uploadButton.controlSize = .small
        uploadButton.keyEquivalent = "\r"
        let laterButton = NSButton(title: "Not now", target: Actions.shared, action: #selector(Actions.notNow(_:)))
        laterButton.bezelStyle = .rounded
        laterButton.controlSize = .small

        [icon, titleLabel, detailLabel, uploadButton, laterButton].forEach(backing.addSubview)

        // Layout by hand, like the toast: measured text, buttons on the
        // right of a bottom row.
        let textX = padding * 2 + 22
        let textWidth = width - textX - padding
        titleLabel.preferredMaxLayoutWidth = textWidth
        detailLabel.preferredMaxLayoutWidth = textWidth
        let titleHeight = titleLabel.sizeThatFits(NSSize(width: textWidth, height: 200)).height
        let detailHeight = detailLabel.sizeThatFits(NSSize(width: textWidth, height: 200)).height
        let buttonsHeight: CGFloat = 24
        let height = padding * 2 + titleHeight + 4 + detailHeight + 12 + buttonsHeight

        created.setContentSize(NSSize(width: width, height: height))
        backing.frame = NSRect(x: 0, y: 0, width: width, height: height)
        icon.frame = NSRect(x: padding, y: height - padding - 20, width: 22, height: 20)
        titleLabel.frame = NSRect(x: textX, y: height - padding - titleHeight, width: textWidth, height: titleHeight)
        detailLabel.frame = NSRect(x: textX, y: height - padding - titleHeight - 4 - detailHeight,
                                   width: textWidth, height: detailHeight)
        uploadButton.sizeToFit()
        laterButton.sizeToFit()
        let uploadWidth = max(72, uploadButton.frame.width)
        let laterWidth = max(72, laterButton.frame.width)
        uploadButton.frame = NSRect(x: width - padding - uploadWidth, y: padding, width: uploadWidth, height: buttonsHeight)
        laterButton.frame = NSRect(x: width - padding - uploadWidth - 8 - laterWidth, y: padding, width: laterWidth, height: buttonsHeight)

        let area = screen.visibleFrame
        // Same shelf as the toast, a little higher so the two never overlap.
        created.setFrameOrigin(NSPoint(x: (area.midX - width / 2).rounded(),
                                       y: (area.minY + max(200, area.height * 0.24)).rounded()))
        return created
    }
}
