//
//  ThumbnailLoader.swift
//  Greenroom
//
//  The little picture on a card: a book cover, a Wikipedia lead image, a
//  video thumbnail. Fetched once per URL, capped in size, scaled down to what
//  the card draws at (56pt, so 112px at 2x), and kept in an NSCache that the
//  system may empty whenever it likes.
//
import AppKit
import Foundation

actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSURL, NSImage>()
    private let session: URLSession
    /// Anything bigger is not a thumbnail. 200 KB is generous for a cover.
    private let byteCap = 200_000
    private let side: CGFloat = 112

    init() {
        cache.countLimit = 40
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpAdditionalHeaders = ["User-Agent": LinkResolver.userAgent]
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard url.scheme == "https" else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              data.count <= byteCap,
              let image = NSImage(data: data) else { return nil }
        let scaled = downscale(image)
        cache.setObject(scaled, forKey: url as NSURL)
        return scaled
    }

    private func downscale(_ image: NSImage) -> NSImage {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return image }
        let scale = min(1, side / max(source.width, source.height))
        guard scale < 1 else { return image }
        let target = NSSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
        let result = NSImage(size: target)
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target), from: NSRect(origin: .zero, size: source),
                   operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
    }
}
