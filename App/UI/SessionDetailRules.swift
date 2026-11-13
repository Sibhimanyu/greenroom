//
//  SessionDetailRules.swift
//
//  The session page's pure rules, kept free of views so tests can compile them.
//
import SwiftUI

enum SessionDetailRules {
    /// Below this page width the inspector folds away rather than squeeze the
    /// player (the page minimum is 900: player about 540, inspector 340).
    static let foldWidth: CGFloat = 820

    /// What the inspector does when the page is resized.
    /// - Returns: whether it is shown, and whether the width (not the person)
    ///   is why it is hidden, so it can come back when the window grows.
    static func inspector(width: CGFloat, shown: Bool, foldedByWidth: Bool)
        -> (shown: Bool, foldedByWidth: Bool) {
        if width > 0, width < foldWidth, shown { return (false, true) }
        if width >= foldWidth, foldedByWidth { return (true, false) }
        return (shown, foldedByWidth)
    }

    /// A click on the marks lane, as a time in the recording.
    static func seekTime(x: CGFloat, width: CGFloat, duration: Double) -> Double? {
        guard duration > 0, width > 0 else { return nil }
        return min(duration, max(0, duration * Double(x / width)))
    }

    /// Where a mark sits along the lane, 0...1.
    static func fraction(of seconds: Double, in duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }

    static func uploadTitle(uploading: Bool, uploaded: Bool) -> String {
        uploading ? "Uploading\u{2026}" : (uploaded ? "On YouTube" : "Upload")
    }

    /// "Analysing 2/4\u{2026}" while it runs, "Report" once there is one.
    static func analyseTitle(running: Bool, analysed: Bool,
                             progress: (index: Int, count: Int)?) -> String {
        if running {
            if let progress, progress.count > 0 { return "Analysing \(progress.index)/\(progress.count)\u{2026}" }
            return "Analysing\u{2026}"
        }
        return analysed ? "Report" : "Analyse"
    }

    /// The first upload asks once; after that it just goes.
    static let uploadConfirmedKey = "youtubeUploadConfirmed"
}

