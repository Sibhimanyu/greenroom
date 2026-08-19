//
//  OBSProcessManager.swift
//  Greenroom
//
//  Launches and supervises the OBS Studio process, seeding obs-websocket's
//  server settings via command-line flags so no manual "Tools > obs-websocket
//  Settings" step is ever needed, and starting it hidden (no window).
//
import Foundation
import AppKit

final class OBSProcessManager {

    static let websocketPort = 4455
    static let websocketPassword = "greenroom-local"
    static let bundleIdentifier = "com.obsproject.obs-studio"

    private(set) var runningApp: NSRunningApplication?

    /// Locates the installed OBS.app.
    static var obsAppURL: URL? {
        let candidates = [
            "/Applications/OBS.app",
            "\(NSHomeDirectory())/Applications/OBS.app"
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isInstalled: Bool { Self.obsAppURL != nil }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    /// obs-websocket's own persisted settings file. Its `server_enabled` flag
    /// defaults to false on a fresh install, and - confirmed by testing - the
    /// `--websocket_port`/`--websocket_password` launch flags configure
    /// values but do NOT flip that flag on. Seeding this file directly is the
    /// reliable path; the launch flags are kept as a harmless belt-and-braces
    /// second source of truth.
    private static var websocketConfigURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")
    }

    private func seedWebSocketConfig() throws {
        let url = Self.websocketConfigURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if let existing = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            settings = json
        }
        settings["server_enabled"] = true
        settings["auth_required"] = true
        settings["server_password"] = Self.websocketPassword
        settings["server_port"] = Self.websocketPort
        settings["alerts_enabled"] = false // no on-screen toast when the server (re)starts

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
    }

    /// Launches OBS hidden (minimized to tray, no window) with obs-websocket
    /// pre-configured. If OBS is already running, NSWorkspace hands back the
    /// existing instance rather than starting a second one, so this is safe
    /// to call every time Greenroom starts. If OBS was already running
    /// *before* this seeded the config, quit it and call launch() again -
    /// obs-websocket only reads this file at startup.
    /// OBS writes `.sentinel/run_<uuid>` at startup and deletes it on a
    /// clean exit. Leftovers make OBS show its "did not shut down
    /// properly - Run in Safe Mode?" prompt on next launch, and Safe Mode
    /// DISABLES WEBSOCKETS - which is the only channel Greenroom has to
    /// OBS, so the session then dies with a bare "Could not connect to
    /// the server". Clearing stale sentinels before launch keeps that
    /// prompt from ever appearing. Only safe when OBS isn't running (a
    /// live run owns its sentinel).
    private static func clearStaleSentinels() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else { return }
        let sentinelDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obs-studio/.sentinel")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: sentinelDirectory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("run_") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func launch() async throws {
        guard let url = Self.obsAppURL else {
            throw NSError(domain: "Greenroom", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "OBS Studio isn't installed. Get it free from obsproject.com, then try again."
            ])
        }

        Self.clearStaleSentinels()
        try seedWebSocketConfig()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [
            "--minimize-to-tray",
            "--websocket_port", String(Self.websocketPort),
            "--websocket_password", Self.websocketPassword
        ]
        configuration.activates = false
        configuration.addsToRecentItems = false

        runningApp = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Terminates OBS regardless of whether *this* OBSProcessManager instance
    /// is the one that launched it - looks it up by bundle identifier rather
    /// than relying solely on a possibly-stale `runningApp` reference (e.g.
    /// after Greenroom itself was relaunched since OBS was started).
    func quit() {
        Self.terminateAnyRunningInstance()
        runningApp = nil
    }

    /// Graceful quit that WAITS for OBS to actually exit (up to ~5s) so it
    /// can delete its own sentinel file. Fire-and-forget termination left
    /// sentinels behind, which produced the Safe Mode prompt on the next
    /// launch - see clearStaleSentinels().
    func quitAndWait() async {
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
        guard !instances.isEmpty else { runningApp = nil; return }
        // Liveness via POSIX kill(pid, 0), NOT by re-querying the
        // workspace list: during Greenroom's own final moments the
        // running-app snapshot goes stale (it refreshes on the main run
        // loop), and a re-query returned empty while OBS was demonstrably
        // still alive - forceTerminate then targeted nothing and a wedged
        // OBS lingered after quit (seen live). The NSRunningApplication
        // objects themselves stay valid, which is why terminate() below
        // reuses this snapshot rather than re-querying.
        let pids = instances.map(\.processIdentifier)
        // Re-ask once a second instead of once, total. A single quit Apple
        // Event gets DROPPED when OBS's main thread isn't in a state to
        // answer it, and nothing retries - so the loop used to wait out its
        // whole grace period and then SIGKILL. Measured on this machine: a
        // settled OBS honours the event in ~200ms, but quitting while OBS
        // was still starting up cost 5.8s. The scene-switch that parks OBS
        // on its idle scene (see windDownForQuit) tears down
        // ScreenCaptureKit immediately before this runs, which is exactly
        // when OBS is least able to answer, so one shot is not enough.
        for tick in 0..<25 {
            if tick % 5 == 0 { instances.forEach { $0.terminate() } }
            if pids.allSatisfy({ kill($0, 0) != 0 }) { break } // ESRCH = exited
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        // SIGKILL directly for stragglers: always deliverable (a wedged
        // main thread ignores Apple Events forever), produces neither a
        // crash report nor a "quit unexpectedly" dialog, and the sentinel
        // it leaves is cleared on the next launch (clearStaleSentinels).
        for pid in pids where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
        runningApp = nil
    }

    /// Shared by both the instance-level `quit()` and the app delegate's
    /// termination hook (see GreenroomApp.swift) - quitting Greenroom used
    /// to leave OBS and its virtual camera running in the background with
    /// no way to stop them short of a manual `killall`. Confirmed working.
    static func terminateAnyRunningInstance() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).forEach { $0.terminate() }
    }
}
