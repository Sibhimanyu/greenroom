//
//  SecretStore.swift
//  Greenroom
//
//  Local storage for the Zoom app credentials, in plain UserDefaults.
//  Greenroom does NOT use the macOS Keychain at all - no Keychain APIs,
//  no Keychain prompts. These are app-level Zoom Marketplace credentials
//  that already travel in plaintext via the settings-transfer file, and
//  the app deliberately never asks for a keychain password. The values
//  live under a "secret_" prefix so they are easy to spot; they are not
//  encrypted at rest. The risk is purely local (someone with access to
//  your Mac user account could read them); nothing is transmitted except
//  to Zoom itself.
//
import Foundation

enum SecretStore {

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
