//
//  ZoomMeetingSDKJWT.swift
//  Greenroom
//
//  Builds the JWT the Meeting SDK needs to authorize itself at init time.
//  Confirmed against Zoom's own docs (developers.zoom.us/docs/meeting-sdk/auth) -
//  native platforms (macOS included) sign HS256 over {appKey, iat, exp,
//  tokenExp}; `mn`/`role` only matter for the Web SDK's per-meeting join
//  flow, not native SDK init, so they're omitted here.
//
import Foundation
import CryptoKit

enum ZoomMeetingSDKJWT {

    /// `exp`/`tokenExp` must land at least 1800s and at most 48h after
    /// `iat`, per Zoom's spec - `validFor` is clamped into that range.
    static func makeToken(clientID: String, clientSecret: String, validFor: TimeInterval = 3600) -> String? {
        let iat = Int(Date().timeIntervalSince1970)
        let exp = iat + Int(min(max(validFor, 1800), 172_800))

        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "appKey": clientID,
            "iat": iat,
            "exp": exp,
            "tokenExp": exp
        ]

        guard let headerData = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }

        let signingInput = "\(base64URL(headerData)).\(base64URL(payloadData))"
        let key = SymmetricKey(data: Data(clientSecret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)

        return "\(signingInput).\(base64URL(Data(signature)))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
