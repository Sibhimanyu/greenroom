//
//  MicrophoneSection.swift
//  Greenroom
//
//  Settings -> Webcam -> Microphone: which microphone the class hears and
//  the recording takes.
//
//  A device menu. "System default" follows whatever macOS has as its
//  input, which is what Greenroom always did; any other selection pins one
//  device, for the built-in meeting client (live, mid-class too) and for
//  OBS's audio source (from the next Start). The separate Zoom app, when
//  used instead, keeps its own audio settings.
//
import SwiftUI

struct MicrophoneSection: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @State private var microphones: [LocalDeviceResolver.Microphone] = []

    var body: some View {
        MicrophoneContent(
            microphones: microphones,
            selection: coordinator.micDeviceUID,
            choose: { uid in
                coordinator.micDeviceUID = uid
                coordinator.previewCamerasChanged()
            },
            refresh: { microphones = LocalDeviceResolver.availableMicrophones() })
            .onAppear { microphones = LocalDeviceResolver.availableMicrophones() }
    }
}

struct MicrophoneContent: View {
    let microphones: [LocalDeviceResolver.Microphone]
    /// Empty: the system's input.
    let selection: String
    let choose: (String) -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Input", selection: Binding(get: { selection }, set: choose)) {
                Label("System default", systemImage: "gearshape").tag("")
                ForEach(microphones) { mic in
                    Label(mic.name, systemImage: Self.symbol(for: mic)).tag(mic.id)
                }
                // A disconnected saved device remains selected. The recording
                // continues to use the system input until it is reconnected.
                if !selection.isEmpty, !microphones.contains(where: { $0.id == selection }) {
                    Label("Saved microphone (not connected)", systemImage: "mic.slash").tag(selection)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .help(selection.isEmpty
                  ? "Follows the input in System Settings → Sound."
                  : "Used by the built-in meeting client and, from the next Start, OBS. If disconnected, recording uses the system input until it returns.")
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Look for microphones again")
                .accessibilityLabel("Refresh the microphone list")
        }
    }

    static func symbol(for mic: LocalDeviceResolver.Microphone) -> String {
        let name = mic.name.lowercased()
        if mic.isBuiltIn { return "laptopcomputer" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("headphone") || name.contains("headset") || name.contains("buds") { return "headphones" }
        return "mic"
    }
}
