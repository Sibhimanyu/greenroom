//
//  CoordinatorController+YouTube.swift
//  Greenroom
//
//  What happens to a recording after it is saved, when the teacher has
//  turned YouTube upload on: ask, or upload, to the connected channel as
//  unlisted (or private). Off by default; nothing here runs until Settings
//  → YouTube says so and a Google account has been connected.
//
//  Seamless means: the question is a floating card that blocks nothing and
//  goes away on its own; the upload runs in the background with its
//  progress in the menu bar, not in a toast the teacher would have to
//  watch; the result arrives as a notification, a toast, and the link on
//  the clipboard. A declined or failed upload can be redone from the
//  Recordings window.
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
        switch youtubeUploadMode {
        case .ask:
            askToUpload(file)
        case .automatic:
            Task { await uploadToYouTube(file, title: youtubeTitle(for: file)) }
        case .off:
            break
        }
    }

    /// The Recordings window's button: an explicit act, so no mode check -
    /// only a connected account is needed.
    func uploadRecordingToYouTube(_ file: URL) {
        guard youtubeConnected else {
            log("Connect a Google account in Settings \u{2192} YouTube first.")
            ToastController.show("Not connected", detail: "Settings \u{2192} YouTube \u{2192} Connect Google account.", kind: .failure)
            return
        }
        Task { await uploadToYouTube(file, title: youtubeTitle(for: file)) }
    }

    /// A floating card, not a modal: the class teardown keeps running behind
    /// it, the main window stays where it is, and two minutes of silence
    /// count as "Not now".
    private func askToUpload(_ file: URL) {
        let title = youtubeTitle(for: file)
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int64 ?? 0
        let sizeLabel = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        UploadPromptCard.show(
            title: "Upload this recording to YouTube?",
            detail: "\u{201C}\(title)\u{201D} \u{00B7} \(sizeLabel) \u{00B7} \(youtubePrivacy). The file stays in Documents/Greenroom either way; you can also upload it later from Recordings.",
            onUpload: { [weak self] in
                guard let self else { return }
                Task { await self.uploadToYouTube(file, title: title) }
            },
            onDismiss: { [weak self] in
                self?.log("Not uploaded to YouTube \u{2014} the recording is in Documents/Greenroom, and Recordings has an Upload button.")
            })
    }

    /// "Morning Reading · 4 Sep 2026", or "Class · 4 Sep 2026" with no
    /// class name set. The date is the recording's, not now's, in case the
    /// upload is retried another day.
    private func youtubeTitle(for file: URL) -> String {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let name = className.trimmingCharacters(in: .whitespaces)
        return "\(name.isEmpty ? "Class" : name) \u{00B7} \(modified.formatted(date: .abbreviated, time: .omitted))"
    }

    /// Fields as Google must see them: a pasted secret often arrives with a
    /// trailing newline, and Google answers that with "invalid secret".
    private var trimmedClientID: String { youtubeClientID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedClientSecret: String { youtubeClientSecret.trimmingCharacters(in: .whitespacesAndNewlines) }

    func uploadToYouTube(_ file: URL, title: String) async {
        guard !isUploadingToYouTube else {
            log("Another upload is still running \u{2014} this recording stays in Documents/Greenroom; upload it from Recordings afterwards.")
            ToastController.show("An upload is already running", detail: "Try this one from Recordings when it finishes.", kind: .failure)
            return
        }
        isUploadingToYouTube = true
        youtubeUploadProgress = 0
        defer {
            isUploadingToYouTube = false
            youtubeUploadProgress = nil
        }

        Analytics.feature("youtube_upload", source: youtubeUploadMode.rawValue)
        log("Uploading to YouTube (\(youtubePrivacy)): \(title)\u{2026} Progress is in the menu bar; you will be told when it is done.")
        // Three seconds, then gone: the teacher is told it started and is not
        // asked to watch it.
        ToastController.show("Uploading to YouTube in the background", detail: "\(title) \u{2014} progress in the menu bar, a notification when it is done.", kind: .working, dismissAfter: 4)

        let clientID = trimmedClientID
        let clientSecret = trimmedClientSecret
        var lastLoggedQuarter = 0
        do {
            let result = try await YouTubeUploader.upload(
                file: file,
                title: title,
                description: "Recorded with Greenroom.",
                privacy: youtubePrivacy,
                token: { try await YouTubeAuth.accessToken(clientID: clientID, clientSecret: clientSecret) },
                progress: { fraction in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.youtubeUploadProgress = fraction
                        // The status log gets the quarters, not every chunk.
                        let quarter = Int(fraction * 4)
                        if quarter > lastLoggedQuarter, quarter < 4 {
                            lastLoggedQuarter = quarter
                            self.log("YouTube upload \(quarter * 25)%\u{2026}")
                        }
                    }
                })
            // The link lives with the class from now on: the Sessions window
            // shows it under the recording, and the folder carries it.
            SessionMetadata.recordUpload(of: file, videoID: result.videoID, url: result.url.absoluteString,
                                         privacy: youtubePrivacy, title: title)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.url.absoluteString, forType: .string)
            log("Uploaded to YouTube (\(youtubePrivacy)): \(result.url.absoluteString) \u{2014} link copied, and kept with the session.")
            ToastController.show("Uploaded to YouTube", detail: "Link copied: \(result.url.absoluteString)", dismissAfter: 6)
            Notifier.post(title: "Uploaded to YouTube", body: "\(title) \u{2014} the \(youtubePrivacy) link is on your clipboard.")
        } catch {
            Analytics.failure("youtube_upload")
            // Google's error prose is long; the log has all of it, the toast
            // says where to look and how to retry.
            log("YouTube upload failed: \(error.localizedDescription) \u{2014} the recording is still in Documents/Greenroom; retry from Recordings.")
            ToastController.show("YouTube upload failed",
                                 detail: "Details in the status log. The recording is saved; retry from Recordings.",
                                 kind: .failure, dismissAfter: 8)
            Notifier.post(title: "YouTube upload failed", body: "\(title) is still in Documents/Greenroom. Details in Greenroom\u{2019}s status log.")
        }
    }

    // MARK: Connect / disconnect (Settings → YouTube)

    func connectYouTube() async {
        youtubeStatus = "Waiting for Google in your browser\u{2026}"
        do {
            try await YouTubeAuth.connect(clientID: trimmedClientID, clientSecret: trimmedClientSecret)
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
