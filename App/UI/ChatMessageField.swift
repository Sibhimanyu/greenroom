//
//  ChatMessageField.swift
//  Greenroom
//
//  The chat's text box. Return sends; Shift-Return is a new line; the box
//  grows to about five lines and then scrolls. It is AppKit because
//  SwiftUI's TextField on macOS would not reliably push a cleared binding
//  back into the focused field editor (the sent text stayed in the box,
//  reported twice), so the clear here is imperative.
//
//  It also owns paste: Cmd-V with a file or an image on the pasteboard shares
//  it instead of pasting a path, and plain text falls through untouched.
//
import SwiftUI
import AppKit

struct ChatMessageField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSend: () -> Void
    var onPasteFiles: ([URL]) -> Void = { _ in }

    static let font = NSFont.systemFont(ofSize: 13)
    private static let inset = NSSize(width: 0, height: 3)
    private static let maxHeight: CGFloat = 96

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SendingTextView()
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = Self.inset
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onSend = { [weak textView] in
            context.coordinator.parent.onSend()
            textView?.string = "" // the imperative clear
            context.coordinator.parent.text = ""
        }
        textView.onPasteFiles = onPasteFiles
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? SendingTextView else { return }
        textView.onPasteFiles = onPasteFiles
        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.setAccessibilityLabel(placeholder)
            textView.needsDisplay = true
        }
        if textView.string != text { textView.string = text }
    }

    /// The height the text needs at the width offered, within one to five lines.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = max(proposal.width ?? 200, 40)
        let lineHeight = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        var measured = text
        if measured.hasSuffix("\n") || measured.isEmpty { measured += "\u{200B}" }
        let bounds = (measured as NSString).boundingRect(
            with: NSSize(width: width - 10, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.font])
        let height = min(max(ceil(bounds.height), lineHeight) + Self.inset.height * 2, Self.maxHeight)
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatMessageField
        init(_ parent: ChatMessageField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }

    final class SendingTextView: NSTextView {
        var onSend: () -> Void = {}
        var onPasteFiles: ([URL]) -> Void = { _ in }
        var placeholder = ""

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            guard isReturn, !hasMarkedText() else { return super.keyDown(with: event) }
            if event.modifierFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSend()
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty else { return }
            let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 5),
                                 y: textContainerInset.height)
            (placeholder as NSString).draw(at: origin, withAttributes: [
                .font: ChatMessageField.font,
                .foregroundColor: NSColor.placeholderTextColor,
            ])
        }

        /// Files and pictures are shared; text pastes as text.
        override func paste(_ sender: Any?) {
            let board = NSPasteboard.general
            if let urls = board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
               !urls.isEmpty, urls.allSatisfy(\.isFileURL) {
                onPasteFiles(urls)
                return
            }
            // An image copied from Preview or a browser has no file behind it.
            if board.string(forType: .string) == nil,
               let image = NSImage(pasteboard: board), let url = Self.writeTemporary(image) {
                onPasteFiles([url])
                return
            }
            super.paste(sender)
        }

        private static func writeTemporary(_ image: NSImage) -> URL? {
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted image.png")
            try? png.write(to: url, options: .atomic)
            return url
        }
    }
}
