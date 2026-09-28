//
//  CameraDirector.swift
//  Greenroom
//
//  Two cameras, one shot, and nobody touching a switcher.
//
//  THE PROBLEM. A teacher with two monitors looks at the students on the
//  second one. The camera is on the first. To the class, the teacher spends
//  the whole hour looking off to the side at something more interesting than
//  them - and the teacher is in fact looking directly at their faces.
//
//  Moving the tile under the lens fixes this on one screen and cannot fix it
//  on two: the faces are on another piece of glass a foot away. Correcting
//  the gaze in software cannot fix it either, and it is worth saying why
//  rather than just leaving it out. Gaze correction warps the pixels of the
//  eye so the iris points at the lens; at thirty-odd degrees off axis there
//  is no front-facing eye left to warp - the camera is looking at the side of
//  a head. The published method says as much and fades itself off when the
//  head turns too far, which means it switches off exactly when it is wanted.
//
//  So: a second camera on the second monitor, and cut to whichever one the
//  teacher is facing. The angle is fixed by where the lens is, which is the
//  only thing that actually fixes it.
//
//  HOW THE DECISION IS MADE.
//
//  Every camera is open at once, one OBS source each, and only the live one
//  is shown - see GreenroomScene.ensureCameraInputs. So this can look through
//  all of them, and it compares them: the shot goes to whichever camera has
//  the teacher's face most head-on, once it has been clearly better than the
//  live one for the dwell. With three cameras it goes straight to the right
//  one instead of trying them in turn. See `Chooser`.
//
//  It used to be the other way round. One source had its device swapped
//  underneath it, so only one camera could be seen, and the director could
//  only say "this camera has lost you" and move to the next in the ring.
//  Every cut then waited for OBS to close one camera and open the other -
//  a freeze or a flash of black - and a further second and a half before
//  the new camera's picture could be trusted. That was most of why a cut
//  felt slow, and none of it is left.
//
//  The dwell is still what keeps it from hunting: nothing switches until
//  the other camera has seen the teacher face-on for `dwellSeconds`, so a
//  glance at a note costs nothing. Because the evidence is now positive it
//  can be much shorter than it was.
//
//  It still falls back to the old ring when no other camera can be seen at
//  all - see `Chooser`.
//
//  IT WATCHES THROUGH OBS, not through its own capture session. The frames
//  come from GetSourceScreenshot on each camera source, which is how the shape
//  preview already works. That avoids resting the whole feature on whether
//  macOS will hand the same camera to two processes at once - which it may
//  well do, but an architecture should not rest on a guess, and the unsigned
//  probe that would have settled it cannot get camera permission to run.
//
import AppKit
import AVFoundation
import Foundation
import Vision

struct CameraDirectorSettings: Codable, Equatable {

    /// Off until someone turns it on. A teacher with one camera must never
    /// discover this by having their picture cut somewhere else.
    var enabled: Bool = false

    /// The cameras to cut between, in order. The first is where a session
    /// starts and where it returns when nothing is working.
    ///
    /// AVFoundation uniqueIDs, which is what OBS's av_capture source speaks
    /// and what survives an unplug and replug - the same identifier
    /// LocalDeviceResolver hands out.
    var cameraUIDs: [String] = []

    /// How long another camera must have the teacher clearly more head-on
    /// than the live one before the shot moves.
    ///
    /// The failure modes either side are not symmetric. Too short and the
    /// shot cuts every time they glance at a note, which is unwatchable. Too
    /// long and they finish the sentence before the camera catches up, which
    /// is merely late. Late is better.
    ///
    /// One second, down from two. Two was set when the only evidence was
    /// "this camera has lost you", which a glance at a note also produces. A
    /// second camera actually seeing the teacher's face turned to it is much
    /// harder to fake by accident. Saved settings keep whatever they had.
    var dwellSeconds: Double = 1.0

    /// How far off the lens the settings window calls "looking at this
    /// camera", while a camera is being aimed.
    ///
    /// Only that. The switching itself compares the cameras against each
    /// other (see CameraDirector.Chooser) and has no fixed line, because
    /// where the angles fall depends on where each camera is mounted. For
    /// aiming, one number to get under is still the easiest instruction:
    /// twenty-five degrees, which a teacher reading the screen under the
    /// camera sits comfortably inside.
    var awayDegrees: Double = 25

    /// What the class sees at the moment the shot moves.
    var transition: CameraTransition = .cut

    static let key = "cameraDirectorSettings"

    /// Usable only when there is somewhere to cut TO.
    var isUsable: Bool { enabled && cameraUIDs.count >= 2 }

    /// The same settings with any camera that is not plugged in right now
    /// dropped.
    ///
    /// A camera uniqueID means nothing on another Mac, and these travel:
    /// Transfer carries them with everything else. Without this, a config
    /// exported from a two-camera desk and imported onto a laptop would hold
    /// two identifiers that match nothing, still read as usable, and cut the
    /// class to a camera that does not exist - a black picture with no
    /// explanation. Filtering makes a transferred config degrade to off.
    ///
    /// It also covers the ordinary case: somebody unplugged the second
    /// camera this morning.
    func availableOnly() -> CameraDirectorSettings {
        let present = Set(LocalDeviceResolver.availableCameras().map(\.id))
        var copy = self
        copy.cameraUIDs = cameraUIDs.filter { present.contains($0) }
        return copy
    }

    static func load(_ defaults: UserDefaults = .standard) -> CameraDirectorSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CameraDirectorSettings.self, from: data) else {
            return CameraDirectorSettings()
        }
        return decoded
    }

    func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// Decoded key by key, because the synthesized decoder refuses a whole value
/// over one missing key - and every settings blob saved before `transition`
/// existed is missing it. That would not have been a crash. It would have
/// been worse: `load` falls back to defaults, so adding a setting would have
/// quietly switched the feature off and forgotten which cameras were chosen,
/// on every Mac and in every exported config.
extension CameraDirectorSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CameraDirectorSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? fallback.enabled
        cameraUIDs = try container.decodeIfPresent([String].self, forKey: .cameraUIDs) ?? fallback.cameraUIDs
        dwellSeconds = try container.decodeIfPresent(Double.self, forKey: .dwellSeconds) ?? fallback.dwellSeconds
        awayDegrees = try container.decodeIfPresent(Double.self, forKey: .awayDegrees) ?? fallback.awayDegrees
        // An unknown case, from a newer build, is a cut rather than a failure.
        transition = (try? container.decodeIfPresent(CameraTransition.self, forKey: .transition))
            .flatMap { $0 } ?? fallback.transition
    }
}

enum CameraTransition: String, Codable, CaseIterable, Identifiable {
    /// Straight from one camera to the other, as a vision mixer does it.
    case cut
    /// A short dissolve, for anyone who finds a hard cut abrupt.
    case crossfade

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cut: return "Cut"
        case .crossfade: return "Crossfade"
        }
    }

    /// Half a second. Long enough to read as a dissolve rather than a
    /// glitch, short enough that the teacher is not two people for a whole
    /// word. It was four tenths while the fade stepped; with the steps
    /// smooth, the extra tenth is what lets the ease at each end show.
    var fadeSeconds: Double {
        switch self {
        case .cut: return 0
        case .crossfade: return 0.5
        }
    }
}

/// What a look at a camera actually found.
///
/// This replaced an `Optional<Double>`, and the reason is a bug that went
/// straight to the person who asked for the feature: with OBS not running
/// there was no frame to look at, the angle stayed nil, and the settings
/// window said "No face in this camera right now" to somebody sitting in
/// front of their camera with their face in it. One nil was carrying three
/// different failures - no picture, no face in the picture, and a face whose
/// angle Vision would not report - and only one of them was the one being
/// printed.
enum CameraSight: Equatable {
    /// Nothing is looking yet.
    case idle
    /// No picture arrived at all.
    case noPicture(String)
    /// A picture, with nobody in it.
    case noFace
    /// A face, but Vision would not give an angle for it. Rare, and worth
    /// saying rather than rounding to zero - zero means "looking right at
    /// you", which is the opposite of "I could not tell".
    case noAngle
    case seen(Double)

    var degrees: Double? {
        if case .seen(let value) = self { return value }
        return nil
    }
}

@MainActor
final class CameraDirector: ObservableObject {

    /// Which camera is live, by name, for the settings window to show. Nil
    /// when the director is not running.
    @Published private(set) var liveCameraName: String?

    /// What it last saw.
    @Published private(set) var sight: CameraSight = .idle

    var offAxisDegrees: Double? { sight.degrees }

    /// How long the current camera has been looked away from.
    @Published private(set) var awaySeconds: Double = 0

    /// Cuts made this session. The one number that says whether the feature
    /// did anything at all.
    @Published private(set) var cuts = 0

    /// A switch that is on its way, for the countdown bar over the self view.
    ///
    /// The dwell is the part of this feature a teacher cannot otherwise see:
    /// they turn to the other monitor and for a second nothing happens, which
    /// reads as "it didn't notice". Showing the second fill up says it did,
    /// and when it will act. Nil whenever nothing is counting down - including
    /// looking at the floor, where no camera has the teacher and nothing is
    /// going to switch.
    @Published private(set) var pendingSwitch: PendingSwitch?

    /// Every camera's smoothed angle to the teacher, by slot, nil where it
    /// sees no face. What the decision is actually made on, so the settings
    /// window can show both numbers side by side instead of only the live one.
    @Published private(set) var angles: [Double?] = []

    /// The camera names, by slot, for showing `angles` against.
    var cameraNamesInOrder: [String] { cameraNames }

    /// The status log. Set by the coordinator.
    var log: (String) -> Void = { _ in }

    /// The slot showing.
    var liveSlot: Int { live }

    struct PendingSwitch: Equatable {
        /// The camera it will switch to.
        var cameraName: String
        /// 0 to 1, of the dwell.
        var progress: Double
        /// The switch is happening now. The bar finishes and fades rather than
        /// draining, which is what a look that did not last looks like.
        var landed = false
    }

    /// How long one reading stands for, so a bar can glide to the next value
    /// instead of stepping three times a second.
    static let readingSeconds = Double(everyMs) / 1_000_000_000

    private var task: Task<Void, Never>?
    private var settings = CameraDirectorSettings()
    /// The slot showing, which is also the index into `settings.cameraUIDs`.
    private var live = 0
    private var cameraNames: [String] = []

    /// When to cut, and to where. See `Chooser`.
    private var chooser = Chooser(dwellSeconds: 1)

    /// Each camera's last screenshot, hashed. A live camera never produces
    /// the same JPEG twice - sensor noise alone sees to that - so a repeat
    /// means OBS is handing back a frozen frame. For a hidden camera that
    /// would be the worst possible reading: the face-on picture from the
    /// last time it was live, still "seeing" the teacher long after they
    /// turned away, pulling the shot back to it. A repeat counts as no
    /// picture, which drops the director to the blind ring rather than
    /// letting it trust a photograph.
    private var lastFrames: [Int: Int] = [:]

    /// Slots whose camera macOS says was unplugged, until it comes back.
    ///
    /// The screenshots alone do not always show it: OBS may hand back black
    /// rather than a frozen frame, and black reads as "nobody there", which
    /// the chooser rightly will not leave a camera for. macOS knows for
    /// certain, so its word turns the slot into no picture at once.
    private var unplugged: Set<Int> = []
    private var deviceObservers: [NSObjectProtocol] = []

    /// How often to look. A bit over three times a second: often enough that
    /// a one-second dwell is judged on three readings rather than two, and
    /// with a quarter-width screenshot per camera it is still nothing next to
    /// what the virtual camera itself moves over the socket.
    private static let everyMs: UInt64 = 300_000_000

    /// Long enough for the cameras to have opened at the start of a session.
    /// Judging sooner would read the black of a camera still starting up as
    /// "nobody there". Only at the start now: a cut goes to a camera that is
    /// already open and was seen with a face in it a moment ago.
    private static let settleSeconds: Double = 1.5

    // MARK: Running

    /// Starts watching. Safe to call when already running, and does nothing
    /// at all when the feature is off or there is only one camera.
    ///
    /// The camera sources must already match `requested` - Start builds them
    /// through ensureConfigured, and a change mid-class goes through
    /// GreenroomScene.setLiveCameras first. Either way slot 0 is showing.
    func start(client: OBSWebSocketClient, settings requested: CameraDirectorSettings) {
        stop()
        let settings = requested.availableOnly()
        guard settings.isUsable else { return }
        self.settings = settings
        live = 0
        lastFrames = [:]
        cameraNames = settings.cameraUIDs.enumerated().map { slot, uid in
            LocalDeviceResolver.cameraName(uid: uid) ?? "Camera \(slot + 1)"
        }
        chooser = Chooser(dwellSeconds: settings.dwellSeconds)
        unplugged = []
        watchDevices()
        cuts = 0
        awaySeconds = 0
        liveCameraName = cameraNames[0]
        task = Task { [weak self] in await self?.watch(client: client) }
    }

    /// Takes new timing or a new transition without touching which camera is
    /// live. Restarting for that would reset the director to slot 0 while OBS
    /// was still showing another - the settings window would name one camera
    /// and the class would see the other.
    func retune(_ requested: CameraDirectorSettings) {
        guard isRunning else { return }
        let settings = requested.availableOnly()
        guard settings.cameraUIDs == self.settings.cameraUIDs else { return }
        self.settings = settings
        chooser.dwellSeconds = settings.dwellSeconds
    }

    func stop() {
        task?.cancel()
        task = nil
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        deviceObservers = []
        unplugged = []
        liveCameraName = nil
        sight = .idle
        awaySeconds = 0
        pendingSwitch = nil
        angles = []
    }

    var isRunning: Bool { task != nil }

    /// Unplugged and plugged back in, by the camera's unique ID.
    ///
    /// A camera that comes back is not given the shot back: its frame is
    /// forgotten so it is judged fresh, and it has to earn the shot the usual
    /// way, by having the better view for the whole dwell.
    private func watchDevices() {
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        func slot(of note: Notification) -> Int? {
            guard let device = note.object as? AVCaptureDevice else { return nil }
            return settings.cameraUIDs.firstIndex(of: device.uniqueID)
        }
        deviceObservers = [
            center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let slot = slot(of: note) else { return }
                    self.unplugged.insert(slot)
                    self.log("\(self.cameraName(slot: slot)) was unplugged.")
                }
            },
            center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let slot = slot(of: note), self.unplugged.contains(slot) else { return }
                    self.unplugged.remove(slot)
                    self.lastFrames[slot] = nil
                    self.chooser.forget(slot)
                    self.log("\(self.cameraName(slot: slot)) is back. It takes the shot again when it has the better view.")
                }
            },
        ]
    }

    private func watch(client: OBSWebSocketClient) async {
        // Let the session get its first frames up before judging them.
        try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))
        while !Task.isCancelled {
            await tick(client: client)
            try? await Task.sleep(nanoseconds: Self.everyMs)
        }
    }

    private func tick(client: OBSWebSocketClient) async {
        var frames: [CGImage?] = []
        for slot in settings.cameraUIDs.indices {
            let grabbed = unplugged.contains(slot) ? nil : await Self.grab(client: client, slot: slot)
            let frozen = grabbed != nil && lastFrames[slot] == grabbed?.hash
            lastFrames[slot] = grabbed?.hash
            frames.append(frozen ? nil : grabbed?.image)
        }
        guard !Task.isCancelled else { return }
        // Vision off the main thread: it is now one face search per camera
        // per tick, and the settings window is on this thread.
        let sights = await Task.detached(priority: .userInitiated) {
            frames.map { frame in frame.map(CameraDirector.look(at:)) ?? .noPicture("") }
        }.value

        if case .noPicture = sights[live] {
            sight = .noPicture("OBS isn't sending a webcam picture.")
        } else {
            sight = sights[live]
        }

        // No face is treated the same as a face turned away. It is the same
        // thing from the class's side: this camera is not showing them
        // anybody who is talking to them.
        let readings = sights.map { sight -> Chooser.Reading in
            switch sight {
            case .noPicture, .idle: return .noPicture
            case .seen(let degrees): return .face(degrees)
            case .noFace, .noAngle: return .nobody
            }
        }
        let target = chooser.advance(readings: readings, live: live,
                                     elapsed: Double(Self.everyMs) / 1_000_000_000)
        awaySeconds = chooser.awaySeconds
        if angles != chooser.angles { angles = chooser.angles }
        pendingSwitch = chooser.progress.map { candidate, progress in
            PendingSwitch(cameraName: cameraName(slot: candidate), progress: progress)
        }
        guard let target, !Task.isCancelled else { return }
        await cut(client: client, to: target)
    }

    /// When to cut and where to, with no OBS and no camera anywhere in it.
    ///
    /// Pulled out of `tick` so the rules that matter can be checked against
    /// a script of readings rather than against a teacher sitting in front of
    /// a webcam turning their head.
    ///
    /// **The cameras are compared, not judged one at a time.** Every tick,
    /// each camera's angle to the teacher's head is smoothed, and the shot
    /// goes to whichever camera has them most head-on - once it has been
    /// clearly better than the live one, by `marginDegrees`, for the whole
    /// dwell.
    ///
    /// This replaced two fixed cut-offs - the live camera past 25 degrees,
    /// another inside 25 - and the reason is what they did on a real desk.
    /// With the second camera on top of an external monitor, looking at that
    /// monitor reads as a head tipped down, so where the angles fell depended
    /// as much on where each camera was mounted as on where the teacher was
    /// looking, and a single noisy reading could land a camera inside the
    /// line and start a switch nobody wanted. Comparing asks the question
    /// that is actually wanted - which camera has the better view of this
    /// face right now - and a mounting that tips every reading by the same
    /// amount changes nothing.
    ///
    ///  - **The margin** is what stops two near-equal cameras trading the
    ///    shot back and forth: the live one keeps it until another is
    ///    clearly better, and a camera just cut away from has to earn it back
    ///    the same way.
    ///  - **The ceiling** is the no-hunting rule. A camera further off than
    ///    `ceilingDegrees` is not "facing" anyone, however much better it is
    ///    than the other; looking at the floor or out of the window leaves
    ///    the shot where it is. See also `CameraDirector.score`, which makes a
    ///    head tipped down at the shoes score like one.
    ///  - **The old ring, as a fallback.** When no other camera sends a picture
    ///    at all there is nothing to compare, so it does what it did before
    ///    every camera was open at once: once the live camera has lost the
    ///    teacher for the dwell, try the next one, and stop after a full lap
    ///    with nobody found.
    ///  - **A live camera with no picture is left**, whatever the others see.
    ///    Every rule above asks which camera has the better view, and a dead
    ///    camera has none - so a secondary camera unplugged mid-class, with
    ///    the main one seeing only the side of a head, held the shot on a
    ///    frozen frame for the rest of the lesson. After `deadSeconds` the
    ///    shot goes to the main camera (slot 0), or the first one with a
    ///    picture, and the ceiling and margin do not get a say.
    struct Chooser {
        enum Reading: Equatable {
            /// No picture arrived from this camera.
            case noPicture
            /// A picture with no usable face in it.
            case nobody
            /// A face, this far off the lens - see `CameraDirector.score`.
            case face(Double)
        }

        var dwellSeconds: Double

        /// How much better another camera must be before it can take the shot.
        static let marginDegrees: Double = 10
        /// Past this, a camera is not facing the teacher at all.
        static let ceilingDegrees: Double = 40
        /// Each reading's weight against the running value. Half: a real turn
        /// shows in two readings, a one-frame blip is halved before it counts.
        static let smoothing: Double = 0.5
        /// How long the live camera may send no picture before it is left.
        /// About three readings, so one screenshot OBS failed to take is not
        /// a cut.
        static let deadSeconds: Double = 1

        /// Each camera's smoothed angle, nil when it has not seen a face.
        private(set) var angles: [Double?] = []
        /// Readings in a row without a face, per camera. One is forgiven -
        /// Vision drops the odd frame - so a blink of the detector does not
        /// hand the shot to the other camera.
        private var misses: [Int] = []
        /// The camera the evidence points to, and for how long it has.
        private(set) var candidate: Int?
        private(set) var candidateSeconds: Double = 0
        /// How long the live camera has been without the teacher, with no
        /// other camera to compare against.
        private(set) var blindSeconds: Double = 0
        /// Blind cuts since a camera last saw the teacher.
        private(set) var blindTries = 0
        /// How long the live camera has sent no picture.
        private(set) var liveDarkSeconds: Double = 0
        /// The last cut asked for was leaving a dead camera, not a choice.
        private(set) var fellBack = false
        /// Cameras left for having no picture, skipped by the blind ring
        /// until one sends a picture again. Without this the ring, which
        /// tries cameras that send nothing, sent the shot straight back to
        /// the dead one, and the class bounced between the two.
        private(set) var wentDark: Set<Int> = []

        init(dwellSeconds: Double) {
            self.dwellSeconds = dwellSeconds
        }

        /// Whatever is being waited on, for the settings window.
        var awaySeconds: Double { candidate != nil ? candidateSeconds : blindSeconds }

        private mutating func smooth(_ readings: [Reading]) {
            if angles.count != readings.count {
                angles = Array(repeating: nil, count: readings.count)
                misses = Array(repeating: 0, count: readings.count)
            }
            for (index, reading) in readings.enumerated() {
                if reading != .noPicture { wentDark.remove(index) }
                if case .face(let degrees) = reading {
                    angles[index] = angles[index].map { $0 + (degrees - $0) * Self.smoothing } ?? degrees
                    misses[index] = 0
                } else {
                    misses[index] += 1
                    if misses[index] > 1 { angles[index] = nil }
                }
            }
        }

        /// Feeds in one reading per camera. A camera index means cut to it now.
        mutating func advance(readings: [Reading], live: Int, elapsed: Double) -> Int? {
            guard readings.indices.contains(live) else { return nil }
            smooth(readings)
            fellBack = false

            liveDarkSeconds = readings[live] == .noPicture ? liveDarkSeconds + elapsed : 0
            if liveDarkSeconds >= Self.deadSeconds,
               let fallback = ([0] + Array(readings.indices))
                .first(where: { $0 != live && readings[$0] != .noPicture }) {
                candidate = nil
                candidateSeconds = 0
                blindSeconds = 0
                fellBack = true
                wentDark.insert(live)
                return fallback
            }

            let liveAngle = angles[live]
            let others = readings.indices.filter { $0 != live }

            let best = others
                .compactMap { index in angles[index].map { (index, $0) } }
                .filter { $0.1 <= Self.ceilingDegrees }
                .min { $0.1 < $1.1 }
            if let (index, angle) = best,
               liveAngle.map({ $0 - angle >= Self.marginDegrees }) ?? true {
                candidateSeconds = index == candidate ? candidateSeconds + elapsed : elapsed
                candidate = index
                blindSeconds = 0
                return candidateSeconds >= dwellSeconds ? index : nil
            }
            candidate = nil
            candidateSeconds = 0

            let liveHasThem = liveAngle.map { $0 <= Self.ceilingDegrees } ?? false
            if liveHasThem { blindTries = 0 }
            let blind = others.allSatisfy { readings[$0] == .noPicture }
            guard blind, !liveHasThem else {
                blindSeconds = 0
                return nil
            }
            // Capped so the moment a camera finds somebody it is one dwell
            // from being right, not a long-banked absence.
            blindSeconds = min(blindSeconds + elapsed, dwellSeconds)
            guard blindSeconds >= dwellSeconds, blindTries < readings.count - 1 else { return nil }
            return (1..<readings.count).lazy
                .map { (live + $0) % readings.count }
                .first { !wentDark.contains($0) }
        }

        /// A camera macOS says is plugged back in may be tried again.
        mutating func forget(_ slot: Int) {
            wentDark.remove(slot)
        }

        /// How far the current candidate is toward a cut, 0 to 1. Nil when no
        /// camera is winning, which includes every blind-ring wait: that one
        /// is a guess, and a countdown would promise something it may not do.
        var progress: (candidate: Int, fraction: Double)? {
            guard let candidate, dwellSeconds > 0 else { return nil }
            return (candidate, min(1, candidateSeconds / dwellSeconds))
        }

        /// Called after a cut lands.
        mutating func didCut(blind: Bool) {
            blindTries = blind ? blindTries + 1 : 0
            candidate = nil
            candidateSeconds = 0
            blindSeconds = 0
            liveDarkSeconds = 0
        }
    }

    private func cut(client: OBSWebSocketClient, to target: Int) async {
        let fellBack = chooser.fellBack
        let blind = !fellBack && chooser.candidate != target
        if fellBack {
            log("\(cameraName(slot: live)) stopped sending a picture \u{2014} back to \(cameraName(slot: target)).")
        } else if !blind {
            pendingSwitch = PendingSwitch(cameraName: cameraName(slot: target), progress: 1, landed: true)
        }
        let previous = live
        live = target
        await GreenroomScene.switchCamera(client: client, to: target, from: previous,
                                          fadeSeconds: settings.transition.fadeSeconds)
        liveCameraName = cameraName(slot: target)
        pendingSwitch = nil
        cuts += 1
        chooser.didCut(blind: blind)
        awaySeconds = 0
    }

    /// From the names read at start, not from the device list: the countdown
    /// asks three times a second, and every ask of the list is an AVFoundation
    /// discovery session.
    private func cameraName(slot: Int) -> String {
        cameraNames.indices.contains(slot) ? cameraNames[slot] : "Camera \(slot + 1)"
    }

    // MARK: Looking

    /// One frame of one camera source, small. Same route the shape preview
    /// takes, at a quarter the width - this is measuring the angle of a head,
    /// not showing anybody a picture. Works on a hidden camera: OBS renders a
    /// source for a screenshot whether or not the scene is showing it.
    static func grab(client: OBSWebSocketClient, slot: Int) async -> (image: CGImage, hash: Int)? {
        guard let response = try? await client.request("GetSourceScreenshot", data: [
            "sourceName": GreenroomScene.cameraSourceName(slot: slot),
            "imageFormat": "jpg",
            "imageWidth": 320
        ]),
              let dataString = response["imageData"] as? String,
              let comma = dataString.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataString[dataString.index(after: comma)...])),
              let image = NSImage(data: data),
              let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // The string, not `data`: Foundation hashes at most the first 80 bytes
        // of a Data, which in a JPEG is the header - identical on every frame,
        // so every frame would have looked frozen. A String hashes it all.
        return (frame, dataString.hashValue)
    }

    /// How far off the lens the biggest face in the frame is pointed, in
    /// degrees, or nil when there is no face.
    ///
    /// Yaw and pitch are not weighted the same, and the difference is the
    /// whole feature. Yaw is the axis that separates two monitors standing
    /// side by side, so it counts fully. Pitch mostly says "reading their own
    /// screen, which is under the camera" - normal, universal, and NOT a
    /// reason to cut, because the other camera would see exactly the same
    /// thing. So pitch is weighted down rather than ignored: a head tipped
    /// right back is still not looking at this camera.
    nonisolated static func offAxis(in frame: CGImage) -> Double? { look(at: frame).degrees }

    /// The same measurement, saying which of the three ways it failed.
    nonisolated static func look(at frame: CGImage) -> CameraSight {
        let request = VNDetectFaceRectanglesRequest()
        // Yaw needs revision 3, and pitch needs it too. Without asking, the
        // OS picks, and a revision without them reports nil - which would
        // read as "perfectly centred" and never cut at all.
        if VNDetectFaceRectanglesRequest.supportedRevisions.contains(VNDetectFaceRectanglesRequestRevision3) {
            request.revision = VNDetectFaceRectanglesRequestRevision3
        }
        try? VNImageRequestHandler(cgImage: frame, orientation: .up).perform([request])
        // The nearest face, on the assumption the presenter is the one
        // closest to the camera.
        guard let face = (request.results ?? []).max(by: { left, right in
            left.boundingBox.width * left.boundingBox.height
                < right.boundingBox.width * right.boundingBox.height
        }) else { return .noFace }

        // A face with no yaw at all is not evidence of anything. Reporting it
        // as zero would say "looking straight at you" on the strength of a
        // missing measurement.
        guard let yaw = face.yaw?.doubleValue else { return .noAngle }
        let pitch = face.pitch?.doubleValue ?? 0
        let yawDegrees = yaw * 180 / .pi
        let pitchDegrees = pitch * 180 / .pi
        return .seen(score(yaw: yawDegrees, pitch: pitchDegrees))
    }

    /// How far off a camera a head is pointed, in degrees, from its yaw and
    /// pitch.
    ///
    /// Yaw counts fully: it is what separates two monitors side by side.
    /// Pitch counts lightly up to `pitchKnee` and fully past it, and the knee
    /// is the fix for a real misfire. Weighting ALL pitch down, as this used
    /// to, was right for a teacher reading the screen under the camera -
    /// fifteen or twenty-five degrees down, normal, not a reason to cut - and
    /// wrong for a teacher looking at their shoes, which at fifty degrees down
    /// scored twenty, inside the "facing" range. So a camera could win while
    /// nobody was looking at any camera at all. Past the knee a head is not
    /// reading a screen, it is looking at the floor, and it scores like it.
    ///
    /// Steeply past it - two and a half to one - so forty-five degrees down
    /// scores past the ceiling in Chooser: that is the floor, not a screen.
    /// Continuous at the knee, so a head tipping slowly down does not jump.
    nonisolated static func score(yaw: Double, pitch: Double) -> Double {
        let down = abs(pitch)
        let counted = down <= pitchKnee
            ? down * pitchWeight
            : pitchKnee * pitchWeight + (down - pitchKnee) * 2.5
        return hypot(yaw, counted)
    }

    /// See `score`. Reading your own screen is not a reason to cut.
    nonisolated static let pitchWeight: Double = 0.4
    /// See `score`. Past this, a head is looking at the floor.
    nonisolated static let pitchKnee: Double = 30
}
