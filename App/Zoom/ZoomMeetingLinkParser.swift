//
//  ZoomMeetingLinkParser.swift
//  Greenroom
//
//  Pulls a meeting number + passcode out of whatever got pasted - a full
//  zoom.us/zoommtg:// join link, or the plain text block Zoom's own
//  calendar invites use ("Meeting ID: 829 1639 0348" / "Passcode: ...").
//  Lets "Paste Link" replace manually copying two separate fields out of
//  an invite.
//
import Foundation

enum ZoomMeetingLinkParser {

    /// Returns `nil` if no meeting number could be found anywhere in `raw`.
    /// Password is `""` (not nil) when a number was found but no password
    /// was - some meetings genuinely don't have one.
    static func parse(_ raw: String) -> (number: String, password: String)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = extractNumber(from: text) else { return nil }
        return (number, extractPassword(from: text) ?? "")
    }

    /// Order matters: URL query/path forms are unambiguous, so they're
    /// tried before the looser "whole string is just digits" fallback.
    private static func extractNumber(from text: String) -> String? {
        if let match = firstMatch(#"(?:/j/|confno=)(\d{9,11})"#, in: text) {
            return match
        }
        if let match = firstMatch(#"Meeting ID:?\s*([\d][\d \-]{7,13}\d)"#, in: text, caseInsensitive: true) {
            return match.filter(\.isNumber)
        }
        let digitsOnly = text.filter(\.isNumber)
        let looksLikeBareID = text.allSatisfy { $0.isNumber || $0.isWhitespace || $0 == "-" }
        if looksLikeBareID, (9...11).contains(digitsOnly.count) {
            return digitsOnly
        }
        return nil
    }

    private static func extractPassword(from text: String) -> String? {
        if let match = firstMatch(#"[?&]pwd=([^&\s]+)"#, in: text) {
            return match
        }
        if let match = firstMatch(#"Pass(?:code|word):?\s*(\S+)"#, in: text, caseInsensitive: true) {
            return match
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> String? {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.firstMatch(in: text, options: [], range: range),
              result.numberOfRanges > 1,
              let matchRange = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[matchRange])
    }
}
