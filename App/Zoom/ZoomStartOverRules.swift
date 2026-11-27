//
//  ZoomStartOverRules.swift
//  Greenroom
//
//  Words and decisions for the setup guide's ways back (spec R10 to R12):
//  Start over (forget both apps' keys), Use a different app (one part), and
//  the Find my app wording. Pure: Foundation only.
//
import Foundation

enum ZoomStartOverRules {
    static let buttonTitle = "Start over\u{2026}"
    static let title = "Remove your Zoom keys from Greenroom?"
    static let message = "Greenroom forgets both apps\u{2019} keys on this Mac and signs out of Zoom here. Your apps in Zoom stay as they are, and you can fill the keys in again from Zoom."
    static let confirmTitle = "Remove keys"
    static let liveHelp = "End the meeting first."
    static let idleHelp = "Forgets both apps\u{2019} keys on this Mac and signs out of Zoom here."

    static let useDifferentAppTitle = "Use a different app"
    static let removedNotice = "Keys removed"

    /// Quiet button in the Zoom step whenever any key is filled.
    static func isShown(_ facts: ZoomGuideFlowFacts) -> Bool { facts.anythingFilled }

    static func help(inSession: Bool) -> String { inSession ? liveHelp : idleHelp }

    /// The fields a part holds (five across both parts); clearing them also clears the Keychain copy of the secrets.
    static func fields(for part: ZoomGuidePart) -> [ZoomKeyField] {
        switch part {
        case .meetingApp: return [.clientID, .clientSecret]
        case .hostingApp: return [.accountID, .clientID, .clientSecret]
        case .check: return []
        }
    }

    static func showsUseDifferentApp(_ state: ZoomGuidePartState) -> Bool { state == .done }
}
