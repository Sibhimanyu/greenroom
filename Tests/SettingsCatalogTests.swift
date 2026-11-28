import XCTest

/// R4 of docs/specs/settings-transfer.md: every persisted key is classified.
final class SettingsCatalogTests: XCTestCase {

    // MARK: Finding persisted keys in the sources

    /// The repo root, from this file's own path (Tests/ sits at the root).
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Keys written or read through UserDefaults, `@AppStorage` or the Keychain
    /// helper, found by scanning App/**/*.swift. A net, not a proof: a key built
    /// at run time (`"x\(id)"`) cannot be seen and is skipped.
    private func persistedKeysInSources() throws -> [String: String] {
        let appDir = root.appendingPathComponent("App")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil))
        let appStorage = try NSRegularExpression(pattern: #"@AppStorage\("([^"\\]+)""#)
        let constant = try NSRegularExpression(pattern: #"static\s+let\s+\w*[kK]ey\s*(?::\s*String)?\s*=\s*"([^"\\]+)""#)
        let readOrWrite = try NSRegularExpression(
            pattern: #"\.(?:string|bool|data|object|integer|double|float|array|dictionary|removeObject)\(forKey:\s*"([^"\\]+)"|\.set\([^\n]*forKey:\s*"([^"\\]+)""#)
        // SavedSettings declares its keys as `key: "..."` (docs/specs/saved-settings.md).
        let declared = try NSRegularExpression(pattern: #"\bkey:\s*"([^"\\]+)""#)
        var found: [String: String] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let name = url.lastPathComponent
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let s = String(line)
                if s.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(s.startIndex..., in: s)
                for regex in (name == "SavedSettings.swift" ? [appStorage, constant, readOrWrite, declared] : [appStorage, constant, readOrWrite]) {
                    for match in regex.matches(in: s, range: range) {
                        for group in 1..<match.numberOfRanges {
                            if let r = Range(match.range(at: group), in: s) { found[String(s[r])] = name }
                        }
                    }
                }
            }
        }
        // CoreAnimation and Core Image use the same "forKey:" spelling.
        for notDefaults in ["in", "out", "dissolve", "frostSolid", "inputCubeData", "inputCubeDimension"] {
            found[notDefaults] = nil
        }
        return found
    }

    private func isClassified(_ key: String) -> Bool {
        SettingsCatalog.entries.contains { $0.matches(key) }
    }

    // R4
    func testEveryPersistedKeyIsClassified() throws {
        let unclassified = try persistedKeysInSources().filter { !isClassified($0.key) }
        let list = unclassified.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }
        XCTAssertTrue(unclassified.isEmpty,
                      "Persisted keys that neither travel nor are excluded with a reason. "
                      + "Add each to SettingsCatalog.entries: \(list.joined(separator: ", "))")
    }

    // R4
    func testCatalogHasNoStaleKeys() throws {
        let present = try persistedKeysInSources()
        let stale = SettingsCatalog.entries.filter { !$0.isPrefix && present[$0.key] == nil }.map(\.key)
        XCTAssertTrue(stale.isEmpty, "Catalog keys no source uses any more: \(stale.sorted())")
    }

    // R4
    func testEveryTransferFieldIsInTheCatalog() {
        let fields = Set(Mirror(reflecting: SettingsTransfer()).children.compactMap(\.label))
        let missing = fields.subtracting(SettingsCatalog.transferKeys)
        XCTAssertTrue(missing.isEmpty, "SettingsTransfer fields no catalog entry names: \(missing.sorted())")
    }

    // R4
    func testEveryTravellingEntryHasATransferField() {
        let fields = Set(Mirror(reflecting: SettingsTransfer()).children.compactMap(\.label))
        let bad = SettingsCatalog.transferKeys.subtracting(fields)
        XCTAssertTrue(bad.isEmpty, "Catalog names transfer fields that do not exist: \(bad.sorted())")
    }

    // R4
    func testExcludedEntriesGiveAReason() {
        for entry in SettingsCatalog.entries {
            if case .excluded(let reason) = entry.disposition {
                XCTAssertFalse(reason.trimmingCharacters(in: .whitespaces).isEmpty, "\(entry.key) has no reason")
            }
        }
    }

    // R4: a key is listed once, and a transfer field is backed by one setting
    // (except the few that are a part of a larger stored value).
    func testKeysAreListedOnce() {
        let keys = SettingsCatalog.entries.map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "Duplicate catalog keys")
    }
}
