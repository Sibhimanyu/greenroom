//
//  CoordinatorController+YouTube.swift
//  Greenroom
//
//  What happens to a recording after it is saved, and the YouTube account.
//
//  Two ways to YouTube, both always offered:
//  - Upload from Greenroom: Sign in with Google (Greenroom's shared Google
//    app by default, or your own, YouTubeRouteRules), then the upload sheet
//    (YouTubeUploadSheet): title and description from the session, Unlisted
//    by default, a required Made for Kids answer, and the YouTube Terms line
//    (API Services Terms §9.1). The upload runs in the background with its
//    progress in the menu bar; the link lands on the clipboard.
//  - Upload in YouTube Studio: no sign-in at all. Opens YouTube's upload
//    page, shows the recording in Finder, and copies the title and
//    description (YouTubeStudioHandoff).
//
//  This is the one place Greenroom sends meeting content off the Mac, which
//  is why "After a recording" is a mode with "Do nothing" first, and why
//  every upload from the sheet is the person's own click.
//
import AppKit
import Foundation

/// The upload sheet's starting values.
struct YouTubeUploadDraft: Identifiable, Equatable {
    let id = UUID()
    let file: URL
    var title: String
    var description: String
}

/// An upload that did not go through, kept so the session page and the
/// toast can offer the way on.
struct YouTubeUploadFailure: Equatable {
    let file: URL
    let details: YouTubeUploadDetails
    let problem: YouTubeProblem
}

extension CoordinatorController {

    // MARK: Which Google app

    var youtubeRouteFacts: YouTubeRouteFacts {
        YouTubeRouteFacts(prefersOwnApp: youtubeUsesOwnApp, sharedClientID: YouTubeOAuth.sharedClient.id,
                          ownClientID: youtubeClientID, ownClientSecret: youtubeClientSecret)
    }

    /// What Sign in with Google uses now. Read from views, so it does not
    /// load the secret itself: whoever shows it calls loadSecretsIfNeeded().
    var youtubeSignInRoute: YouTubeRoute {
        YouTubeRouteRules.signInRoute(youtubeRouteFacts)
    }

    /// The chosen option's account, for Settings, the guide and the upload sheet.
    var youtubeAccountFacts: YouTubeAccountFacts {
        YouTubeAccountFacts(route: youtubeRouteFacts, signedIn: youtubeConnected, tokenApp: YouTubeAuth.tokenApp,
                            channelName: youtubeChannel?.name, signingIn: youtubeSigningIn)
    }

    var youtubeAccountChoice: YouTubeAccountChoice { YouTubeAccountRules.choice(youtubeAccountFacts) }

    /// Uploads can go: signed in through the CHOSEN Google app. A sign-in from
    /// the other app never stands in for it (no silent fallback).
    var youtubeReadyToUpload: Bool {
        loadSecretsIfNeeded()
        return youtubeAccountChoice.readyToUpload
    }

    /// The setup guide's YouTube step, at a spot (Settings' "Set up… / Edit setup…").
    func openYouTubeSetupGuide(at spot: YouTubeGuideSpot = .ownApp) {
        NSApp.activate(ignoringOtherApps: true)
        youtubeGuideSpot = spot
        presentOnboarding()
    }

    /// The client for an app. Your own: the pasted fields, trimmed (a pasted
    /// secret often arrives with a trailing newline, and Google answers that
    /// with "invalid secret").
    private func youtubeClient(_ app: YouTubeGoogleApp) -> YouTubeOAuthClient {
        switch app {
        case .shared: return YouTubeOAuth.sharedClient
        case .own:
            loadSecretsIfNeeded()
            return YouTubeOAuthClient(id: youtubeClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                      secret: youtubeClientSecret.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Access tokens for the stored sign-in, refreshed with the app that issued it.
    func youtubeTokenProvider() -> () async throws -> String {
        let client = youtubeClient(YouTubeAuth.tokenApp)
        return { try await YouTubeAuth.accessToken(client: client) }
    }

    private var youtubeTokenIsShared: Bool { YouTubeAuth.tokenApp == .shared }

    // MARK: After a recording

    /// Every recording ends here - the ⌃⌥⌘R stop and End Session's stop both
    /// call it with the final path the recorder reported. Never blocks the
    /// caller. Once nothing is live, the after-session card shows (its Upload
    /// opens the upload sheet); a recording stopped mid-meeting waits for the
    /// meeting to end. Automatic upload starts at once, when it can.
    func recordingFinished(path: String) {
        let file = URL(fileURLWithPath: path)
        lastFinishedRecording = file
        if !phase.isSessionUp { presentFinishedSession() }
        guard youtubeUploadMode == .automatic else { return }
        guard youtubeReadyToUpload else {
            log("YouTube upload is on, but nobody is signed in through the chosen Google app \u{2014} the card after the meeting has Upload to YouTube.")
            return
        }
        guard let madeForKids = youtubeMadeForKids else {
            log("Automatic YouTube upload needs the Made for Kids answer in Settings \u{2192} YouTube; not uploaded.")
            return
        }
        let draft = youtubeDraft(for: file)
        let details = YouTubeUploadDetails(title: draft.title, description: draft.description,
                                           privacy: youtubePrivacy, madeForKids: madeForKids)
        Task { await uploadToYouTube(file, details: details) }
    }

    /// Opens the upload sheet for a recording. `title` is the session's name
    /// when the caller knows it.
    func presentYouTubeUpload(_ file: URL, title: String? = nil) {
        loadSecretsIfNeeded()
        var draft = youtubeDraft(for: file)
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { draft.title = title }
        youtubeUploadDraft = draft
    }

    /// The sheet's starting title and description: the session's name (or the
    /// meeting name and the date), and the day it was recorded.
    private func youtubeDraft(for file: URL) -> YouTubeUploadDraft {
        let recorded = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        let saved = SessionMetadata.load(in: file.deletingLastPathComponent()).title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = className.trimmingCharacters(in: .whitespaces)
        let title = saved.flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(name.isEmpty ? "Meeting" : name) \u{00B7} \(recorded.formatted(date: .abbreviated, time: .omitted))"
        return YouTubeUploadDraft(file: file, title: title,
                                  description: YouTubeUploadRules.defaultDescription(recordedOn: recorded))
    }

    /// The sheet's Upload. The Made for Kids answer is remembered for next time.
    func startYouTubeUpload(_ file: URL, details: YouTubeUploadDetails) {
        youtubeMadeForKids = details.madeForKids
        youtubeUploadDraft = nil
        Task { await uploadToYouTube(file, details: details) }
    }

    /// After a failed call: if Google ended the sign-in, the stored token is
    /// already cleared, so make Settings show Sign in instead of the channel.
    /// Returns true when that happened.
    @discardableResult
    private func noteSignInLostIfNeeded() -> Bool {
        guard youtubeConnected, !YouTubeAuth.isConnected else { return false }
        youtubeConnected = false
        youtubeChannel = nil
        youtubeStatus = "Not connected: your Google sign-in has ended. Sign in again."
        return true
    }

    func uploadToYouTube(_ file: URL, details: YouTubeUploadDetails) async {
        // The secret is only read from storage when Settings opens; a recording
        // can finish before that on a fresh launch.
        loadSecretsIfNeeded()
        guard !isUploadingToYouTube else {
            log("Another upload is still running \u{2014} this recording stays in Documents/Greenroom; upload it from Sessions afterwards.")
            ToastController.show("An upload is already running", detail: "Try this one from Sessions when it finishes.", kind: .failure)
            return
        }
        guard youtubeReadyToUpload else {
            reportYouTubeFailure(file, details, YouTubeErrorRules.problem(.notSignedIn, sharedApp: !youtubeUsesOwnApp))
            return
        }
        isUploadingToYouTube = true
        youtubeUploadProgress = 0
        if youtubeFailure?.file == file { youtubeFailure = nil }
        defer {
            isUploadingToYouTube = false
            youtubeUploadProgress = nil
        }

        let privacy = details.privacy
        Analytics.feature("youtube_upload", source: youtubeUploadMode.rawValue)
        log("Uploading to YouTube (\(privacy), made for kids: \(details.madeForKids ? "yes" : "no")): \(details.title)\u{2026} Progress is in the menu bar.")
        ToastController.show("Uploading to YouTube in the background", detail: "\(details.title) \u{2014} progress in the menu bar, a notification when it is done.", kind: .working, dismissAfter: 4)

        var lastLoggedQuarter = 0
        do {
            let result = try await YouTubeUploader.upload(
                file: file,
                details: details,
                token: youtubeTokenProvider(),
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
            // The link lives with the session from now on: Sessions shows it
            // under the recording, and the folder carries it.
            SessionMetadata.recordUpload(of: file, videoID: result.videoID, url: result.url.absoluteString,
                                         privacy: privacy, title: YouTubeUploadRules.title(details.title))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.url.absoluteString, forType: .string)
            log("Uploaded to YouTube (\(privacy)): \(result.url.absoluteString) \u{2014} link copied, and kept with the session.")
            ToastController.show("Uploaded to YouTube", detail: "Link copied: \(result.url.absoluteString)")
            Notifier.post(title: "Uploaded to YouTube", body: "\(details.title) \u{2014} the \(privacy) link is on your clipboard.")
        } catch {
            Analytics.failure("youtube_upload")
            log("YouTube upload failed: \(error.localizedDescription) \u{2014} the recording is still in Documents/Greenroom.")
            noteSignInLostIfNeeded()
            reportYouTubeFailure(file, details, youtubeProblem(for: error))
        }
    }

    /// Plain words and buttons for any error from sign-in or upload.
    func youtubeProblem(for error: Error) -> YouTubeProblem {
        let shared = youtubeTokenIsShared
        switch error {
        case YouTubeAuth.AuthError.signInExpired:
            return YouTubeErrorRules.problem(.signInEnded, sharedApp: shared)
        case YouTubeAuth.AuthError.notConnected:
            return YouTubeErrorRules.problem(.notSignedIn, sharedApp: shared)
        case YouTubeUploader.UploadError.unreadable:
            return YouTubeErrorRules.problem(.unreadable, sharedApp: shared)
        case YouTubeUploader.UploadError.gaveUp, is URLError:
            return YouTubeErrorRules.problem(.connection, sharedApp: shared)
        case YouTubeUploader.UploadError.api(let status, let reason, let message):
            return YouTubeErrorRules.problem(status: status, reason: reason, message: message, sharedApp: shared)
        default:
            var p = YouTubeErrorRules.problem(.other, sharedApp: shared)
            p.detail = error.localizedDescription
            return p
        }
    }

    private func reportYouTubeFailure(_ file: URL, _ details: YouTubeUploadDetails, _ problem: YouTubeProblem) {
        let failure = YouTubeUploadFailure(file: file, details: details, problem: problem)
        youtubeFailure = failure
        // The toast's click is the first way on; the session page shows all of them.
        let first = problem.actions.first
        ToastController.show(problem.title,
                             detail: "\(problem.detail) \(YouTubeErrorRules.savedNote)"
                                + (first.map { " Click to \($0.title.lowercased())." } ?? ""),
                             kind: .failure,
                             action: first.map { action in { [weak self] in self?.performYouTubeAction(action, failure: failure) } })
        Notifier.post(title: problem.title, body: "\(details.title): \(problem.detail)")
    }

    /// A problem's button.
    func performYouTubeAction(_ action: YouTubeAction, failure: YouTubeUploadFailure?) {
        switch action {
        case .signIn, .signInAnother:
            Task { await signInToYouTube() }
        case .openStudio:
            if let failure {
                uploadInYouTubeStudio(failure.file, title: failure.details.title, description: failure.details.description)
            } else {
                NSWorkspace.shared.open(YouTubeStudioHandoff.uploadURL)
            }
        case .tryAgain:
            guard let failure else { return }
            Task { await uploadToYouTube(failure.file, details: failure.details) }
        case .createChannel:
            NSWorkspace.shared.open(YouTubeUploadRules.createChannelURL)
        case .openCloudConsole:
            NSWorkspace.shared.open(YouTubeUploadRules.cloudConsoleURL)
        }
    }

    // MARK: Upload in YouTube Studio (no sign-in)

    /// Opens YouTube's upload page, shows the recording in Finder selected,
    /// and copies the title and description.
    func uploadInYouTubeStudio(_ file: URL, title: String, description: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(YouTubeStudioHandoff.clipboardText(title: title, description: description),
                                       forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([file])
        NSWorkspace.shared.open(YouTubeStudioHandoff.uploadURL)
        youtubeUploadDraft = nil
        Analytics.feature("youtube_studio_handoff")
        log("Opened YouTube Studio for \(file.lastPathComponent); title and description copied.")
        ToastController.show(YouTubeStudioHandoff.toastTitle, detail: YouTubeStudioHandoff.toastDetail)
    }

    // MARK: Rename on YouTube (Sessions window)

    /// Changes the title of an uploaded video and remembers it in the session
    /// folder. Returns nil on success, or the message to show.
    func renameYouTubeVideo(_ upload: SessionMetadata.Upload, in folder: URL, to title: String) async -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The title cannot be empty." }
        guard youtubeConnected else { return YouTubeAuth.AuthError.notConnected.localizedDescription }
        do {
            try await YouTubeUploader.rename(
                videoID: upload.videoID, title: trimmed, description: "Recorded with Greenroom.",
                token: youtubeTokenProvider())
            SessionMetadata.updateUploadTitle(videoID: upload.videoID, to: trimmed, in: folder)
            Analytics.feature("youtube_rename")
            log("Renamed on YouTube: \u{201C}\(trimmed)\u{201D} (\(upload.url)).")
            return nil
        } catch {
            noteSignInLostIfNeeded()
            log("Couldn't rename on YouTube: \(error.localizedDescription)")
            let p = youtubeProblem(for: error)
            return "\(p.title). \(p.detail)"
        }
    }

    // MARK: Delete from YouTube (Sessions window)

    /// Deletes an uploaded video from the channel and forgets its link.
    /// The recording on this Mac is not touched. Returns nil on success, or
    /// the message to show.
    func deleteYouTubeVideo(_ upload: SessionMetadata.Upload, in folder: URL) async -> String? {
        guard youtubeConnected else { return YouTubeAuth.AuthError.notConnected.localizedDescription }
        do {
            try await YouTubeUploader.delete(videoID: upload.videoID, token: youtubeTokenProvider())
            SessionMetadata.forgetUpload(videoID: upload.videoID, in: folder)
            Analytics.feature("youtube_delete")
            log("Deleted from YouTube: \u{201C}\(upload.title)\u{201D} (\(upload.url)). The recording is still in Documents/Greenroom.")
            return nil
        } catch {
            noteSignInLostIfNeeded()
            log("Couldn't delete from YouTube: \(error.localizedDescription)")
            let p = youtubeProblem(for: error)
            return "\(p.title). \(p.detail)"
        }
    }

    // MARK: Sign in / sign out (Settings → YouTube, the upload sheet)

    /// Sign in with Google, through the chosen Google app. Google always shows
    /// its account chooser, so this is also "Use another account": the old
    /// sign-in is revoked once the new one is in.
    func signInToYouTube() async {
        loadSecretsIfNeeded()
        let route = youtubeSignInRoute
        guard let app = route.app else {
            if case .none(let gap) = route { youtubeStatus = "Not connected: \(gap.message)" }
            return
        }
        youtubeSigningIn = true
        defer { youtubeSigningIn = false }
        youtubeStatus = "Waiting for Google in your browser\u{2026}"
        do {
            try await YouTubeAuth.connect(client: youtubeClient(app), app: app)
            youtubeConnected = true
            youtubeChannel = nil
            youtubeStatus = ""
            log("YouTube signed in (\(app == .shared ? "Greenroom's Google app" : "your own Google app")).")
            Analytics.feature("youtube_connect", source: app.rawValue)
            await refreshYouTubeChannel()
        } catch {
            youtubeConnected = YouTubeAuth.isConnected
            youtubeStatus = "Not connected: \(error.localizedDescription)"
            log("YouTube sign-in failed: \(error.localizedDescription)")
        }
    }

    /// Reads the signed-in account's channel for "Signed in as". An account
    /// with no channel says so (the upload would fail with the same words).
    func refreshYouTubeChannel() async {
        guard youtubeConnected else { return }
        do {
            let token = try await youtubeTokenProvider()()
            if let channel = try await YouTubeAuth.channel(token: token) {
                youtubeChannel = channel
            } else {
                youtubeChannel = nil
                let p = YouTubeErrorRules.problem(.noChannel, sharedApp: youtubeTokenIsShared)
                youtubeStatus = "\(p.title). \(p.detail)"
            }
        } catch {
            noteSignInLostIfNeeded()
            log("Couldn't read the YouTube channel: \(error.localizedDescription)")
        }
    }

    /// Sign out: revokes the token at Google and forgets the channel here.
    func signOutOfYouTube() async {
        await YouTubeAuth.disconnect()
        youtubeConnected = false
        youtubeChannel = nil
        // A result, not a state: a toast, never a line left on the page.
        youtubeStatus = ""
        ToastController.show("Signed out of YouTube", detail: "Google has been told to remove Greenroom\u{2019}s access.")
        log("YouTube signed out.")
    }
}
