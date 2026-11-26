//
//  YouTubeUploader.swift
//  Greenroom
//
//  Resumable upload to the YouTube Data API (videos.insert), in 32 MiB
//  chunks. A class recording is one to two gigabytes; a dropped Wi-Fi
//  connection halfway through resumes from the last byte YouTube confirmed
//  instead of starting over, and every chunk is a progress tick for the
//  toast. No SDK: a few request shapes and URLSession. After the upload,
//  the same file renames the video and deletes it.
//
//  Quota, for the record (Google's docs, 2026-11-26): videos.insert has its
//  own bucket of 100 calls a day per Cloud project. With the shared Google
//  app that bucket is shared by everyone using Greenroom; when it runs out,
//  Google answers quotaExceeded and YouTubeErrorRules says so and offers
//  Upload in YouTube Studio.
//
import Foundation

enum YouTubeUploader {

    struct Result {
        let videoID: String
        var url: URL { URL(string: "https://youtu.be/\(videoID)")! }
    }

    /// `api` carries Google's reason code, which YouTubeErrorRules turns
    /// into plain words and buttons.
    enum UploadError: LocalizedError {
        case unreadable, api(status: Int, reason: String?, message: String), gaveUp

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The recording could not be read."
            case .api(let status, let reason, let why):
                return "YouTube answered HTTP \(status)\(reason.map { " (\($0))" } ?? ""): \(why)"
            case .gaveUp: return "The connection kept dropping; gave up after several retries. The recording is still on this Mac."
            }
        }
    }

    static let chunkSize = 32 * 1024 * 1024

    /// Uploads `file`. `token` is asked for before every chunk so a
    /// sign-in that expires during a long upload renews itself.
    static func upload(file: URL,
                       details: YouTubeUploadDetails,
                       token: @escaping () async throws -> String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0,
              let handle = try? FileHandle(forReadingFrom: file) else {
            throw UploadError.unreadable
        }
        defer { try? handle.close() }

        let session = try await startSession(details: details, size: size, token: token)

        var offset: Int64 = 0
        var failures = 0
        while offset < size {
            try handle.seek(toOffset: UInt64(offset))
            let length = Int(min(Int64(chunkSize), size - offset))
            let chunk = handle.readData(ofLength: length)

            var request = URLRequest(url: session)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
            request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
            request.setValue("bytes \(offset)-\(offset + Int64(length) - 1)/\(size)", forHTTPHeaderField: "Content-Range")

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.upload(for: request, from: chunk)
            } catch {
                // Network dropped mid-chunk: ask YouTube how far it got.
                failures += 1
                guard failures <= 6 else { throw UploadError.gaveUp }
                try await Task.sleep(nanoseconds: UInt64(min(30, 2 << failures)) * 1_000_000_000)
                offset = try await confirmedOffset(session: session, size: size, token: token) ?? offset
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0

            switch status {
            case 308:
                // Resume Incomplete: the Range header names the last byte stored.
                if let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range"),
                   let last = range.split(separator: "-").last, let lastByte = Int64(last) {
                    offset = lastByte + 1
                } else {
                    offset += Int64(length)
                }
                failures = 0
                progress(Double(offset) / Double(size))
            case 200, 201:
                progress(1)
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let id = json["id"] as? String else {
                    throw UploadError.api(status: status, reason: nil, message: "no video id in the response")
                }
                return Result(videoID: id)
            case 500...599:
                failures += 1
                guard failures <= 6 else { throw UploadError.gaveUp }
                try await Task.sleep(nanoseconds: UInt64(min(30, 2 << failures)) * 1_000_000_000)
                offset = try await confirmedOffset(session: session, size: size, token: token) ?? offset
            default:
                throw apiError(status, data)
            }
        }
        throw UploadError.api(status: 0, reason: nil, message: "the upload ended without a video id")
    }

    /// Changes a video's title after the fact (videos.update, 50 quota
    /// units). `description` is sent again because an update that omits a
    /// mutable snippet field clears it.
    static func rename(videoID: String, title: String, description: String,
                       token: () async throws -> String) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/youtube/v3/videos?part=snippet")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "id": videoID,
            "snippet": [
                "title": YouTubeUploadRules.title(title),
                "description": description,
                "categoryId": "27",
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw apiError(status, data)
        }
    }

    /// Removes a video from the channel (videos.delete, 50 quota units).
    /// Permanent: YouTube has no bin to restore from. A video that is
    /// already gone - deleted in YouTube Studio, say - counts as success,
    /// because the caller's only job afterwards is to forget the link.
    static func delete(videoID: String, token: () async throws -> String) async throws {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")!
        components.queryItems = [URLQueryItem(name: "id", value: videoID)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) || status == 404 else {
            throw apiError(status, data)
        }
    }

    /// Step one: register the upload and get the session URL every chunk
    /// goes to. Metadata travels here, once.
    private static func startSession(details: YouTubeUploadDetails,
                                     size: Int64, token: () async throws -> String) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = try JSONSerialization.data(withJSONObject: YouTubeUploadRules.metadata(details))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location) else {
            if status == 0 { throw UploadError.gaveUp }
            throw apiError(status, data)
        }
        return url
    }

    /// After a failure: "how much do you have?" A PUT with an empty body and
    /// `bytes */size` returns 308 with the stored range, or 200 if it was
    /// in fact complete (that case is left to the main loop's next PUT).
    private static func confirmedOffset(session: URL, size: Int64,
                                        token: () async throws -> String) async throws -> Int64? {
        var request = URLRequest(url: session)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 308 {
            guard let range = http.value(forHTTPHeaderField: "Range"),
                  let last = range.split(separator: "-").last, let lastByte = Int64(last) else { return 0 }
            return lastByte + 1
        }
        return nil
    }

    private static func apiError(_ status: Int, _ data: Data) -> UploadError {
        let parsed = YouTubeErrorRules.parse(data)
        let fallback = String(data: data.prefix(200), encoding: .utf8) ?? "no detail"
        return .api(status: status, reason: parsed.reason, message: parsed.message ?? fallback)
    }
}
