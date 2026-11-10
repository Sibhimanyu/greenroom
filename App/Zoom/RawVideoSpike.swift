#if DEBUG
import Foundation
import CoreGraphics
import CoreText
import ZoomSDK

/// Piece 0 of docs/drop-obs-plan.md, step 2: a throwaway test pattern pushed
/// into the meeting through `setExternalVideoSource`, to learn whether the SDK
/// accepts raw frames from us and at what size and frame rate.
///
/// DEBUG builds only, and only when the UserDefaults bool
/// `GreenroomRawVideoSpike` is YES. It is removed or replaced by
/// `ZoomVideoSender` in piece 2 of the plan. Every line it logs starts with
/// "Raw video spike:" and goes to the session log and to os_log.
///
/// The SDK header says nothing about ordering, but the source has to be
/// registered before the camera starts, so we install it right after auth,
/// before any join or start. `sendRawData` returns void, so there is no
/// return code to log; we log the first send and a running count instead.
final class RawVideoSpike: NSObject, ZoomSDKVirtualVideoSourceDelegate {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "GreenroomRawVideoSpike") }

    private let queue = DispatchQueue(label: "greenroom.rawvideospike")
    private var timer: DispatchSourceTimer?
    private var sender: ZoomSDKRawDataSender?
    private var width = 640
    private var height = 360
    private var fps = 30
    private var frameCount = 0
    private var sentCount = 0
    private var startedAt = Date()
    private var rgb = [UInt8]()
    private var i420 = [UInt8]()

    static func log(_ message: String) {
        ZoomMeetingSDKClient.logLicenceLine("Raw video spike: \(message)")
    }

    private static func describe(_ list: [Any]?) -> String {
        guard let list, !list.isEmpty else { return "(none)" }
        return list.compactMap { $0 as? ZoomSDKVideoCapabilityItem }
            .map { "\($0.getWidth())x\($0.getHeight())@\($0.getFrame())" }
            .joined(separator: ", ")
    }

    // MARK: ZoomSDKVirtualVideoSourceDelegate

    func onInitialize(_ sender: ZoomSDKRawDataSender?, supportedCapabilityList capabilityList: [Any]?, suggestCapability suggestCap: ZoomSDKVideoCapabilityItem?) {
        queue.sync { self.sender = sender }
        Self.log("onInitialize, sender \(sender == nil ? "MISSING" : "present").")
        for case let cap as ZoomSDKVideoCapabilityItem in capabilityList ?? [] {
            Self.log("supported capability \(cap.getWidth())x\(cap.getHeight()) at \(cap.getFrame()) fps")
        }
        if let s = suggestCap {
            Self.log("suggested capability \(s.getWidth())x\(s.getHeight()) at \(s.getFrame()) fps")
            queue.sync {
                width = Int(s.getWidth()) & ~1
                height = Int(s.getHeight()) & ~1
                fps = max(1, Int(s.getFrame()))
            }
        } else {
            Self.log("no suggested capability; falling back to 640x360 at 30 fps")
        }
    }

    func onPropertyChange(_ supportedCapabilityList: [Any]?, suggestCapability suggestCap: ZoomSDKVideoCapabilityItem?) {
        Self.log("capabilities changed: \(Self.describe(supportedCapabilityList)); suggested \(suggestCap.map { "\($0.getWidth())x\($0.getHeight())@\($0.getFrame())" } ?? "none")")
    }

    func onStartSend() {
        Self.log("start-send: the SDK wants frames now.")
        queue.async { [self] in
            timer?.cancel()
            frameCount = 0
            sentCount = 0
            startedAt = Date()
            rgb = [UInt8](repeating: 0, count: width * height * 4)
            i420 = [UInt8](repeating: 0, count: width * height * 3 / 2)
            Self.log("drawing \(width)x\(height) at \(fps) fps, I420 limited range.")
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
            t.setEventHandler { [weak self] in self?.tick() }
            timer = t
            t.resume()
        }
    }

    func onStopSend() {
        Self.log("stop-send: stopping the timer after \(queue.sync { sentCount }) frames.")
        queue.async { [self] in timer?.cancel(); timer = nil }
    }

    func onUninitialize() {
        Self.log("uninitialize: the SDK let go of the source.")
        queue.async { [self] in timer?.cancel(); timer = nil; sender = nil }
    }

    // MARK: Drawing (on `queue`)

    private func tick() {
        guard let sender else { return }
        let w = width, h = height
        drawPattern(w: w, h: h)
        convertToI420(w: w, h: h)
        let length = UInt32(i420.count)
        i420.withUnsafeMutableBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            sender.sendRawData(p, width: UInt32(w), height: UInt32(h), dataLength: length, rotation: ZoomSDKLOCAL_DEVICE_ROTATION_ACTION_0)
        }
        sentCount += 1
        if sentCount == 1 { Self.log("first frame handed to sendRawData (it returns nothing, so no error code exists).") }
        if sentCount % (fps * 10) == 0 { Self.log("\(sentCount) frames sent so far.") }
        frameCount += 1
    }

    private func drawPattern(w: Int, h: Int) {
        rgb.withUnsafeMutableBytes { raw in
            let space = CGColorSpaceCreateDeviceRGB()
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return }
            // Solid dark blue background.
            ctx.setFillColor(CGColor(red: 0.05, green: 0.15, blue: 0.45, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Bright bar sweeping left to right once per second.
            let phase = Double(frameCount % fps) / Double(fps)
            let barW = CGFloat(w) / 12
            ctx.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(phase) * CGFloat(w - Int(barW)), y: 0, width: barW, height: CGFloat(h)))
            // Big frame counter, then resolution and wall clock.
            drawText("\(frameCount)", size: CGFloat(h) / 3, x: CGFloat(w) * 0.06, y: CGFloat(h) * 0.42, ctx: ctx)
            let clock = Self.clockFormatter.string(from: Date())
            drawText("\(w)x\(h)  \(clock)", size: CGFloat(h) / 12, x: CGFloat(w) * 0.06, y: CGFloat(h) * 0.12, ctx: ctx)
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func drawText(_ text: String, size: CGFloat, x: CGFloat, y: CGFloat, ctx: CGContext) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs as [NSAttributedString.Key: Any]))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
    }

    /// BGRA (little-endian premultiplied first) to planar I420, BT.601 limited
    /// range. The context origin is bottom-left, so rows are flipped on the way.
    private func convertToI420(w: Int, h: Int) {
        rgb.withUnsafeBufferPointer { src in
            i420.withUnsafeMutableBufferPointer { dst in
                let uOff = w * h, vOff = w * h + (w / 2) * (h / 2)
                for row in 0..<h {
                    let s = (h - 1 - row) * w * 4
                    for col in 0..<w {
                        let b = Int(src[s + col * 4]), g = Int(src[s + col * 4 + 1]), r = Int(src[s + col * 4 + 2])
                        dst[row * w + col] = UInt8(clamping: ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16)
                        if row & 1 == 0 && col & 1 == 0 {
                            let ci = (row / 2) * (w / 2) + col / 2
                            dst[uOff + ci] = UInt8(clamping: ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128)
                            dst[vOff + ci] = UInt8(clamping: ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128)
                        }
                    }
                }
            }
        }
    }
}
#endif
