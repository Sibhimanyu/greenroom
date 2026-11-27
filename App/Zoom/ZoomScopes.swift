//
//  ZoomScopes.swift
//  Greenroom
//
//  The one list of Server-to-Server scopes Greenroom needs. Settings → Zoom
//  shows the names, onboarding's "Check Zoom setup" checks each against the
//  token's granted scopes, and the edit errors name the one that is missing.
//
import Foundation

enum ZoomScopes {
    enum Key: String, CaseIterable {
        case create, list, details, update, delete, host, end, personalRoom
    }

    struct Scope: Identifiable {
        let key: Key
        let name: String
        let purpose: String
        /// The older scope name Zoom's classic apps grant instead.
        let legacy: String
        var id: String { name }

        /// The line's title in Check Zoom setup.
        var checkTitle: String {
            switch key {
            case .create: "Permission to create meetings"
            case .list: "Permission to list meetings"
            case .details: "Permission to read meeting details"
            case .update: "Permission to edit scheduled meetings"
            case .delete: "Permission to delete scheduled meetings"
            case .host: "Permission to get the hosting token"
            case .end: "Permission to end meetings"
            case .personalRoom: "Permission to read your personal room"
            }
        }
    }

    static let all: [Scope] = [
        Scope(key: .create, name: "meeting:write:meeting:admin", purpose: "Create meetings", legacy: "meeting:write:admin"),
        Scope(key: .list, name: "meeting:read:list_meetings:admin", purpose: "List scheduled meetings", legacy: "meeting:read:admin"),
        Scope(key: .details, name: "meeting:read:meeting:admin", purpose: "Read meeting details", legacy: "meeting:read:admin"),
        Scope(key: .update, name: "meeting:update:meeting:admin", purpose: "Edit scheduled meetings", legacy: "meeting:write:admin"),
        Scope(key: .delete, name: "meeting:delete:meeting:admin", purpose: "Delete scheduled meetings", legacy: "meeting:write:admin"),
        Scope(key: .host, name: "user:read:token:admin", purpose: "Get your hosting token", legacy: "user:read:admin"),
        Scope(key: .end, name: "meeting:update:status:admin", purpose: "End meetings for everyone", legacy: "meeting:write:admin"),
        // GET /users/me: the personal room (PMI) pinned on Home's My Meetings list.
        // Zoom's granular-scope table, "Get a user": user:read:user / user:read:user:admin.
        Scope(key: .personalRoom, name: "user:read:user:admin", purpose: "Read your personal room", legacy: "user:read:admin"),
    ]

    static var names: [String] { all.map(\.name) }
    static var count: Int { all.count }

    static func scope(_ key: Key) -> Scope { all.first { $0.key == key }! }

    /// Granted if Zoom lists the scope's name or its legacy name.
    static func isGranted(_ scope: Scope, in granted: Set<String>) -> Bool {
        granted.contains(scope.name) || granted.contains(scope.legacy)
    }

    /// The scopes missing from a granted set, in list order.
    static func missing(in granted: Set<String>) -> [Scope] {
        all.filter { !isGranted($0, in: granted) }
    }

    static let countWord: String = {
        ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"][all.count]
    }()
}
