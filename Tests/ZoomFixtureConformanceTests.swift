import XCTest
@testable import GreenroomTests

/// Keeps `FixturePage` honest: for each page the 2026-11-27 live run recorded (Tests/Fixtures/zoom/live-2026-11-27.jsonl,
/// copied from the DEBUG recorder, key values already redacted), the scripted Zoom shows exactly the controls the real
/// page showed, and the recording decodes with the reader's own model. A fixture that drifts from the real page fails here.
@MainActor
final class ZoomFixtureConformanceTests: XCTestCase {
    private func recording(_ name: String) throws -> ZoomPageSnapshot {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/zoom/live-2026-11-27.jsonl")
        let text = try String(contentsOf: dir, encoding: .utf8)
        for line in text.split(separator: "\n") {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], obj["name"] as? String == name,
                  let snap = obj["snapshot"], let data = try? JSONSerialization.data(withJSONObject: snap) else { continue }
            return try JSONDecoder().decode(ZoomPageSnapshot.self, from: data)
        }
        throw XCTSkip("no recording named \(name)")
    }

    private func app(_ kind: ZoomApp) -> FixturePage.App {
        FixturePage.App(kind: kind, id: "appIdIdIdIdIdIdIdId1", clientID: "clientClientClient1", secret: "secretSecretSecret12", accountID: "accountAccountAcc1")
    }

    func testCreatedAppsOnAFreshAccount() async throws {
        let zoom = FixturePage.freshAccount()
        let live = try recording("created-apps-fresh")
        let now = await zoom.read()
        XCTAssertEqual(now?.controls, live.controls)
        XCTAssertEqual(now?.dialog, live.dialog)
    }

    func testTheTypeDialog() async throws {
        let zoom = FixturePage.freshAccount()
        _ = await zoom.perform(.press(.plus)); _ = await zoom.perform(.press(.buildApp))
        let live = try recording("type-dialog")
        let now = await zoom.read()
        XCTAssertEqual(now?.controls, live.controls)
        if case .appType = live.dialog, case .appType? = now?.dialog {} else { XCTFail("the type dialog") }
    }

    func testTheGeneralAppsPages() async throws {
        let zoom = FixturePage.freshAccount()
        zoom.apps = [app(.meeting)]
        zoom.address = .general(zoom.apps[0].id, .information)
        let info = try recording("general-information")
        let nowInfo = await zoom.read()
        XCTAssertEqual(nowInfo?.controls, info.controls)
        XCTAssertEqual(nowInfo?.keys[.clientSecret], info.keys[.clientSecret], "the secret is copyable, not readable")
        zoom.address = .general(zoom.apps[0].id, .embed)
        let embed = try recording("general-embed")
        let nowEmbed = await zoom.read()
        XCTAssertEqual(nowEmbed?.controls, embed.controls)
        XCTAssertEqual(nowEmbed?.meetingSDKOn, embed.meetingSDKOn, "the switch starts off")
    }

    func testTheServerToServerPages() async throws {
        let zoom = FixturePage.freshAccount()
        zoom.apps = [app(.hosting)]
        zoom.address = .s2s(zoom.apps[0].id, .credentials)
        let credentials = try recording("s2s-credentials")
        let nowCredentials = await zoom.read()
        XCTAssertEqual(nowCredentials?.controls, credentials.controls)
        XCTAssertEqual(nowCredentials?.keys[.clientID], credentials.keys[.clientID])
        zoom.address = .s2s(zoom.apps[0].id, .information)
        let information = try recording("s2s-information")
        let nowInformation = await zoom.read()
        XCTAssertEqual(nowInformation?.controls, information.controls)
    }
}
