//
//  Toast.swift
//  Greenroom
//
//  A short confirmation. It shows on the island that grows out of the notch
//  (NotchStatusController.swift): an icon and one line, about 2.5 s, then the
//  island retracts. Toasts wait their turn in a FIFO behind the start's status
//  and the recording countdown, so they never stack or cover a Greenroom control.
//
import AppKit

enum ToastController {

    typealias Kind = IslandToastKind

    /// Pass as `dismissAfter` for the standard time: 2.5 s, a failure 4 s, and
    /// a failure with an action until it is clicked.
    static let automatic: TimeInterval = -1

    /// Shows a toast. A new toast replaces one that is held while it waits for
    /// its result ("Saving the last 5 min" then "Clipped the last 5 min").
    ///
    /// - Parameter dismissAfter: nil holds it, for a step that is still
    ///   running and will be replaced by its own result.
    /// - Parameter action: runs when the toast is clicked; a failure toast with
    ///   an action stays until then.
    static func show(_ title: String,
                     detail: String? = nil,
                     kind: Kind = .success,
                     dismissAfter: TimeInterval? = ToastController.automatic,
                     action: (() -> Void)? = nil) {
        MainActor.assumeIsolated {
            let duration = dismissAfter == automatic
                ? IslandRules.toastDuration(kind: kind, hasAction: action != nil)
                : dismissAfter
            NotchStatusController.shared.showToast(
                IslandToast(title: title, detail: detail, kind: kind, duration: duration, hasAction: action != nil),
                action: action)
        }
    }

    static func hide() {
        MainActor.assumeIsolated { NotchStatusController.shared.hideToasts() }
    }
}
