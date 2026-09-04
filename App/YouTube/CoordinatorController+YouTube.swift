//
//  CoordinatorController+YouTube.swift
//  Greenroom
//
//  What happens to a recording after it is saved, when the teacher has
//  turned YouTube upload on: ask, or upload, to the connected channel as
//  unlisted (or private). Off by default; nothing here runs until Settings
//  → YouTube says so and a Google account has been connected.
//
//  This is the one place Greenroom sends class content off the Mac, which
//  is why it is a mode with "off" first, why the ask is the recommended
//  setting, and why the safety page carries its own card for it.
//
import AppKit
import Foundation

/// Settings → YouTube → "After a recording".
enum YouTubeUploadMode: String, CaseIterable, Identifiable {
    case off, ask, automatic
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Do nothing"
        case .ask: return "Ask whether to upload"
        case .automatic: return "Upload automatically"
        }
    }
}

extension CoordinatorController {

    /// Every recording ends here - the ⌥⌘R stop and End Session's stop both
    /// call it with the final path OBS reported. Never blocks the caller:
    /// the ask, and the upload, run on their own.
    func recordingFinished(path: String) {
        guard youtubeUploadMode != .off else { return }
        guard youtubeConnected else {
            log("YouTube upload is on, but no Google account is connected \u{2014} Settings \u{2192} YouTube \u{2192} Connect.")
            return
        }
        let file = URL(fileURLWithPath: path)
        Task { await offerYouTubeUpload(file) }
    }

    private func offerYouTubeUpload(_ file: URL) async {
        let title = youtubeTitle(for: file)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 ?? 0
        let sizeLabel = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)

        if youtubeUploadMode == .ask {
            // The class just ended and Greenroom is behind the main app; the
            // question has to come forward or it is never seen.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Upload this recording to YouTube?"
            alert.informativeText = "\u{201C}\(title)\u{201D} \u{2014} \(sizeLabel), \(youtubePrivacy) on the connected channel. The file stays in Documents/Greenroom either way."
            alert.addButton(withTitle: "Upload")
            alert.addButton(withTitle: "Not now")
            guard alert.runModal() == .alertFirstButtonReturn else {
                log("Not uploaded to YouTube \u{2014} the recording is in Documents/Greenroom.")
                return
            }
        }
        await uploadToYouTube(file, title: title)
    }

    /// "Morning Reading · 4 Sep 2026", or "Class · 4 Sep 2026" with no
    /// class name set. The date is the recording's, not now's, in case the
    /// upload is retried another day.
    private func youtubeTitle(for file: URL) -> String {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let name = className.trimmingCharacters(in: .whitespaces)
        return "\(name.isEmpty ? "Class" : name) \u{00B7} \(modified.formatted(date: .abbreviated, time: .omitted))"
    }

    func uploadToYouTube(_ file: URL, title: String) async {
        guard !isUploadingToYouTube else {
            log("Another upload is still running \u{2014} this recording stays in Documents/Greenroom.")
            return
        }
        isUploadingToYouTube = true
        defer { isUploadingToYouTube = false }

        Analytics.feature("youtube_upload", source: youtubeUploadMode.rawValue)
        log("Uploading to YouTube (\(youtubePrivacy)): \(title)\u{2026}")
        ToastController.show("Uploading to YouTube\u{2026}", detail: title, kind: .working, dismissAfter: nil)

        let clientID = youtubeClientID
        let clientSecret = youtubeClientSecret
        do {
            let result = try await YouTubeUploader.upload(
                file: file,
                title: title,
                description: "Recorded with Greenroom.",
                privacy: youtubePrivacy,
                token: { try await YouTubeAuth.accessToken(clientID: clientID, clientSecret: clientSecret) },
                progress: { fraction in
                    let percent = Int((fraction * 100).rounded())
                    Task { @MainActor in
                        ToastController.show("Uploading to YouTube\u{2026} \(percent)%", detail: title,
                                             kind: .working, dismissAfter: nil)
                    }
                })
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.url.absoluteString, forType: .string)
            log("Uploaded to YouTube (\(youtubePrivacy)): \(result.url.absoluteString) \u{2014} link copied.")
            ToastController.show("Uploaded to YouTube", detail: "Link copied: \(result.url.absoluteString)", dismissAfter: 6)
            Notifier.post(title: "Uploaded to YouTube", body: "\(title) \u{2014} the \(youtubePrivacy) link is on your clipboard.")
        } catch {
            Analytics.failure("youtube_upload")
            log("YouTube upload failed: \(error.localizedDescription) \u{2014} the recording is still in Documents/Greenroom.")
            ToastController.show("Upload failed", detail: error.localizedDescription, kind: .failure, dismissAfter: 8)
        }
    }

    // MARK: Connect / disconnect (Settings → YouTube)

    func connectYouTube() async {
        youtubeStatus = "Waiting for Google in your browser\u{2026}"
        do {
            try await YouTubeAuth.connect(clientID: youtubeClientID, clientSecret: youtubeClientSecret)
            youtubeConnected = true
            youtubeStatus = "Connected. Recordings can be uploaded to this account's channel."
            log("YouTube connected.")
            Analytics.feature("youtube_connect")
        } catch {
            youtubeConnected = YouTubeAuth.isConnected
            youtubeStatus = "Not connected: \(error.localizedDescription)"
            log("YouTube connect failed: \(error.localizedDescription)")
        }
    }

    func disconnectYouTube() async {
        await YouTubeAuth.disconnect()
        youtubeConnected = false
        youtubeStatus = "Disconnected. Google has been told to revoke the grant."
        log("YouTube disconnected.")
    }
}
