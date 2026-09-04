//
//  PrompterMenuBar.swift
//  Greenroom
//
//  Prompter's surface when there is no reference display: a status item with
//  a waveform and an unseen count, and a popover of cards under it.
//
//  AppKit rather than a second MenuBarExtra: a SwiftUI menu-bar extra with a
//  window style activates the app when it opens, and Prompter must never pull
//  Greenroom in front of the page the teacher is reading. An NSPopover from an
//  NSStatusItem does not.
//
//  Exactly one waveform in the menu bar at a time: this item while it is the
//  surface, the "GR" label's glyph while the rail is. The coordinator decides.
//
import AppKit

@MainActor
final class PrompterMenuBar: NSObject, NSPopoverDelegate {

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private let content = PopoverContent()
    private var state = PrompterSurfaceState.empty
    private var unseen = 0

    /// Called when the popover opens, so the badge can clear.
    var onOpen: (() -> Void)?
    /// "Stop listening for this class."
    var onStopForClass: (() -> Void)?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = content
        content.onStop = { [weak self] in
            self?.popover.performClose(nil)
            self?.onStopForClass?()
        }
    }

    var isVisible: Bool { item != nil }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let created = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            created.button?.target = self
            created.button?.action = #selector(toggle)
            created.button?.imagePosition = .imageLeading
            created.button?.setAccessibilityLabel("Prompter")
            item = created
            render()
        } else if !visible, let existing = item {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(existing)
            item = nil
        }
    }

    func apply(_ next: PrompterSurfaceState, unseen: Int, statusText: String) {
        state = next
        self.unseen = unseen
        content.apply(next, statusText: statusText)
        render()
        if popover.isShown { resize() }
    }

    private func render() {
        guard let button = item?.button else { return }
        let symbol = state.paused ? "waveform.slash" : "waveform"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Prompter")
        image?.isTemplate = true
        button.image = image
        button.title = unseen > 0 ? " \(unseen)" : ""
        button.toolTip = state.paused ? "Prompter is paused" : "Prompter is listening \u{00B7} \(state.cards.count) link\(state.cards.count == 1 ? "" : "s")"
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            resize()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            onOpen?()
        }
    }

    private func resize() {
        let width: CGFloat = 380
        let height = content.height(forWidth: width)
        popover.contentSize = NSSize(width: width, height: height)
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)
        content.needsLayout = true
    }

    func popoverDidClose(_ notification: Notification) {
        render()
    }

    // MARK: Content

    private final class PopoverContent: NSView {
        private let status = NSTextField(labelWithString: "")
        private let empty = NSTextField(wrappingLabelWithString: "")
        private let cards: [PrompterCardView] = (0..<PrompterRailBlock.maxCards).map { _ in PrompterCardView(frame: .zero) }
        private lazy var stop = ClosureButton { [weak self] in self?.onStop?() }
        private var state = PrompterSurfaceState.empty
        var onStop: (() -> Void)?

        private let pad: CGFloat = 12
        private let gap: CGFloat = 6

        override init(frame: NSRect) {
            super.init(frame: frame)
            status.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            status.textColor = .tertiaryLabelColor
            addSubview(status)
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.stringValue = "Nothing yet. Name a book, a video you saw, a topic or a place and a link will appear here."
            addSubview(empty)
            for card in cards {
                card.isHidden = true
                addSubview(card)
            }
            stop.bezelStyle = .rounded
            stop.controlSize = .small
            stop.title = "Stop listening for this class"
            addSubview(stop)
        }

        required init?(coder: NSCoder) { nil }

        func apply(_ next: PrompterSurfaceState, statusText: String) {
            state = next
            status.stringValue = statusText.uppercased()
            let shown = Array(next.cards.prefix(PrompterRailBlock.maxCards))
            for (index, view) in cards.enumerated() {
                if index < shown.count {
                    view.isHidden = false
                    view.onOpen = next.open
                    view.onSend = next.send
                    view.onDismiss = next.dismiss
                    view.apply(shown[index], canSend: next.canSend)
                } else {
                    view.isHidden = true
                }
            }
            empty.isHidden = !shown.isEmpty
            needsLayout = true
        }

        func height(forWidth width: CGFloat) -> CGFloat {
            let count = min(state.cards.count, PrompterRailBlock.maxCards)
            var height = pad + 14 + gap
            if count == 0 {
                let textWidth = width - pad * 2
                height += empty.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height + gap
            } else {
                height += CGFloat(count) * PrompterCardView.height + CGFloat(count - 1) * gap + gap
            }
            height += 24 + pad
            return height
        }

        override func layout() {
            super.layout()
            let width = bounds.width - pad * 2
            var y = bounds.height - pad - 14
            status.frame = NSRect(x: pad, y: y, width: width, height: 14)
            y -= gap
            if empty.isHidden {
                for view in cards where !view.isHidden {
                    y -= PrompterCardView.height
                    view.frame = NSRect(x: pad, y: y, width: width, height: PrompterCardView.height)
                    y -= gap
                }
            } else {
                let textHeight = empty.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height
                y -= textHeight
                empty.frame = NSRect(x: pad, y: y, width: width, height: textHeight)
                y -= gap
            }
            stop.frame = NSRect(x: pad, y: pad, width: 200, height: 24)
        }
    }
}
