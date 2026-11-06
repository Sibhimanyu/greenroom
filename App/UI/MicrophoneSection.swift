//
//  MicrophoneSection.swift
//  Greenroom
//
//  Settings -> Webcam -> Microphone: which microphone the class hears and
//  the recording takes.
//
//  Cards, like the cameras above it. "System" follows whatever macOS has as
//  its input, which is what Greenroom always did; any other card pins one
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

    private let columns = [GridItem(.adaptive(minimum: 132), spacing: 8)]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ChoiceTile(title: "System", selected: selection.isEmpty, badge: nil) {
                    symbol("gearshape", selected: selection.isEmpty)
                } action: { choose("") }
                .help("Whatever macOS uses as its input (System Settings \u{2192} Sound)")

                ForEach(microphones) { mic in
                    ChoiceTile(title: mic.name, selected: selection == mic.id, badge: nil) {
                        symbol(Self.symbol(for: mic), selected: selection == mic.id)
                    } action: { choose(mic.id) }
                    .help(mic.name)
                }

                // A pinned microphone that is not plugged in stays visible,
                // so unplugging it does not silently change the choice.
                if !selection.isEmpty, !microphones.contains(where: { $0.id == selection }) {
                    ChoiceTile(title: "Not connected", selected: true, badge: nil) {
                        symbol("mic.slash", selected: true)
                    } action: {}
                    .help("The microphone you picked isn\u{2019}t plugged in. Recording uses the system input until it is.")
                }
            }
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Look for microphones again")
                .accessibilityLabel("Refresh the microphone list")
        }
        .padding(.vertical, 4)
    }

    private func symbol(_ name: String, selected: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 22))
            .foregroundStyle(selected ? Brand.green : Color.secondary)
            .frame(height: 28)
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
