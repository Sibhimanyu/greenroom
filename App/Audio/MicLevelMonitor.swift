//
//  MicLevelMonitor.swift
//  Greenroom
//
//  A real, live level for YOUR microphone.
//
//  Worth recording why this exists rather than using the SDK. Zoom does expose
//  `onMicLevelChanged:`, but it sits on ZoomSDKSettingTestMicrophoneDeviceHelper
//  and only fires while `startRecordingMic:` is running - a device test that
//  would fight the live meeting for the microphone. There is no live level API
//  for the local user, and none at all for other participants: the roster offers
//  `isTalking`, a boolean, and nothing more.
//
//  So this taps the default input device directly with AVAudioEngine, alongside
//  Zoom rather than through it. CoreAudio permits several readers of one input
//  device, so both can listen at once.
//
//  Honesty matters here: this measures the microphone, not what Zoom transmits.
//  If Zoom is muted the meter still moves, which is exactly what a teacher needs
//  to see - "your mic hears you, but the class cannot" is the single most common
//  confusion in a video call, and a meter that went dead on mute would hide it.
//
import AVFoundation
import Foundation

@MainActor
final class MicLevelMonitor: ObservableObject {

    /// 0...1, already smoothed and perceptually scaled for a bar.
    @Published private(set) var level: Double = 0

    /// True once a tap is genuinely running, so callers can hide the meter
    /// rather than show a permanently empty one.
    @Published private(set) var isRunning = false

    private let engine = AVAudioEngine()
    /// Attack is fast and release is slow, the way a hardware meter behaves.
    /// Symmetric smoothing either looks twitchy or feels laggy.
    private let attack = 0.5
    private let release = 0.12
    private var smoothed: Double = 0

    func start() {
        guard !isRunning else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // A zero sample rate means no usable input device. Installing a tap on
        // that format throws inside CoreAudio rather than returning an error.
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }

            // RMS, not peak: peak jumps on every consonant and reads as noise.
            var sum: Float = 0
            for index in 0..<count {
                let sample = channel[index]
                sum += sample * sample
            }
            let rms = (sum / Float(count)).squareRoot()

            // dBFS, then mapped across a 50 dB window. A linear amplitude bar
            // spends most of its travel invisible - speech sits far below full
            // scale - so this is the range that actually moves for a voice.
            let db = 20 * log10(max(Double(rms), 1e-7))
            let normalised = max(0, min(1, (db + 50) / 50))

            Task { @MainActor [weak self] in
                self?.apply(normalised)
            }
        }

        do {
            try engine.start()
            isRunning = true
        } catch {
            // Silent by design. A missing or busy input device is not something
            // to interrupt a class about; the meter simply does not appear.
            input.removeTap(onBus: 0)
        }
    }

    private func apply(_ value: Double) {
        let coefficient = value > smoothed ? attack : release
        smoothed += (value - smoothed) * coefficient
        level = smoothed
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        smoothed = 0
        level = 0
    }
}
