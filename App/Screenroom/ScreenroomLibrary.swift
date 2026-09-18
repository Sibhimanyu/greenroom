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

    /// Every presentation under ~/Documents/Greenroom, newest first.
    ///
    /// One level deep, because that is how deep sessions go. A recursive walk
    /// would also find clips folders and anything a teacher dragged in there,
    /// and would get slower every term for no gain.
    static func presentations() -> [ScreenroomPresentation] {
        let root = GreenroomScene.recordingsDirectory
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        return folders.compactMap { folder -> ScreenroomPresentation? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let notesFile = ScreenroomNotesFile.url(in: folder)
            guard FileManager.default.fileExists(atPath: notesFile.path) else { return nil }

            let recording = folder.appendingPathComponent(ScreenroomRecorder.recordingFileName)
            let hasRecording = FileManager.default.fileExists(atPath: recording.path)
            let metadata = SessionMetadata.load(in: folder)

            return ScreenroomPresentation(
                folder: folder,
                presenter: metadata.title ?? trimStamp(from: folder.lastPathComponent),
                presentedAt: date(of: folder),
                recording: hasRecording ? recording : nil,
                noteCount: ScreenroomNotesFile.load(in: folder).count)
        }
        .sorted { $0.presentedAt > $1.presentedAt }
    }

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
