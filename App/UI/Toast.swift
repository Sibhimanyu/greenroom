//
//  Toast.swift
//  Greenroom
//
//  A short confirmation. Drawn by the one message panel at the top-right of
//  the screen (WindowBanner.swift), where macOS shows its own notifications,
//  so a teacher mid-class sees it land without turning their head and it never
//  covers a Greenroom control.
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
    }

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
        MainActor.assumeIsolated {
            BannerCenter.shared.showToast(.init(title: title, detail: detail, kind: kind),
                                          dismissAfter: dismissAfter)
        }
    }

    static func hide() {
        MainActor.assumeIsolated { BannerCenter.shared.hideToast() }
    }
}
