//
//  DevicesSettingsTab.swift
//  Greenroom
//
//  Settings -> Devices: the hardware Greenroom uses and how it records.
//  Cameras (cards, the second-camera cut and its aim), the microphone, the
//  four Recording toggles and "Other apps' recordings". Moved here from the
//  Webcam tab unchanged: same controls, same defaults keys.
//
import SwiftUI

struct DevicesSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController

    var body: some View {
        Form {
            Section("Camera") { CameraSwitchSection() }
            Section("Microphone") { MicrophoneSection() }
            Section("Recording") {
                Toggle("Keep the last 5 minutes clippable", isOn: $coordinator.clipBufferEnabled)
                    .help("The clip shortcuts (Settings \u{2192} Shortcuts) save the last minutes as a clip, recording or not. About 300 MB of memory, nothing on disk until you press.")
                Toggle("Record automatically with the meeting", isOn: $coordinator.autoRecordOnStart)
                    .help("Off: press Record or \(ShortcutStore.phrase(.toggleRecording)). Files land in Documents/Greenroom.")
                Picker("Countdown before recording", selection: $coordinator.recordingCountdownSeconds) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                .help("A big number counts down on screen before a recording you start begins. Esc or Cancel stops it. A recording that starts by itself with the meeting has no countdown.")
                #if DEBUG
                if Shelved.macSound {
                    Toggle("Record the Mac\u{2019}s sound \(Shelved.macSoundCaption)", isOn: $coordinator.recordSystemAudio)
                        .help("\(Shelved.macSoundCaption) Adds what is playing from the screen or app you share (a video, a call) to the recording, mixed with your microphone. Greenroom\u{2019}s own sound is left out, so the meeting is not doubled. Needs something shared under Behind you.")
                }
                #endif
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
