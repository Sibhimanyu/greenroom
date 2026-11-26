import Security
import XCTest

/// SecretVault: the secrets live in ONE Keychain item, are read once per launch,
/// and move out of UserDefaults once, deleting the old copy only after the
/// Keychain gives the value back. The Keychain is faked (`FakeKeychain`), so no
/// test touches the real one or can raise a prompt.
final class SecretStoreTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!
    private var keychain: FakeKeychain!

    override func setUp() {
        super.setUp()
        suite = "SecretStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        keychain = FakeKeychain()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func vault() -> SecretVault {
        SecretVault(keychain: keychain, defaults: defaults, log: { _ in })
    }

    private func legacy(_ key: String) -> String? { defaults.string(forKey: "secret_\(key)") }
    private func putLegacy(_ value: String, _ key: String) { defaults.set(value, forKey: "secret_\(key)") }

    // MARK: Round trip

    func testSetGetRemoveRoundTrip() {
        let v = vault()
        XCTAssertNil(v.get("zoomSDKClientSecret"))
        XCTAssertTrue(v.set("abc", forKey: "zoomSDKClientSecret"))
        XCTAssertEqual(v.get("zoomSDKClientSecret"), "abc")
        // A fresh launch reads it back out of the Keychain, not from memory.
        XCTAssertEqual(vault().get("zoomSDKClientSecret"), "abc")
        XCTAssertTrue(v.remove("zoomSDKClientSecret"))
        XCTAssertNil(v.get("zoomSDKClientSecret"))
        XCTAssertNil(vault().get("zoomSDKClientSecret"))
    }

    func testSettingEmptyRemoves() {
        let v = vault()
        v.set("abc", forKey: "youtubeClientSecret")
        v.set("", forKey: "youtubeClientSecret")
        XCTAssertNil(vault().get("youtubeClientSecret"))
    }

    func testNothingIsWrittenToUserDefaults() {
        let v = vault()
        v.set("abc", forKey: "zoomS2SClientSecret")
        XCTAssertNil(legacy("zoomS2SClientSecret"))
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "abc" })
    }

    // MARK: Few Keychain calls (no prompt storms)

    func testKeychainIsReadOncePerLaunch() {
        keychain.store(["zoomSDKClientSecret": "abc"])
        let v = vault()
        for _ in 0..<50 { _ = v.get("zoomSDKClientSecret"); _ = v.get("youtubeRefreshToken") }
        XCTAssertEqual(keychain.reads(of: SecretVault.service), 1)
    }

    func testUnchangedValueIsNotRewritten() {
        let v = vault()
        v.set("abc", forKey: "zoomSDKClientSecret")
        let writes = keychain.writes
        v.set("abc", forKey: "zoomSDKClientSecret")
        XCTAssertEqual(keychain.writes, writes)
    }

    func testUnreadableItemIsNeverOverwritten() {
        keychain.store(["zoomSDKClientSecret": "abc"])
        keychain.readStatus = errSecAuthFailed      // e.g. the person pressed Deny
        let v = vault()
        XCTAssertNil(v.get("zoomSDKClientSecret"))
        XCTAssertFalse(v.set("new", forKey: "youtubeClientSecret"))
        XCTAssertEqual(keychain.writes, 0, "a partial write would wipe the secrets it could not read")
        XCTAssertEqual(keychain.reads(of: SecretVault.service), 1, "a failed read is not retried in the same launch")
    }

    // MARK: Migration out of UserDefaults

    func testMigrationMovesValuesAndDeletesOldCopiesAfterVerifiedRead() {
        putLegacy("sdk", "zoomSDKClientSecret")
        putLegacy("s2s", "zoomS2SClientSecret")
        putLegacy("yt", "youtubeClientSecret")
        putLegacy("ytr", "youtubeRefreshToken")
        let v = vault()
        XCTAssertTrue(v.migrateIfNeeded())
        XCTAssertEqual(keychain.stored(), ["zoomSDKClientSecret": "sdk", "zoomS2SClientSecret": "s2s",
                                          "youtubeClientSecret": "yt", "youtubeRefreshToken": "ytr"])
        XCTAssertGreaterThanOrEqual(keychain.reads(of: SecretVault.service), 2, "verified by reading back")
        for key in ["zoomSDKClientSecret", "zoomS2SClientSecret", "youtubeClientSecret", "youtubeRefreshToken"] {
            XCTAssertNil(legacy(key), key)
        }
        XCTAssertTrue(defaults.bool(forKey: SecretVault.migratedFlagKey))
        XCTAssertEqual(vault().get("youtubeRefreshToken"), "ytr")
    }

    func testMigrationPicksUpUnlistedSecretKeys() {
        putLegacy("x", "someOtherSecret")
        XCTAssertTrue(vault().migrateIfNeeded())
        XCTAssertEqual(keychain.stored()["someOtherSecret"], "x")
        XCTAssertNil(legacy("someOtherSecret"))
    }

    func testFailedWriteKeepsOldCopy() {
        putLegacy("sdk", "zoomSDKClientSecret")
        keychain.writeStatus = errSecIO
        var logged: [String] = []
        let v = SecretVault(keychain: keychain, defaults: defaults, log: { logged.append($0) })
        XCTAssertFalse(v.migrateIfNeeded())
        XCTAssertEqual(legacy("zoomSDKClientSecret"), "sdk")
        XCTAssertFalse(defaults.bool(forKey: SecretVault.migratedFlagKey))
        XCTAssertFalse(logged.isEmpty, "the failure is logged")
        XCTAssertFalse(logged.joined().contains("sdk"), "the value itself is never logged")
        // The app keeps working from the old copy until a later launch moves it.
        XCTAssertEqual(v.get("zoomSDKClientSecret"), "sdk")
    }

    func testReadBackMismatchKeepsOldCopy() {
        putLegacy("sdk", "zoomSDKClientSecret")
        keychain.corruptWrites = true
        XCTAssertFalse(vault().migrateIfNeeded())
        XCTAssertEqual(legacy("zoomSDKClientSecret"), "sdk")
        XCTAssertFalse(defaults.bool(forKey: SecretVault.migratedFlagKey))
    }

    func testFailedMigrationIsRetriedNextLaunch() {
        putLegacy("sdk", "zoomSDKClientSecret")
        keychain.writeStatus = errSecIO
        XCTAssertFalse(vault().migrateIfNeeded())
        keychain.writeStatus = errSecSuccess
        XCTAssertTrue(vault().migrateIfNeeded())
        XCTAssertNil(legacy("zoomSDKClientSecret"))
        XCTAssertEqual(keychain.stored()["zoomSDKClientSecret"], "sdk")
    }

    func testMigrationRunsOnce() {
        putLegacy("sdk", "zoomSDKClientSecret")
        XCTAssertTrue(vault().migrateIfNeeded())
        let reads = keychain.totalReads, writes = keychain.writes
        putLegacy("late", "zoomS2SClientSecret")
        XCTAssertTrue(vault().migrateIfNeeded())
        XCTAssertEqual(keychain.totalReads, reads, "no Keychain call once the flag is set")
        XCTAssertEqual(keychain.writes, writes)
        XCTAssertNil(keychain.stored()["zoomS2SClientSecret"])
    }

    func testNothingToMoveStillSetsTheFlagWithoutWriting() {
        XCTAssertTrue(vault().migrateIfNeeded())
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertTrue(defaults.bool(forKey: SecretVault.migratedFlagKey))
    }

    // MARK: The old Zoom sign-in item folds into the one item

    func testLegacyZoomItemMovesAndIsDeleted() {
        keychain.items[FakeKeychain.ID(SecretVault.legacyZoomService, SecretVault.legacyZoomAccount)] = Data("zr".utf8)
        XCTAssertTrue(vault().migrateIfNeeded())
        XCTAssertEqual(keychain.stored()["zoomUserRefreshToken"], "zr")
        XCTAssertNil(keychain.items[FakeKeychain.ID(SecretVault.legacyZoomService, SecretVault.legacyZoomAccount)])
        XCTAssertEqual(vault().get("zoomUserRefreshToken"), "zr")
    }

    func testUnreadableLegacyZoomItemIsKeptAndRetried() {
        keychain.items[FakeKeychain.ID(SecretVault.legacyZoomService, SecretVault.legacyZoomAccount)] = Data("zr".utf8)
        keychain.failingReads = [SecretVault.legacyZoomService]
        XCTAssertFalse(vault().migrateIfNeeded())
        XCTAssertNotNil(keychain.items[FakeKeychain.ID(SecretVault.legacyZoomService, SecretVault.legacyZoomAccount)])
        XCTAssertFalse(defaults.bool(forKey: SecretVault.migratedFlagKey))
    }

    // MARK: The real queries

    func testQueriesNameOneGenericPasswordItem() {
        let q = SystemKeychain.query(service: SecretVault.service, account: SecretVault.account)
        XCTAssertEqual(q[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(q[kSecAttrService as String] as? String, "com.sibhimanyu.greenroom.secrets")
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, SecretVault.account)
        // Not the data-protection keychain: it needs the keychain-access-groups
        // entitlement, which macOS only honours with a provisioning profile.
        XCTAssertNil(q[kSecUseDataProtectionKeychain as String])
    }

    func testNewItemsStayOnThisMac() {
        let a = SystemKeychain.addAttributes(service: SecretVault.service, account: SecretVault.account, data: Data())
        XCTAssertEqual(a[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(a[kSecAttrSynchronizable as String] as? Bool, false)
    }
}

/// An in-memory Keychain with failure switches and call counts.
final class FakeKeychain: KeychainItems {
    struct ID: Hashable {
        let service: String, account: String
        init(_ service: String, _ account: String) { self.service = service; self.account = account }
    }
    var items: [ID: Data] = [:]
    var readStatus: OSStatus = errSecSuccess
    var writeStatus: OSStatus = errSecSuccess
    var failingReads: Set<String> = []
    var corruptWrites = false
    private(set) var readLog: [String] = []
    private(set) var writes = 0
    var totalReads: Int { readLog.count }

    func reads(of service: String) -> Int { readLog.filter { $0 == service }.count }

    func read(service: String, account: String) -> KeychainRead {
        readLog.append(service)
        if readStatus != errSecSuccess || failingReads.contains(service) { return .failed(errSecAuthFailed) }
        guard let data = items[ID(service, account)] else { return .missing }
        return .found(data)
    }

    func write(_ data: Data, service: String, account: String) -> OSStatus {
        writes += 1
        guard writeStatus == errSecSuccess else { return writeStatus }
        items[ID(service, account)] = corruptWrites ? Data("{}".utf8) : data
        return errSecSuccess
    }

    func delete(service: String, account: String) -> OSStatus {
        items[ID(service, account)] = nil
        return errSecSuccess
    }

    func store(_ secrets: [String: String]) {
        items[ID(SecretVault.service, SecretVault.account)] = try? JSONEncoder().encode(secrets)
    }

    func stored() -> [String: String] {
        guard let data = items[ID(SecretVault.service, SecretVault.account)] else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
