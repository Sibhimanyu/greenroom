import XCTest
@testable import GreenroomTests

/// The snapshot model (docs/specs/zoom-setup-flow.md): JSON from the reader decodes, round-trips, redacts, and the reader script only reads.
final class ZoomPageSnapshotTests: XCTestCase {
    private let secret = "SecretCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
    private let id = "AbC_123-xyZ789qrstuvw1"

    private func decode(_ json: String, address: ZoomMarketplacePage? = nil) -> ZoomPageSnapshot? {
        ZoomPageSnapshot.decode(reading: json, address: address)
    }

    // MARK: Decoding what the reader returns

    func testACreatedAppsReadingDecodes() throws {
        let s = try XCTUnwrap(decode("""
        {"signedIn":true,"dialog":{"kind":"none"},"menuItems":["Build app"],"appList":["hosting","meeting","other"],
         "scopesOnPage":[],"infoEmptyRequired":[],"keys":{},"controls":["plus","buildApp","appRow.0","appRow.1","appRow.2","navLink.embed","bogus.id"]}
        """, address: .createdApps))
        XCTAssertEqual(s.address, .createdApps)
        XCTAssertEqual(s.signedIn, true)
        XCTAssertEqual(s.dialog, .none)
        XCTAssertEqual(s.menuItems, ["Build app"])
        XCTAssertEqual(s.appList, [.hosting, .meeting, .other])
        XCTAssertEqual(s.controls, [.plus, .buildApp, .appRow(0), .appRow(1), .appRow(2), .navLink(.embed)], "an unknown ID is skipped, not fatal")
        XCTAssertNil(s.meetingSDKOn); XCTAssertNil(s.activated)
    }

    func testEveryDialogKindDecodes() throws {
        let type = try XCTUnwrap(decode(#"{"dialog":{"kind":"appType","choices":{"general":true,"serverToServer":false,"webhookOnly":false}}}"#))
        XCTAssertEqual(type.dialog, .appType([.general: true, .serverToServer: false, .webhookOnly: false]))
        let name = try XCTUnwrap(decode(#"{"dialog":{"kind":"name","app":"hosting","filled":true,"createEnabled":false}}"#))
        XCTAssertEqual(name.dialog, .name(app: .hosting, filled: true, createEnabled: false))
        let scopes = try XCTUnwrap(decode(#"{"dialog":{"kind":"addScopes","searchPresent":true,"ticked":["meeting:write:meeting:admin"]}}"#))
        XCTAssertEqual(scopes.dialog, .addScopes(searchPresent: true, ticked: ["meeting:write:meeting:admin"]))
        let other = try XCTUnwrap(decode(#"{"dialog":{"kind":"other","heading":"something else"}}"#))
        XCTAssertEqual(other.dialog, .other(heading: "something else"))
    }

    func testKeysDecodeAsValueCopyableHiddenAbsent() throws {
        let s = try XCTUnwrap(decode("""
        {"keys":{"accountID":{"kind":"value","value":"\(id)"},"clientID":{"kind":"copyable"},"clientSecret":{"kind":"hidden"}}}
        """, address: .s2s(id, .credentials)))
        XCTAssertEqual(s.keys[.accountID], .value(id))
        XCTAssertEqual(s.keys[.clientID], .copyable)
        XCTAssertEqual(s.keys[.clientSecret], .hidden)
        let g = try XCTUnwrap(decode(#"{"keys":{"accountID":{"kind":"absent"}}}"#))
        XCTAssertEqual(g.keys[.accountID], KeyReading.absent)
    }

    func testTheNewPageFactsDecode() throws {
        let s = try XCTUnwrap(decode("""
        {"scopeSearchMatches":1,"activated":false,"activationMissing":["Developer contact name","Company name"],
         "infoFields":{"appName":"filled","contactEmail":"error","companyName":"empty"},
         "controls":["pageScopeSearch","pageScopeAddLink","infoField.contactEmail"]}
        """))
        XCTAssertEqual(s.scopeSearchMatches, 1)
        XCTAssertEqual(s.activationMissing, ["Developer contact name", "Company name"])
        XCTAssertEqual(s.infoFields, [.appName: .filled, .contactEmail: .error, .companyName: .empty])
        XCTAssertTrue(s.has(.pageScopeSearch) && s.has(.pageScopeAddLink) && s.has(.infoField(.contactEmail)))
        XCTAssertNotEqual(ZoomControl.pageScopeSearch, .scopeSearch, "the page's search and the dialog's are different controls")
    }

    func testAScriptErrorOrGarbageIsNotASnapshot() {
        XCTAssertNil(decode("error: boom"))
        XCTAssertNil(decode(""))
    }

    // MARK: Round trips

    func testControlIDsRoundTrip() {
        var all: [ZoomControl] = [.plus, .buildApp, .create, .cancel, .nameField, .addScopes, .scopeSearch, .scopesDone, .activate,
                                  .continue, .signIn, .tryAnotherWay, .closeDialog, .pageScopeSearch, .pageScopeAddLink,
                                  .scopeCheckbox("meeting:write:meeting:admin"), .appRow(3)]
        all += [ZoomAppKind.meeting, .hosting].map { .typeRadio($0) }
        all += [ZoomKeyField.accountID, .clientID, .clientSecret].map { .copy($0) }
        all += ZoomNavLink.allCases.map { .navLink($0) }
        all += ZoomInfoField.allCases.map { .infoField($0) }
        for c in all { XCTAssertEqual(ZoomControl(id: c.id), c, c.id) }
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "IDs are unique")
        XCTAssertNil(ZoomControl(id: "appRow.-1"))
        XCTAssertNil(ZoomControl(id: "copy.nope"))
    }

    func testASnapshotRoundTripsThroughJSON() throws {
        let s = ZoomPageSnapshot(address: .s2s(id, .credentials), signedIn: true, dialog: .name(app: .meeting, filled: false, createEnabled: true),
                                 menuItems: ["Build app"], appList: [.meeting], meetingSDKOn: true, scopesOnPage: ["user:read:user:admin"],
                                 activated: false, infoEmptyRequired: ["App name"], infoFields: [.appName: .empty],
                                 scopeSearchMatches: 2, activationMissing: ["Company name"],
                                 keys: [.clientID: .value(id), .clientSecret: .redacted(length: 36, fingerprint: "ab12")],
                                 controls: [.plus, .copy(.clientSecret), .scopeCheckbox("a:b:c")])
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ZoomPageSnapshot.self, from: data), s)
        for page: ZoomMarketplacePage in [.createdApps, .chooseType(id), .s2s(id, .scopes), .general(id, .embed), .general(id, .other), .signIn, .passkey] {
            let one = ZoomPageSnapshot(address: page)
            XCTAssertEqual(try JSONDecoder().decode(ZoomPageSnapshot.self, from: JSONEncoder().encode(one)).address, page)
        }
    }

    // MARK: Redaction

    func testRedactedReplacesEveryValueByLengthAndAFingerprint() throws {
        let s = ZoomPageSnapshot(keys: [.accountID: .value(id), .clientSecret: .value(secret), .clientID: .copyable])
        let r = s.redacted()
        XCTAssertEqual(r.keys[.clientSecret], .redacted(length: secret.count, fingerprint: KeyReading.fingerprint(secret)))
        XCTAssertEqual(r.keys[.clientID], .copyable)
        let text = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        XCTAssertFalse(text.contains(secret)); XCTAssertFalse(text.contains(id))
        XCTAssertNil(r.keys[.clientSecret]?.text)
        XCTAssertEqual(s.keys[.clientSecret]?.text, secret, "the original still holds it, in memory")
    }

    func testTheFingerprintShowsAChangedKeyWithoutRevealingIt() {
        let a = KeyReading.fingerprint(secret), b = KeyReading.fingerprint(secret + "x")
        XCTAssertEqual(a.count, 4)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(a, KeyReading.fingerprint(secret), "stable")
        XCTAssertNotEqual(a, b)
        let one = ZoomPageSnapshot(keys: [.clientSecret: .value(secret)]).redacted()
        let two = ZoomPageSnapshot(keys: [.clientSecret: .value(secret + "x")]).redacted()
        XCTAssertNotEqual(one, two, "a recording differs when Zoom changed the key")
        XCTAssertEqual(one, ZoomPageSnapshot(keys: [.clientSecret: .value(secret)]).redacted())
    }

    func testRecordingLinesNeverCarryAValueAndScrubClicks() throws {
        let line = ZoomRecordingLine.snapshot(ZoomPageSnapshot(address: .createdApps, keys: [.clientSecret: .value(secret)]), at: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(line.contains(secret))
        XCTAssertTrue(line.contains("\"ts\":\"1970-01-01T00:00:00Z\""))
        XCTAssertFalse(line.contains("\n"), "one JSON line")
        _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
        let click = ZoomRecordingLine.click(control: nil, role: "button", text: "Copy \(secret)", at: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(click.contains(secret))
        XCTAssertTrue(click.contains("[token 35]"))
        XCTAssertTrue(click.contains("\"event\":\"click\""))
        let resolved = ZoomRecordingLine.click(control: "buildApp", role: "menuitem", text: "Build app", at: Date())
        XCTAssertTrue(resolved.contains("\"control\":\"buildApp\"") && !resolved.contains("Build app"), "a resolved control is the whole report")
    }

    // MARK: The script only reads

    func testTheReaderNeverActsOnThePageOrTalksOut() {
        let js = ZoomPageScript.source
        for banned in [".click(", ".focus(", ".blur(", "dispatchEvent", "new Event", "MouseEvent", ".submit(", "requestSubmit", "fetch(",
                       "XMLHttpRequest", "console.", "postMessage", "localStorage", "sessionStorage", "document.cookie", "eval(",
                       "setAttribute", ".value =", ".value=", "scrollIntoView", "location.href", "window.open", "innerHTML ="] {
            XCTAssertFalse(js.contains(banned), banned)
        }
    }

    func testTheReaderResolvesEveryControlIDAndOnlyReadsKeysOnCredentialsPages() {
        let js = ZoomPageScript.source
        for id in ZoomControl.fixedIDs { XCTAssertTrue(js.contains("'\(id)'"), id) }
        for kind in ["typeRadio", "copy", "navLink", "appRow", "scopeCheckbox", "infoField"] { XCTAssertTrue(js.contains("'\(kind)'"), kind) }
        for scope in ZoomScopes.names { XCTAssertTrue(js.contains(scope), scope) }
        for link in ZoomNavLink.allCases { XCTAssertTrue(js.contains(link.label), link.label) }
        XCTAssertTrue(js.contains("if (keysPath()) for (var f in KEYLABEL)"), "key values are read on the credentials pages only")
        XCTAssertTrue(js.contains("hostname === 'marketplace.zoom.us'"), "off Marketplace only the Try another way button is looked for")
    }

    func testTheLibraryIsEmbeddedWholeInTheReader() {
        XCTAssertTrue(ZoomPageScript.source.contains(ZoomPageScript.library))
        XCTAssertTrue(ZoomPageScript.library.contains("function resolve(id)"))
        XCTAssertTrue(ZoomPageScript.library.contains("function allControlIds("))
    }
}
