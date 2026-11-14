//
//  UploadPrompt.swift
//  Greenroom
//
//  The one question the YouTube feature asks: "Upload this recording?" It opens
//  the island that grows out of the notch (NotchStatusController.swift) into a
//  larger panel with two buttons, and retracts once answered. Not an NSAlert: a
//  modal would hold Greenroom's own main loop hostage while the class teardown
//  is still running behind it, and would drag the main window to the front to
//  be seen. The island blocks nothing and takes no focus; ignoring it for two
//  minutes is a "Not now". Prompts queue first in, first out.
//
import AppKit

@MainActor
enum UploadPromptCard {

    /// Queues the prompt. `onUpload` runs on Upload; `onDismiss` on Not now or
    /// after `timeout` seconds on screen with no answer. `detail` is ONE line;
    /// `help` is the longer explanation, shown on hover.
    static func show(title: String, detail: String, help: String? = nil, uploadTitle: String = "Upload",
                     timeout: TimeInterval = IslandRules.promptTimeout,
                     onUpload upload: @escaping () -> Void,
                     onDismiss dismiss: @escaping () -> Void) {
        NotchStatusController.shared.showPrompt(
            IslandPrompt(title: title, detail: detail, help: help, uploadTitle: uploadTitle, timeout: timeout),
            onUpload: upload, onDismiss: dismiss)
    }

    /// Takes the prompts down. `answered` false means the dismiss handlers run;
    /// true means a button already handled it.
    static func hide(answered: Bool) {
        NotchStatusController.shared.hidePrompts(answered: answered)
    }
}
