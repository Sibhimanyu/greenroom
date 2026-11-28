#if DEBUG
import Foundation
import ZoomSDK

/// Probe A of the meeting-audio investigation (2026-11-27): can Greenroom get the
/// other people's voices as Zoom raw audio? Subscribes to the raw audio helper at
/// InMeeting and logs, in plain words, what comes back. It only LOGS: nothing it
/// receives is recorded or played. Debug builds only (the whole file is compiled
/// out of Release). Also starts the ScreenCaptureKit probes (`OwnAudioProbe`).
///
/// Every line starts "Audio probe:" in ~/Library/Logs/Greenroom-session.log.
final class MeetingAudioProbe: NSObject, ZoomSDKAudioRawDataDelegate {
    static let shared = MeetingAudioProbe()

    private static let windowSeconds = 30
    private static let tickSeconds = 5
    private static let maxSubscribeTries = 4

    // Touched from the SDK's callback threads and the timer queue: always under `lock`.
    private let lock = NSLock()
    private var helper: ZoomSDKAudioRawDataHelper?
    private var subscribed = false
    private var running = false
    private var logging = false
    private var tries = 0
    private var ticks = 0
    private var mixedCount = 0
    private var mixedRate: UInt32 = 0
    private var mixedChannels: UInt32 = 0
    private var mixedMeter = AudioLevelMeter()
    private var oneWay: [UInt32: (count: Int, meter: AudioLevelMeter)] = [:]
    private var shareCount = 0
    private var timer: DispatchSourceTimer?

    static func log(_ message: String) {
        ZoomMeetingSDKClient.logLicenceLine("Audio probe: \(message)")
    }

    /// Called when the meeting goes InMeeting. Safe to call again (reconnects).
    func start() {
        guard AudioProbeSwitch.enabled else { return }
        lock.lock()
        if running { lock.unlock(); return }
        running = true; logging = true; ticks = 0; tries = 0
        mixedCount = 0; mixedMeter.reset(); oneWay = [:]; shareCount = 0
        lock.unlock()

        Self.log("A (Zoom raw audio): meeting is live, trying to subscribe.")
        trySubscribe()
        OwnAudioProbe.shared.start()

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "greenroom.audio-probe"))
        t.schedule(deadline: .now() + .seconds(Self.tickSeconds), repeating: .seconds(Self.tickSeconds))
        t.setEventHandler { [weak self] in self?.tick() }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }

    /// Called at Disconnecting / Ended / Failed.
    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false; logging = false
        let t = timer; timer = nil
        let h = helper; let wasSubscribed = subscribed
        helper = nil; subscribed = false
        lock.unlock()
        t?.cancel()
        if wasSubscribed, let h {
            let r = h.unSubscribe()
            Self.log("A: unsubscribed at meeting end (\(Self.describe(r))).")
        }
        OwnAudioProbe.shared.stop()
    }

    private static func describe(_ r: ZoomSDKError) -> String {
        "\(ZoomMeetingSDKClient.errorName(r)) = \(r.rawValue)"
    }

    private func trySubscribe() {
        lock.lock(); tries += 1; let attempt = tries; lock.unlock()
        guard let controller = ZoomSDK.shared().getRawDataController() else {
            Self.log("A: subscribe attempt \(attempt): the SDK gave no raw data controller.")
            return
        }
        let licence = controller.hasRawDataLicense()
        Self.log("A: raw data licence check: \(licence == ZoomSDKError_Success ? "yes" : "no (\(Self.describe(licence)))").")
        var h: ZoomSDKAudioRawDataHelper?
        let got = controller.getAudioRawDataHelper(&h)
        guard got == ZoomSDKError_Success, let h else {
            Self.log("A: subscribe attempt \(attempt): could not get the audio helper (\(Self.describe(got))).")
            return
        }
        h.delegate = self
        lock.lock(); helper = h; lock.unlock()
        let r = h.subscribe()
        if r == ZoomSDKError_Success {
            lock.lock(); subscribed = true; lock.unlock()
            Self.log("A: subscribe attempt \(attempt): SUBSCRIBED (\(Self.describe(r))). Waiting for audio.")
        } else {
            Self.log("A: subscribe attempt \(attempt): REFUSED (\(Self.describe(r))).")
        }
    }

    private func tick() {
        lock.lock()
        ticks += 1
        let n = ticks
        let isSubscribed = subscribed
        let needRetry = !isSubscribed && tries < Self.maxSubscribeTries
        let stillLogging = logging
        lock.unlock()
        guard stillLogging else { return }
        if needRetry { trySubscribe() }
        if isSubscribed { report(second: n * Self.tickSeconds) }
        if n * Self.tickSeconds >= Self.windowSeconds {
            lock.lock(); logging = false; timer?.cancel(); timer = nil; lock.unlock()
            Self.log("A: 30 s window over; staying subscribed, no more logging.")
        }
    }

    private func report(second: Int) {
        lock.lock()
        let count = mixedCount, rate = mixedRate, ch = mixedChannels
        let mixed = mixedMeter
        let users = oneWay
        let shares = shareCount
        mixedCount = 0; mixedMeter.reset()
        for k in oneWay.keys { oneWay[k] = (0, AudioLevelMeter()) }
        lock.unlock()
        var line = "A @\(second)s: mixed callbacks \(count)"
        if count > 0 { line += ", \(rate) Hz, \(ch) ch, \(mixed.summary)" }
        line += "; one-way users \(users.count)"
        for (id, u) in users.sorted(by: { $0.key < $1.key }) {
            line += " [user \(id): \(u.count) callbacks, \(u.meter.summary)]"
        }
        if shares > 0 { line += "; share-audio callbacks so far \(shares)" }
        Self.log(line)
    }

    private static func int16(_ data: ZoomSDKAudioRawData, into meter: inout AudioLevelMeter) {
        guard let buf = data.getBuffer() else { return }
        let n = Int(data.getBufferLen()) / MemoryLayout<Int16>.size
        buf.withMemoryRebound(to: Int16.self, capacity: n) {
            meter.add(int16: UnsafeBufferPointer(start: $0, count: n))
        }
    }

    // MARK: ZoomSDKAudioRawDataDelegate (SDK threads)

    func onMixedAudioRawDataReceived(_ data: ZoomSDKAudioRawData?) {
        guard let data else { return }
        lock.lock(); defer { lock.unlock() }
        guard logging else { return }
        mixedCount += 1
        mixedRate = data.getSampleRate(); mixedChannels = data.getChannelNum()
        Self.int16(data, into: &mixedMeter)
    }

    func onOneWayAudioRawDataReceived(_ data: ZoomSDKAudioRawData?, userID: UInt32) {
        guard let data else { return }
        lock.lock(); defer { lock.unlock() }
        guard logging else { return }
        var entry = oneWay[userID] ?? (0, AudioLevelMeter())
        entry.count += 1
        Self.int16(data, into: &entry.meter)
        oneWay[userID] = entry
    }

    func onOneWayAudioRawDataReceived(_ data: ZoomSDKAudioRawData?, nodeID: UInt32) {}

    func onShareAudioRawDataReceived(_ data: ZoomSDKAudioRawData?) {
        lock.lock(); shareCount += 1; lock.unlock()
    }

    func onShareAudioRawDataReceived(_ data: ZoomSDKAudioRawData?, userID: UInt32) {
        lock.lock(); shareCount += 1; lock.unlock()
    }

    func onOneWayInterpreterAudioRawDataReceived(_ data: ZoomSDKAudioRawData, strLanguageName languageName: String) {}
}
#endif
