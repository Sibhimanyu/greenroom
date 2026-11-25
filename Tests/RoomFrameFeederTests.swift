import CoreMedia
import CoreVideo
import QuartzCore
import XCTest

/// The Room screen's frames reach its layer: whatever the meeting's picture was
/// last, that is what the layer holds, however long the meeting runs.
///
/// The bug (2026-11-26): frames kept arriving at 30 fps, but the layer stopped
/// showing them (the system's own image-queue stats for that layer read
/// "enqueued: 180, displayed: 0, evicted: 180" every 6 s, 15 to 106 s into each
/// meeting) and the room saw one frozen picture.
final class RoomFrameFeederTests: XCTestCase {
    private func frame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        return try XCTUnwrap(buffer)
    }

    private func surface(of layer: CALayer) -> IOSurface? {
        guard let contents = layer.contents else { return nil }
        guard CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        return (contents as! IOSurfaceRef) as IOSurface
    }

    /// Lets the main queue run what the feeder handed it.
    private func settle() {
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    private func makeFeeder() -> (RoomFrameFeeder, CALayer) {
        let layer = CALayer()
        return (RoomFrameFeeder(layer: layer), layer)
    }

    func testTheLayerHoldsTheNewestFrame() throws {
        let (feeder, layer) = makeFeeder()
        let frames = try (0..<3).map { _ in try frame() }
        for f in frames { feeder.show(f, stampedAt: .invalid) }
        settle()
        let shown = try XCTUnwrap(surface(of: layer), "the layer holds no frame")
        XCTAssertTrue(shown === CVPixelBufferGetIOSurface(frames[2])!.takeUnretainedValue() as IOSurface)
    }

    /// A long meeting from the render queue: the layer keeps up to the last frame.
    func testFramesFromAnotherQueueKeepLandingForAWholeMeeting() throws {
        let (feeder, layer) = makeFeeder()
        let pool = try (0..<6).map { _ in try frame() }      // a pool's worth, reused like the compositor's
        let render = DispatchQueue(label: "test.render")
        let total = 3_000                                    // 100 s at 30 fps
        let sent = expectation(description: "sent")
        render.async {
            for i in 0..<total { feeder.show(pool[i % pool.count], stampedAt: .invalid) }
            sent.fulfill()
        }
        wait(for: [sent], timeout: 10)
        settle()
        let shown = try XCTUnwrap(surface(of: layer), "the layer holds no frame")
        let last = pool[(total - 1) % pool.count]
        XCTAssertTrue(shown === CVPixelBufferGetIOSurface(last)!.takeUnretainedValue() as IOSurface)
    }
}
