//
//  EditorConfig.swift
//  Greenroom
//
//  Written for Greenroom (not ported). Replaces Recorditor's AppPaths and the
//  three AppSettings statics the editor reads (frameRate, bitsPerPixel,
//  saveFolderOverride), and decides where an edit is saved.
//
import Foundation

enum EditorConfig {
    /// Export frame rate. Recorditor reads this from a Settings screen
    /// (30/60); Greenroom has no such setting, so it is fixed.
    static let frameRate = 30

    /// Export quality, bits per pixel per frame (Recorditor: 0.5 / 0.8 / 1.2).
    static let bitsPerPixel = 0.8

    /// The suffix on an edit's session folder.
    static let editedSuffix = "\u{2013} Edited"   // en dash

    /// Creates the folder an edit is saved into: a NEW session folder next to
    /// the original, named "<original folder name> \u{2013} Edited" (" 2", " 3" if
    /// taken). The original file and folder are never touched.
    ///
    /// When the source is not inside a session folder (a loose legacy file in
    /// the recordings root, or a file picked from elsewhere with Load Video),
    /// the folder is named from the file's own name and created in the
    /// recordings root, so the edit still shows up in Recordings.
    static func makeEditedSessionFolder(for source: URL) throws -> URL {
        let root = SessionFolders.recordingsDirectory
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let parent = source.deletingLastPathComponent().standardizedFileURL
        let inSession = parent.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
        let base = inSession ? parent.lastPathComponent
                             : source.deletingPathExtension().lastPathComponent
        let name = "\(base) \(editedSuffix)"

        var folder = root.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while fm.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(name) \(counter)", isDirectory: true)
            counter += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// Gives the new folder the display name Recordings shows: the original
    /// session's title (its custom name, else its folder name) + " \u{2013} Edited".
    static func writeMetadata(forEditIn folder: URL, source: URL) {
        let parent = source.deletingLastPathComponent()
        let inSession = parent.deletingLastPathComponent().standardizedFileURL
            == SessionFolders.recordingsDirectory.standardizedFileURL
        let original = inSession ? SessionMetadata.load(in: parent).title ?? parent.lastPathComponent
                                 : source.deletingPathExtension().lastPathComponent
        var metadata = SessionMetadata()
        metadata.title = "\(original) \(editedSuffix)"
        metadata.save(in: folder)
    }
}
