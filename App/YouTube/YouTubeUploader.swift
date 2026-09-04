//
//  YouTubeUploader.swift
//  Greenroom
//
//  Resumable upload to the YouTube Data API (videos.insert), in 32 MiB
//  chunks. A class recording is one to two gigabytes; a dropped Wi-Fi
//  connection halfway through resumes from the last byte YouTube confirmed
//  instead of starting over, and every chunk is a progress tick for the
//  toast. No SDK: three request shapes and URLSession.
//
//  Quota, for the record: an upload costs about 1,600 of the project's
//  10,000 daily units, so roughly six uploads a day. One class a morning is
//  well inside that.
//
import Foundation

enum YouTubeUploader {

    struct Result {
        let videoID: String
        var url: URL { URL(string: "https://youtu.be/\(videoID)")! }
    }

    enum UploadError: LocalizedError {
        case unreadable, noSession(String), rejected(Int, String), gaveUp

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The recording could not be read."
            case .noSession(let why): return "YouTube would not start the upload: \(why)"
            case .rejected(let status, let why): return "YouTube rejected the upload (HTTP \(status)): \(why)"
            case .gaveUp: return "The connection kept dropping; gave up after several retries. The recording is still on this Mac."
            }
        }
    }

    static let chunkSize = 32 * 1024 * 1024

    /// Uploads `file`. `token` is asked for before every chunk so a
    /// sign-in that expires during a long upload renews itself.
    static func upload(file: URL,
                       title: String,
                       description: String,
                       privacy: String,
                       token: @escaping () async throws -> String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0,
              let handle = try? FileHandle(forReadingFrom: file) else {
            throw UploadError.unreadable
        }
        defer { try? handle.close() }

        let session = try await startSession(title: title, description: description, privacy: privacy,
                                             size: size, token: token)

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
                    throw UploadError.rejected(status, "no video id in the response")
                }
                return Result(videoID: id)
            case 500...599:
                failures += 1
                guard failures <= 6 else { throw UploadError.gaveUp }
                try await Task.sleep(nanoseconds: UInt64(min(30, 2 << failures)) * 1_000_000_000)
                offset = try await confirmedOffset(session: session, size: size, token: token) ?? offset
            default:
                throw UploadError.rejected(status, message(in: data))
            }
        }
        throw UploadError.rejected(0, "the upload ended without a video id")
    }

    /// Step one: register the upload and get the session URL every chunk
    /// goes to. Metadata travels here, once.
    private static func startSession(title: String, description: String, privacy: String,
                                     size: Int64, token: () async throws -> String) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
        let metadata: [String: Any] = [
            "snippet": [
                "title": String(title.prefix(100)),   // YouTube's title limit
                "description": description,
                "categoryId": "27",                    // Education
            ],
            "status": [
                "privacyStatus": privacy,
                "selfDeclaredMadeForKids": false,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let url = URL(string: location) else {
            throw UploadError.noSession(status == 0 ? "no response" : "HTTP \(status): \(message(in: data))")
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

    private static func message(in data: Data) -> String {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return String(data: data.prefix(200), encoding: .utf8) ?? "no detail"
        }
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
        }
        return (json["error_description"] as? String) ?? (json["error"] as? String) ?? "no detail"
    }
}
