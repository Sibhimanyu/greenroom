//
//  SessionNotesBar.swift
//  Greenroom
//
//  Notes, in any session.
//
//  Screenroom's timed note-taking used to belong to Screenroom alone: a
//  separate window, a separate recorder, a separate kind of session. But the
//  thing it does - type while something is happening, and have each note land
//  at the moment you noticed it - is as useful in a class as in a presentation.
//  So it became a switch on the home screen, and this is what the switch puts
//  on screen: one small floating bar for the length of the session, writing
//  into that session's folder.
//
//  The rules it keeps from Screenroom (ScreenroomController's file note has the
//  long version):
//
//   - A note is stamped at its FIRST keystroke, not at Return. The moment
//     worth marking is when the teacher noticed something; the rest is them
//     finding words, and stamping on Return pushes the most considered notes
//     furthest from what they describe.
//   - The file is Screenroom's own: `notes.jsonl`, appended per note, so the
//     report, the Sessions window's Notes tab and anything outside the app
//     read it without knowing a class wrote it.
//   - `atMs` points into the RECORDING when there is one. Before the tape
//     rolls there is no file to point into, so the note is timed from the
//     session's start and says so (`timedFrom: "session"`) rather than pass
//     off a number measured against something else.
//
//  The bar is a control surface sharing a screen with the teacher's work, so
//  DESIGN.md's rule for those applies: it never asserts itself. It is a
//  non-activating panel - shown without taking focus, keys only once clicked -
//  and it is ordered front once, when the session starts, never on a timer.
//
import AppKit
import Combine
import SwiftUI

@MainActor
final class SessionNotes: ObservableObject {

    static let shared = SessionNotes()

    /// Settings -> Layout -> "Open notes when a session starts". Read here as
    /// well as bound there, so the bar follows it even when the main window is
    /// closed. It is the default; `manualOverride` is this session's say.
    static let enabledKey = SavedSettings.sessionNotesEnabled.key

    /// This session's own choice, from the Notes buttons (control bar, Record
    /// view, menu bar). nil means "follow the setting". Set before a session
    /// goes live it carries into that session; reset to nil when the session
    /// ends, so the setting is the default again for the next one.
    @Published var manualOverride: Bool? {
        didSet { if oldValue != manualOverride { update() } }
    }

    /// Whether the bar is (or, before the session is live, will be) open.
    var effectiveEnabled: Bool { manualOverride ?? enabled }

    /// Flips the effective state into the override.
    func toggle() { manualOverride = !effectiveEnabled }

    /// A session is under way: a Zoom class, a live stage, a recording, or a
    /// Record-mode session (live from "Ready to record", before Record).
    static func sessionIsLive(_ c: CoordinatorController) -> Bool {
        c.phase.hasSessionOrTakeOnScreen
    }
    private var wasLive = false

    @Published var draft: String = "" {
        didSet { draftChanged(from: oldValue) }
    }
    /// Notes written in THIS session, oldest first, for the count and the
    /// last-note line.
    @Published private(set) var notes: [ScreenroomNote] = []
    /// Bumped every second while the bar is up, so the clock beside the
    /// field moves without the view owning a timer.
    @Published private(set) var now = Date()

    private weak var coordinator: CoordinatorController?
    private var folder: URL?
    private var draftAtMs: Int?
    private var draftTimedFrom: String?
    private var draftStartedAt: Date?
    private var bag: Set<AnyCancellable> = []
    private var ticker: Timer?
    private var panel: NotesPanel?

    /// Wires the bar to the session. Idempotent - the home screen calls it on
    /// every appearance, and only the first does anything.
    func attach(_ coordinator: CoordinatorController) {
        guard self.coordinator == nil else { return }
        self.coordinator = coordinator
        // Every published change that can start or end a session, and the
        // switch itself. Coalesced to the next runloop turn: the coordinator
        // flips several of these together and the bar needs the settled state.
        Publishers.Merge5(
            coordinator.$isRunning.map { _ in () },
            coordinator.$stageLive.map { _ in () },
            coordinator.$isRecording.map { _ in () },
            // Home -> Record: a session with no meeting.
            coordinator.$recordOnlyActive.map { _ in () },
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update() }
            .store(in: &bag)
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// The session's folder, while there is a session.
    ///
    /// `sessionFolder` is named at Start and lives until Stop; the published
    /// flags are what say a session is actually under way.
    private var liveFolder: URL? {
        guard let coordinator,
              coordinator.phase.hasSessionOrTakeOnScreen
        else { return nil }
        return coordinator.sessionFolder
    }

    func update() {
        let live = liveFolder
        if live == nil {
            // The session ended: the setting is the default again.
            if wasLive { wasLive = false; manualOverride = nil }
        } else {
            wasLive = true
        }
        guard effectiveEnabled, let live else { close(); return }
        if live != folder {
            // A new session. Pick up anything already written, so turning
            // the switch off and on mid-class does not lose the count.
            commit()
            folder = live
            notes = ScreenroomNotesFile.load(in: live)
            clearDraft()
        }
        show()
    }

    // MARK: Timing

    /// Where a note typed right now would land, and against what.
    private var position: (ms: Int, timedFrom: String?) {
        let now = Date()
        // The recording's own clock: paused time is not in the file, so a note
        // typed after a pause lands where it was said, not that much later.
        if let coordinator, let seconds = coordinator.recordingElapsed(at: now) {
            return (max(0, Int(seconds * 1000)), nil)
        }
        let started = coordinator?.sessionStartedAt ?? now
        return (max(0, Int(now.timeIntervalSince(started) * 1000)), "session")
    }

    private func draftChanged(from oldValue: String) {
        let wasEmpty = oldValue.trimmingCharacters(in: .whitespaces).isEmpty
        let isEmpty = draft.trimmingCharacters(in: .whitespaces).isEmpty
        if wasEmpty && !isEmpty {
            // The first character of a new note: this, not Return, is the
            // moment being marked.
            let at = position
            draftAtMs = at.ms
            draftTimedFrom = at.timedFrom
            draftStartedAt = Date()
        } else if isEmpty {
            clearStamp()
        }
    }

    /// Commits the note being typed. Bound to Return.
    func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let folder else { clearDraft(); return }
        let at = position
        var note = ScreenroomNote(atMs: draftAtMs ?? at.ms, text: text,
                                  markedAt: draftStartedAt ?? Date())
        note.timedFrom = draftAtMs == nil ? at.timedFrom : draftTimedFrom
        if ScreenroomNotesFile.append(note, in: folder) {
            notes.append(note)
        }
        clearDraft()
    }

    private func clearDraft() {
        // The stamp first: setting `draft` re-enters draftChanged, which
        // clears it anyway, but not before a reader could see a stale one.
        clearStamp()
        draft = ""
    }

    private func clearStamp() {
        draftAtMs = nil
        draftTimedFrom = nil
        draftStartedAt = nil
    }

    /// What the clock beside the field says: the draft's frozen stamp while
    /// one is being typed, the live position otherwise.
    var stampLabel: String {
        _ = now
        return ScreenroomAnalysisPane.stamp(draftAtMs ?? position.ms)
    }

    /// Whether the clock is counting the tape or only the session.
    var timingRecording: Bool {
        draftAtMs != nil ? draftTimedFrom == nil : position.timedFrom == nil
    }

    // MARK: The panel

    /// Non-activating and able to take keys: clicking the field types into
    /// it without bringing Greenroom in front of the teacher's work.
    private final class NotesPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    static let barSize = NSSize(width: 520, height: 64)

    private func show() {
        if panel == nil { panel = makePanel() }
        guard let panel, !panel.isVisible else { return }
        // Where it was left on this display, or its default: displays may have
        // changed since the last session.
        panel.setFrame(restingFrame(), display: false)
        // Once, at the start of the session. orderFrontRegardless puts it up
        // without activating the app or taking key - see the file note.
        panel.orderFrontRegardless()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    /// The control bar has just been moved, collapsed or expanded. If it has
    /// landed on this bar, this one steps clear (above it, or below when there
    /// is no room above); a bar that is not in the way stays where the teacher
    /// put it.
    func keepClear(of other: NSRect) {
        guard let panel, panel.isVisible else { return }
        let gap = MeetingBarPlacement.stackGap
        guard panel.frame.insetBy(dx: -gap, dy: -gap).intersects(other) else { return }
        let area = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        var frame = panel.frame
        frame.origin.y = other.maxY + gap
        if frame.maxY > area.maxY { frame.origin.y = other.minY - gap - frame.height }
        panel.setFrame(MeetingBarPlacement.clamp(frame, to: area), display: true, animate: false)
    }

    private func close() {
        // Called on every defaults change while no session runs; nothing to do.
        guard folder != nil || panel?.isVisible == true else { return }
        commit()
        folder = nil
        notes = []
        ticker?.invalidate()
        ticker = nil
        panel?.orderOut(nil)
    }

    // MARK: Remembered position

    private static func displayKey(_ screen: NSScreen) -> String? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return LocalDeviceResolver.uuid(for: id)
    }

    /// Called when a drag of the bar ends: keeps it fully on the display it was
    /// dropped on, and remembers that spot for that display.
    func dropped(_ window: NSWindow) {
        let screens = NSScreen.screens
        let areas = screens.map(\.visibleFrame)
        guard let area = MeetingBarPlacement.area(for: window.frame, in: areas),
              let screen = screens.first(where: { $0.visibleFrame == area }) else { return }
        let frame = MeetingBarPlacement.clamp(window.frame, to: area)
        window.setFrame(frame, display: true, animate: false)
        guard let key = Self.displayKey(screen) else { return }
        var all = UserDefaults.standard.dictionary(forKey: NotesBarPlacement.defaultsKey) as? [String: String] ?? [:]
        NotesBarPlacement.save(NotesBarPlacement.offset(of: frame, in: area), for: key, into: &all)
        UserDefaults.standard.set(all, forKey: NotesBarPlacement.defaultsKey)
        UserDefaults.standard.set(key, forKey: NotesBarPlacement.lastDisplayKey)
    }

    /// The bar's frame now: the saved spot on the display it was last dropped on (when still connected,
    /// else the main display), clamped, or the default.
    private func restingFrame() -> NSRect {
        let main = NSScreen.main ?? NSScreen.screens.first
        let last = UserDefaults.standard.string(forKey: NotesBarPlacement.lastDisplayKey)
        let connected = NSScreen.screens.compactMap(Self.displayKey)
        let key = NotesBarPlacement.restingDisplay(lastDropped: last, connected: connected, main: main.flatMap(Self.displayKey))
        let screen = NSScreen.screens.first { Self.displayKey($0) == key } ?? main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let all = UserDefaults.standard.dictionary(forKey: NotesBarPlacement.defaultsKey) as? [String: String] ?? [:]
        let saved = screen.flatMap(Self.displayKey).flatMap { NotesBarPlacement.saved(for: $0, in: all) }
        return NotesBarPlacement.frame(savedOffset: saved, size: Self.barSize, in: area,
                                       defaultY: MeetingControlBarController.notesBarRestingY(in: area))
    }

    private func makePanel() -> NotesPanel {
        // Low and centred, under where a toast appears (Toast.swift sits at
        // 14% up). Not a corner: the layout tiles a side column flush to the
        // bottom and right, and a corner lands on it. Above the control bar's
        // row (MeetingControls.swift: 16 up, 44 tall) so the two never touch,
        // or back at its own default when the control bar has been moved away.
        let frame = restingFrame()
        let created = NotesPanel(contentRect: frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        created.isReleasedWhenClosed = false
        created.hidesOnDeactivate = false
        // Above the tiled windows, which is the whole reason it floats - and
        // nothing higher, so a sheet or an alert still comes over it.
        created.level = .floating
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The bar's background view moves the panel itself (NotesBarDragSurface).
        created.isMovableByWindowBackground = false
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true
        // Moved once, stays moved, per display (dropped(_:), NotesBarPlacement).
        let host = NSHostingView(rootView: SessionNotesBar(notes: self))
        host.frame = NSRect(origin: .zero, size: Self.barSize)
        created.contentView = host
        return created
    }
}

/// The bar, bound to the live controller.
private struct SessionNotesBar: View {
    @ObservedObject var notes: SessionNotes

    var body: some View {
        SessionNotesBarContent(draft: $notes.draft,
                               stamp: notes.stampLabel,
                               timingRecording: notes.timingRecording,
                               count: notes.notes.count,
                               last: notes.notes.last?.text,
                               commit: notes.commit,
                               close: notes.toggle)
    }
}

/// The bar itself, with nothing live in it - so it can be drawn off screen.
struct SessionNotesBarContent: View {
    @Binding var draft: String
    let stamp: String
    let timingRecording: Bool
    let count: Int
    let last: String?
    let commit: () -> Void
    /// Puts the bar away for this session (the Notes button brings it back).
    var close: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(stamp)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(draft.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.text))
                    .frame(width: 48, alignment: .leading)
                    .help(timingRecording
                          ? "Where this note lands in the recording. It is stamped at your first keystroke."
                          : "Not recording, so this note is timed from the start of the session.")
                TextField("Type a note, Return to save", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { commit() }
                    // Esc clears a draft; on an empty bar it closes the bar.
                    .onExitCommand { if draft.isEmpty { close() } else { draft = "" } }
                Label("\(count)", systemImage: "note.text")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("\(count) note\(count == 1 ? "" : "s") in this session. They open in Sessions, under Notes.")
                // The bar could not be put away from itself (owner, 2026-11-15).
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Color.primary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close the notes bar. Notes in the meeting bar or the menu bar opens it again.")
                .accessibilityLabel("Close the notes bar")
            }
            Text(last.map { "Saved: \($0)" }
                 ?? (timingRecording ? "Timed to the recording" : "Timed from the start of the session"))
                .font(.system(size: 11))
                // Secondary, not tertiary: tertiary all but vanishes on glass.
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 60)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: SessionNotes.barSize.width, height: SessionNotes.barSize.height)
        // Anywhere that is not the field or a button drags the bar. Under the
        // content, so the field and the close button still get their clicks.
        .background(NotesBarDragSurface())
        // Liquid Glass like every floating surface (Glass.swift, DESIGN.md).
        .greenroomGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The bar's background, as an AppKit view that moves the panel itself.
/// `isMovableByWindowBackground` does not work here: the hosting view does not
/// let a press on its background move the window (the owner could not move the
/// bar, 2026-11-25). Same approach as the meeting bar's grip: the press is
/// followed by hand, and on release the spot is saved for this display.
private struct NotesBarDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> SurfaceView { SurfaceView() }
    func updateNSView(_ view: SurfaceView, context: Context) {}

    final class SurfaceView: NSView {
        private var startMouse = NSPoint.zero
        private var startOrigin = NSPoint.zero
        private var dragging = false

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startMouse = NSEvent.mouseLocation
            startOrigin = window.frame.origin
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x, dy = now.y - startMouse.y
            if !dragging {
                guard hypot(dx, dy) > MeetingBarPlacement.dragThreshold else { return }
                dragging = true
            }
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            guard dragging, let window else { return }
            dragging = false
            SessionNotes.shared.dropped(window)
        }
    }
}
