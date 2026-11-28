import Foundation

/// Level maths for the meeting-audio probes (Foundation only, so tests compile it).
/// Feed it samples; read peak and RMS in dBFS. Silence reads as -inf, shown "silent".
struct AudioLevelMeter {
    private(set) var peak: Double = 0        // linear, 0...1
    private var sumSquares: Double = 0
    private(set) var sampleCount: Int = 0

    mutating func add(int16 samples: UnsafeBufferPointer<Int16>) {
        for s in samples {
            let v = abs(Double(s) / 32768.0)
            peak = max(peak, v)
            sumSquares += v * v
        }
        sampleCount += samples.count
    }

    mutating func add(float32 samples: UnsafeBufferPointer<Float>) {
        for s in samples {
            let v = abs(Double(s))
            peak = max(peak, v)
            sumSquares += v * v
        }
        sampleCount += samples.count
    }

    var rms: Double { sampleCount == 0 ? 0 : (sumSquares / Double(sampleCount)).squareRoot() }
    var peakDB: Double { Self.dBFS(peak) }
    var rmsDB: Double { Self.dBFS(rms) }

    /// Fold another meter's samples into this one.
    mutating func merge(_ other: AudioLevelMeter) {
        peak = max(peak, other.peak)
        sumSquares += other.sumSquares
        sampleCount += other.sampleCount
    }

    mutating func reset() { self = AudioLevelMeter() }

    static func dBFS(_ linear: Double) -> Double {
        linear <= 0 ? -.infinity : 20 * log10(linear)
    }

    static func text(_ db: Double) -> String {
        db.isFinite ? String(format: "%.1f dBFS", db) : "silent"
    }

    /// "peak -12.3 dBFS, rms -20.1 dBFS" or "silent".
    var summary: String {
        peak == 0 ? "silent" : "peak \(Self.text(peakDB)), rms \(Self.text(rmsDB))"
    }
}

/// The probes' one switch: on in Debug builds, off in Release. Every probe file
/// is also wrapped in `#if DEBUG`, so a release binary holds none of their code.
enum AudioProbeSwitch {
    #if DEBUG
    static let enabled = true
    #else
    static let enabled = false
    #endif
}
