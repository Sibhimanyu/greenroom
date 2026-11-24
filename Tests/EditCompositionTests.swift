import AVFoundation
import CoreImage
import XCTest

/// Builds the one combined composition from two real (generated) clips of
/// different sizes and checks its length, its geometry and its pictures.
final class EditCompositionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditCompositionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A solid-colour H.264 clip, 30 fps, no sound.
    private func makeClip(named name: String, size: CGSize, seconds: Double,
                          red: UInt8, green: UInt8, blue: UInt8) async throws -> URL {
        let url = directory.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int(seconds * 30)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    let p = base + y * stride + x * 4
                    p[0] = blue; p[1] = green; p[2] = red; p[3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func pixel(_ image: CGImage, x fx: Double, y fy: Double) -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let px = -Int(Double(image.width) * fx), py = -Int(Double(image.height) * (1 - fy))
        context.draw(image, in: CGRect(x: px, y: py - 0, width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    private func frame(of composition: AVMutableComposition, _ video: AVVideoComposition?,
                       at seconds: Double) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: composition)
        generator.videoComposition = video
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                         actualTime: nil)
    }

    func testTwoClipsOneComposition() async throws {
        let a = try await makeClip(named: "a.mp4", size: CGSize(width: 320, height: 180), seconds: 2,
                                   red: 255, green: 0, blue: 0)
        let b = try await makeClip(named: "b.mp4", size: CGSize(width: 160, height: 160), seconds: 2,
                                   red: 0, green: 0, blue: 255)
        let segments = [
            EditSegment(id: UUID(), url: a, fileDuration: 2, srcStart: 0, srcEnd: 2),
            EditSegment(id: UUID(), url: b, fileDuration: 2, srcStart: 0.5, srcEnd: 2),
        ]
        let sequence = EditSequence(segments: segments)
        // Cut 1.5...2.5 on the timeline: across the clip boundary.
        let timeline = sequence.timeline(cuts: [(1.5, 2.5)])
        XCTAssertEqual(timeline.editedDuration, 3.0, accuracy: 1e-9)
        let built = try await EditComposition.build(urls: segments.map(\.url), pieces: timeline.pieces)
        XCTAssertEqual(built.composition.duration.seconds, timeline.editedDuration, accuracy: 0.05)
        XCTAssertEqual(built.placements.map(\.segmentIndex), [0, 1])

        // The canvas is the first clip's size; the square clip sits centred.
        let video = try XCTUnwrap(EditComposition.videoComposition(for: built, crop: nil))
        XCTAssertEqual(video.renderSize, CGSize(width: 320, height: 180))
        let inA = try frame(of: built.composition, video, at: 0.5)
        XCTAssertGreaterThan(pixel(inA, x: 0.5, y: 0.5).r, 200)
        let inB = try frame(of: built.composition, video, at: timeline.editedDuration - 0.3)
        let centre = pixel(inB, x: 0.5, y: 0.5)
        XCTAssertGreaterThan(centre.b, 200)
        XCTAssertLessThan(centre.r, 60)
        let bar = pixel(inB, x: 0.05, y: 0.5)
        XCTAssertLessThan(bar.b + bar.r + bar.g, 60)

        // One crop (right half) applies to the whole sequence.
        let crop = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let cropped = try XCTUnwrap(EditComposition.videoComposition(for: built, crop: crop))
        XCTAssertEqual(cropped.renderSize, CGSize(width: 160, height: 180))
        let croppedA = try frame(of: built.composition, cropped, at: 0.5)
        XCTAssertGreaterThan(pixel(croppedA, x: 0.5, y: 0.5).r, 200)
        let croppedB = try frame(of: built.composition, cropped, at: timeline.editedDuration - 0.3)
        XCTAssertGreaterThan(pixel(croppedB, x: 0.2, y: 0.5).b, 200)
        let right = pixel(croppedB, x: 0.9, y: 0.5)
        XCTAssertLessThan(right.b + right.r + right.g, 60)
    }

    func testSpeedAcrossTheBoundaryShortensTheComposition() async throws {
        let a = try await makeClip(named: "a.mp4", size: CGSize(width: 320, height: 180), seconds: 2,
                                   red: 255, green: 0, blue: 0)
        let b = try await makeClip(named: "b.mp4", size: CGSize(width: 160, height: 160), seconds: 2,
                                   red: 0, green: 0, blue: 255)
        let segments = [
            EditSegment(id: UUID(), url: a, fileDuration: 2, srcStart: 0, srcEnd: 2),
            EditSegment(id: UUID(), url: b, fileDuration: 2, srcStart: 0, srcEnd: 2),
        ]
        let timeline = EditSequence(segments: segments)
            .timeline(cuts: [], speed: [EditSpeedSpan(start: 1, end: 3, factor: 2)])
        XCTAssertEqual(timeline.finalDuration, 3, accuracy: 1e-9)
        let built = try await EditComposition.build(urls: segments.map(\.url), pieces: timeline.pieces,
                                                    speed: timeline.speedRanges)
        XCTAssertEqual(built.composition.duration.seconds, 3, accuracy: 0.05)
        // The second clip starts at edited 2 s: 1 s plain, then 1 s at 2x = 1.5 s.
        XCTAssertEqual(built.placements[1].start, 1.5, accuracy: 0.05)
    }

    func testWholeFileItemKeepsTimelineTime() async throws {
        let a = try await makeClip(named: "a.mp4", size: CGSize(width: 320, height: 180), seconds: 1,
                                   red: 255, green: 0, blue: 0)
        let b = try await makeClip(named: "b.mp4", size: CGSize(width: 160, height: 160), seconds: 2,
                                   red: 0, green: 0, blue: 255)
        let built = try await EditComposition.build(
            urls: [a, b], pieces: EditComposition.wholeFilePieces(fileDurations: [1, 2]))
        XCTAssertEqual(built.composition.duration.seconds, 3, accuracy: 0.05)
        XCTAssertEqual(built.segmentIndex(at: 0.5), 0)
        XCTAssertEqual(built.segmentIndex(at: 1.5), 1)
    }

    func testExportedFileHasTheExpectedLength() async throws {
        let a = try await makeClip(named: "a.mp4", size: CGSize(width: 320, height: 180), seconds: 2,
                                   red: 255, green: 0, blue: 0)
        let b = try await makeClip(named: "b.mp4", size: CGSize(width: 160, height: 160), seconds: 2,
                                   red: 0, green: 0, blue: 255)
        let segments = [
            EditSegment(id: UUID(), url: a, fileDuration: 2, srcStart: 0, srcEnd: 2),
            EditSegment(id: UUID(), url: b, fileDuration: 2, srcStart: 0, srcEnd: 2),
        ]
        let timeline = EditSequence(segments: segments).timeline(
            cuts: [(1.5, 2.5)], speed: [EditSpeedSpan(start: 3, end: 4, factor: 2)])
        let built = try await EditComposition.build(urls: segments.map(\.url), pieces: timeline.pieces,
                                                    speed: timeline.speedRanges)
        let video = try XCTUnwrap(EditComposition.videoComposition(for: built, crop: nil))
        let session = try XCTUnwrap(AVAssetExportSession(asset: built.composition,
                                                         presetName: AVAssetExportPresetMediumQuality))
        session.videoComposition = video
        let output = directory.appendingPathComponent("out.mp4")
        try await session.export(to: output, as: .mp4)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(timeline.finalDuration, 3 - 0.5, accuracy: 1e-9)
        XCTAssertEqual(duration, timeline.finalDuration, accuracy: 0.15)
    }

    /// The preview's effects handler (EffectsRenderer.previewComposition) puts
    /// each clip on the canvas itself, so it relies on a handler composition
    /// handing it every clip's frame at that clip's own size, origin at zero.
    func testHandlerCompositionSeesEachClipAtItsOwnSize() async throws {
        let a = try await makeClip(named: "a.mp4", size: CGSize(width: 320, height: 180), seconds: 1,
                                   red: 255, green: 0, blue: 0)
        let b = try await makeClip(named: "b.mp4", size: CGSize(width: 160, height: 160), seconds: 1,
                                   red: 0, green: 0, blue: 255)
        let built = try await EditComposition.build(
            urls: [a, b], pieces: EditComposition.wholeFilePieces(fileDurations: [1, 1]))
        final class Extents: @unchecked Sendable {
            var seen: [CGRect] = []
            let lock = NSLock()
        }
        let extents = Extents()
        let handler = AVMutableVideoComposition(asset: built.composition) { request in
            extents.lock.lock()
            if request.compositionTime.seconds > 1.2 { extents.seen.append(request.sourceImage.extent) }
            extents.lock.unlock()
            request.finish(with: request.sourceImage, context: nil)
        }
        handler.renderSize = CGSize(width: 320, height: 180)
        _ = try frame(of: built.composition, handler, at: 1.5)
        XCTAssertEqual(extents.seen.first, CGRect(x: 0, y: 0, width: 160, height: 160))
    }
}
