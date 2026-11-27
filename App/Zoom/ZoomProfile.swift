//
//  ZoomProfile.swift
//  Greenroom
//
//  The signed-in Zoom account's own name and email, found in the text of Zoom's profile page
//  (zoom.us/profile, read-only in Greenroom's Zoom sign-in). Set up for me fills Zoom's required
//  Developer Contact with them (owner, 2026-11-27: "we should just fill in their own email").
//  Pure: Foundation only. The page is read by ZoomProfileReader.
//
import Foundation

enum ZoomProfile {
    struct Found: Equatable { var name: String?; var email: String? }

    /// Lines of the page's visible text. The email is the one after a "Sign-In Email" / "Email" label, else
    /// the first address that isn't Zoom's own; the name the line after "Display Name".
    static func parse(_ text: String) -> Found {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func isEmail(_ s: String) -> Bool {
            s.range(of: #"^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
                && !s.lowercased().hasSuffix("@zoom.us") && !s.lowercased().hasSuffix(".zoom.us")
        }
        func after(_ labels: [String], where ok: (String) -> Bool) -> String? {
            for (i, l) in lines.enumerated() where labels.contains(l.lowercased()) {
                if i + 1 < lines.count, ok(lines[i + 1]) { return lines[i + 1] }
            }
            return nil
        }
        let email = after(["sign-in email", "email", "email address"], where: isEmail) ?? lines.first(where: isEmail)
        let name = after(["display name", "name"], where: { !isEmail($0) && $0.count <= 80 && $0.lowercased() != "change" })
        return Found(name: name, email: email)
    }
}
