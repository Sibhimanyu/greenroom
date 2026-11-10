//
//  MicrophoneTap.swift
//  Greenroom
//
//  The microphone, read for the recorder.
//
//  The meeting opens the same microphone through the Zoom SDK. CoreAudio lets
//  several readers share one input, so this takes nothing from it. An empty uid
//  means the system's input, and a chosen microphone is its CoreAudio uid, which is
//  what AVFoundation calls `uniqueID`.
//
//  Buffers come out as 48 kHz stereo float PCM whatever the device is, so a
//  mono headset and a six-channel interface both feed the AAC encoder the same
//  shape. Timestamps are on the host clock, the same clock as the stage
//  frames (checked by the recorder's harness).
//
//  No app-only dependencies, so the recorder can be compiled and measured on
//  its own.
//

import AVFoundation
import Foundation

final class MicrophoneTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum StartResult { case running, denied, noDevice, failed(String) }

    /// Called on the tap's own queue for every buffer. Must return quickly.
    var onSamples: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "greenroom.recorder.mic.samples", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "greenroom.recorder.mic.control")
    private var configuredUID: String?

    static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Starts reading. Never prompts: asking for permission is the app's
    /// job (the meeting already does), and a recorder that pops a dialog
    /// mid-class is worse than one that records silence and says so.
    func start(uid: String, completion: @escaping (StartResult) -> Void) {
        controlQueue.async { [self] in
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                completion(.denied); return
            }
            let device = (uid.isEmpty ? nil : AVCaptureDevice(uniqueID: uid)) ?? AVCaptureDevice.default(for: .audio)
            guard let device else { completion(.noDevice); return }
            if session.isRunning { session.stopRunning() }
            for input in session.inputs { session.removeInput(input) }
            session.beginConfiguration()
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    session.commitConfiguration(); completion(.failed("cannot add input")); return
                }
                session.addInput(input)
            } catch {
                session.commitConfiguration(); completion(.failed(error.localizedDescription)); return
            }
            if !session.outputs.contains(output) {
                guard session.canAddOutput(output) else {
                    session.commitConfiguration(); completion(.failed("cannot add output")); return
                }
                session.addOutput(output)
            }
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            session.commitConfiguration()
            session.startRunning()
            configuredUID = uid
            completion(session.isRunning ? .running : .failed("session did not start"))
        }
    }

    func stop() {
        controlQueue.async { [self] in
            output.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning { session.stopRunning() }
            for input in session.inputs { session.removeInput(input) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onSamples?(sampleBuffer)
    }
}
