#if DEBUG
import Foundation
import Accelerate
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
/// What the first live run taught us: the SDK suggests 1920x1080@25 at init,
/// then about 4 s later changes its mind (320x180 and 640x480 at 25, with
/// 640x480 suggested). So the spike follows `onPropertyChange` and re-sizes
/// without ever telling the SDK to stop. The first version also only managed
/// about 4 fps, because it redrew and converted every pixel in Swift loops.
/// Now the static picture is drawn once per size, each frame copies it and
/// draws only the bar, counter and clock, and vImage does the I420 conversion.
///
/// `sendRawData` returns void, so there is no return code to log; the
/// achieved fps and per-frame cost are logged every 5 seconds instead.
final class RawVideoSpike: NSObject, ZoomSDKVirtualVideoSourceDelegate {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "GreenroomRawVideoSpike") }

    /// True while the SDK has asked for frames and we are drawing them.
    var isSending: Bool { queue.sync { sending } }

    // Everything below is touched only on `queue`.
    private let queue = DispatchQueue(label: "greenroom.rawvideospike", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var sender: ZoomSDKRawDataSender?
    private var sending = false
    private var width = 640
    private var height = 360
    private var fps = 30

    private var frameCount = 0
    private var statFrames = 0
    private var statStart = DispatchTime.now().uptimeNanoseconds
    private var statTotalNs: UInt64 = 0
    private var statWorstNs: UInt64 = 0
    private var totalSent = 0

    private var base: UnsafeMutableRawPointer?   // static picture, BGRA
    private var work: UnsafeMutableRawPointer?   // base plus the moving parts
    private var yuv: UnsafeMutableRawPointer?    // I420, w*h*3/2
    private var ctx: CGContext?
    private var convertInfo = vImage_ARGBToYpCbCr()
    private var haveConvertInfo = false

    static func log(_ message: String) {
        ZoomMeetingSDKClient.logLicenceLine("Raw video spike: \(message)")
    }

    private static func describe(_ c: ZoomSDKVideoCapabilityItem) -> String {
        "\(c.getWidth())x\(c.getHeight())@\(c.getFrame())"
    }

    // MARK: ZoomSDKVirtualVideoSourceDelegate

    func onInitialize(_ sender: ZoomSDKRawDataSender?, supportedCapabilityList capabilityList: [Any]?, suggestCapability suggestCap: ZoomSDKVideoCapabilityItem?) {
        Self.log("onInitialize, sender \(sender == nil ? "MISSING" : "present").")
        for case let cap as ZoomSDKVideoCapabilityItem in capabilityList ?? [] {
            Self.log("supported capability \(Self.describe(cap)) fps")
        }
        Self.log("suggested capability \(suggestCap.map(Self.describe) ?? "none; falling back to 640x360@30")")
        let size = Self.size(of: suggestCap)
        queue.async { [self] in
            self.sender = sender
            apply(size, reason: "initial size")
        }
    }

    func onPropertyChange(_ supportedCapabilityList: [Any]?, suggestCapability suggestCap: ZoomSDKVideoCapabilityItem?) {
        let list = (supportedCapabilityList ?? []).compactMap { $0 as? ZoomSDKVideoCapabilityItem }.map(Self.describe)
        Self.log("capabilities changed: \(list.isEmpty ? "(none)" : list.joined(separator: ", ")); suggested \(suggestCap.map(Self.describe) ?? "none")")
        guard suggestCap != nil else { return }
        let size = Self.size(of: suggestCap)
        queue.async { [self] in apply(size, reason: "the SDK changed its suggestion") }
    }

    func onStartSend() {
        Self.log("start-send: the SDK wants frames now.")
        queue.async { [self] in
            sending = true
            startTimer()
        }
    }

    func onStopSend() {
        queue.async { [self] in
            Self.log("stop-send: stopping the timer after \(totalSent) frames.")
            sending = false
            timer?.cancel(); timer = nil
        }
    }

    func onUninitialize() {
        queue.async { [self] in
            Self.log("uninitialize: the SDK let go of the source.")
            sending = false
            timer?.cancel(); timer = nil
            sender = nil
            freeBuffers()
        }
    }

    // MARK: Size changes (on `queue`)

    private static func size(of cap: ZoomSDKVideoCapabilityItem?) -> (Int, Int, Int) {
        guard let cap else { return (640, 360, 30) }
        return (max(2, Int(cap.getWidth()) & ~1), max(2, Int(cap.getHeight()) & ~1), max(1, Int(cap.getFrame())))
    }

    /// Adopt a new size and rate. Buffers and timer are rebuilt; the SDK is
    /// never told to stop, and if it was already asking for frames we carry on.
    private func apply(_ s: (Int, Int, Int), reason: String) {
        if s.0 == width && s.1 == height && s.2 == fps && base != nil { return }
        if base != nil {
            Self.log("switching from \(width)x\(height)@\(fps) to \(s.0)x\(s.1)@\(s.2) (\(reason)).")
        }
        (width, height, fps) = s
        buildBuffers()
        if sending { startTimer() }
    }

    private func freeBuffers() {
        ctx = nil
        base?.deallocate(); base = nil
        work?.deallocate(); work = nil
        yuv?.deallocate(); yuv = nil
    }

    /// Allocates the three buffers and draws the static picture once.
    private func buildBuffers() {
        freeBuffers()
        let bytes = width * height * 4
        base = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
        work = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
        yuv = UnsafeMutableRawPointer.allocate(byteCount: width * height * 3 / 2, alignment: 64)

        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // Draw the static layer into `base` first, through a context over it.
        if let c = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info) {
            c.setFillColor(CGColor(red: 0.05, green: 0.15, blue: 0.45, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: width, height: height))
            drawText("\(width)x\(height) @ \(fps) fps", size: CGFloat(height) / 14, x: CGFloat(width) * 0.06, y: CGFloat(height) * 0.84, in: c)
        }
        memcpy(work!, base!, bytes)
        ctx = CGContext(data: work, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)

        if !haveConvertInfo {
            // BT.601, 8-bit video range (Y 16...235, Cb/Cr 16...240).
            var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
            let err = vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4, &range, &convertInfo, kvImageARGB8888, kvImage420Yp8_Cb8_Cr8, vImage_Flags(kvImageNoFlags))
            haveConvertInfo = (err == kvImageNoError)
            if !haveConvertInfo { Self.log("vImage conversion setup failed (\(err)).") }
        }
        frameCount = 0
        resetStats()
    }

    private func resetStats() {
        statFrames = 0; statTotalNs = 0; statWorstNs = 0
        statStart = DispatchTime.now().uptimeNanoseconds
    }

    private func startTimer() {
        timer?.cancel()
        guard base != nil else { return }
        resetStats()
        Self.log("drawing \(width)x\(height) at \(fps) fps, I420 limited range, vImage conversion.")
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .microseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    // MARK: One frame (on `queue`)

    private func tick() {
        guard let sender, let work, let base, let yuv, let ctx, haveConvertInfo else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let w = width, h = height

        // Fresh copy of the static picture, then the three moving parts.
        memcpy(work, base, w * h * 4)
        let phase = Double(frameCount % fps) / Double(fps)
        let barW = CGFloat(w) / 12
        ctx.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: CGFloat(phase) * (CGFloat(w) - barW), y: 0, width: barW, height: CGFloat(h)))
        drawText("\(frameCount)", size: CGFloat(h) / 3, x: CGFloat(w) * 0.06, y: CGFloat(h) * 0.42, in: ctx)
        drawText(Self.clockFormatter.string(from: Date()), size: CGFloat(h) / 12, x: CGFloat(w) * 0.06, y: CGFloat(h) * 0.12, in: ctx)

        // BGRA in memory -> planar I420. Memory row 0 is the top of the picture.
        var src = vImage_Buffer(data: work, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
        var yBuf = vImage_Buffer(data: yuv, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
        var cbBuf = vImage_Buffer(data: yuv + w * h, height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2), rowBytes: w / 2)
        var crBuf = vImage_Buffer(data: yuv + w * h + (w / 2) * (h / 2), height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2), rowBytes: w / 2)
        var permute: [UInt8] = [3, 2, 1, 0] // BGRA -> ARGB
        vImageConvert_ARGB8888To420Yp8_Cb8_Cr8(&src, &yBuf, &cbBuf, &crBuf, &convertInfo, &permute, vImage_Flags(kvImageNoFlags))

        sender.sendRawData(yuv.assumingMemoryBound(to: CChar.self), width: UInt32(w), height: UInt32(h),
                           dataLength: UInt32(w * h * 3 / 2), rotation: ZoomSDKLOCAL_DEVICE_ROTATION_ACTION_0)

        let spent = DispatchTime.now().uptimeNanoseconds - t0
        frameCount += 1; totalSent += 1; statFrames += 1
        statTotalNs += spent; statWorstNs = max(statWorstNs, spent)
        if totalSent == 1 { Self.log("first frame handed to sendRawData (it returns nothing, so no error code exists).") }

        let elapsed = DispatchTime.now().uptimeNanoseconds - statStart
        if elapsed >= 5_000_000_000 {
            let secs = Double(elapsed) / 1e9
            let avg = Double(statTotalNs) / Double(statFrames) / 1e6
            let worst = Double(statWorstNs) / 1e6
            Self.log(String(format: "%dx%d: %.1f fps achieved (target %d), per frame avg %.1f ms, worst %.1f ms, %d frames in %.1f s.",
                            w, h, Double(statFrames) / secs, fps, avg, worst, statFrames, secs))
            resetStats()
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func drawText(_ text: String, size: CGFloat, x: CGFloat, y: CGFloat, in c: CGContext) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        c.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, c)
    }
}
#endif
