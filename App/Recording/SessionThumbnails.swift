//
//  SessionThumbnails.swift
//  Greenroom
//
//  A frame of each recording for the Sessions grid, and how long it runs.
//
//  Taken 10% in rather than at the start: the first frames of a class are the
//  camera warming up and a teacher reaching for the mouse, and a grid of those
//  all look the same. A tenth of the way in, the slides are up.
//
//  Cached twice. In memory for the life of the window, and as a small JPEG in
//  ~/Library/Caches keyed by the file's path, size and modification date - so
//  a recording that is replaced gets a new picture, and opening Sessions
//  tomorrow does not decode forty hour-long videos again. The cache is only a
//  cache: delete it and every picture comes back on the next open.
//
import AppKit
import AVFoundation
import CryptoKit

@MainActor
final class SessionThumbnails: ObservableObject {

    static let shared = SessionThumbnails()

    @Published private(set) var images: [URL: NSImage] = [:]
    @Published private(set) var durations: [URL: Double] = [:]
    private var pending: Set<URL> = []

    /// The picture for a recording, asking for it if it is not known yet.
    /// Nil until it arrives, and forever for a file nothing can decode - the
    /// card draws its kind's glyph instead.
    func image(for url: URL) -> NSImage? {
        if let image = images[url] { return image }
        request(url)
        return nil
    }

    func duration(for url: URL) -> Double? {
        if let duration = durations[url] { return duration }
        request(url)
        return nil
    }

    private func request(_ url: URL) {
        guard !pending.contains(url) else { return }
        pending.insert(url)
        Task.detached(priority: .utility) {
            let made = await Self.make(url)
            await MainActor.run {
                if let image = made.image { self.images[url] = image }
                // Zero, not nil, for a file that would not open: nil means
                // "ask", and asking again would decode it on every redraw.
                self.durations[url] = made.duration ?? 0
            }
        }
    }

    // MARK: Making one

    private nonisolated static func make(_ url: URL) async -> (image: NSImage?, duration: Double?) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration))?.seconds
        let cached = cacheURL(for: url)
        if let cached, let image = NSImage(contentsOf: cached) {
            return (image, duration)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        // Near enough is fine for a thumbnail, and exact seeks into a long
        // H.264 file decode from the previous keyframe for no visible gain.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let at = CMTime(seconds: max(0, (duration ?? 0) * 0.1), preferredTimescale: 600)
        guard let frame = try? await generator.image(at: at).image else { return (nil, duration) }
        let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        if let cached {
            let rep = NSBitmapImageRep(cgImage: frame)
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                try? FileManager.default.createDirectory(at: cached.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? jpeg.write(to: cached, options: .atomic)
            }
        }
        return (image, duration)
    }

    /// Where a recording's picture is kept. Nil when the file cannot be read.
    private nonisolated static func cacheURL(for url: URL) -> URL? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let key = "\(url.path)|\(values.fileSize ?? 0)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Greenroom")
            .appendingPathComponent("SessionThumbnails")
            .appendingPathComponent(String(digest.prefix(32)) + ".jpg")
    }
}
