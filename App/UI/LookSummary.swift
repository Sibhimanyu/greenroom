//
//  LookSummary.swift
//  Greenroom
//
//  One line on Home saying what Start will send or record: the look, what is
//  behind you, the camera and the microphone, with a way to change them.
//
//  Settings -> Webcam is the one place the picture is decided, and all three
//  of Home's modes use it. That is only safe if Home says what it is set to:
//  a picture chosen yesterday for a student's presentation should not be a
//  surprise at this morning's class. Read-only on purpose - the choices
//  themselves stay on the Webcam page, where they can be seen working.
//
//  `LookSummaryRow` draws from plain values so it can be rendered off screen;
//  `LookSummaryLine` feeds it from the coordinator.
//
import AVFoundation
import SwiftUI

/// What the line says, worked out from the settings.
struct LookSummary: Equatable {
    var shape: WebcamShape
    var showsContent: Bool
    var showsCamera: Bool
    /// "Cutout", "Keynote window", "MacBook Pro Camera", "AirPods Pro".
    var parts: [String]

    var text: String { parts.joined(separator: " \u{00B7} ") }
}

// MARK: - Reading the settings

extension LookSummary {
    @MainActor
    static func current(_ coordinator: CoordinatorController,
                        cameras: [LocalDeviceResolver.Camera],
                        microphones: [LocalDeviceResolver.Microphone],
                        systemMicrophone: String?) -> LookSummary {
        let share = coordinator.shareTarget
        let showsContent = share.kind != .nothing
        let showsCamera = !coordinator.cameraIsOff
        var parts: [String] = []
        // The look only matters when there is a camera to give it to.
        if showsCamera { parts.append(coordinator.webcamShape.label) }
        parts.append(shareText(share))
        parts.append(cameraText(coordinator, cameras: cameras))
        parts.append(microphoneText(uid: coordinator.micDeviceUID, microphones: microphones,
                                    system: systemMicrophone))
        return LookSummary(shape: coordinator.webcamShape, showsContent: showsContent,
                           showsCamera: showsCamera, parts: parts)
    }

    private static func shareText(_ share: ShareTarget) -> String {
        switch share.kind {
        case .display: return "Whole screen"
        case .app: return share.appBundleID.isEmpty ? "One app" : "\(share.displayName) app"
        case .window: return share.appBundleID.isEmpty ? "One window" : "\(share.displayName) window"
        case .nothing: return "Nothing behind you"
        }
    }

    @MainActor
    private static func cameraText(_ coordinator: CoordinatorController,
                                   cameras: [LocalDeviceResolver.Camera]) -> String {
        if coordinator.cameraIsOff { return "No camera" }
        // sceneCameraUIDs' rule, worked against the list already held rather
        // than by calling it: it discovers the devices afresh every time.
        let settings = coordinator.cameraDirectorSettings
        let chosen = settings.cameraUIDs.compactMap { uid in cameras.first { $0.id == uid } }
        if settings.enabled, chosen.count >= 2 { return "\(chosen.count) cameras, switching" }
        let camera = chosen.first ?? cameras.first { $0.isBuiltIn } ?? cameras.first
        return camera?.name ?? "No camera found"
    }

    /// An empty choice follows the system's input, so it is named as that
    /// device: "System microphone" says nothing about which one you get.
    private static func microphoneText(uid: String, microphones: [LocalDeviceResolver.Microphone],
                                       system: String?) -> String {
        if let picked = microphones.first(where: { $0.id == uid }) { return picked.name }
        return system ?? "System microphone"
    }
}

/// Feeds the row from the coordinator.
///
/// The device lists are held here and refreshed when a device comes or goes,
/// not looked up on every redraw: Home redraws on every status line, and a
/// device discovery per line is a lot of AVFoundation for one sentence.
struct LookSummaryLine: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    let change: () -> Void
    @State private var cameras: [LocalDeviceResolver.Camera] = []
    @State private var microphones: [LocalDeviceResolver.Microphone] = []
    @State private var systemMicrophone: String?

    var body: some View {
        LookSummaryRow(summary: LookSummary.current(coordinator, cameras: cameras, microphones: microphones,
                                                    systemMicrophone: systemMicrophone),
                       change: change)
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refresh() }
    }

    private func refresh() {
        cameras = LocalDeviceResolver.availableCameras()
        microphones = LocalDeviceResolver.availableMicrophones()
        systemMicrophone = AVCaptureDevice.default(for: .audio)?.localizedName
    }
}

// MARK: - Drawing

/// The line itself: a thumbnail of the look, the words, and Change.
struct LookSummaryRow: View {
    let summary: LookSummary
    let change: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            LookThumbnail(shape: summary.shape, showsContent: summary.showsContent,
                          showsCamera: summary.showsCamera)
            Text(summary.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(summary.text)
            Button("Change\u{2026}", action: change)
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Brand.text)
                .help("Opens Settings \u{2192} Webcam, where the picture is set for all three modes.")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Picture: \(summary.text)")
    }
}

/// The look as a picture the size of a word: a dark frame (the backdrop the
/// scene draws on), the shared content as a grey panel, you in green.
private struct LookThumbnail: View {
    let shape: WebcamShape
    let showsContent: Bool
    let showsCamera: Bool

    var body: some View {
        let width: CGFloat = 32, height: CGFloat = 18
        ZStack {
            // --ink, the colour the compositor draws its backdrop in.
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: NSColor(srgbRed: 0x10 / 255, green: 0x18 / 255, blue: 0x28 / 255, alpha: 1)))
            if showsContent {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(0.22))
                    .frame(width: shape.isPresenterStyle && showsCamera ? 20 : 28,
                           height: shape.isPresenterStyle && showsCamera ? 12 : 14)
                    .offset(x: shape.isPresenterStyle && showsCamera ? 4 : 0)
            }
            if showsCamera { person(width: width, height: height) }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func person(width: CGFloat, height: CGFloat) -> some View {
        if !showsContent {
            // The camera fills the frame: you, centred, full height.
            Image(systemName: "person.fill")
                .resizable().scaledToFit()
                .foregroundStyle(Brand.green)
                .frame(height: height - 4)
        } else if shape.usesChromaKey {
            Image(systemName: "person.fill")
                .resizable().scaledToFit()
                .foregroundStyle(Brand.green)
                .frame(height: shape.isPresenterStyle ? height - 4 : 9)
                .offset(x: shape.isPresenterStyle ? -10 : 9, y: shape.isPresenterStyle ? 1 : 3)
        } else {
            Group {
                switch shape {
                case .circle: Circle().fill(Brand.green)
                case .roundedRectangle: RoundedRectangle(cornerRadius: 1.5).fill(Brand.green)
                default: Rectangle().fill(Brand.green)
                }
            }
            .frame(width: shape == .circle ? 6 : 8, height: 6)
            .offset(x: 10, y: 4)
        }
    }
}
