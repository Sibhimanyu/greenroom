//
//  SessionFolders.swift
//  Greenroom
//
//  Where recordings live, what a session folder is called, and how much room
//  is left for them. Used by the coordinator, the recordings list and
//  Screenroom.
//
import Foundation

enum SessionFolders {

    /// How much of the class the clip buffer holds. The shortcuts offer 1, 2
    /// and 5 minutes, so five is the most that can be asked for.
    static let clipBufferSeconds = 300

    /// Where recordings land on every Mac: ~/Documents/Greenroom, created
    /// on demand.
    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Greenroom", isDirectory: true)
    }

    /// One folder per session, holding that class's recording and its clips.
    ///
    /// Recordings used to land flat in `recordingsDirectory`, named by the recorder's
    /// timestamp, so a term's worth of classes was a wall of identical-looking
    /// files. A folder per session gives the clips somewhere to live and gives
    /// the class a name a human chose.
    ///
    /// The date is always present even when a name was given: two runs of the
    /// same class on the same day would otherwise collide, and a teacher who
    /// records the same lesson twice is exactly who needs to tell them apart.
    /// `fallback` names the thing when nobody typed a name.
    ///
    /// "Green" for a Greenroom session, "Screen" for a Screenroom one. Named
    /// from the two halves of the app rather than from what they contain:
    /// "Class" and "Presentation" are words this app does not otherwise use,
    /// and an unnamed folder should carry the same vocabulary as the tab it
    /// appears under.
    static func sessionFolderName(className: String, started: Date,
                                  fallback: String = "Green") -> String {
        let stamp = sessionStampFormatter.string(from: started)
        let cleaned = sanitizedClassName(className)
        return cleaned.isEmpty ? "\(fallback) - \(stamp)" : "\(cleaned) - \(stamp)"
    }

    /// A folder that does not already exist, by adding "(2)", "(3)" and so on.
    ///
    /// The stamp is minute-resolution, which is plenty for classes - nobody
    /// starts two a minute apart - and not enough for presentations, which
    /// run two minutes each and get recorded back to back. Two in one minute
    /// produced the SAME folder name, and Screenroom deletes an existing
    /// presentation.mov before recording on the grounds that it must be a
    /// previous attempt at the same presentation. So the second student's
    /// recording destroyed the first student's.
    ///
    /// Reachable only rarely while a name was required and every unnamed one
    /// would have collided the moment it stopped being.
    static func uniqueSessionFolder(named name: String, in root: URL) -> URL {
        let manager = FileManager.default
        var candidate = root.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        // A folder that exists but holds nothing is a session that was
        // started and abandoned; reusing it is right, and stop() already
        // removes those.
        while manager.fileExists(atPath: candidate.path),
              let contents = try? manager.contentsOfDirectory(atPath: candidate.path),
              !contents.isEmpty {
            candidate = root.appendingPathComponent("\(name) (\(counter))", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    /// Trims a typed class name down to something safe as a folder name.
    ///
    /// `/` and `:` are the two characters the filesystem and Finder disagree
    /// about, and a name long enough to break path limits is not a name anyone
    /// meant to type. Runs of whitespace collapse so a stray double space does
    /// not produce two different folders for the same class.
    static func sanitizedClassName(_ raw: String) -> String {
        let stripped = raw.components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
        let collapsed = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    private static let sessionStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Hyphens, not colons: a colon is a path separator to Finder and shows
        // up as a slash in the sidebar.
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter
    }()
    // MARK: Recording disk space

    /// How much room is left for recordings, in bytes, on the volume that
    /// actually holds them.
    ///
    /// `volumeAvailableCapacityForImportantUsage` rather than the raw free
    /// count or the "opportunistic" variant: it is the number macOS will
    /// really let a foreground write consume, because it counts purgeable
    /// caches the system is willing to evict. The raw count understates what
    /// is available and would cry wolf.
    static var recordingsFreeBytes: Int64? {
        let directory = recordingsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// What the recordings themselves currently occupy.
    ///
    /// Walks the tree rather than the top level: recordings live in a folder per
    /// session now, so a flat scan would have reported the disk filling up with
    /// nothing in it.
    static var recordingsUsedBytes: Int64 {
        let directory = recordingsDirectory
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// How worried to be about the space left.
    ///
    /// The thresholds are sized in CLASSES, not abstract gigabytes. A 1080p
    /// composite runs roughly 60 MB a minute, so an hour-long class costs
    /// about 3.5 GB: `critical` is therefore "this class might not fit" and
    /// `low` is "you have a couple left before it won't". Deliberately
    /// generous, since running out mid-class is unrecoverable and a warning
    /// that arrives too late is no warning at all.
    enum SpaceLevel {
        case ok, low, critical

        /// Roughly one class of recording.
        static let criticalBytes: Int64 = 4 * 1_000_000_000
        /// Roughly three.
        static let lowBytes: Int64 = 12 * 1_000_000_000
    }

    static func spaceLevel(freeBytes: Int64) -> SpaceLevel {
        if freeBytes < SpaceLevel.criticalBytes { return .critical }
        if freeBytes < SpaceLevel.lowBytes { return .low }
        return .ok
    }

    /// Human-readable free space, or nil when the volume could not be read.
    static var recordingsFreeLabel: String? {
        recordingsFreeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}
