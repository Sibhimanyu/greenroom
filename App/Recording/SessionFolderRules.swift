//
//  SessionFolderRules.swift
//  Greenroom
//
//  Pure rules for "did this session leave anything worth keeping?". Foundation
//  only, so GreenroomTests compiles it directly.
//
import Foundation

enum SessionFolderRules {
    /// True when `url` is a file that exists and holds bytes: the only kind of
    /// video a sidecar (`<name>.events.json`) may sit beside.
    static func isNonEmptyFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        return size > 0
    }

    /// Whether a session folder is "effectively empty" and may be removed.
    ///
    /// THE RULE (conservative: anything not named here keeps the folder):
    /// every entry must be one of
    ///   - a `*.events.json` click/keystroke sidecar (useless without its video),
    ///   - `notes.jsonl` that is 0 bytes (a note file with a note in it is kept),
    ///   - `session.json` that decodes and carries nothing the person made:
    ///     no title, no uploads, no links (a kind marker alone is bookkeeping).
    /// A video, a clip, a report, notes with content, a titled session.json,
    /// an unreadable session.json, a subfolder or any other file keeps it.
    /// An empty folder is effectively empty.
    static func isEffectivelyEmpty(_ folder: URL, fileManager: FileManager = .default) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        return entries.allSatisfy { isDisposable($0, fileManager: fileManager) }
    }

    private static func isDisposable(_ url: URL, fileManager: FileManager) -> Bool {
        let name = url.lastPathComponent
        if name.hasSuffix(".events.json") { return true }
        if name == "notes.jsonl" {
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return size == 0
        }
        if name == "session.json" {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let uploads = object["uploads"] as? [Any] ?? []
            let links = object["links"] as? [Any] ?? []
            let known: Set<String> = ["title", "uploads", "links", "kind"]
            return title.isEmpty && uploads.isEmpty && links.isEmpty && Set(object.keys).isSubset(of: known)
        }
        return false
    }
}
