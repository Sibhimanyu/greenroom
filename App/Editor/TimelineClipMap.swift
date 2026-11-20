import Foundation

/// Pure timeline arithmetic for the editor's bar: which clip a timeline time
/// falls in, and how many filmstrip tiles a stretch of the bar gets. The bar
/// lays the main video first and the joined clips after it, each at its FULL
/// duration (trim only shades it); speed changes are dropped while clips are
/// joined, so nothing here needs a speed factor.
enum TimelineClipMap {

    struct Location: Equatable {
        /// nil = the main video, otherwise the index into the joined clips.
        let clipIndex: Int?
        /// Seconds into that clip's own file.
        let localTime: Double
    }

    /// Timeline time -> (clip, local time). Mirrors `EditorViewModel.seek(to:)`:
    /// a boundary belongs to the clip that ends there, and times past the end
    /// land on the end of the last clip.
    static func locate(_ time: Double, mainDuration: Double,
                       clipDurations: [Double]) -> Location {
        let total = mainDuration + clipDurations.reduce(0, +)
        let t = min(max(time, 0), total)
        if t <= mainDuration || clipDurations.isEmpty {
            return Location(clipIndex: nil, localTime: min(t, mainDuration))
        }
        var offset = mainDuration
        for (index, duration) in clipDurations.enumerated() {
            if t <= offset + duration || index == clipDurations.count - 1 {
                return Location(clipIndex: index,
                                localTime: min(max(t - offset, 0), duration))
            }
            offset += duration
        }
        return Location(clipIndex: nil, localTime: mainDuration)
    }

    /// Where a clip's own time sits on the timeline, honouring that clip's trim
    /// (`local` is clamped to [trimStart, trimEnd]).
    static func timelineTime(clipIndex: Int, local: Double, mainDuration: Double,
                             clipDurations: [Double], trimStart: Double,
                             trimEnd: Double) -> Double {
        guard clipDurations.indices.contains(clipIndex) else { return mainDuration }
        let offset = mainDuration + clipDurations.prefix(clipIndex).reduce(0, +)
        return offset + min(max(local, trimStart), max(trimStart, trimEnd))
    }

    /// Tiles for a stretch `width` points wide, at tiles `tileWidth` wide.
    /// Rounded up to a multiple of 6 so small resizes reuse the cache.
    static func tileCount(width: Double, tileWidth: Double) -> Int {
        guard tileWidth > 0 else { return 1 }
        let raw = max(1, Int(ceil(max(0, width) / tileWidth)))
        return min(120, ((raw + 5) / 6) * 6)
    }

    /// Centres of `count` equal slices of a clip, in the clip's own time.
    static func sampleTimes(duration: Double, count: Int) -> [Double] {
        guard duration > 0, count > 0 else { return [] }
        return (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
    }
}
