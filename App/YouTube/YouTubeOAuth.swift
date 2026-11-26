//
//  YouTubeOAuth.swift
//  Greenroom
//
//  The Google OAuth pieces that are plain values: Greenroom's one shared
//  Desktop client, the consent URL, and the PKCE challenge. The network side
//  (loopback listener, token exchange) is YouTubeAuth.swift.
//
//  Owner decision, 2026-11-26: no Google verification. Greenroom ships ONE
//  shared "Desktop app" OAuth client; everyone signs in with any Google
//  account through the normal browser flow. The Cloud project is published
//  "In production" unverified, so Google shows "Google hasn't verified this
//  app" and caps the project at 100 new users for its lifetime. Past that,
//  people use "Use your own Google app" (YouTubeRouteRules).
//
//  Desktop clients are public clients (Google's docs): the secret is not
//  confidential and PKCE S256 plus a loopback redirect is what protects the
//  code. Shipping it in the binary is the documented shape, not a leak.
//
//  Pure: Foundation and CryptoKit only.
//
import CryptoKit
import Foundation

struct YouTubeOAuthClient: Equatable {
    let id: String
    let secret: String
}

enum YouTubeOAuth {

    /// THE shared client: the Desktop OAuth client of the owner's "Greenroom Youtube"
    /// Cloud project (published In production, unverified; owner, 2026-11-26). Nowhere
    /// else reads it. A desktop secret is not confidential (Google: desktop apps are
    /// public clients). An id starting with "PLACEHOLDER" would make Sign in with Google
    /// "not available yet" (`YouTubeRouteRules.sharedAvailable`).
    static let sharedClient = YouTubeOAuthClient(
        id: "586090482136-7v050te76etsgj9dk2nugtskciv3f5v3.apps.googleusercontent.com",
        secret: "")

    /// Upload and edit the account's own videos. `youtube.upload` alone
    /// cannot change a title afterwards, and there is no Google scope between
    /// "add only" and "manage videos", so this is the narrowest that lets a
    /// session be renamed on YouTube after the fact. Also read by channels.list
    /// for the "signed in as" line.
    static let scope = "https://www.googleapis.com/auth/youtube.force-ssl"

    static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    static let revokeEndpoint = "https://oauth2.googleapis.com/revoke"

    /// Loopback on the IP literal, as Google documents for desktop apps
    /// ("localhost" can resolve to ::1 while the listener is on 127.0.0.1).
    static func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    /// The consent page. `prompt=select_account consent`: Google always shows
    /// the account chooser (so "Use another account" really can pick another)
    /// and always asks for consent, which is what makes it return a refresh
    /// token on every sign-in, re-sign-ins included. `access_type=offline` is
    /// the other half of getting that refresh token.
    static func authURL(clientID: String, redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(string: authEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        return components.url!
    }

    /// PKCE S256: base64url(SHA-256(verifier)), no padding (RFC 7636 §4.2).
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
