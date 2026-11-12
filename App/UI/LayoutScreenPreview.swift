//
//  LayoutScreenPreview.swift
//  Greenroom
//
//  "Show on screen": for a second and a half, an outline on each real display
//  where each piece of the layout would go, naming it.
//
//  Borderless, click-through and non-activating, like the readiness card: it
//  must never take focus, never intercept a click, and leave on its own. It is
//  not a window the teacher can reach, so it cannot get in the way of the
//  layout it is describing.
//
import SwiftUI
import AppKit

@MainActor
enum LayoutScreenPreview {

    /// One rectangle to outline: where, on which display's coordinates, and what to call it.
    struct Item {
        var frame: CGRect          // NSWindow (bottom-left) coordinates
        var title: String
        var detail: String
        var icon: NSImage?
    }

    private static var panels: [NSPanel] = []
    private static var dismissTask: Task<Void, Never>?
    static let duration: TimeInterval = 1.5

    /// Resolves a template's current variant against the connected displays.
    /// `look` names a piece (the page already knows how).
    static func items(for template: LayoutTemplate, look: (LayoutPiece) -> LayoutPieceLook) -> [Item] {
        func resolve(_ pieces: [LayoutPiece], on screen: NSScreen) -> [Item] {
            pieces.map { piece in
                let frame = LayoutGeometry.nsFrame(for: piece.rect, visibleFrame: screen.visibleFrame)
                let l = look(piece)
                return Item(frame: frame, title: l.name,
                            detail: "\(Int(frame.width.rounded()))\u{00D7}\(Int(frame.height.rounded()))",
                            icon: l.icon)
            }
        }
        guard let main = DisplayResolver.mainDisplayScreen() else { return [] }
        if let two = template.twoDisplays, let second = secondScreen(uuid: two.secondUUID) {
            return resolve(two.main, on: main) + resolve(two.second, on: second)
        }
        return resolve(template.oneDisplay, on: main)
    }

    /// The saved display, else the first one that is not the main (the same rule
    /// the participant view uses).
    static func secondScreen(uuid: String) -> NSScreen? {
        if !uuid.isEmpty, let s = DisplayResolver.screen(forUUID: uuid) { return s }
        return DisplayResolver.firstSecondaryScreen()
    }

    static func show(_ items: [Item]) {
        dismiss(animated: false)
        for item in items where item.frame.width > 8 && item.frame.height > 8 {
            let panel = OverlayPanel(contentRect: item.frame)
            let host = NSHostingView(rootView: OutlineView(item: item))
            host.frame = NSRect(origin: .zero, size: item.frame.size)
            panel.contentView = host
            panel.alphaValue = 0
            panel.orderFrontRegardless()   // never makeKey: nothing here may take focus
            panels.append(panel)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panels.forEach { $0.animator().alphaValue = 1 }
        }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if Task.isCancelled { return }
            dismiss(animated: true)
        }
    }

    private static func dismiss(animated: Bool) {
        dismissTask?.cancel()
        let closing = panels
        panels = []
        guard animated else { closing.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            closing.forEach { $0.orderOut(nil) }
        })
    }

    private final class OverlayPanel: NSPanel {
        init(contentRect: CGRect) {
            super.init(contentRect: contentRect,
                       styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            ignoresMouseEvents = true
            level = .floating
            hidesOnDeactivate = false
            isReleasedWhenClosed = false
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
            setFrame(contentRect, display: false)
        }
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private struct OutlineView: View {
        let item: Item

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Brand.green.opacity(0.18))
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Brand.green, lineWidth: 3)
                VStack(spacing: 6) {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                    }
                    Text(item.title)
                        .font(.system(size: 20, weight: .semibold))
                    Text(item.detail)
                        .font(.system(size: 13, design: .monospaced))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.72)))
            }
            .padding(4)
        }
    }
}
