//
//  WhisperInstaller.swift
//  Greenroom
//
//  Setting whisper up from inside Greenroom.
//
//  It used to be two Terminal commands shown in Settings → Screenroom:
//  `brew install whisper-cpp`, then a `curl` line for the model. A teacher on
//  a fresh Mac met Cues' "Listens with: Whisper" greyed out in the setup
//  guide, with a pointer to a settings tab that only offered commands to
//  paste. Nobody sets up a class tool in Terminal.
//
//  So both steps are buttons. The model is a plain HTTPS download into
//  Greenroom's own folder, with progress. The program still comes from
//  Homebrew - whisper.cpp is not something to ship inside the app - but when
//  Homebrew is there, Greenroom runs the install itself and shows what it is
//  doing. When Homebrew is not there, it says so and links to it, which is
//  the one step that honestly belongs to the teacher.
//
//  Nothing downloads without a press. A model is half a gigabyte.
//
import Foundation

@MainActor
final class WhisperInstaller: NSObject, ObservableObject {

    static let shared = WhisperInstaller()

    enum Phase: Equatable {
        case idle
        case installingProgram(lastLine: String)
        case downloading(model: String, fraction: Double, detail: String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Bumped whenever something on disk changed, so views that ask
    /// ScreenroomWhisper directly know to ask again.
    @Published private(set) var revision = 0

    /// The model a teacher is offered first: multilingual, and the best
    /// measured here on accented English. See ScreenroomWhisper.offeredModels.
    nonisolated static let recommendedModel = "ggml-small.bin"

    var hasProgram: Bool { ScreenroomWhisper.resolvedBinary != nil }
    var hasModel: Bool { !ScreenroomWhisper.availableModels().isEmpty }
    var isReady: Bool { hasProgram && hasModel }
    var isBusy: Bool {
        switch phase {
        case .installingProgram, .downloading: return true
        default: return false
        }
    }

    /// Homebrew, found by its two standard places rather than a login shell,
    /// so a view can ask without running anything.
    static var homebrew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func noteChange() {
        ScreenroomWhisper.refreshBinary()
        revision += 1
    }

    // MARK: The program

    func installProgram() {
        guard !isBusy else { return }
        guard let brew = Self.homebrew else {
            phase = .failed("Homebrew is not on this Mac. Install it from brew.sh, then press Install again.")
            return
        }
        phase = .installingProgram(lastLine: "Starting Homebrew\u{2026}")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "whisper-cpp"]
        var environment = ProcessInfo.processInfo.environment
        // Skips the index refresh, which is most of the wait and not needed
        // to install one formula.
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let line = text.split(whereSeparator: \.isNewline).last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { return }
            Task { @MainActor in
                guard let self, case .installingProgram = self.phase else { return }
                self.phase = .installingProgram(lastLine: String(line.prefix(90)))
            }
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.noteChange()
                if status == 0, self.hasProgram {
                    self.phase = .idle
                } else {
                    self.phase = .failed("Homebrew could not install whisper (exit \(status)). Run \u{201C}brew install whisper-cpp\u{201D} in Terminal to see why.")
                }
            }
        }
        do {
            try process.run()
        } catch {
            phase = .failed("Could not start Homebrew: \(error.localizedDescription)")
        }
    }

    // MARK: The model

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var downloadingName = ""

    func download(_ name: String = WhisperInstaller.recommendedModel) {
        guard !isBusy else { return }
        guard let url = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(name)") else { return }
        downloadingName = name
        phase = .downloading(model: name, fraction: 0, detail: "Starting\u{2026}")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        phase = .idle
    }

    fileprivate func finished(at location: URL?, error: Error?) {
        defer {
            session?.finishTasksAndInvalidate()
            session = nil
            task = nil
        }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            phase = .failed("The model did not download: \(error.localizedDescription)")
            return
        }
        guard let location else { return }
        let folder = ScreenroomWhisper.installFolder
        let target = folder.appendingPathComponent(downloadingName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: location, to: target)
            phase = .idle
        } catch {
            phase = .failed("The model downloaded but could not be saved: \(error.localizedDescription)")
        }
        noteChange()
    }
}

extension WhisperInstaller: URLSessionDownloadDelegate {

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let mb = { (bytes: Int64) in String(format: "%.0f MB", Double(bytes) / 1_048_576) }
        let detail = totalBytesExpectedToWrite > 0
            ? "\(mb(totalBytesWritten)) of \(mb(totalBytesExpectedToWrite))"
            : mb(totalBytesWritten)
        MainActor.assumeIsolated {
            guard case .downloading(let model, _, _) = self.phase else { return }
            self.phase = .downloading(model: model, fraction: fraction, detail: detail)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The file at `location` is deleted when this returns, so it is
        // moved aside synchronously before hopping anywhere.
        let holding = FileManager.default.temporaryDirectory
            .appendingPathComponent("greenroom-whisper-\(UUID().uuidString).bin")
        let moved = (try? FileManager.default.moveItem(at: location, to: holding)) != nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        MainActor.assumeIsolated {
            if status >= 400 {
                try? FileManager.default.removeItem(at: holding)
                self.finished(at: nil, error: NSError(domain: "Greenroom", code: status, userInfo: [
                    NSLocalizedDescriptionKey: "the server answered HTTP \(status)"]))
            } else {
                self.finished(at: moved ? holding : nil, error: moved ? nil : NSError(domain: "Greenroom", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "the file could not be moved out of the download folder"]))
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated { self.finished(at: nil, error: error) }
    }
}
