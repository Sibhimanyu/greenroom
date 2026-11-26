//
//  SecretStore.swift
//  Greenroom
//
//  Every secret Greenroom keeps (the pasted Zoom and Google client secrets,
//  the YouTube and Zoom sign-in refresh tokens) lives in the macOS Keychain
//  (owner, 2026-11-26). Nothing secret goes into UserDefaults.
//
//  The shape is chosen so the Keychain never nags (owner: at most one prompt,
//  ever; ideally none):
//  - ONE item holds them all: a generic password, service
//    com.sibhimanyu.greenroom.secrets, account "secrets", its data a JSON
//    [key: value]. A build signed differently from the one that wrote it would
//    be asked about one item, not five.
//  - It is read ONCE per launch into memory; a write happens only when a value
//    changes. A failed read is remembered for the launch, never retried in a
//    loop, and an item that could not be read is never overwritten (that would
//    wipe the secrets it holds).
//  - It is the login (file-based) keychain, not the data-protection keychain.
//    The data-protection keychain needs the keychain-access-groups entitlement,
//    and macOS kills an app carrying it without a provisioning profile
//    (checked 2026-11-26: SIGKILL at launch; without the entitlement
//    SecItemAdd returns -34018). Greenroom ships with the Apple Development
//    certificate and no profile. The login keychain lets the app that wrote an
//    item read it silently, and every Greenroom build (Debug, Release, Sparkle
//    updates) carries the same certificate, so the same designated requirement:
//    checked with rebuilt, re-signed binaries, no prompt.
//  - Accessible after first unlock, this device only, not synchronizable: the
//    items never sync or leave the Mac.
//
//  The one-time move out of the old places runs at first use in each launch
//  until it has succeeded once (the `secretsInKeychainMigrated` flag): every
//  "secret_<key>" UserDefaults value, and the Zoom refresh token's old item
//  (service com.sibhimanyu.greenroom.zoom). Old copies are deleted only after
//  the Keychain gives the values back; on any failure they stay, the failure is
//  logged (key names and status only, never a value), and the next launch
//  tries again. Until then `get` falls back to the old UserDefaults copy, so
//  nothing goes missing.
//
//  SecretStore is the app-wide facade; SecretVault is the logic, with the
//  Keychain behind `KeychainItems` so tests use a fake (SecretStoreTests).
//
import Foundation
import os
import Security

enum SecretStore {

    /// Created, and migrated, on first use: whichever comes first, launch
    /// (AppDelegate) or a property initialiser that reads a secret.
    static let shared: SecretVault = {
        let logger = Logger(subsystem: "com.sibhimanyu.greenroom", category: "secrets")
        let vault = SecretVault(keychain: SystemKeychain(), defaults: .standard,
                                log: { logger.notice("\($0, privacy: .public)") })
        vault.migrateIfNeeded()
        return vault
    }()

    static func set(_ value: String, forKey key: String) { shared.set(value, forKey: key) }
    static func get(_ key: String) -> String? { shared.get(key) }
    static func remove(_ key: String) { shared.remove(key) }

    /// Called once at launch so the move out of UserDefaults happens early.
    static func prepare() { _ = shared }
}

// MARK: - The logic

final class SecretVault {
    static let service = "com.sibhimanyu.greenroom.secrets"
    static let account = "secrets"
    static let migratedFlagKey = "secretsInKeychainMigrated"
    /// Where secrets lived before the Keychain: UserDefaults "secret_<key>".
    static let legacyPrefix = "secret_"
    /// Every key known to have been stored under `legacyPrefix`; any other
    /// key with the prefix is moved too.
    static let knownKeys = ["zoomSDKClientSecret", "zoomS2SClientSecret", "youtubeClientSecret",
                            "youtubeRefreshToken", "zoomUserRefreshToken"]
    /// The Zoom sign-in's refresh token had its own Keychain item before.
    static let legacyZoomService = "com.sibhimanyu.greenroom.zoom"
    static let legacyZoomAccount = "zoomUserRefreshToken"

    private let keychain: KeychainItems
    private let defaults: UserDefaults
    private let log: (String) -> Void
    private let lock = NSLock()
    /// The item's contents, read once. nil until the first read.
    private var cache: [String: String]?
    /// The item exists but could not be read this launch: never write over it.
    private var unreadable = false

    init(keychain: KeychainItems, defaults: UserDefaults, log: @escaping (String) -> Void) {
        self.keychain = keychain
        self.defaults = defaults
        self.log = log
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let value = loaded()[key], !value.isEmpty { return value }
        // Not moved yet (a failed migration): the old copy is still the value.
        if let old = defaults.string(forKey: Self.legacyPrefix + key), !old.isEmpty { return old }
        return nil
    }

    /// Stores `value`; an empty value removes the key. False when the Keychain
    /// refused (logged); the previous value is then still what `get` returns.
    @discardableResult
    func set(_ value: String, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var next = loaded()
        if value.isEmpty { next[key] = nil } else { next[key] = value }
        return commit(next, touching: key)
    }

    @discardableResult
    func remove(_ key: String) -> Bool { set("", forKey: key) }

    /// The one-time move into the Keychain. True once it has succeeded (now or
    /// on an earlier launch); false leaves every old copy in place.
    @discardableResult
    func migrateIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if defaults.bool(forKey: Self.migratedFlagKey) { return true }

        let current = loaded()
        guard !unreadable else {
            log("Secrets: the Keychain item could not be read; moving secrets out of UserDefaults waits for a later launch.")
            return false
        }
        var next = current
        var ok = true

        // The Zoom refresh token's old item. Read once, here; the flag below
        // stops this read on later launches. It wins over an older
        // UserDefaults copy of the same token (as the previous build had it).
        var zoomItemFound = false, zoomTokenTaken = false
        switch keychain.read(service: Self.legacyZoomService, account: Self.legacyZoomAccount) {
        case .found(let data):
            zoomItemFound = true
            if let token = String(data: data, encoding: .utf8), !token.isEmpty,
               (next[Self.legacyZoomAccount] ?? "").isEmpty {
                next[Self.legacyZoomAccount] = token
                zoomTokenTaken = true
            }
        case .missing:
            break
        case .failed(let status):
            ok = false
            log("Secrets: could not read the old Zoom sign-in Keychain item (status \(status)); it is kept and tried again next launch.")
        }

        // UserDefaults "secret_<key>" values. The old copy is what the app
        // used until now, so it wins over anything already in the item.
        let prefixed = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.legacyPrefix) }
            .map { String($0.dropFirst(Self.legacyPrefix.count)) }
        let keys = Array(Set(Self.knownKeys).union(prefixed)).sorted()
        var moved: [String] = []      // copied into the item, old copy deleted after the check
        var dropped: [String] = []    // empty, or superseded by the Zoom item: just deleted
        for key in keys {
            guard let old = defaults.string(forKey: Self.legacyPrefix + key) else { continue }
            if old.isEmpty || (key == Self.legacyZoomAccount && zoomTokenTaken) { dropped.append(key); continue }
            next[key] = old
            moved.append(key)
        }
        let report = moved + (zoomTokenTaken ? ["Zoom sign-in item"] : [])

        if next != current {
            let status = write(next)
            guard status == errSecSuccess else {
                log("Secrets: Keychain write failed (status \(status)); not moved, old copies kept: \(report.joined(separator: ", ")).")
                return false
            }
            // Verify: read the item back and compare, before deleting anything.
            guard case .found(let data) = keychain.read(service: Self.service, account: Self.account),
                  let back = try? JSONDecoder().decode([String: String].self, from: data), back == next else {
                log("Secrets: the Keychain did not give back what was written; not moved, old copies kept: \(report.joined(separator: ", ")).")
                return false
            }
            cache = next
        }

        for key in moved + dropped { defaults.removeObject(forKey: Self.legacyPrefix + key) }
        if zoomItemFound {
            let status = keychain.delete(service: Self.legacyZoomService, account: Self.legacyZoomAccount)
            if status != errSecSuccess && status != errSecItemNotFound {
                ok = false
                log("Secrets: could not delete the old Zoom sign-in Keychain item (status \(status)); tried again next launch.")
            }
        }
        if !report.isEmpty { log("Secrets: moved into the Keychain: \(report.joined(separator: ", ")).") }
        if ok { defaults.set(true, forKey: Self.migratedFlagKey) }
        return ok
    }

    // MARK: Plumbing (call with the lock held)

    /// The item's contents, read from the Keychain at most once.
    private func loaded() -> [String: String] {
        if let cache { return cache }
        var contents: [String: String] = [:]
        switch keychain.read(service: Self.service, account: Self.account) {
        case .found(let data):
            if let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                contents = decoded
            } else {
                unreadable = true
                log("Secrets: the Keychain item is not in the expected shape; it is left as it is.")
            }
        case .missing:
            break
        case .failed(let status):
            unreadable = true
            log("Secrets: could not read the Keychain item (status \(status)); not retried this launch.")
        }
        cache = contents
        return contents
    }

    private func commit(_ next: [String: String], touching key: String) -> Bool {
        guard !unreadable else {
            log("Secrets: not saving \(key): the Keychain item could not be read this launch, and writing would replace it.")
            return false
        }
        if next != cache {
            let status = write(next)
            guard status == errSecSuccess else {
                log("Secrets: could not save \(key) in the Keychain (status \(status)).")
                return false
            }
            cache = next
        }
        // A fresh value supersedes an old copy a failed migration left behind.
        defaults.removeObject(forKey: Self.legacyPrefix + key)
        return true
    }

    private func write(_ contents: [String: String]) -> OSStatus {
        if contents.isEmpty {
            let status = keychain.delete(service: Self.service, account: Self.account)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        guard let data = try? JSONEncoder().encode(contents) else { return errSecParam }
        return keychain.write(data, service: Self.service, account: Self.account)
    }
}

// MARK: - The Keychain

enum KeychainRead: Equatable {
    case found(Data)
    case missing
    case failed(OSStatus)
}

/// One generic-password item per (service, account).
protocol KeychainItems: AnyObject {
    func read(service: String, account: String) -> KeychainRead
    /// Creates the item, or replaces its data.
    func write(_ data: Data, service: String, account: String) -> OSStatus
    func delete(service: String, account: String) -> OSStatus
}

final class SystemKeychain: KeychainItems {

    /// The one query every call starts from. No kSecUseDataProtectionKeychain:
    /// see the file header.
    static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func addAttributes(service: String, account: String, data: Data) -> [String: Any] {
        var q = query(service: service, account: account)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        q[kSecAttrLabel as String] = "Greenroom"
        return q
    }

    func read(service: String, account: String) -> KeychainRead {
        var q = Self.query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data else { return .failed(errSecDecode) }
            return .found(data)
        case errSecItemNotFound:
            return .missing
        default:
            return .failed(status)
        }
    }

    func write(_ data: Data, service: String, account: String) -> OSStatus {
        // Update in place, so a failure never leaves the item deleted.
        let status = SecItemUpdate(Self.query(service: service, account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(Self.addAttributes(service: service, account: account, data: data) as CFDictionary, nil)
    }

    func delete(service: String, account: String) -> OSStatus {
        SecItemDelete(Self.query(service: service, account: account) as CFDictionary)
    }
}
