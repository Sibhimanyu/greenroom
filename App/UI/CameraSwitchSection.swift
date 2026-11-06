//
//  CameraSwitchSection.swift
//  Greenroom
//
//  Settings -> Webcam -> Cameras: the two-camera cut.
//
import SwiftUI

/// Re-draws its content whenever the director or the probe publishes.
///
/// Both are ObservableObjects owned by the coordinator, and SwiftUI does not
/// see through one observable to another: reading `coordinator.cameraDirector
/// .sight` subscribes to the coordinator, which never changes when the sight
/// does. So the angle and the switch countdown only moved when something else
/// happened to redraw the window. Observing the two directly fixes that
/// without making the whole coordinator republish three times a second.
private struct LiveReadings<Content: View>: View {
    @ObservedObject var director: CameraDirector
    @ObservedObject var probe: CameraProbe
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}


/// Setting up the two-camera cut.
///
/// The hard part of this feature is not the software, it is aiming a camera,
/// and that cannot be done blind. So the angle this camera currently reads is
/// on screen the whole time the tab is open - move the camera, watch the
/// number fall. Nothing cuts while you are in here; see
/// CameraDirector.startObserving.
struct CameraSwitchSection: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var cameras: [LocalDeviceResolver.Camera] = []
    /// Which camera the preview and the angle readout are currently on.
    @State private var aiming: String?

    private var settings: Binding<CameraDirectorSettings> { $coordinator.cameraDirectorSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Switch to the camera you\u{2019}re facing", isOn: settings.enabled)
                .help("For two monitors: put a camera on each, and the class sees whichever one you face instead of the side of your head.")

            // Shown whether or not switching is on, like the rest of Settings.
            // Choosing and aiming the cameras stays live - it is the setup a
            // teacher does BEFORE trusting the feature, and the angle readout
            // is how they check it - while the two settings that only shape a
            // cut grey out until there are cuts to shape.
            LiveReadings(director: coordinator.cameraDirector, probe: coordinator.cameraProbe) {
                chooser
            }
            Group {
                dwell
                transition
            }
            .disabled(!coordinator.cameraDirectorSettings.enabled)
            LiveReadings(director: coordinator.cameraDirector, probe: coordinator.cameraProbe) {
                readout
            }
        }
        .onAppear { cameras = LocalDeviceResolver.availableCameras() }
        .onDisappear {
            // A settings window left open would otherwise hold a camera - and
            // its light on - for as long as the app ran.
            coordinator.stopAiming()
            aiming = nil
        }
    }

    // MARK: Which cameras, and in what order

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CAMERAS, IN ORDER \u{00B7} A SESSION STARTS ON THE FIRST")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(.tertiary)

            if cameras.count < 2 {
                Text("Only one camera is plugged in, so there is nothing to cut to. Your iPhone counts \u{2014} put it on the other monitor and it appears here as a camera.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(cameras) { camera in
                let position = coordinator.cameraDirectorSettings.cameraUIDs.firstIndex(of: camera.id)
                Toggle(isOn: Binding(
                    get: { position != nil },
                    set: { wanted in toggle(camera, on: wanted) })) {
                    HStack(spacing: 8) {
                        // The order is the whole point, so it is a number
                        // rather than a checkmark: "which one do I start on"
                        // is the question a teacher actually has.
                        Text(position.map { "\($0 + 1)" } ?? "\u{2013}")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(position == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.text))
                            .frame(width: 14, alignment: .trailing)
                        Text(camera.name)
                        if coordinator.cameraDirector.liveCameraName == camera.name {
                            Text("LIVE")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Brand.fill, in: Capsule())
                        }
                        Spacer(minLength: 8)
                        // Aiming the second camera is the setup task, and the
                        // angle below reports whichever camera OBS is on. So
                        // there has to be a way to put it on this one.
                        if !coordinator.virtualCamActive {
                            Button(aiming == camera.id ? "Looking\u{2026}" : "Aim this one") {
                                aiming = camera.id
                                coordinator.aimCamera(uid: camera.id)
                            }
                            .controlSize(.small)
                            .disabled(aiming == camera.id)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            Button("Refresh the list") { cameras = LocalDeviceResolver.availableCameras() }
                .controlSize(.small)
        }
    }

    /// Ticking a camera appends it, so the order follows the order they were
    /// chosen in. That makes "the first one" something the teacher decided
    /// rather than something the device enumeration decided for them.
    private var aimingName: String? {
        aiming.flatMap { uid in cameras.first { $0.id == uid }?.name }
    }

    /// The live reading. During a class it is the director's, because the
    /// director owns the cameras then; otherwise it is the probe's.
    private var sight: CameraSight {
        coordinator.virtualCamActive ? coordinator.cameraDirector.sight : coordinator.cameraProbe.sight
    }

    private func toggle(_ camera: LocalDeviceResolver.Camera, on: Bool) {
        var uids = coordinator.cameraDirectorSettings.cameraUIDs
        if on {
            guard !uids.contains(camera.id) else { return }
            uids.append(camera.id)
        } else {
            uids.removeAll { $0 == camera.id }
        }
        coordinator.cameraDirectorSettings.cameraUIDs = uids
    }

    // MARK: How patient it is

    private var dwell: some View {
        HStack(spacing: 10) {
            Text("Cut after").font(.callout)
            Slider(value: settings.dwellSeconds, in: 0.5...6, step: 0.5)
                .frame(width: 180)
            Text(String(format: "%.1fs", coordinator.cameraDirectorSettings.dwellSeconds))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .frame(width: 42, alignment: .leading)
            Text("facing another camera")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: What the class sees

    /// Every camera is already open, so a cut has no hitch in it either way;
    /// this is only taste. Applies live, from the next switch.
    private var transition: some View {
        Picker(selection: settings.transition) {
            ForEach(CameraTransition.allCases) { style in
                Text(style.label).tag(style)
            }
        } label: {
            SettingLabel(title: "When it switches",
                         subtitle: "A cut is instant. A crossfade dissolves over half a second.")
        }
        .pickerStyle(.segmented)
    }

    // MARK: Proof that it is working

    /// The number that makes this setup-able.
    ///
    /// Aim the camera, read the angle, aim again. Below the threshold it is
    /// looking at you; above it, this camera has lost you, and another one
    /// that has you face-on would take over. Without this a
    /// teacher is guessing, and the first thing they would do is guess wrong
    /// and decide the feature is broken.
    private var readout: some View {
        let threshold = coordinator.cameraDirectorSettings.awayDegrees
        let degrees = sight.degrees
        let here = (degrees ?? .infinity) <= threshold
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(degrees.map { "\(Int($0.rounded()))\u{00B0}" } ?? "\u{2014}")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(here ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary))
                    .frame(width: 60, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            // What the switch is decided on: every camera's angle, side by
            // side. The single number above is the live camera alone, which
            // cannot say why the shot moved - the comparison can. Lower wins,
            // once it is clearly lower for the whole delay.
            if coordinator.virtualCamActive, coordinator.cameraDirector.isRunning {
                comparison
            }
            // The same countdown the self view shows, for setting the dwell
            // by feel: drag the slider, turn, watch how long it takes.
            if coordinator.virtualCamActive, let pending = coordinator.cameraDirector.pendingSwitch {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: pending.progress)
                        .progressViewStyle(.linear)
                        .tint(Brand.green)
                        .animation(.linear(duration: CameraDirector.readingSeconds), value: pending.progress)
                    Text("Switching to \(pending.cameraName)\u{2026}")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if coordinator.virtualCamActive, coordinator.cameraDirector.cuts > 0 {
                Text("\(coordinator.cameraDirector.cuts) cut\(coordinator.cameraDirector.cuts == 1 ? "" : "s") this session.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var comparison: some View {
        let director = coordinator.cameraDirector
        let names = director.cameraNamesInOrder
        let angles = director.angles
        let best = angles.enumerated()
            .compactMap { index, angle in angle.map { (index, $0) } }
            .min { $0.1 < $1.1 }?.0
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                let angle = angles.indices.contains(index) ? angles[index] : nil
                HStack(spacing: 8) {
                    Text(angle.map { "\(Int($0.rounded()))\u{00B0}" } ?? "\u{2014}")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(index == best ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary))
                        .frame(width: 40, alignment: .leading)
                    Text(name).font(.caption).lineLimit(1)
                    if index == director.liveSlot {
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Brand.fill, in: Capsule())
                    }
                    Spacer()
                }
            }
            Text("Lower is more head-on. The class gets whichever camera is clearly lower for the whole delay.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line per state, and never the wrong one.
    ///
    /// The first version printed "No face in this camera right now" whenever
    /// the angle was missing - including when nothing was looking at all,
    /// which is what a reader saw while sitting in front of their own camera.
    /// Every branch here is a different thing to DO about it.
    private var headline: String {
        switch sight {
        case .idle:
            return aiming == nil
                ? "Press \u{201C}Aim this one\u{201D} on a camera to see the angle it reads you at."
                : "Opening the camera\u{2026}"
        case .noPicture(let why):
            return why
        case .noFace:
            return "A picture, but nobody in it."
        case .noAngle:
            return "Found a face, but couldn\u{2019}t measure which way it is turned."
        case .seen(let degrees):
            return degrees <= coordinator.cameraDirectorSettings.awayDegrees
                ? "Looking at this camera."
                : "Turned away from this camera. In a class, a camera that sees you face-on would take over."
        }
    }

    private var detail: String {
        if coordinator.virtualCamActive {
            return "Measured through OBS while the class runs."
        }
        guard let aimingName else {
            return "Nothing is looking through a camera yet."
        }
        return "Looking through \(aimingName). Move it and watch this change."
    }
}

