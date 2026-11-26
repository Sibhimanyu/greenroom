//
//  YouTubeUploadRules.swift
//  Greenroom
//
//  The plain-value side of uploading: the videos.insert metadata, what the
//  upload sheet needs before Upload is allowed, the YouTube API Services
//  Terms wording it must show, the connected channel line, and the
//  "Upload in YouTube Studio" hand-off that needs no sign-in at all.
//
//  Pure: Foundation only.
//
import Foundation

/// What the person chose in the upload sheet (or Settings, for automatic uploads).
struct YouTubeUploadDetails: Equatable {
    var title: String
    var description: String
    /// "unlisted" or "private".
    var privacy: String
    /// The Made for Kids answer (`status.selfDeclaredMadeForKids`).
    var madeForKids: Bool
}

/// The "signed in as" line: channels.list?mine=true.
struct YouTubeChannel: Equatable, Codable {
    var name: String
    var avatarURL: String?
}

enum YouTubeUploadRules {

    static let defaultPrivacy = "unlisted"

    /// YouTube API Services Terms of Service §9.1(1): shown on the screen
    /// where the person clicks Upload. Word for word.
    static let certifyLine = "By clicking \u{2018}upload,\u{2019} you certify that the content you are uploading complies with the YouTube Terms of Service (including the YouTube Community Guidelines) at https://www.youtube.com/t/terms. Please be sure not to violate others\u{2019} copyright or privacy rights."
    static let termsURL = URL(string: "https://www.youtube.com/t/terms")!
    static let guidelinesURL = URL(string: "https://www.youtube.com/howyoutubeworks/policies/community-guidelines/")!
    /// Google's own page on what "made for kids" means.
    static let madeForKidsHelpURL = URL(string: "https://support.google.com/youtube/answer/9528076")!
    static let createChannelURL = URL(string: "https://www.youtube.com/create_channel")!
    static let cloudConsoleURL = URL(string: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")!

    /// The resumable upload's first request body. Privacy is unlisted unless
    /// "private" was chosen; Greenroom never publishes publicly.
    static func metadata(_ d: YouTubeUploadDetails) -> [String: Any] {
        [
            "snippet": [
                "title": title(d.title),
                "description": String(clean(d.description).prefix(5000)),
                "categoryId": "27", // Education
            ],
            "status": [
                "privacyStatus": d.privacy == "private" ? "private" : "unlisted",
                "selfDeclaredMadeForKids": d.madeForKids,
            ],
        ]
    }

    /// YouTube refuses "<" and ">" in titles and descriptions, and titles over
    /// 100 characters; an empty title is refused too.
    static func title(_ raw: String) -> String {
        let cleaned = clean(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Recording" : String(cleaned.prefix(100))
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
    }

    /// The sheet's Upload button: a Made for Kids answer is required, as is a title.
    static func canUpload(title: String, madeForKids: Bool?, signedIn: Bool) -> Bool {
        signedIn && madeForKids != nil && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The description the sheet starts with.
    static func defaultDescription(recordedOn date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMMM yyyy"
        return "Recorded with Greenroom on \(formatter.string(from: date))."
    }

    /// The first channel in a channels.list?part=snippet&mine=true answer, or
    /// nil when the Google account has no YouTube channel.
    static func channel(fromChannelsList data: Data) -> YouTubeChannel? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let first = (json["items"] as? [[String: Any]])?.first,
              let snippet = first["snippet"] as? [String: Any],
              let name = snippet["title"] as? String else { return nil }
        let thumbnails = snippet["thumbnails"] as? [String: Any]
        let avatar = ["default", "medium", "high"].lazy
            .compactMap { (thumbnails?[$0] as? [String: Any])?["url"] as? String }.first
        return YouTubeChannel(name: name, avatarURL: avatar)
    }
}

/// "Upload in YouTube Studio": the way that always works, signed in or not.
/// Opens YouTube's upload page in the browser, shows the recording in Finder
/// selected (to drag in), and puts the title and description on the clipboard.
enum YouTubeStudioHandoff {
    /// Opens YouTube Studio with its upload dialog on the signed-in channel
    /// (and the browser's sign-in first when nobody is signed in).
    static let uploadURL = URL(string: "https://www.youtube.com/upload")!
    static let toastTitle = "Title and description copied"
    static let toastDetail = "YouTube is opening, and the recording is selected in Finder. Drag it in."

    static func clipboardText(title: String, description: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return d.isEmpty ? t : "\(t)\n\n\(d)"
    }
}
