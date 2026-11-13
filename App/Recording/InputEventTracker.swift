// Ported from Recorditor (ZRecorditor @7210322, native/MacRecorder/Recording/InputEventTracker.swift).
import AppKit
import Carbon.HIToolbox

/// Watches clicks and keystrokes while a recording runs, for the editor's
/// click ripples, keystroke chips and auto-zoom (`RecordingEvents`).
///
/// Needs Accessibility. Without it this does nothing, silently: recording
/// never prompts for it (Greenroom asks elsewhere, see AppWindowManager).
/// Both monitors deliver on the main run loop.
///
/// Where a click lands in the finished video is not this class's business:
/// the caller hands in `locate`, which turns a global point (CoreGraphics
/// coordinates, origin top-left of the main display) into 0...1 coordinates
/// in the recorded picture, or nil when the click is not on the shared
/// content. See `StageCompositor.videoPosition(ofGlobalPoint:)` for the
/// mapping used in Greenroom.
@MainActor
final class InputEventTracker {
    nonisolated init() {}

    private var monitors: [Any] = []
    private var events = RecordingEvents()
    private var elapsed: () -> Double? = { nil }
    private var locate: (CGPoint) -> CGPoint? = { _ in nil }

    /// elapsed: seconds into the finished video, nil before its first frame
    /// or while the recording is paused (the event is then dropped). The caller
    /// supplies the paused-adjusted clock (`SessionRecorder.elapsedMilliseconds`),
    /// so times after a pause line up with the file. Phase 4 done.
    /// Returns false when nothing is being tracked (no Accessibility).
    @discardableResult
    func start(elapsed: @escaping () -> Double?, locate: @escaping (CGPoint) -> CGPoint?) -> Bool {
        stopMonitors()
        events = RecordingEvents()
        guard AXIsProcessTrusted() else { return false }
        self.elapsed = elapsed
        self.locate = locate

        if let clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.recordClick() }
            }) {
            monitors.append(clickMonitor)
        }
        if let keyMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .keyDown, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.recordKey(event) }
            }) {
            monitors.append(keyMonitor)
        }
        return !monitors.isEmpty
    }

    /// Ends tracking; writes the sidecar next to the finished video, and only
    /// when that video exists and has bytes. Otherwise the events are dropped,
    /// so a share that recorded nothing leaves no lone `.events.json` behind.
    func stopAndSave(nextTo videoURL: URL?) {
        stopMonitors()
        if let videoURL, SessionFolderRules.isNonEmptyFile(videoURL) { events.save(for: videoURL) }
        events = RecordingEvents()
    }

    private func stopMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
    }

    private func recordClick() {
        guard let t = elapsed() else { return }
        // CGEvent gives the point in the same space as window and display
        // frames (top-left origin), so no flip is needed here.
        guard let point = CGEvent(source: nil)?.location,
              let p = locate(point) else { return }
        events.clicks.append(RecordingEvents.Click(t: t, x: Double(p.x), y: Double(p.y)))
    }

    private func recordKey(_ event: NSEvent) {
        // Greenroom addition: never log while secure input is on (password
        // fields, some terminals). macOS already withholds those keys from
        // global monitors; this is the belt to that braces.
        guard !IsSecureEventInputEnabled() else { return }
        guard let t = elapsed(), let text = Self.display(for: event) else { return }
        events.keys.append(RecordingEvents.Key(t: t, text: text))
    }

    /// Human-readable key: modifier symbols plus the key name.
    private static func display(for event: NSEvent) -> String? {
        var parts = ""
        let flags = event.modifierFlags
        if flags.contains(.control) { parts += "⌃" }
        if flags.contains(.option) { parts += "⌥" }
        if flags.contains(.shift) { parts += "⇧" }
        if flags.contains(.command) { parts += "⌘" }

        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        // Greenroom change (owner's call, 2026-11-13): shortcuts and special
        // keys only, never plain typing. Upstream logged every key, so typed
        // text (chat, search, email) landed in the sidecar in plain text.
        // A character key counts only with ⌘ or ⌃ held: ⇧ and ⌥ alone still
        // type characters. Plain Space and ⌫ are typing too (they'd show word
        // lengths), so they need a modifier like the letters.
        let isShortcut = flags.contains(.command) || flags.contains(.control)
        if let name = special[event.keyCode] {
            let typingKey = event.keyCode == 49 || event.keyCode == 51
            return (typingKey && parts.isEmpty) ? nil : parts + name
        }
        guard isShortcut else { return nil }
        guard let characters = event.charactersIgnoringModifiers,
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar) else {
            return parts.isEmpty ? nil : nil
        }
        return parts + characters.uppercased()
    }
}
