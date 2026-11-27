//
//  ZoomClipboardRules.swift
//  Greenroom
//
//  Zoom's Basic information page does not put the Client secret in its page
//  (only dots; Zoom fetches it when you press its copy or reveal control). So the
//  person presses Zoom's OWN copy button and Greenroom picks the copied text up
//  from the clipboard (spec R17): while a credentials page is shown, and for 60s
//  after, a new clipboard string that is key-shaped, and not a key already read,
//  becomes the field the coach is pointing at. The text is never logged and is
//  handed straight to the same fill/offer path as a page read. Pure: Foundation only.
//
import Foundation

enum ZoomClipboardRules {
    /// How long after leaving a credentials page a copy still counts.
    static let graceSeconds: TimeInterval = 60

    /// Only a single key-shaped token (trimmed) is a candidate.
    static func clean(_ copied: String) -> String? {
        let t = copied.trimmingCharacters(in: .whitespacesAndNewlines)
        return ZoomMarketplacePages.isKey(t) ? t : nil
    }

    /// The field a copied string belongs to, or nil. `missing` are the page's fields Greenroom does not have yet;
    /// `pointedAt` is the one the coach is spotlighting; `found` are the values already known.
    static func assign(copied: String, found: [ZoomKeyField: String], missing: [ZoomKeyField], pointedAt: ZoomKeyField?) -> ZoomKeyField? {
        guard let key = clean(copied), !found.values.contains(key), !missing.isEmpty else { return nil }
        if let pointedAt, missing.contains(pointedAt) { return pointedAt }
        let order: [ZoomKeyField] = [.accountID, .clientID, .clientSecret]
        return order.first { missing.contains($0) }
    }

    /// `onCredentialsPage`: one is shown now; `secondsSinceLeaving`: nil if never on one (or still on it).
    static func isWatching(onCredentialsPage: Bool, secondsSinceLeaving: TimeInterval?) -> Bool {
        if onCredentialsPage { return true }
        guard let s = secondsSinceLeaving else { return false }
        return s < graceSeconds
    }
}
