#if DEBUG
//
//  DebugFilm.swift
//  Greenroom
//
//  DEBUG-only: films the main window while the tour changes page, so a
//  transition can be judged frame by frame instead of by eye. The capture is
//  the main window alone, composited where it sits on its display (so moves
//  and resizes show), at 60 fps. Every display frame, the window's frame
//  is logged too, which catches jumps that a picture can hide.
//
//    film page=home|sessions [secs=1.0] [dir=...]
//
//  Writes <dir>/film-NNN.png (half size) and <dir>/film.json (per-frame time and
//  window frame). Nothing is activated, clicked or typed.
//
import AppKit
import ScreenCaptureKit
import CoreMedia

@MainActor
enum DebugFilm {
    private final class Sink: NSObject, SCStreamOutput, @unchecked Sendable {
        let lock = NSLock()
        var frames: [(t: Double, image: CGImage)] = []
        let start = CACurrentMediaTime()
        func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
            // Idle frames repeat the last one; keep only complete ones.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
               let raw = attachments.first?[.status] as? Int,
               SCFrameStatus(rawValue: raw) != .complete { return }
            let ci = CIImage(cvPixelBuffer: pixels)
            guard let image = CIContext().createCGImage(ci, from: ci.extent) else { return }
            lock.lock(); frames.append((CACurrentMediaTime() - start, image)); lock.unlock()
        }
    }

    static func film(_ info: [String: String], dir: String, change: @escaping () -> Void) async throws -> [String: Any] {
        guard let window = MainWindow.current, let screen = window.screen else { throw DebugTour.TourError("no main window") }
        let secs = min(3, max(0.3, Double(info["secs"] ?? "") ?? 1.0))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // A window on another Space cannot be captured; the frame log alone
        // still shows a stall, so carry on without pictures.
        let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let sink = Sink()
        var stream: SCStream?
        if let content,
           let scWindow = content.windows.first(where: { Int($0.windowID) == window.windowNumber }),
           let display = content.displays.first(where: { $0.frame == screen.frame }) ?? content.displays.first {
            let filter = SCContentFilter(display: display, including: [scWindow])
            let cfg = SCStreamConfiguration()
            cfg.width = Int(display.frame.width)
            cfg.height = Int(display.frame.height)
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.showsCursor = false
            cfg.queueDepth = 8
            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "film"))
            try await s.startCapture()
            stream = s
        }
        try? await Task.sleep(nanoseconds: 150_000_000)

        // Window frame every display tick, from the change on.
        var log: [[String: Any]] = []
        let t0 = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let f = window.frame
                log.append(["t": CACurrentMediaTime() - t0, "frame": [f.minX, f.minY, f.width, f.height]])
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let changeAt = CACurrentMediaTime() - sink.start
        change()
        try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
        timer.invalidate()
        try await stream?.stopCapture()

        sink.lock.lock(); let frames = sink.frames; sink.lock.unlock()
        var times: [Double] = []
        for (i, f) in frames.enumerated() {
            let w = f.image.width / 2, h = f.image.height / 2
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.interpolationQuality = .medium
            ctx.draw(f.image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let small = ctx.makeImage(),
                  let png = NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "film-%03d.png", i)))
            times.append(f.t - changeAt)
        }
        let manifest: [String: Any] = ["frameTimesFromChange": times, "windowFrames": log, "secs": secs]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("film.json"))
        }
        return ["frames": frames.count, "captured": stream != nil]
    }
}
#endif
