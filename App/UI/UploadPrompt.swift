//
//  UploadPrompt.swift
//  Greenroom
//
//  The one question the YouTube feature asks: "Upload this recording?" A
//  small card with two buttons, in the one message panel at the top-right
//  of the screen the teacher is looking at (WindowBanner.swift). Not an
//  NSAlert: a modal would hold Greenroom's own main loop hostage while the
//  class teardown is still running behind it, and would drag the
//  main window to the front to be seen. This card blocks nothing and takes
//  no focus; ignoring it for two minutes is a "Not now".
//
import AppKit

@MainActor
enum UploadPromptCard {

    private static var onUpload: (() -> Void)?
    private static var onDismiss: (() -> Void)?
    private static var timeoutTask: Task<Void, Never>?

    /// Shows the card. `onUpload` runs on Upload; `onDismiss` on Not now or
    /// after `timeout` seconds with no answer. Showing again replaces the
    /// previous card (its dismiss handler is called first).
    static func show(title: String, detail: String, uploadTitle: String = "Upload", timeout: TimeInterval = 120,
                     onUpload upload: @escaping () -> Void,
                     onDismiss dismiss: @escaping () -> Void) {
        hide(answered: false)
        onUpload = upload
        onDismiss = dismiss

        BannerCenter.shared.showPrompt(.init(title: title, detail: detail, uploadTitle: uploadTitle))

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
        BannerCenter.shared.hidePrompt()
        if !answered { dismiss?() }
    }

    /// The two answers, for the card's buttons.
    static func upload() {
        let handler = onUpload
        hide(answered: true)
        handler?()
    }

    static func notNow() {
        hide(answered: false)
    }
}
