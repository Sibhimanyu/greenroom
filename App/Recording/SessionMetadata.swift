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

    var title: String?
    var uploads: [Upload] = []

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

    static func rename(folder: URL, to title: String) {
        var metadata = load(in: folder)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = trimmed.isEmpty ? nil : trimmed
        metadata.save(in: folder)
    }
}
