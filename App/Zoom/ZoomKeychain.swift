//
//  ZoomKeychain.swift
//  Greenroom
//
//  The Zoom sign-in's refresh token lives in a real Keychain item (generic
//  password, service com.sibhimanyu.greenroom.zoom), readable after the first
//  unlock and never leaving this device. This is the one Keychain use in the
//  app: it holds a long-lived grant to a person's Zoom account, which is not
//  something to leave in a plain preferences file.
//
import Foundation
import Security

enum ZoomKeychain {
    static let service = "com.sibhimanyu.greenroom.zoom"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        delete(account)
        guard !value.isEmpty else { return true }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
