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
/// and that cannot be done blind. So the angle a camera reads you at is on
/// screen the whole time the tab is open - move the camera, watch the needle.
/// Nothing cuts while you are in here; see CameraDirector.startObserving.
///
/// Drawn the way the rest of the Webcam page is: cameras as cards, the
/// transition as two pictures, the angle as a gauge, and the explanations in
/// hover help. This wrapper reads the coordinator; `CameraSwitchContent`
/// draws, from plain values, so it can be rendered off screen.
struct CameraSwitchSection: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var cameras: [LocalDeviceResolver.Camera] = []
    /// Which camera the angle readout is currently on.
    @State private var aiming: String?

    private var settings: Binding<CameraDirectorSettings> { $coordinator.cameraDirectorSettings }

    var body: some View {
        LiveReadings(director: coordinator.cameraDirector, probe: coordinator.cameraProbe) {
            CameraSwitchContent(
                enabled: settings.enabled,
                cameras: cameras,
                order: coordinator.cameraDirectorSettings.cameraUIDs,
                single: coordinator.sceneCameraUIDs(limit: 1).first,
                liveCameraName: coordinator.cameraDirector.liveCameraName,
                aiming: aiming,
                canAim: !coordinator.virtualCamActive,
                dwell: settings.dwellSeconds,
                transition: settings.transition,
                reading: reading,
                toggle: toggle,
                pick: pick,
                aim: { uid in
                    aiming = uid
                    coordinator.aimCamera(uid: uid)
                },
                refresh: { cameras = LocalDeviceResolver.availableCameras() },
                noCamera: coordinator.cameraIsOff,
                noCameraAllowed: coordinator.shareTarget.kind != .nothing,
                chooseNoCamera: chooseNoCamera,
                liveDetail: { liveDetail })
        }
        .onAppear { cameras = LocalDeviceResolver.availableCameras() }
        .onDisappear {
            // A settings window left open would otherwise hold a camera - and
            // its light on - for as long as the app ran.
            coordinator.stopAiming()
            aiming = nil
        }
    }

    /// Ticking a camera appends it, so the order follows the order they were
    /// chosen in. That makes "the first one" something the teacher decided
    /// rather than something the device enumeration decided for them.
    /// With switching off there is one camera, and clicking a card makes it
    /// that camera: it moves to the front of the same list switching uses,
    /// so turning switching on later starts from the camera already chosen.
    private func pick(_ uid: String) {
        // One write, so the settings change (and save) once.
        var settings = coordinator.cameraDirectorSettings
        settings.cameraUIDs = settings.cameraUIDs.filter { $0 != uid }
        settings.cameraUIDs.insert(uid, at: 0)
        settings.noCamera = false
        coordinator.cameraDirectorSettings = settings
        coordinator.previewCamerasChanged()
    }

    /// No camera: the picture is what you share, alone. The chosen camera
    /// stays first in the list, so picking a camera again is one click on it.
    private func chooseNoCamera() {
        coordinator.cameraDirectorSettings.noCamera = true
        coordinator.previewCamerasChanged()
    }

    private func toggle(_ uid: String, _ on: Bool) {
        var uids = coordinator.cameraDirectorSettings.cameraUIDs
        if on {
            guard !uids.contains(uid) else { return }
            uids.append(uid)
        } else {
            uids.removeAll { $0 == uid }
        }
        coordinator.cameraDirectorSettings.cameraUIDs = uids
    }

    /// The live reading. During a class it is the director's, because the
    /// director owns the cameras then; otherwise it is the probe's.
    private var reading: CameraReading {
        let sight = coordinator.virtualCamActive ? coordinator.cameraDirector.sight : coordinator.cameraProbe.sight
        let threshold = coordinator.cameraDirectorSettings.awayDegrees
        let name = aiming.flatMap { uid in cameras.first { $0.id == uid }?.name }
        return CameraReading(degrees: sight.degrees, threshold: threshold,
                             status: Self.status(sight, threshold: threshold, aiming: aiming != nil),
                             source: coordinator.virtualCamActive ? "Through OBS" : name)
    }

    /// One line per state, and never the wrong one. The first version said
    /// "No face" whenever the angle was missing - including when nothing was
    /// looking at all. Every branch is a different thing to DO about it.
    private static func status(_ sight: CameraSight, threshold: Double, aiming: Bool) -> String {
        switch sight {
        case .idle: return aiming ? "Opening the camera\u{2026}" : "Aim a camera to measure"
        case .noPicture(let why): return why
        case .noFace: return "Nobody in the picture"
        case .noAngle: return "Can\u{2019}t tell which way you face"
        case .seen(let degrees): return degrees <= threshold ? "Facing this camera" : "Turned away"
        }
    }

    /// During a class: every camera's angle side by side, the countdown to a
    /// switch, and how many cuts so far. The single gauge shows one camera,
    /// which cannot say why the shot moved; the comparison can.
    @ViewBuilder private var liveDetail: some View {
        let director = coordinator.cameraDirector
        if coordinator.virtualCamActive, director.isRunning {
            let best = director.angles.enumerated()
                .compactMap { index, angle in angle.map { (index, $0) } }
                .min { $0.1 < $1.1 }?.0
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(director.cameraNamesInOrder.enumerated()), id: \.offset) { index, name in
                    let angle = director.angles.indices.contains(index) ? director.angles[index] : nil
                    HStack(spacing: 8) {
                        Text(angle.map { "\(Int($0.rounded()))\u{00B0}" } ?? "\u{2014}")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(index == best ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.secondary))
                            .frame(width: 40, alignment: .leading)
                        Text(name).font(.caption).lineLimit(1)
                        if index == director.liveSlot { PictureChip(text: "LIVE", dot: Brand.green) }
                        Spacer()
                    }
                }
                if let pending = director.pendingSwitch {
                    ProgressView(value: pending.progress)
                        .tint(Brand.green)
                        .animation(.linear(duration: CameraDirector.readingSeconds), value: pending.progress)
                        .help("Switching to \(pending.cameraName)")
                }
            }
            .help("Lower is more head-on. The class gets whichever camera is clearly lower for the whole delay. \(director.cuts) cut\(director.cuts == 1 ? "" : "s") this session.")
        }
    }
}

/// What the gauge shows.
struct CameraReading {
    var degrees: Double?
    var threshold: Double
    var status: String
    /// Which camera it is looking through, or nil when none.
    var source: String?

    var isFacing: Bool { (degrees ?? .infinity) <= threshold }
}

// MARK: - Drawing

struct CameraSwitchContent<LiveDetail: View>: View {
    @Binding var enabled: Bool
    let cameras: [LocalDeviceResolver.Camera]
    /// Chosen cameras, in cut order.
    let order: [String]
    /// The one camera in use while switching is off.
    let single: String?
    let liveCameraName: String?
    let aiming: String?
    let canAim: Bool
    @Binding var dwell: Double
    @Binding var transition: CameraTransition
    let reading: CameraReading
    let toggle: (String, Bool) -> Void
    let pick: (String) -> Void
    let aim: (String) -> Void
    let refresh: () -> Void
    /// "No camera" is picked. Only offered with switching off.
    var noCamera = false
    /// False while nothing is shared: no camera would leave nothing to show.
    var noCameraAllowed = true
    var chooseNoCamera: () -> Void = {}
    @ViewBuilder let liveDetail: () -> LiveDetail

    var body: some View {
        Toggle("Switch to the camera you\u{2019}re facing", isOn: $enabled)
            .help("For two monitors: put a camera on each, and the class sees whichever one you face instead of the side of your head.")

        cameraRow

        HStack(alignment: .center, spacing: 16) {
            AngleGauge(reading: reading)
            VStack(alignment: .leading, spacing: 4) {
                Text(reading.degrees.map { "\(Int($0.rounded()))\u{00B0}" } ?? "\u{2014}")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(reading.isFacing ? AnyShapeStyle(Brand.text) : AnyShapeStyle(.primary))
                Text(reading.status).font(.callout.weight(.medium))
                if let source = reading.source {
                    Text(source).font(.caption).foregroundStyle(.secondary)
                }
                liveDetail()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .help("The angle this camera reads you at. Inside the green you are facing it. Move the camera and watch the needle.")

        Group {
            LabeledContent {
                HStack(spacing: 12) {
                    Slider(value: $dwell, in: 0.5...6, step: 0.5)
                        .frame(minWidth: 160)
                    Text(String(format: "%.1f s", dwell))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            } label: {
                Text("Switch after")
            }
            .help("How long you must face another camera before the class is cut to it. Glances shorter than this cost nothing.")

            HStack(spacing: 8) {
                Text("Switch with").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(CameraTransition.allCases) { style in
                    ChoiceTile(title: style.label, selected: style == transition, badge: nil) {
                        TransitionGlyph(style: style, highlighted: style == transition)
                    } action: { transition = style }
                    .help(style == .cut ? "Instant" : "Dissolves over half a second")
                    .frame(width: 150)
                }
            }
        }
        .disabled(!enabled)
    }

    /// The cameras as cards. The number is the order - "which one do I start
    /// on" is the question a teacher actually has - and clicking a card adds
    /// or removes it.
    private var cameraRow: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(cameras) { camera in
                let position = order.firstIndex(of: camera.id)
                CameraCard(camera: camera,
                           // Numbered only when there is an order to show.
                           position: enabled ? position : nil,
                           chosen: enabled ? position != nil : !noCamera && single == camera.id,
                           isLive: liveCameraName == camera.name,
                           isAiming: aiming == camera.id, canAim: canAim,
                           toggle: { enabled ? toggle(camera.id, position == nil) : pick(camera.id) },
                           aim: { aim(camera.id) })
            }
            if cameras.count < 2 && enabled {
                AddCameraHint()
            }
            if !enabled {
                NoCameraCard(chosen: noCamera, allowed: noCameraAllowed, choose: chooseNoCamera)
            }
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Look for cameras again")
                .accessibilityLabel("Refresh the camera list")
        }
        .padding(.vertical, 4)
    }
}

private struct CameraCard: View {
    let camera: LocalDeviceResolver.Camera
    let position: Int?
    let chosen: Bool
    let isLive: Bool
    let isAiming: Bool
    let canAim: Bool
    let toggle: () -> Void
    let aim: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: toggle) {
                VStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 22))
                        .foregroundStyle(chosen ? Brand.green : Color.secondary)
                        .frame(height: 28)
                    Text(camera.name)
                        .font(.callout.weight(chosen ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(position != nil ? "Click to leave this camera out" : "Click to use this camera")

            if canAim {
                Button(isAiming ? "Looking\u{2026}" : "Aim") { aim() }
                    .controlSize(.small)
                    .disabled(isAiming)
                    .help("Measure the angle this camera reads you at")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: 148)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(chosen ? Brand.green.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(chosen ? Brand.green : Color.secondary.opacity(0.25), lineWidth: chosen ? 2 : 1))
        .overlay(alignment: .topLeading) {
            if position == nil, chosen {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Brand.green)
                    .padding(6)
            } else if let position {
                Text("\(position + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Brand.green, in: Circle())
                    .padding(6)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isLive { PictureChip(text: "LIVE", dot: Brand.green).padding(6) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(camera.name)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var symbol: String {
        if camera.isBuiltIn { return "laptopcomputer" }
        if camera.name.localizedCaseInsensitiveContains("iphone") { return "iphone" }
        return "web.camera"
    }
}

/// The camera left out: the picture is the shared content alone.
private struct NoCameraCard: View {
    let chosen: Bool
    let allowed: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                Image(systemName: "video.slash")
                    .font(.system(size: 22))
                    .foregroundStyle(chosen ? Brand.green : Color.secondary)
                    .frame(height: 28)
                Text("No camera")
                    .font(.callout.weight(chosen ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(width: 148)
        .frame(minHeight: 84)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(chosen ? Brand.green.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(chosen ? Brand.green : Color.secondary.opacity(0.25), lineWidth: chosen ? 2 : 1))
        .overlay(alignment: .topLeading) {
            if chosen {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Brand.green)
                    .padding(6)
            }
        }
        .opacity(allowed ? 1 : 0.5)
        .help(allowed ? "Just what you share, full frame. No camera is opened."
                      : "Pick something for Behind you first. With nothing behind you and no camera, there\u{2019}s nothing to show.")
        .accessibilityLabel("No camera")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The empty second slot: says what would go there.
private struct AddCameraHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 18))
                .frame(height: 28)
            Text("Second camera")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 12)
        .frame(width: 148)
        .frame(minHeight: 84)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .help("Plug in another camera, or put your iPhone on the other monitor: Continuity Camera shows up here.")
    }
}

/// Cut as two frames with a hard edge, crossfade as two overlapping.
private struct TransitionGlyph: View {
    let style: CameraTransition
    let highlighted: Bool

    var body: some View {
        let tint = highlighted ? Brand.green : Color.secondary
        ZStack {
            switch style {
            case .cut:
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.35))
                    RoundedRectangle(cornerRadius: 3).fill(tint)
                }
            case .crossfade:
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.35)).offset(x: -8)
                    RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.7)).offset(x: 8)
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(width: 64, height: 32)
        .accessibilityHidden(true)
    }
}

/// The angle as a needle on a half dial: 0 degrees straight up, and the green
/// wedge is "facing this camera". The number is beside it, not on it.
struct AngleGauge: View {
    let reading: CameraReading
    /// The dial runs 90 degrees each way.
    private static let span = 90.0

    var body: some View {
        let size = CGSize(width: 120, height: 70)
        Canvas { context, canvasSize in
                let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height - 4)
                let radius = min(canvasSize.width / 2, canvasSize.height) - 6
                func arc(_ from: Double, _ to: Double) -> Path {
                    Path { path in
                        path.addArc(center: centre, radius: radius,
                                    startAngle: .degrees(-90 + from), endAngle: .degrees(-90 + to),
                                    clockwise: false)
                    }
                }
                context.stroke(arc(-Self.span, Self.span), with: .color(.secondary.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 8, lineCap: .round))
                let wedge = min(reading.threshold, Self.span)
                context.stroke(arc(-wedge, wedge), with: .color(Brand.green.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 8, lineCap: .round))
                if let degrees = reading.degrees {
                    // Which way the head turns is not measured, only how far,
                    // so the needle leans right.
                    let angle = Angle.degrees(-90 + min(degrees, Self.span))
                    let tip = CGPoint(x: centre.x + cos(angle.radians) * (radius - 2),
                                      y: centre.y + sin(angle.radians) * (radius - 2))
                    var needle = Path()
                    needle.move(to: centre)
                    needle.addLine(to: tip)
                    context.stroke(needle, with: .color(.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                context.fill(Path(ellipseIn: CGRect(x: centre.x - 3, y: centre.y - 3, width: 6, height: 6)),
                             with: .color(.primary))
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(reading.degrees.map { "\(Int($0.rounded())) degrees off" } ?? "No reading")
    }
}
