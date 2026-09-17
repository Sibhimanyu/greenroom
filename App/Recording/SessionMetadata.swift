//
//  SessionMetadata.swift
//  Greenroom
//
//  What a class folder knows about itself beyond its files: the name the
//  teacher gave it, and where its recordings went. One `session.json` per
//  folder, next to the recordings, so the record travels with the files and
//  a folder copied elsewhere still knows its YouTube links.
//
//  The folder is never renamed on disk: OBS and the clip pipeline refer to
//  it by path during a session, and a display title is what the teacher
//  actually wants to change.
//
import Foundation

struct SessionMetadata: Codable {
    struct Upload: Codable, Identifiable, Hashable {
        /// The recording's file name within the folder.
        var file: String
        var videoID: String
        var url: String
        var privacy: String
        var title: String
        var uploadedAt: Date
        var id: String { videoID }
    }

    /// A Cues card the teacher acted on. Written on Open or Send ONLY -
    /// never for a card that was merely shown, never a mention, a query or a
    /// word of the transcript. This is the class's own record of what it
    /// looked at, kept because "what was that book from Tuesday" is a real
    /// question.
    struct Link: Codable, Identifiable, Hashable {
        var kind: String
        var title: String
        var url: String
        /// "opened" | "sent"
        var action: String
        var at: Date
        var id: String { "\(url)#\(at.timeIntervalSince1970)" }
    }

    var title: String?
    var uploads: [Upload] = []
    var links: [Link] = []

    static let fileName = "session.json"

    static func url(in folder: URL) -> URL { folder.appendingPathComponent(fileName) }

    static func load(in folder: URL) -> SessionMetadata {
        guard let data = try? Data(contentsOf: url(in: folder)),
              let decoded = try? JSONDecoder().decode(SessionMetadata.self, from: data) else {
            return SessionMetadata()
        }
        return decoded
    }

    @discardableResult
    func save(in folder: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: Self.url(in: folder), options: .atomic)) != nil
    }

    /// The upload record for one recording file, if it has been uploaded.
    func upload(for recording: URL) -> Upload? {
        uploads.last { $0.file == recording.lastPathComponent }
    }

    // MARK: Mutations

    /// Remembers an upload against the recording's folder. Loose legacy files
    /// at the root have no folder of their own and are not recorded.
    static func recordUpload(of recording: URL, videoID: String, url: String, privacy: String, title: String) {
        let folder = recording.deletingLastPathComponent()
        guard folder != GreenroomScene.recordingsDirectory else { return }
        var metadata = load(in: folder)
        metadata.uploads.removeAll { $0.file == recording.lastPathComponent }
        metadata.uploads.append(Upload(file: recording.lastPathComponent, videoID: videoID, url: url,
                                       privacy: privacy, title: title, uploadedAt: Date()))
        metadata.save(in: folder)
    }

    static func updateUploadTitle(videoID: String, to title: String, in folder: URL) {
        var metadata = load(in: folder)
        guard let index = metadata.uploads.firstIndex(where: { $0.videoID == videoID }) else { return }
        metadata.uploads[index].title = title
        metadata.save(in: folder)
    }

    /// Remembers a link the teacher opened or sent during the class. The
    /// folder is created if the session has not written anything else yet.
    static func recordLink(in folder: URL, kind: String, title: String, url: String, action: String) {
        guard folder != GreenroomScene.recordingsDirectory else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var metadata = load(in: folder)
        // The same link opened and then sent is one entry with the later action.
        metadata.links.removeAll { $0.url == url }
        metadata.links.append(Link(kind: kind, title: title, url: url, action: action, at: Date()))
        metadata.save(in: folder)
    }

    static func rename(folder: URL, to title: String) {
        var metadata = load(in: folder)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = trimmed.isEmpty ? nil : trimmed
        metadata.save(in: folder)
    }
}
