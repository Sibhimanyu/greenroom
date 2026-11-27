//
//  ZoomMarketplacePages.swift
//  Greenroom
//
//  What Zoom Marketplace page the Zoom window is on, and the addresses of the
//  pages the setup guide links to (docs/specs/zoom-setup-assist.md, R2, R4,
//  R5). The shapes come from the DEBUG probe of 2026-11-27 (owner's account).
//  Only https://marketplace.zoom.us counts; look-alike hosts are nil. Pure:
//  Foundation only.
//
import Foundation

enum ZoomS2STab: Equatable, Hashable { case information, credentials, feature, scopes, activation }
enum ZoomGeneralTab: Equatable, Hashable { case information, embed, scopes, other }

enum ZoomMarketplacePage: Equatable, Hashable {
    case createdApps
    case chooseType(String)
    case s2s(String, ZoomS2STab)
    case general(String, ZoomGeneralTab)
    case signIn

    /// Which of your two apps the page belongs to; nil for pages that are neither (yet).
    var app: ZoomOwnApp? {
        switch self {
        case .s2s: return .s2s
        case .general: return .sdk
        default: return nil
        }
    }

    var appID: String? {
        switch self {
        case .chooseType(let id), .s2s(let id, _), .general(let id, _): return id
        default: return nil
        }
    }
}

/// The fields a credentials page shows, in the order Zoom lays them out.
enum ZoomKeyField: Equatable, Hashable { case accountID, clientID, clientSecret }

enum ZoomMarketplacePages {
    static let host = "marketplace.zoom.us"
    static let idPattern = "^[A-Za-z0-9_-]{10,40}$"
    static let keyPattern = "^[A-Za-z0-9_-]{10,64}$"

    /// The real Marketplace host over https (any path): the only place the page scripts run.
    static func isMarketplace(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.port == nil && url.host?.lowercased() == host
    }

    static func isAppID(_ s: String) -> Bool { s.range(of: idPattern, options: .regularExpression) != nil }
    static func isKey(_ s: String) -> Bool { s.range(of: keyPattern, options: .regularExpression) != nil }

    /// Sign-in hosts: Zoom's own sign-in path, and the identity providers it hands off to.
    private static let identityHosts: Set<String> = ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com"]

    static func page(for url: URL) -> ZoomMarketplacePage? {
        guard url.scheme == "https", url.user == nil, url.port == nil,
              let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if identityHosts.contains(host) { return .signIn }
        if host == "zoom.us" || host == "www.zoom.us" || host == "accounts.zoom.us" {
            return parts.first == "signin" ? .signIn : nil
        }
        guard host == Self.host else { return nil }
        if parts == ["user", "build"] { return .createdApps }
        guard parts.count >= 3, parts[0] == "develop", isAppID(parts[2]) else { return nil }
        let id = parts[2]
        let rest = Array(parts.dropFirst(3))
        if parts[1] == "apps" {
            guard rest.count == 1 else { return nil }
            switch rest[0] {
            case "information": return .s2s(id, .information)
            case "credentials": return .s2s(id, .credentials)
            case "feature": return .s2s(id, .feature)
            case "scope", "scopes": return .s2s(id, .scopes)
            case "activation": return .s2s(id, .activation)
            default: return nil
            }
        }
        if parts[1] == "applications" {
            if rest == ["information"] { return .general(id, .information) }
            if rest == ["features", "sdk"] { return .general(id, .embed) }
            if rest == ["scopes"] { return .general(id, .scopes) }
            return rest.isEmpty ? .chooseType(id) : .general(id, .other)
        }
        return nil
    }

    /// The address a guide button opens; nil for pages with no single address.
    static func url(for page: ZoomMarketplacePage) -> URL? {
        let path: String
        switch page {
        case .createdApps: path = "/user/build"
        case .chooseType(let id): path = "/develop/applications/\(id)"
        case .s2s(let id, let tab):
            let leaf: String
            switch tab {
            case .information: leaf = "information"
            case .credentials: leaf = "credentials"
            case .feature: leaf = "feature"
            case .scopes: leaf = "scope"
            case .activation: leaf = "activation"
            }
            path = "/develop/apps/\(id)/\(leaf)"
        case .general(let id, let tab):
            switch tab {
            case .information: path = "/develop/applications/\(id)/information"
            case .embed: path = "/develop/applications/\(id)/features/sdk"
            case .scopes: path = "/develop/applications/\(id)/scopes"
            case .other: return nil
            }
        case .signIn: return nil
        }
        return URL(string: "https://\(host)\(path)")
    }

    /// The key fields to read on this page; nil on every other page (the reader never runs there).
    static func keyFields(on page: ZoomMarketplacePage) -> [ZoomKeyField]? {
        switch page {
        case .s2s(_, .credentials): return [.accountID, .clientID, .clientSecret]
        case .general(_, .information): return [.clientID, .clientSecret]
        default: return nil
        }
    }
}

/// The app IDs the window has seen, one per kind (R4). Not secrets: kept in UserDefaults.
struct ZoomAppIDs: Equatable {
    private(set) var meeting: String?
    private(set) var hosting: String?

    init(meeting: String? = nil, hosting: String? = nil) {
        self.meeting = meeting.flatMap { ZoomMarketplacePages.isAppID($0) ? $0 : nil }
        self.hosting = hosting.flatMap { ZoomMarketplacePages.isAppID($0) ? $0 : nil }
    }

    mutating func see(_ page: ZoomMarketplacePage) {
        guard let app = page.app, let id = page.appID else { return }
        switch app {
        case .sdk: meeting = id
        case .s2s: hosting = id
        }
    }

    mutating func forget(_ app: ZoomOwnApp) {
        switch app {
        case .sdk: meeting = nil
        case .s2s: hosting = nil
        }
    }

    func id(for app: ZoomOwnApp) -> String? { app == .sdk ? meeting : hosting }
}
