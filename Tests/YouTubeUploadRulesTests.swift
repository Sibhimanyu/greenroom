import XCTest

/// What Greenroom sends to videos.insert, what the upload sheet requires,
/// the channel line, and the YouTube Studio hand-off.
final class YouTubeUploadRulesTests: XCTestCase {

    private func details(title: String = "Morning Reading", description: String = "Recorded with Greenroom.",
                         privacy: String = "unlisted", madeForKids: Bool = false) -> YouTubeUploadDetails {
        YouTubeUploadDetails(title: title, description: description, privacy: privacy, madeForKids: madeForKids)
    }

    private func snippet(_ d: YouTubeUploadDetails) -> [String: Any] {
        YouTubeUploadRules.metadata(d)["snippet"] as? [String: Any] ?? [:]
    }

    private func status(_ d: YouTubeUploadDetails) -> [String: Any] {
        YouTubeUploadRules.metadata(d)["status"] as? [String: Any] ?? [:]
    }

    // MARK: Request fields

    func testTitleAndDescriptionGoInTheSnippet() {
        let s = snippet(details())
        XCTAssertEqual(s["title"] as? String, "Morning Reading")
        XCTAssertEqual(s["description"] as? String, "Recorded with Greenroom.")
        XCTAssertEqual(s["categoryId"] as? String, "27")
    }

    func testPrivacyGoesInTheStatus() {
        XCTAssertEqual(status(details())["privacyStatus"] as? String, "unlisted")
        XCTAssertEqual(status(details(privacy: "private"))["privacyStatus"] as? String, "private")
    }

    func testMadeForKidsIsTheSelfDeclaration() {
        XCTAssertEqual(status(details(madeForKids: true))["selfDeclaredMadeForKids"] as? Bool, true)
        XCTAssertEqual(status(details(madeForKids: false))["selfDeclaredMadeForKids"] as? Bool, false)
    }

    func testAnythingButPrivateIsSentAsUnlisted() {
        XCTAssertEqual(status(details(privacy: "public"))["privacyStatus"] as? String, "unlisted")
        XCTAssertEqual(status(details(privacy: ""))["privacyStatus"] as? String, "unlisted")
    }

    /// YouTube refuses < and > in both, caps the title at 100 and the description at 5000.
    func testFieldsAreCleanedTheWayYouTubeNeeds() {
        let s = snippet(details(title: "  <Week 4> " + String(repeating: "a", count: 200),
                                description: "a<b>c" + String(repeating: "d", count: 6000)))
        let title = s["title"] as? String ?? ""
        XCTAssertFalse(title.contains("<") || title.contains(">"))
        XCTAssertTrue(title.hasPrefix("Week 4 "))
        XCTAssertEqual(title.count, 100)
        let description = s["description"] as? String ?? ""
        XCTAssertTrue(description.hasPrefix("abc"))
        XCTAssertEqual(description.count, 5000)
    }

    func testAnEmptyTitleBecomesRecording() {
        XCTAssertEqual(snippet(details(title: "  <> "))["title"] as? String, "Recording")
    }

    // MARK: The sheet

    func testDefaultPrivacyIsUnlisted() {
        XCTAssertEqual(YouTubeUploadRules.defaultPrivacy, "unlisted")
    }

    func testUploadNeedsAMadeForKidsAnswerATitleAndASignIn() {
        XCTAssertTrue(YouTubeUploadRules.canUpload(title: "A", madeForKids: false, signedIn: true))
        XCTAssertTrue(YouTubeUploadRules.canUpload(title: "A", madeForKids: true, signedIn: true))
        XCTAssertFalse(YouTubeUploadRules.canUpload(title: "A", madeForKids: nil, signedIn: true))
        XCTAssertFalse(YouTubeUploadRules.canUpload(title: "  ", madeForKids: false, signedIn: true))
        XCTAssertFalse(YouTubeUploadRules.canUpload(title: "A", madeForKids: false, signedIn: false))
    }

    /// YouTube API Services Terms §9.1(1), on the screen with the Upload button.
    func testTheCertifyLineIsTheTermsWording() {
        XCTAssertEqual(YouTubeUploadRules.certifyLine,
                       "By clicking \u{2018}upload,\u{2019} you certify that the content you are uploading complies with the YouTube Terms of Service (including the YouTube Community Guidelines) at https://www.youtube.com/t/terms. Please be sure not to violate others\u{2019} copyright or privacy rights.")
        XCTAssertEqual(YouTubeUploadRules.termsURL.absoluteString, "https://www.youtube.com/t/terms")
    }

    func testTheDescriptionIsPrefilledFromTheSession() {
        let date = DateComponents(calendar: .init(identifier: .gregorian), timeZone: .init(identifier: "UTC"),
                                  year: 2026, month: 11, day: 26, hour: 9).date!
        XCTAssertEqual(YouTubeUploadRules.defaultDescription(recordedOn: date, timeZone: .init(identifier: "UTC")!),
                       "Recorded with Greenroom on 26 November 2026.")
    }

    // MARK: The connected channel

    func testTheChannelLineReadsChannelsListMine() throws {
        let json = #"{"items":[{"id":"UC1","snippet":{"title":"Ms Rao's Class","thumbnails":{"default":{"url":"https://yt3.ggpht.com/a.jpg"}}}}]}"#
        let channel = try XCTUnwrap(YouTubeUploadRules.channel(fromChannelsList: Data(json.utf8)))
        XCTAssertEqual(channel.name, "Ms Rao's Class")
        XCTAssertEqual(channel.avatarURL, "https://yt3.ggpht.com/a.jpg")
    }

    func testAnAccountWithNoChannelHasNoChannelLine() {
        XCTAssertNil(YouTubeUploadRules.channel(fromChannelsList: Data(#"{"items":[]}"#.utf8)))
        XCTAssertNil(YouTubeUploadRules.channel(fromChannelsList: Data(#"{"pageInfo":{}}"#.utf8)))
    }

    // MARK: Upload in YouTube Studio

    func testTheStudioHandOffCopiesTitleThenDescription() {
        XCTAssertEqual(YouTubeStudioHandoff.clipboardText(title: "Morning Reading", description: "Recorded with Greenroom."),
                       "Morning Reading\n\nRecorded with Greenroom.")
    }

    func testTheStudioHandOffTrimsAndSkipsAnEmptyDescription() {
        XCTAssertEqual(YouTubeStudioHandoff.clipboardText(title: "  Morning Reading \n", description: "  "),
                       "Morning Reading")
    }

    func testTheStudioHandOffOpensTheUploadPageAndSaysWhatItCopied() {
        XCTAssertEqual(YouTubeStudioHandoff.uploadURL.absoluteString, "https://www.youtube.com/upload")
        XCTAssertEqual(YouTubeStudioHandoff.toastTitle, "Title and description copied")
    }
}
