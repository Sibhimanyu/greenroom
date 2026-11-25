import XCTest

/// R17 One icon language (Q28 to Q33). One enum of meanings gives every surface its symbol,
/// tint and spoken words; the guard test keeps raw symbol names out of the rest of App/.
final class VisibilitySymbolsTests: XCTestCase {
    // R17.1 (Q28): the eye means "everyone sees it", and only that.
    func testTheEyeIsEveryoneSees() {
        XCTAssertEqual(VisibilitySymbol.everyoneSees(true).symbol, "eye")
        XCTAssertEqual(VisibilitySymbol.everyoneSees(false).symbol, "eye.slash")
        XCTAssertEqual(VisibilitySymbol.everyoneSees(true).tint, .net)
        XCTAssertEqual(VisibilitySymbol.everyoneSees(false).tint, .neutral)
        XCTAssertEqual(VisibilitySymbol.everyoneSees(true).words, "Everyone sees this")
        XCTAssertEqual(VisibilitySymbol.everyoneSees(false).words, "Only you")
    }

    // R17.2 (Q29): starts hidden is a dashed outline, not an icon.
    func testStartsHiddenIsDashedAndHasNoIcon() {
        XCTAssertNil(VisibilitySymbol.startsHidden.symbol)
        XCTAssertTrue(VisibilitySymbol.startsHidden.dashed)
        XCTAssertEqual(VisibilitySymbol.startsHidden.words, "Starts hidden on your screen")
        XCTAssertFalse(VisibilitySymbol.everyoneSees(true).dashed)
    }

    // R17.3 (Q30): the camera uses Zoom's icons in four states.
    func testTheFourCameraStates() {
        XCTAssertEqual(VisibilitySymbol.camera(.everyoneAndMe).symbol, "video.fill")
        XCTAssertNil(VisibilitySymbol.camera(.everyoneAndMe).badge)
        XCTAssertEqual(VisibilitySymbol.camera(.onlyEveryone).symbol, "video.fill")
        XCTAssertTrue(VisibilitySymbol.camera(.onlyEveryone).dashed)
        XCTAssertEqual(VisibilitySymbol.camera(.onlyMe).symbol, "video.fill")
        XCTAssertEqual(VisibilitySymbol.camera(.onlyMe).badge, "eye.slash")
        XCTAssertEqual(VisibilitySymbol.camera(.off).symbol, "video.slash")
        for s in CameraState.allCases {
            XCTAssertFalse(["eye", "camera", "camera.fill"].contains(VisibilitySymbol.camera(s).symbol ?? ""))
        }
    }

    // R49, R17.3: Stop video is Zoom's red, filled video.slash; camera state Off keeps the outline
    // video.slash in the quiet tint. Two meanings, two shapes and two colours, so colour is never alone.
    func testStopVideoHasItsOwnMarkApartFromOff() {
        XCTAssertEqual(VisibilitySymbol.videoStopped.symbol, "video.slash.fill")
        XCTAssertEqual(VisibilitySymbol.videoStopped.tint, .stopped)
        XCTAssertEqual(VisibilitySymbol.videoStopped.words, "Video stopped")
        XCTAssertNil(VisibilitySymbol.videoStopped.badge)
        XCTAssertNotEqual(VisibilitySymbol.videoStopped.symbol, VisibilitySymbol.camera(.off).symbol)
        XCTAssertEqual(VisibilitySymbol.camera(.off).tint, .neutral)
        for s in CameraState.allCases { XCTAssertNotEqual(VisibilitySymbol.camera(s).tint, .stopped, s.name) }
    }

    // R17.3
    func testCameraOnOffAndNoDevice() {
        XCTAssertEqual(VisibilitySymbol.cameraOn.symbol, "video.fill")
        XCTAssertEqual(VisibilitySymbol.cameraOff.symbol, "video.slash")
        XCTAssertEqual(VisibilitySymbol.noCameraDevice.symbol, "video")
        XCTAssertEqual(VisibilitySymbol.noCameraDevice.badge, "questionmark.circle.fill")
    }

    // R17.5 (Q32, Q33): one icon per action.
    func testOneIconPerAction() {
        XCTAssertEqual(VisibilitySymbol.share.symbol, "rectangle.on.rectangle")
        XCTAssertEqual(VisibilitySymbol.stopShare.symbol, "rectangle.on.rectangle.slash")
        XCTAssertEqual(VisibilitySymbol.showOnScreen.symbol, "rectangle.dashed")
        XCTAssertEqual(VisibilitySymbol.screenRecordingPermission.symbol, "rectangle.dashed.badge.record")
        XCTAssertEqual(VisibilitySymbol.blur.symbol, "aqi.medium")
        XCTAssertEqual(VisibilitySymbol.shareNothing.symbol, "video")
        XCTAssertEqual(VisibilitySymbol.hideMeetingWindow.symbol, "rectangle.slash")
        let all: [VisibilitySymbol] = [.share, .stopShare, .showOnScreen, .screenRecordingPermission, .blur,
                                       .shareNothing, .hideMeetingWindow, .cameraOn, .cameraOff,
                                       .everyoneSees(true), .everyoneSees(false)]
        XCTAssertFalse(all.contains { $0.symbol == "eye" && $0 != .everyoneSees(true) })
        XCTAssertTrue(all.allSatisfy { !$0.words.localizedCaseInsensitiveContains("class") })
    }

    // R17.5: the camera that sees nobody, two displays and an empty layout each have one icon.
    func testNobodyInCameraTwoDisplaysAndEmptyLayoutHaveTheirOwnIcons() {
        XCTAssertEqual(VisibilitySymbol.nobodyInCamera.symbol, "person.fill.questionmark")
        XCTAssertEqual(VisibilitySymbol.nobodyInCamera.tint, .neutral)
        XCTAssertEqual(VisibilitySymbol.nobodyInCamera.words, "Can\u{2019}t see you")
        XCTAssertEqual(VisibilitySymbol.twoDisplays.symbol, "display.2")
        XCTAssertEqual(VisibilitySymbol.noPieces.symbol, "rectangle.dashed")
        XCTAssertNotEqual(VisibilitySymbol.nobodyInCamera.symbol, VisibilitySymbol.everyoneSees(false).symbol, "the eye means only you")
        XCTAssertNotEqual(VisibilitySymbol.twoDisplays.symbol, VisibilitySymbol.share.symbol, "Share is not two displays")
    }

    // R17.4 (Q31): nobody outside VisibilitySymbols.swift spells these symbol names.
    // Allowed: the editor's own drawing tools (App/Editor is checked only for the eye family, which
    // it no longer uses; its "rectangle.dashed" marquee hint is a generic shape and not guarded),
    // the physical "display" glyph (not a share symbol), word lists and request keys in Cues/Zoom/Debug (not symbols), and the Recording node in the
    // Screenroom flow diagram (a recording step, not the camera).
    func testNoRawVisibilitySymbolsOutsideTheOneFile() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App")
        let always = try NSRegularExpression(pattern: #""(eye(\.[a-z.]+)?|dot\.radiowaves[a-z.]*)""#)
        let ambiguous = try NSRegularExpression(
            pattern: #"(systemName|systemSymbolName|symbol|Symbol|icon|orb|guideRow|image)[^\n]*"(video(\.fill|\.slash|\.slash\.fill)?|camera(\.fill)?|rectangle\.on\.rectangle(\.slash)?|rectangle\.dashed(\.badge\.record)?|aqi\.medium|rectangle\.slash|person\.fill\.questionmark|display\.2)""#)
        let notSymbols = ["/Cues/", "/Zoom/", "/Debug/"]
        let allowedLines: [(file: String, contains: String)] = [
            ("Screenroom/ScreenroomSettingsTab.swift", #"node("video.fill", "Recording""#),
        ]
        var found: [String] = []
        let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let path = url.path
            if path.hasSuffix("/UI/VisibilitySymbols.swift") { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                let hit = (!notSymbols.contains { path.contains($0) } && always.firstMatch(in: line, range: range) != nil)
                    || (!notSymbols.contains { path.contains($0) } && ambiguous.firstMatch(in: line, range: range) != nil)
                if hit, !allowedLines.contains(where: { path.hasSuffix($0.file) && line.contains($0.contains) }) {
                    found.append("\(path.replacingOccurrences(of: app.path + "/", with: "")):\(n + 1): \(trimmed)")
                }
            }
        }
        XCTAssertEqual(found, [], "Raw visibility/camera symbol names outside VisibilitySymbols.swift")
    }
}
