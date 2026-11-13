//
//  StageScreenSource.swift
//  Greenroom
//
//  One ScreenCaptureKit stream: a whole display, one app, or one window, the
//  three things `ShareTarget` can name.
//
//  Complete frames only, BGRA. Audio is off unless `captureAudio` is set (the
//  recorder's "Record the Mac's sound"): then the stream also delivers the
//  sound of what it captures (the display's, the app's or the window's app's)
//  to `onAudio`, with Greenroom's own sound left out so the meeting is not
//  recorded twice.
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
    /// Called on the capture queue with each buffer of the Mac's sound
    /// (48 kHz stereo Float32, host-clock stamps). Only when `captureAudio`.
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// Called when macOS ends the stream under us (-3805 and friends).
    var onStop: ((Error) -> Void)?
    /// Called once, on a background queue, when a window capture has shown no
    /// complete frame 3 s after starting. Plain words for the person.
    var onNoPicture: ((String) -> Void)?

    private var stream: SCStream?   // under stateLock
    private let queue = DispatchQueue(label: "greenroom.stage.screen", qos: .userInteractive)
    private let maxSize: CGSize
    let captureAudio: Bool

    init(target: Target, displayUUID: String, maxSize: CGSize, captureAudio: Bool = false) {
        self.target = target
        self.displayUUID = displayUUID
        self.maxSize = maxSize
        self.captureAudio = captureAudio
    }

    /// Shows macOS's own prompt the first time. After a refusal macOS never
    /// prompts again, so the Screen Recording pane is opened instead - the
    /// only place the answer can be changed.
    @MainActor static func askForPermission() {
        if CGRequestScreenCaptureAccess() { return }
        if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(pane)
        }
    }

    static let permissionMessage = "Greenroom can\u{2019}t record the screen yet. Allow it in System Settings \u{2192} Privacy & Security \u{2192} Screen & System Audio Recording, then quit and reopen Greenroom."

    // MARK: Log

    /// One plain line in the session log, the one the coordinator writes.
    /// Never per frame.
    static func log(_ line: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { CoordinatorController.sessionLog("Screen: " + line) }
        }
    }

    /// "That went wrong (code -3805)": the real error, in words.
    static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.localizedDescription) (code \(e.code), \(e.domain))"
    }

    // MARK: Permission

    private static let paneLock = NSLock()
    private static var paneOpened = false

    /// Opens Screen Recording in System Settings, the first time in a launch
    /// only. Callers do it for something the person just did (Start, or
    /// choosing a screen-based tile), never from merely showing Settings.
    @discardableResult
    static func openPermissionPaneOnce() -> Bool {
        paneLock.lock()
        let first = !paneOpened
        paneOpened = true
        paneLock.unlock()
        guard first else { return false }
        log("Screen Recording is off for Greenroom; opening System Settings. Turn Greenroom on there, then quit and reopen it.")
        DispatchQueue.main.async {
            if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(pane)
            }
        }
        return true
    }

    /// A real permission problem: Screen Recording is off, or ScreenCaptureKit
    /// says the person declined (-3801). Anything else is something else.
    static func isPermissionProblem(_ error: Error) -> Bool {
        if !CGPreflightScreenCaptureAccess() { return true }
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.Code.userDeclined.rawValue
    }

    private static func failure(for error: Error, doing what: String) -> Failure {
        if isPermissionProblem(error) {
            log("\(what) refused: \(describe(error)). Screen Recording is not allowed for this launch.")
            return Failure(errorDescription: permissionMessage)
        }
        log("\(what) failed: \(describe(error)).")
        return Failure(errorDescription: "The screen capture couldn\u{2019}t start: \(error.localizedDescription) (code \((error as NSError).code)).")
    }

    private var targetText: String {
        switch target {
        case .display: return "whole screen"
        case .app(let id): return "app \(id)"
        case .window(let id): return "window \(id)"
        }
    }

    // MARK: Start / stop

    private let stateLock = NSLock()
    private var stopReason: String?
    private var sawFirstFrame = false
    /// Set when the capture is of one window (a window share, or an app that
    /// is on another desktop), for the no-picture check.
    private var windowLabel: String?
    /// What the picture is OF, in global CoreGraphics points (top-left origin
    /// of the main display): the display's frame, or the window being
    /// followed. Set in `start()`; read by `capturedFrame()`.
    private var capturedDisplayFrame: CGRect?
    private var capturedWindowID: CGWindowID?

    /// The screen area the current picture shows, right now, in global
    /// CoreGraphics points. A window is looked up afresh each call, because
    /// it moves and resizes; nil when it has gone.
    /// The capture follows one window (a window share, or an app that is on
    /// another desktop), so its frame moves; false for a whole display.
    var followsWindow: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return capturedWindowID != nil
    }

    func capturedFrame() -> CGRect? {
        stateLock.lock()
        let windowID = capturedWindowID, display = capturedDisplayFrame
        stateLock.unlock()
        guard let windowID else { return display }
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    func start() async throws {
        let content: SCShareableContent
        do {
            // Every window, not only those on this Space: a full-screen or
            // other-Space window is "off screen" but the per-window filter
            // below follows it. Unusable ones are filtered by ScreenWindowRules.
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw Self.failure(for: error, doing: "Listing the screens")
        }
        guard let display = content.displays.first(where: {
            LocalDeviceResolver.uuid(for: $0.displayID) == displayUUID
        }) ?? content.displays.first else {
            Self.log("No display was found among \(content.displays.count).")
            throw Failure(errorDescription: "No screen was found to share.")
        }
        stateLock.lock(); capturedDisplayFrame = display.frame; stateLock.unlock()
        let displays = content.displays.enumerated().map { i, d in
            ScreenDisplayInfo(index: i + 1, frame: d.frame, isMain: d.displayID == CGMainDisplayID())
        }
        let displayInfo = displays.first { $0.frame == display.frame }
            ?? ScreenDisplayInfo(index: 1, frame: display.frame, isMain: true)
        Self.log("Capture requested: \(targetText), on display \(displayInfo.index) (\(display.width)\u{00D7}\(display.height))\(displayInfo.isMain ? ", the main one" : "").")

        let filter: SCContentFilter
        switch target {
        case .display:
            // Greenroom's own windows stay out of the class picture, the rail and notes bar are on this screen.
            let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            // Overlay panels made later (control bar, border, countdown) are
            // Greenroom's windows too, and are kept out only because the whole
            // app is excluded. If macOS does not list the app, say so.
            if own.isEmpty { Self.log("Greenroom is not in ScreenCaptureKit's application list, so its own windows are not excluded from this capture.") }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        case .app(let bundleID):
            filter = try appFilter(bundleID: bundleID, content: content, display: display,
                                   info: displayInfo, all: displays)
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                Self.log("Window \(windowID) is not in the list of \(content.windows.count) windows.")
                throw Failure(errorDescription: "That window has gone. Pick another one.")
            }
            guard ScreenWindowRules.isCapturable(layer: window.windowLayer, size: window.frame.size) else {
                Self.log("Window \(windowID) can\u{2019}t give a picture (layer \(window.windowLayer), \(Int(window.frame.width))\u{00D7}\(Int(window.frame.height))).")
                throw Failure(errorDescription: "That window can\u{2019}t be shared. Pick another one.")
            }
            windowLabel = Self.windowName(window)
            if !window.isOnScreen {
                Self.log("\(windowLabel ?? "The window") is on another desktop or full screen; following it there.")
            }
            stateLock.lock(); capturedWindowID = window.windowID; stateLock.unlock()
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
        Self.log("Filter is \(Int(size.width))\u{00D7}\(Int(size.height)) points; capturing \(configuration.width)\u{00D7}\(configuration.height) pixels.")
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = captureAudio
        if captureAudio {
            // Greenroom's and the meeting's own sound is already in the mix
            // from the meeting side; leave it out here so it is not doubled.
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }
        configuration.backgroundColor = .clear
        configuration.ignoreShadowsSingleWindow = true      // show_shadow: false
        configuration.queueDepth = 4

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if captureAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            try await stream.startCapture()
        } catch {
            throw Self.failure(for: error, doing: "Starting the capture")
        }
        // stop() may have come while the stream was starting. It had nothing to
        // stop yet, so it is stopped here rather than left running unseen.
        stateLock.lock()
        let early = stopReason
        if early == nil { self.stream = stream }
        stateLock.unlock()
        if let early {
            Self.log("Stopped as it finished starting (\(early)).")
            try? await stream.stopCapture()
            return
        }
        Self.log("Capture started: \(targetText).")
        if let label = windowLabel { watchForPicture(of: label) }
    }

    /// A window capture that delivers nothing is not retried; it is said.
    /// Whether ScreenCaptureKit keeps drawing a window on another desktop is
    /// the thing this tells us on a real Mac.
    private func watchForPicture(of label: String) {
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let seen = self.sawFirstFrame, stopped = self.stopReason != nil
            self.stateLock.unlock()
            guard !seen, !stopped else { return }
            Self.log("no picture from \(label) \u{2014} macOS isn\u{2019}t drawing it (minimised or on a desktop it won\u{2019}t capture)")
            self.onNoPicture?("\(label) isn\u{2019}t giving a picture. It may be minimised, or on a desktop macOS won\u{2019}t capture. Bring it forward, or pick another window.")
        }
    }

    private static func windowName(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "A window"
        guard let title = w.title, !title.isEmpty else { return app }
        return "\(app) \u{2013} \(title)"
    }

    private func appFilter(bundleID: String, content: SCShareableContent, display: SCDisplay,
                           info: ScreenDisplayInfo, all: [ScreenDisplayInfo]) throws -> SCContentFilter {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        let pids = Set(running.map(\.processIdentifier))
        let infos = content.windows.map {
            ScreenWindowInfo(id: $0.windowID, pid: $0.owningApplication?.processID ?? 0,
                             bundleID: $0.owningApplication?.bundleIdentifier, frame: $0.frame,
                             layer: $0.windowLayer, onScreen: $0.isOnScreen)
        }
        let verdict = ScreenAppMatch.match(bundleID: bundleID, pids: pids, windows: infos,
                                           display: info, allDisplays: all,
                                           ownPID: ProcessInfo.processInfo.processIdentifier)
        let name = running.first?.localizedName ?? bundleID
        let listed = content.applications.first { $0.bundleIdentifier == bundleID }
            ?? content.applications.first { pids.contains($0.processID) }
        Self.log("App \(bundleID): \(running.isEmpty ? "not running" : "running as pid \(pids.sorted())"); "
                 + "ScreenCaptureKit \(listed == nil ? "does not list it" : "lists it"); windows: \(verdict).")

        switch verdict {
        case .elsewhere(let windowID, let onScreen):
            // Full screen on its own desktop, or only on another desktop or
            // display: a display filter would show nothing, so follow its
            // main window instead.
            if let window = content.windows.first(where: { $0.windowID == windowID }) {
                windowLabel = Self.windowName(window)
                Self.log("\(name) is on \(onScreen ? "another display" : "another desktop"); showing its main window.")
                stateLock.lock(); capturedWindowID = window.windowID; stateLock.unlock()
                return SCContentFilter(desktopIndependentWindow: window)
            }
        case .windows(let ids):
            if let listed {
                return SCContentFilter(display: display, including: [listed], exceptingWindows: [])
            }
            let chosen = content.windows.filter { ids.contains($0.windowID) }
            return SCContentFilter(display: display, including: chosen)
        case .noWindows:
            break
        }
        if running.isEmpty {
            throw Failure(errorDescription: "\(name) isn\u{2019}t open.")
        }
        throw Failure(errorDescription: "\(name) is open but has no window that can be shared. Bring a window forward, then try again.")
    }

    /// Stops the stream. `reason` goes in the log: who did it, and why.
    func stop(because reason: String) {
        stateLock.lock()
        let existing = stream
        stream = nil
        if stopReason == nil { stopReason = reason }
        stateLock.unlock()
        onFrame = nil
        onAudio = nil
        onStop = nil
        Self.log("Capture stopped: \(targetText), \(reason).")
        Task { try? await existing?.stopCapture() }
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .audio {
            if sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0 { onAudio?(sampleBuffer) }
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        stateLock.lock()
        let first = !sawFirstFrame
        sawFirstFrame = true
        stateLock.unlock()
        if first {
            Self.log("First frame: \(targetText), \(CVPixelBufferGetWidth(pixels))\u{00D7}\(CVPixelBufferGetHeight(pixels)).")
        }
        onFrame?(pixels)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Self.log("macOS ended the capture: \(targetText), \(Self.describe(error)).")
        onStop?(error)
    }

    deinit { Self.log("Capture released: \(targetText).") }
}
