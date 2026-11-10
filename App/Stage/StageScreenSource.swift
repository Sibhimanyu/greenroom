//
//  StageScreenSource.swift
//  Greenroom
//
//  One ScreenCaptureKit stream: a whole display, one app, or one window, the
//  three things `ShareTarget` can name. Replaces OBS's screen_capture source.
//
//  Patterns are ScreenroomScreenEngine's: complete frames only, BGRA, audio
//  off. Audio off is not tidiness: it is the setting OBS needed to stop its
//  own ScreenCaptureKit crash, and Greenroom has no use for system audio.
//
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

final class StageScreenSource: NSObject, SCStreamOutput, SCStreamDelegate {

    enum Target {
        case display
        case app(bundleID: String)
        case window(id: CGWindowID)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    let id = UUID()
    let target: Target
    let displayUUID: String
    /// A whole display fills its box; an app or window is fitted with a margin.
    var wholeDisplay: Bool { if case .display = target { return true } else { return false } }

    /// Called on the capture queue with each complete frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called when macOS ends the stream under us (-3805 and friends).
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "greenroom.stage.screen", qos: .userInteractive)
    private let maxSize: CGSize

    init(target: Target, displayUUID: String, maxSize: CGSize) {
        self.target = target
        self.displayUUID = displayUUID
        self.maxSize = maxSize
    }

    static let permissionMessage = "Greenroom can\u{2019}t record the screen yet. Allow it in System Settings \u{2192} Privacy & Security \u{2192} Screen & System Audio Recording, then press Start again."

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Failure(errorDescription: Self.permissionMessage)
        }
        guard let display = content.displays.first(where: {
            LocalDeviceResolver.uuid(for: $0.displayID) == displayUUID
        }) ?? content.displays.first else {
            throw Failure(errorDescription: "No screen was found to share.")
        }

        let filter: SCContentFilter
        switch target {
        case .display:
            // Greenroom's own windows stay out of the class picture, as in
            // Screenroom: the rail and notes bar are on this screen.
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        case .app(let bundleID):
            guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
                throw Failure(errorDescription: "That app isn\u{2019}t open on this screen.")
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw Failure(errorDescription: "That window has gone. Pick another one.")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let configuration = SCStreamConfiguration()
        // Pixel size of the content, shrunk (never enlarged) to fit the canvas.
        let size = filter.contentRect.size
        let scale = max(1, CGFloat(filter.pointPixelScale))
        let nativeW = size.width * scale, nativeH = size.height * scale
        let fit = min(1, maxSize.width / max(nativeW, 1), maxSize.height / max(nativeH, 1))
        configuration.width = max(2, Int((nativeW * fit).rounded()) & ~1)
        configuration.height = max(2, Int((nativeH * fit).rounded()) & ~1)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.backgroundColor = .clear
        configuration.ignoreShadowsSingleWindow = true      // show_shadow: false
        configuration.queueDepth = 4

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        do { try await stream.startCapture() } catch {
            throw Failure(errorDescription: Self.permissionMessage)
        }
        self.stream = stream
    }

    func stop() {
        let existing = stream
        stream = nil
        onFrame = nil
        onStop = nil
        Task { try? await existing?.stopCapture() }
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixels)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
