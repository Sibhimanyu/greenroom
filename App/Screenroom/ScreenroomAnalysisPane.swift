//
//  ScreenroomAnalysisPane.swift
//  Greenroom
//
//  Time labels the Sessions window uses for analysis rows and note stamps.
//  The pane view that once lived here moved into the Sessions window itself.
//
import Foundation

enum ScreenroomAnalysisPane {
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s < 60 ? "\(s)s" : String(format: "%dm %02ds", s / 60, s % 60)
    }

    static func stamp(_ ms: Int) -> String {
        let total = max(0, ms / 1000)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
