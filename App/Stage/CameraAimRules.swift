//
//  CameraAimRules.swift
//  Greenroom
//
//  The pure decisions behind "Aim" and behind reading a face off a camera
//  whose picture may be turned. Foundation only, so tests can pin them.
//
import Foundation

/// One Aim press: measure for a moment, then say what it found and stop.
///
/// Aim used to read for ever. The button stayed on "Looking..." until Settings
/// closed, and a camera that never sent a picture looked the same as one that
/// was thinking. Now there are three ends: a steady angle, the clock, or no
/// picture at all.
struct AimMeter {

    enum Reading: Equatable {
        case angle(Double)
        case noFace
        case noAngle
    }

    enum Outcome: Equatable {
        case measuring
        case angle(Double)
        case noFace
        case noAngle
        case noPicture
    }

    /// No frame this long after the camera opened: busy, asleep or unplugged.
    static let noPictureSeconds: Double = 3
    /// The longest an Aim lasts.
    static let maxSeconds: Double = 5
    /// This many angles in a row, all within `steadyDegrees`, is an answer.
    static let steadyCount = 3
    static let steadyDegrees: Double = 8

    private(set) var elapsed: Double = 0
    private(set) var frames = 0
    private var angles: [Double] = []
    private var last: Reading?

    /// A picture was looked at and this is what it showed.
    mutating func note(_ reading: Reading) {
        frames += 1
        last = reading
        if case .angle(let degrees) = reading { angles.append(degrees) } else { angles.removeAll() }
    }

    /// Time passing, and the verdict so far.
    mutating func advance(by seconds: Double) -> Outcome {
        elapsed += seconds
        return outcome
    }

    var outcome: Outcome {
        let recent = Array(angles.suffix(Self.steadyCount))
        if recent.count == Self.steadyCount,
           let low = recent.min(), let high = recent.max(), high - low <= Self.steadyDegrees {
            return .angle(Self.median(recent))
        }
        if elapsed >= Self.maxSeconds {
            if !recent.isEmpty { return .angle(Self.median(recent)) }
            switch last {
            case .noAngle?: return .noAngle
            case .noFace?: return .noFace
            default: return frames == 0 ? .noPicture : .noFace
            }
        }
        if frames == 0, elapsed >= Self.noPictureSeconds { return .noPicture }
        return .measuring
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}

/// Which way up a camera's picture is, judged from the roll Vision reports.
///
/// Vision measures yaw against the picture's own up. A Continuity Camera
/// picture that arrives on its side has a head rolled a quarter turn, and the
/// "yaw" read off it is not the turn of the head at all. The roll gives it
/// away: when it is large, look again with the picture turned each way and
/// keep the look where the head is most upright. (Sign-agnostic on purpose:
/// the look with the smallest |roll| wins, whichever way it was turned.)
enum FaceUpright {

    /// Past this roll the picture is taken to be on its side.
    static let rollLimitDegrees: Double = 35

    static func isSideways(rollDegrees: Double) -> Bool { abs(rollDegrees) > rollLimitDegrees }

    /// Index of the candidate look with the most upright head, or nil for
    /// none. Candidates with no face are nil. Ties go to the earlier one, so
    /// the picture as it came wins when it is already fine.
    static func mostUpright(_ rolls: [Double?]) -> Int? {
        var best: Int?
        for (index, roll) in rolls.enumerated() {
            guard let roll else { continue }
            if best == nil || abs(roll) < abs(rolls[best!]!) - 0.0001 { best = index }
        }
        return best
    }
}
