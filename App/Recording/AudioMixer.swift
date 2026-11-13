//
//  AudioMixer.swift
//  Greenroom
//
//  Mixes the microphone and the Mac's own sound into the ONE audio stream the
//  recording has. (Written for Greenroom. Recorditor keeps two audio tracks;
//  Greenroom's players and the ported editor expect a single AAC track.)
//
//  How it lines the two up: both sources are stamped on the host clock, the
//  same clock as the stage frames. Each buffer is placed on a 48 kHz grid by
//  its own timestamp, not by when it happened to arrive. Small jitter between a
//  buffer's stamp and where the last one ended (under 10 ms) is ignored, so a
//  steady source is copied through untouched; a bigger gap is filled with
//  silence and a bigger overlap is trimmed, so the two never drift apart by
//  more than that.
//
//  Output is cut into fixed 10 ms chunks, each stamped on the same grid, and
//  held back 150 ms so the slower source can catch up. A source that has gone
//  quiet (a muted microphone, nothing playing) simply counts as silence: the
//  other one carries the clock. The two are added at full level and clipped at
//  full scale; there is no automatic gain.
//
//  Not thread safe: SessionRecorder calls it from its one writer queue.
//  No app-only dependencies; the tests compile this file as it is.
//

import AudioToolbox
import CoreMedia
import Foundation

final class AudioMixer {
    enum Source { case microphone, system }

    /// One run of mixed audio: interleaved stereo Float32 at 48 kHz.
    struct Chunk: Equatable {
        /// Host-clock seconds of its first frame.
        var start: Double
        var samples: [Float]
        var frames: Int { samples.count / 2 }
    }

    static let sampleRate = 48_000.0
    /// 10 ms.
    static let hop = 480
    /// How long output is held back so the slower source can arrive.
    static let latencyFrames: Int64 = 7_200   // 150 ms
    /// Stamp jitter this small is not a gap or an overlap.
    static let toleranceFrames: Int64 = 480

    var onChunk: ((Chunk) -> Void)?

    private struct Lane {
        var samples: [Float] = []           // interleaved stereo
        var start: Int64 = 0                // grid frame of samples[0]
        var frames: Int64 { Int64(samples.count / 2) }
        var end: Int64 { start + frames }
    }

    private var origin: Double?             // host seconds of grid frame 0
    private var out: Int64 = 0              // next grid frame to emit
    private var mic = Lane()
    private var system = Lane()

    init() {}

    /// Drop everything; the next buffer starts a fresh grid.
    func reset() {
        origin = nil; out = 0; mic = Lane(); system = Lane()
    }

    /// Adds interleaved stereo samples whose first frame is stamped `time` (host seconds).
    func add(_ samples: [Float], at time: Double, from source: Source) {
        guard !samples.isEmpty else { return }
        if origin == nil { origin = time; out = 0 }
        let startFrame = Int64(((time - origin!) * Self.sampleRate).rounded())
        var lane = source == .microphone ? mic : system
        var input = samples[...]
        var start = startFrame

        if lane.samples.isEmpty {
            // Nothing pending: begin at the stamp, minus whatever was already emitted.
            start = max(startFrame, out)
            input = input.dropFirst(Int(start - startFrame) * 2)
            lane.start = start
        } else {
            let gap = startFrame - lane.end
            if gap > Self.toleranceFrames {
                lane.samples.append(contentsOf: repeatElement(0, count: Int(gap) * 2))
            } else if gap < -Self.toleranceFrames {
                input = input.dropFirst(Int(-gap) * 2)       // overlap: keep what we have
            }
        }
        lane.samples.append(contentsOf: input)
        if source == .microphone { mic = lane } else { system = lane }
        drain(until: max(mic.end, system.end) - Self.latencyFrames)
    }

    /// Emits everything still held (the last chunk padded with silence).
    func flush() {
        let end = max(mic.end, system.end)
        guard origin != nil, end > out else { return }
        let hops = (end - out + Int64(Self.hop) - 1) / Int64(Self.hop)
        drain(until: out + hops * Int64(Self.hop))
    }

    private func drain(until horizon: Int64) {
        guard let origin else { return }
        let hop = Int64(Self.hop)
        while out + hop <= horizon {
            var mixed = [Float](repeating: 0, count: Self.hop * 2)
            Self.mix(&mic, into: &mixed, at: out)
            Self.mix(&system, into: &mixed, at: out)
            for i in mixed.indices { mixed[i] = min(max(mixed[i], -1), 1) }
            let chunk = Chunk(start: origin + Double(out) / Self.sampleRate, samples: mixed)
            out += hop
            onChunk?(chunk)
        }
    }

    /// Adds the lane's frames for [at, at + hop) into `mixed` and drops them from the lane.
    private static func mix(_ lane: inout Lane, into mixed: inout [Float], at: Int64) {
        let hop = Int64(Self.hop)
        defer {
            // Everything before the end of this chunk is spent.
            let spent = min(max(at + hop - lane.start, 0), lane.frames)
            if spent > 0 { lane.samples.removeFirst(Int(spent) * 2); lane.start += spent }
            if lane.samples.isEmpty { lane.start = at + hop }
        }
        guard lane.frames > 0, lane.start < at + hop else { return }
        let lead = max(lane.start - at, 0)                   // silence before it begins
        let count = min(lane.frames, hop - lead)
        guard count > 0 else { return }
        for i in 0..<Int(count * 2) {
            mixed[Int(lead) * 2 + i] += lane.samples[i]
        }
    }
}

// MARK: - Sample buffer conversion

extension AudioMixer {
    /// Interleaved stereo Float32 from a CoreAudio sample buffer (the microphone's
    /// interleaved buffers and ScreenCaptureKit's planar ones both come out the
    /// same), and its first frame's host-clock seconds. Nil when the buffer is not
    /// 48 kHz Float32 PCM (nothing else is mixed, rather than mixed wrongly).
    static func floats(from buffer: CMSampleBuffer) -> (samples: [Float], time: Double)? {
        guard CMSampleBufferIsValid(buffer),
              let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              asbd.mSampleRate == sampleRate,
              asbd.mChannelsPerFrame >= 1 else { return nil }
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard frames > 0 else { return nil }

        var needed = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr,
              needed > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let channels = Int(asbd.mChannelsPerFrame)
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        var out = [Float](repeating: 0, count: frames * 2)
        if planar {
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let rightBuffer = buffers.count > 1 ? buffers[1] : buffers[0]
            guard let right = rightBuffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let available = Int(buffers[0].mDataByteSize) / 4
            for i in 0..<min(frames, available) { out[i * 2] = left[i]; out[i * 2 + 1] = right[i] }
        } else {
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
            let available = Int(buffers[0].mDataByteSize) / 4 / channels
            for i in 0..<min(frames, available) {
                out[i * 2] = data[i * channels]
                out[i * 2 + 1] = data[i * channels + (channels > 1 ? 1 : 0)]
            }
        }
        return (out, CMSampleBufferGetPresentationTimeStamp(buffer).seconds)
    }

    /// A sample buffer for a mixed chunk (interleaved stereo Float32, 48 kHz)
    /// stamped `time`. The caller has already moved `time` for any pause.
    static func sampleBuffer(samples: [Float], at time: CMTime) -> CMSampleBuffer? {
        let frames = samples.count / 2
        guard frames > 0 else { return nil }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let copied = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == noErr else { return nil }
        var out: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &out)
        return status == noErr ? out : nil
    }
}
