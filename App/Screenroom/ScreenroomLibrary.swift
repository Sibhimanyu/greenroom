//
//  ScreenroomLibrary.swift
//  Greenroom
//
//  Finding the presentations already on disk.
//
//  There is no index, no database and no list held anywhere. The folders ARE
//  the library, which is the whole point of approach A: a presentation copied
//  off this Mac still works, a folder deleted in the Finder is really gone,
//  and nothing can drift out of step with the files because there is nothing
//  else to drift.
//
//  A folder is a Screenroom presentation when it contains notes.jsonl. Not when it
//  contains a recording - classes have those too - and not by a marker file,
//  which would be one more thing to write, forget to write, and have to
//  repair.
//
import Foundation

struct ScreenroomPresentation: Identifiable, Hashable {
    let folder: URL
    /// The name the teacher typed, from session.json, falling back to the
    /// folder name with its timestamp trimmed off.
    let presenter: String
    let presentedAt: Date
    let recording: URL?
    let noteCount: Int
    var id: URL { folder }

    var hasRecording: Bool { recording != nil }

    func notes() -> [ScreenroomNote] { ScreenroomNotesFile.load(in: folder) }
    func scoring() -> ScreenroomScoring? { ScreenroomScoring.load(in: folder) }
    func analysis() -> ScreenroomAnalysis? { ScreenroomAnalysis.load(in: folder) }
    var hasReport: Bool {
        FileManager.default.fileExists(atPath: ScreenroomReport.url(in: folder).path)
    }

    var dateLabel: String {
        presentedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

enum ScreenroomLibrary {

    /// Every session under ~/Documents/Greenroom, newest first - classes and
    /// presentations alike.
    ///
    /// It used to list only folders containing notes.jsonl, which meant a
    /// class recorded through Greenroom's own Start button was invisible here
    /// even though the analysis works on it perfectly well: a transcript,
    /// filler counts, pace and an agent pass need a recording, not notes. The
    /// notes are what a presentation has EXTRA, not what makes a folder
    /// worth opening.
    ///
    /// One level deep, because that is how deep sessions go. A recursive walk
    /// would also find clips folders and anything a teacher dragged in, and
    /// would get slower every term for no gain.
    static func presentations() -> [ScreenroomPresentation] {
        let root = GreenroomScene.recordingsDirectory
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        return folders.compactMap { folder -> ScreenroomPresentation? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }

            let notes = ScreenroomNotesFile.load(in: folder)
            let recording = recording(in: folder)
            // A folder earns a place here by holding something to analyse.
            // Notes with no recording still qualify - the notes are the point.
            guard recording != nil || !notes.isEmpty else { return nil }

            let metadata = SessionMetadata.load(in: folder)
            return ScreenroomPresentation(
                folder: folder,
                presenter: metadata.title ?? trimStamp(from: folder.lastPathComponent),
                presentedAt: date(of: folder),
                recording: recording,
                noteCount: notes.count)
        }
        .sorted { $0.presentedAt > $1.presentedAt }
    }

    /// The recording to analyse in a folder, whatever produced it.
    ///
    /// `presentation.mov` when Screenroom recorded it, and otherwise the
    /// largest playable file that is not a clip and not something Screenroom
    /// itself wrote. Largest rather than first: a class whose tape was stopped
    /// and restarted leaves several files, and the long one is the class.
    static func recording(in folder: URL) -> URL? {
        let manager = FileManager.default
        let own = folder.appendingPathComponent(ScreenroomRecorder.recordingFileName)
        if manager.fileExists(atPath: own.path) { return own }

        guard let files = try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }

        return files.filter { file in
            let name = file.lastPathComponent
            return playableExtensions.contains(file.pathExtension.lowercased())
                && !name.hasPrefix(SessionClipExporter.clipPrefix)
                && name != ScreenroomVideoExport.annotatedFileName
        }
        .max {
            let a = (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let b = (try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return a < b
        }
    }

    static let playableExtensions = ["mov", "mp4", "mkv", "m4v"]

    /// Everything marked, shaped for the consistency pass.
    ///
    /// Presentations with no rubric saved are dropped rather than counted as
    /// zero: a presentation nobody marked says nothing about how the marker
    /// was marking.
    static func cohortEntries() -> [ScreenroomCohort.Entry] {
        presentations().compactMap { presentation in
            guard let scoring = presentation.scoring() else { return nil }
            return ScreenroomCohort.Entry(
                folder: presentation.folder,
                presenter: presentation.presenter,
                scoring: scoring,
                // When the rubric was marked, not when the presentation
                // happened - the order effect is about the marking session,
                // and a teacher may well mark a week's presentations in one
                // sitting on Friday.
                markedAt: scoring.markedAt ?? presentation.presentedAt)
        }
    }

    // MARK: Folder names

    /// `Priya Raman - 2026-09-18 10-44` -> `Priya Raman`.
    ///
    /// The stamp's shape is fixed by GreenroomScene.sessionFolderName, so this
    /// looks for that shape rather than splitting on the last dash - a
    /// presenter called "Jean-Luc" would lose half a name to a naive split.
    static func trimStamp(from folderName: String) -> String {
        let pattern = #" - \d{4}-\d{2}-\d{2} \d{2}-\d{2}$"#
        guard let range = folderName.range(of: pattern, options: .regularExpression) else {
            return folderName
        }
        return String(folderName[folderName.startIndex..<range.lowerBound])
    }

    /// When the presentation happened: read out of the folder name, which is
    /// the only record that survives a copy, with the folder's creation date
    /// as the fallback.
    static func date(of folder: URL) -> Date {
        let name = folder.lastPathComponent
        if let range = name.range(of: #"\d{4}-\d{2}-\d{2} \d{2}-\d{2}$"#, options: .regularExpression),
           let parsed = stampFormatter.date(from: String(name[range])) {
            return parsed
        }
        return (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter
    }()
}
