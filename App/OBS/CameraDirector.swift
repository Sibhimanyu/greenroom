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
//  HOW THE DECISION IS MADE, and the compromise in it.
//
//  Only ONE camera is live at a time, because Greenroom keeps one OBS webcam
//  source and swaps which device it points at - see the note on
//  GreenroomScene.setWebcamDevice for why a second source was not worth what
//  it would cost. That means this cannot compare the two cameras and pick the
//  better one. It watches the camera it is on, and when that camera stops
//  seeing a face pointed at it, it moves to the next one in the ring.
//
//  With two cameras that converges in one step and reads exactly like a
//  multicam cut. With three it may take two. The dwell is what keeps it from
//  hunting: nothing switches until the current camera has been looked away
//  from continuously for `dwellSeconds`, so a glance at a note costs nothing.
//
//  IT WATCHES THROUGH OBS, not through its own capture session. The frames
//  come from GetSourceScreenshot on the webcam source, which is how the shape
//  preview already works. That avoids resting the whole feature on whether
//  macOS will hand the same camera to two processes at once - which it may
//  well do, but an architecture should not rest on a guess, and the unsigned
//  probe that would have settled it cannot get camera permission to run.
//
import AppKit
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

    /// How long the teacher must be looking away from the live camera before
    /// the shot moves.
    ///
    /// Two seconds, because the failure modes either side are not symmetric.
    /// Too short and the shot cuts every time they glance at a note, which is
    /// unwatchable. Too long and they finish the sentence before the camera
    /// catches up, which is merely late. Late is better.
    var dwellSeconds: Double = 2.0

    /// How far off the lens counts as looking away.
    ///
    /// Twenty-five degrees. A teacher reading their own screen under the
    /// camera sits around seventeen, so this deliberately does NOT trip on
    /// that - there is nothing to cut to, and cutting would be wrong. Two
    /// monitors side by side put the other one past thirty.
    var awayDegrees: Double = 25

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

    private var task: Task<Void, Never>?
    private var settings = CameraDirectorSettings()
    private var index = 0

    /// When to cut. See `Switcher`.
    private var switcher = Switcher(dwellSeconds: 2, cameraCount: 0)

    /// How often to look. Twice a second is far more than the decision needs
    /// - it turns on a two-second dwell - and it keeps the screenshot traffic
    /// on the OBS socket to something that cannot compete with a class.
    private static let everyMs: UInt64 = 500_000_000

    /// Long enough after a cut for the new device to have opened and produced
    /// a frame. Judging during this window would read the black of a camera
    /// still starting up as "nobody there" and cut straight onwards.
    private static let settleSeconds: Double = 1.5

    // MARK: Running

    /// Starts watching. Safe to call when already running, and does nothing
    /// at all when the feature is off or there is only one camera.
    func start(client: OBSWebSocketClient, settings requested: CameraDirectorSettings) {
        stop()
        let settings = requested.availableOnly()
        guard settings.isUsable else { return }
        self.settings = settings
        index = 0
        switcher = Switcher(dwellSeconds: settings.dwellSeconds,
                            cameraCount: settings.cameraUIDs.count)
        cuts = 0
        awaySeconds = 0
        liveCameraName = LocalDeviceResolver.cameraName(uid: settings.cameraUIDs[0])
        task = Task { [weak self] in await self?.watch(client: client) }
    }

    func stop() {
        task?.cancel()
        task = nil
        liveCameraName = nil
        sight = .idle
        awaySeconds = 0
    }

    var isRunning: Bool { task != nil }

    private func watch(client: OBSWebSocketClient) async {
        // Let the session get its first frame up before judging it.
        try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))
        while !Task.isCancelled {
            await tick(client: client)
            try? await Task.sleep(nanoseconds: Self.everyMs)
        }
    }

    private func tick(client: OBSWebSocketClient) async {
        guard let frame = await Self.grab(client: client) else {
            sight = .noPicture("OBS isn't sending a webcam picture.")
            return
        }
        let reading = Self.look(at: frame)
        sight = reading

        // No face is treated the same as a face turned away. It is the same
        // thing from the class's side: this camera is not showing them
        // anybody who is talking to them.
        let lookingHere = (reading.degrees ?? .infinity) <= settings.awayDegrees
        let verdict = switcher.advance(lookingHere: lookingHere,
                                       elapsed: Double(Self.everyMs) / 1_000_000_000)
        awaySeconds = switcher.awaySeconds
        guard verdict else { return }
        await cut(client: client)
    }

    /// When to cut, with no OBS and no camera anywhere in it.
    ///
    /// Pulled out of `tick` so the two rules that matter can be tested
    /// against a script of readings rather than against a teacher sitting in
    /// front of a webcam turning their head: the dwell, which stops a glance
    /// from cutting, and the hunt guard, which stops an empty room from
    /// cycling the shot round every camera forever.
    struct Switcher {
        var dwellSeconds: Double
        var cameraCount: Int

        private(set) var awaySeconds: Double = 0
        /// Cameras tried since one of them last saw a face pointed at it.
        private(set) var triedSinceGood = 0

        /// Feeds in one reading. True means cut now.
        mutating func advance(lookingHere: Bool, elapsed: Double) -> Bool {
            if lookingHere {
                awaySeconds = 0
                triedSinceGood = 0
                return false
            }
            awaySeconds += elapsed
            guard awaySeconds >= dwellSeconds else { return false }
            guard triedSinceGood < cameraCount - 1 else {
                // Every camera has been tried and none found anybody. Hold
                // this one: nothing is gained by cutting round an empty room,
                // and the recording would be unwatchable. Pinned rather than
                // left to grow so the moment somebody comes back it is one
                // dwell away from being right again.
                awaySeconds = dwellSeconds
                return false
            }
            return true
        }

        /// Called after a cut lands.
        mutating func cut() {
            triedSinceGood += 1
            awaySeconds = 0
        }
    }

    private func cut(client: OBSWebSocketClient) async {
        index = (index + 1) % settings.cameraUIDs.count
        let uid = settings.cameraUIDs[index]
        let name = LocalDeviceResolver.cameraName(uid: uid)
        await GreenroomScene.setWebcamDevice(client: client, uid: uid, name: name)
        liveCameraName = name
        cuts += 1
        switcher.cut()
        awaySeconds = 0
        sight = .idle
        // Do not judge the new camera until it has actually opened.
        try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))
    }

    // MARK: Looking

    /// One frame of the webcam source, small. Same route the shape preview
    /// takes, at a quarter the width - this is measuring the angle of a head,
    /// not showing anybody a picture.
    static func grab(client: OBSWebSocketClient) async -> CGImage? {
        guard let response = try? await client.request("GetSourceScreenshot", data: [
            "sourceName": GreenroomScene.webcamSourceName,
            "imageFormat": "jpg",
            "imageWidth": 320
        ]),
              let dataString = response["imageData"] as? String,
              let comma = dataString.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataString[dataString.index(after: comma)...])),
              let image = NSImage(data: data) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
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
    static func offAxis(in frame: CGImage) -> Double? { look(at: frame).degrees }

    /// The same measurement, saying which of the three ways it failed.
    static func look(at frame: CGImage) -> CameraSight {
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
        return .seen(hypot(yawDegrees, pitchDegrees * Self.pitchWeight))
    }

    /// See `offAxis`. Looking down at your own screen is not a reason to cut.
    static let pitchWeight: Double = 0.4
}
