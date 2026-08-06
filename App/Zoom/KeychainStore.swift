//
//  KeychainStore.swift
//  Greenroom
//
//  Secret storage - DELIBERATELY plain UserDefaults, not the actual macOS
//  Keychain, despite the name (kept so call sites didn't churn).
//
//  This was real Keychain code originally, and it produced an endless
//  parade of access prompts: dev rebuilds changing the app identity,
//  CLI-restored items with foreign ownership, partition-list rules that
//  survive even "Always Allow". The user's verdict was explicit: the app
//  must NEVER ask for the keychain password - and these are app-level
//  Zoom credentials that already travel in plaintext via the settings
//  transfer file, so the Keychain's ceremony bought little here anyway.
//  Trade-off made consciously: convenience over at-rest encryption for
//  low-stakes personal-tool credentials.
//
import Foundation

enum KeychainStore {

    private static let defaults = UserDefaults.standard

    static func set(_ value: String, forKey key: String) {
        if value.isEmpty {
            defaults.removeObject(forKey: "secret_\(key)")
        } else {
            defaults.set(value, forKey: "secret_\(key)")
        }
    }

    static func get(_ key: String) -> String? {
        defaults.string(forKey: "secret_\(key)")
    }
}
