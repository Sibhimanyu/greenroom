//
//  SessionTranscriptView.swift
//  Greenroom
//
//  What was said in a class, and what it was about.
//
//  Until now the transcript was written to the class folder and readable only
//  in Finder: the app recorded it, saved it, named it in the status log, and
//  then offered no way to look at it. This is that way.
//
//  Two things stacked, in the order a teacher wants them. The summary first,
//  because after a lesson you want the gist and not 40 minutes of lines. The
//  transcript under it, timestamped and selectable, because the summary is a
//  model's account and the lines are the evidence.
//
//  The summary is generated on this Mac and cached in the class's own folder.
//  Never a cloud call: a class transcript is children speaking, and Cues
//  already promises that only a short search phrase ever leaves.
//
import SwiftUI

/// Reads, edits and reverts the transcript file behind the tab.
///
/// Edits rewrite ONE raw row of the file the line came from (see
/// `TranscriptEditRules`), atomically. The untouched file is copied to
/// "<name>.original.txt" before the first edit. Every write registers with the
/// window's UndoManager, so Edit > Undo and Command-Z walk the edits back (and
/// forward again); a restore only applies while the file still holds what the
/// edit wrote, so a stale entry can never clobber later work.
@MainActor
final class TranscriptEditor: ObservableObject {
    @Published private(set) var lines: [SessionSummary.Line] = []
    @Published private(set) var hasOriginal = false
    @Published private(set) var summaryStale = false
    @Published var problem: String?
    /// The file text before and after the latest delete, for the inline Undo.
    private(set) var lastRemoval: (before: String, after: String)?
    weak var undoManager: UndoManager?
    private var folder: URL?

    private var url: URL? { folder.map { SessionSummary.transcriptURL(in: $0) } }
    private var originalURL: URL? {
        url.map { $0.deletingLastPathComponent()
            .appendingPathComponent(TranscriptEditRules.originalName(for: $0.lastPathComponent)) }
    }

    func load(_ folder: URL) {
        if self.folder != folder { undoManager?.removeAllActions(withTarget: self) }
        self.folder = folder
        problem = nil
        lastRemoval = nil
        reload()
    }

    func reload() {
        guard let folder else { return }
        lines = SessionSummary.lines(in: folder)
        hasOriginal = originalURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        refreshStale()
    }

    func refreshStale() {
        guard let folder, let url else { return }
        func modified(_ u: URL) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
        }
        let summary = SessionSummary.summaryURL(in: folder)
        summaryStale = FileManager.default.fileExists(atPath: summary.path)
            && TranscriptEditRules.summaryIsStale(transcriptModified: modified(url), summaryModified: modified(summary))
    }

    func forget() { undoManager?.removeAllActions(withTarget: self) }

    /// Saves new text for a line; blank text removes it. Returns whether the
    /// line was removed.
    @discardableResult
    func save(rawIndex: Int, text: String) -> Bool {
        guard let url, let old = try? String(contentsOf: url, encoding: .utf8),
              let new = TranscriptEditRules.rewrite(raw: old, rawIndex: rawIndex, newText: text)
        else { return false }
        guard new != old else { return false }
        let removed = TranscriptEditRules.oneLine(text).isEmpty
        guard keepOriginal(of: old) else { return false }
        if write(new, replacing: old, name: removed ? "Remove Line" : "Edit Line") {
            lastRemoval = removed ? (old, new) : nil
            return removed
        }
        return false
    }

    /// The inline "Undo" after a removal.
    func undoRemoval() {
        guard let lastRemoval else { return }
        _ = restore(lastRemoval.before, expecting: lastRemoval.after, name: "Remove Line")
        self.lastRemoval = nil
    }

    func revertToOriginal() {
        guard let url, let originalURL,
              let original = try? String(contentsOf: originalURL, encoding: .utf8),
              let current = try? String(contentsOf: url, encoding: .utf8), original != current else { return }
        lastRemoval = nil
        write(original, replacing: current, name: "Revert Transcript")
    }

    /// Copies the untouched file aside on the first edit. False (and a note)
    /// when that fails, in which case nothing is edited.
    private func keepOriginal(of text: String) -> Bool {
        guard let url, let originalURL else { return false }
        let files = FileManager.default
        guard TranscriptEditRules.shouldCopyOriginal(originalExists: files.fileExists(atPath: originalURL.path),
                                                     sourceExists: files.fileExists(atPath: url.path)) else { return true }
        do {
            try files.copyItem(at: url, to: originalURL)
            return true
        } catch {
            problem = "Could not keep a copy of the original, so nothing was changed."
            return false
        }
    }

    @discardableResult
    private func write(_ new: String, replacing old: String, name: String) -> Bool {
        guard let url else { return false }
        do {
            try new.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            problem = "Could not save the transcript: \(error.localizedDescription)"
            return false
        }
        problem = nil
        registerUndo(restoring: old, expecting: new, name: name)
        reload()
        return true
    }

    private func registerUndo(restoring old: String, expecting new: String, name: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            _ = target.restore(old, expecting: new, name: name)
        }
        undoManager.setActionName(name)
    }

    /// Puts `old` back, only if the file still holds `expecting`.
    private func restore(_ old: String, expecting new: String, name: String) -> Bool {
        guard let url, let current = try? String(contentsOf: url, encoding: .utf8), current == new else { return false }
        do { try old.write(to: url, atomically: true, encoding: .utf8) } catch {
            problem = "Could not save the transcript: \(error.localizedDescription)"
            return false
        }
        registerUndo(restoring: new, expecting: old, name: name)
        reload()
        return true
    }
}

struct SessionTranscriptView: View {
    let folder: URL
    /// Watch mode: a click on a line moves the picture to it (and leaves it
    /// playing or paused, as it was).
    var onSeek: ((Double) -> Void)?
    /// The player's time and state, for following along.
    var playhead: Double = 0
    var isPlaying = false

    @StateObject private var editor = TranscriptEditor()
    @Environment(\.undoManager) private var undoManager
    @State private var summary: String?
    @State private var problem: String?
    @State private var working = false
    @State private var copied = false
    /// Which pass is running. A real class is several model calls, so a bare
    /// spinner would sit there for a minute looking broken.
    @State private var step = "Reading the meeting\u{2026}"

    @State private var starts: [Double] = []
    @State private var selected: Int?
    @State private var editing: Int?
    @State private var lastManualScroll: Date?
    @State private var removedNotice = false
    @State private var noticeTask: Task<Void, Never>?
    @State private var confirmRevert = false
    @FocusState private var listFocused: Bool

    private var lines: [SessionSummary.Line] { editor.lines }

    /// The raw index of the line the picture is at.
    private var currentRaw: Int? {
        TranscriptEditRules.currentLine(starts: starts, at: playhead).map { lines[$0].rawIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryCard
            Divider()
            transcriptList
            notice
        }
        .task(id: folder) {
            editor.undoManager = undoManager
            editor.load(folder)
            starts = lines.map { TranscriptEditRules.stampSeconds($0.stamp) ?? .infinity }
            summary = SessionSummary.cached(in: folder)
            problem = nil
            copied = false
            selected = nil
            editing = nil
            removedNotice = false
        }
        .onChange(of: editor.lines.map(\.rawIndex)) { _, _ in
            starts = lines.map { TranscriptEditRules.stampSeconds($0.stamp) ?? .infinity }
        }
        .onDisappear { editor.forget() }
        .confirmationDialog("Revert to the original transcript?", isPresented: $confirmRevert) {
            Button("Revert", role: .destructive) {
                editor.undoManager = undoManager
                editor.revertToOriginal()
            }
        } message: {
            Text("Your edits to the transcript are replaced by what was first saved. You can undo this.")
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("SUMMARY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(.tertiary)
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                    Text(step)
                        .font(.caption).foregroundStyle(.secondary)
                } else if summary != nil {
                    Button("Copy") { copy() }
                        .controlSize(.small)
                        .help("Copy the summary")
                    Button("Again") { summarise() }
                        .controlSize(.small)
                        .help("Write a new summary from the same transcript")
                } else if lines.isEmpty {
                    EmptyView()
                } else if let reason = SessionSummary.unavailableReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Summarise on this Mac") { summarise() }
                        .controlSize(.small)
                }
                if editor.hasOriginal {
                    Menu {
                        Button("Revert to original\u{2026}") { confirmRevert = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Transcript options")
                    .accessibilityLabel("Transcript options")
                }
            }

            if let summary {
                ScrollView {
                    Text(LocalizedStringKey(summary))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
                if editor.summaryStale, !working {
                    HStack(spacing: 8) {
                        Text("Transcript edited since this summary")
                            .font(.caption).foregroundStyle(.secondary)
                        if SessionSummary.unavailableReason == nil {
                            Button("Summarise again") { summarise() }
                                .controlSize(.small)
                        }
                    }
                }
            } else if let problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if lines.isEmpty {
                Text(SessionSummary.hasTranscript(in: folder)
                     ? "Nothing was said that the speech model could make out: this meeting's transcript is only room sound."
                     : "No transcript for this meeting. Cues writes one only when it was listening and \u{201C}Save the transcript and links with the meeting\u{201D} is on.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(lines.count) line\(lines.count == 1 ? "" : "s") transcribed. Nothing leaves this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if copied {
                Text("Copied").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Transcript

    @ViewBuilder private var transcriptList: some View {
        if lines.isEmpty {
            VStack(spacing: 6) {
                Text("Nothing was transcribed")
                    .font(.system(size: 13, weight: .medium))
                Text("A bilingual meeting transcribes thinly: the speech model finalises only what it can render in English, and there is no Tamil model on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines, id: \.rawIndex) { line in
                            row(line)
                                .id(line.rawIndex)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .background(TranscriptScrollProbe { lastManualScroll = Date() })
                .focusable()
                .focusEffectDisabled()
                .focused($listFocused)
                .onKeyPress(.return) {
                    guard editing == nil, let selected, lines.contains(where: { $0.rawIndex == selected })
                    else { return .ignored }
                    editing = selected
                    return .handled
                }
                .onChange(of: currentRaw) { _, raw in
                    guard isPlaying, editing == nil, let raw,
                          TranscriptEditRules.shouldAutoScroll(lastManualScroll: lastManualScroll, now: Date())
                    else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(raw, anchor: .center) }
                }
            }
        }
    }

    private func row(_ line: SessionSummary.Line) -> some View {
        let isCurrent = currentRaw == line.rawIndex
        let isSelected = selected == line.rawIndex
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Machine facts in mono, prose in the system face, which is the
            // split DESIGN.md asks for. Tabular figures so the stamps form a
            // column. The stamp always seeks, even while another line is open.
            Text(line.stamp)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { seek(line) }
                .help("Play from this line")
            if editing == line.rawIndex {
                TranscriptEditField(text: line.text,
                                    onCommit: { commit(line, $0) },
                                    onCancel: { editing = nil; listFocused = true })
            } else {
                Text(line.text)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(isCurrent ? Brand.green.opacity(0.14)
                    : isSelected ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selected = line.rawIndex
            editing = line.rawIndex
        }
        .onTapGesture {
            guard editing != line.rawIndex else { return }
            selected = line.rawIndex
            listFocused = true
            seek(line)
        }
        .help("Click to jump here. Double-click, or select and press Return, to edit.")
    }

    private func seek(_ line: SessionSummary.Line) {
        if let onSeek, let at = TranscriptEditRules.stampSeconds(line.stamp) { onSeek(at) }
    }

    private func commit(_ line: SessionSummary.Line, _ text: String) {
        editing = nil
        listFocused = true
        guard TranscriptEditRules.oneLine(text) != line.text else { return }
        editor.undoManager = undoManager
        if editor.save(rawIndex: line.rawIndex, text: text) { showRemovedNotice() }
    }

    // MARK: Notice

    @ViewBuilder private var notice: some View {
        if removedNotice || editor.problem != nil {
            HStack(spacing: 8) {
                if let problem = editor.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Line removed \u{00B7}").font(.caption).foregroundStyle(.secondary)
                    Button("Undo") {
                        editor.undoRemoval()
                        removedNotice = false
                    }
                    .controlSize(.small)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.quinary)
        }
    }

    private func showRemovedNotice() {
        removedNotice = true
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { await MainActor.run { removedNotice = false } }
        }
    }

    // MARK: Work

    private func summarise() {
        guard #available(macOS 26.0, *) else { return }
        working = true
        problem = nil
        step = "Reading the meeting\u{2026}"
        Task {
            let outcome = await SessionSummary.generate(for: folder) { note in
                Task { @MainActor in step = note }
            }
            await MainActor.run {
                working = false
                switch outcome {
                case .summary(let text): summary = text
                case .problem(let text): problem = text
                }
                editor.refreshStale()
            }
        }
    }

    private func copy() {
        guard let summary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await MainActor.run { copied = false }
        }
    }
}

// MARK: - Inline editing

/// One line's text as a field. Return saves, Esc cancels, losing focus (a click
/// anywhere else) saves.
private struct TranscriptEditField: View {
    let text: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var draft = ""
    @State private var done = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .onAppear {
                draft = text
                focused = true
            }
            .onSubmit { finish { onCommit(draft) } }
            .onExitCommand { finish { onCancel() } }
            .onChange(of: focused) { _, now in
                if !now { finish { onCommit(draft) } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func finish(_ action: () -> Void) {
        guard !done else { return }
        done = true
        action()
    }
}

/// Reports wheel and trackpad scrolling over the transcript, so follow-along
/// can leave a reader who is looking around alone.
private struct TranscriptScrollProbe: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.onScroll = onScroll }

    final class Probe: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onScroll?()
                }
                return event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

// MARK: - Edit mode

/// The transcript as a way to cut: a click on a sentence marks that stretch as
/// removed (shift-click extends to a second sentence), a click on a struck
/// sentence puts it back, and the stamp moves the picture there.
struct SessionEditTranscript: View {
    let folder: URL
    @EnvironmentObject private var vm: EditorViewModel
    @State private var lines: [SessionSummary.Line] = []
    @State private var starts: [Double] = []
    @State private var anchor: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TRANSCRIPT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            if lines.isEmpty {
                Text("No transcript to click on. Get feedback writes one, on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            row(index, line)
                        }
                    }
                    .padding(.bottom, 8)
                }
                Text("Click a sentence to cut it out. Shift-click to cut through a second one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: folder) {
            lines = SessionSummary.lines(in: folder)
            starts = lines.map { SessionDetailRules.stampSeconds($0.stamp) ?? 0 }
        }
    }

    private var current: Int? { SessionDetailRules.currentLine(starts: starts, at: vm.playhead) }

    private func cut(covering index: Int) -> CutRegion? {
        guard let span = SessionDetailRules.transcriptSpan(starts: starts, from: index, duration: vm.duration)
        else { return nil }
        let mid = (span.lowerBound + span.upperBound) / 2
        return vm.cuts.first { $0.start <= mid && mid <= $0.end }
    }

    private func row(_ index: Int, _ line: SessionSummary.Line) -> some View {
        let struck = cut(covering: index) != nil
        let isCurrent = current == index
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.stamp)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .leading)
                .onTapGesture { vm.seek(to: starts[index]) }
            Text(line.text)
                .font(.system(size: 13))
                .strikethrough(struck)
                .foregroundStyle(struck ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(isCurrent ? Color.primary.opacity(0.07) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { clicked(index) }
        .help(struck ? "Click to put this back" : "Click to cut this out of the video")
    }

    private func clicked(_ index: Int) {
        if let existing = cut(covering: index) {
            vm.deleteCut(id: existing.id)
            anchor = nil
            return
        }
        let shift = NSEvent.modifierFlags.contains(.shift)
        if shift, let first = anchor {
            let lo = min(first, index), hi = max(first, index)
            if let span = SessionDetailRules.transcriptSpan(starts: starts, from: lo, to: hi, duration: vm.duration) {
                vm.addCut(start: span.lowerBound, end: span.upperBound)
            }
            anchor = nil
        } else if let span = SessionDetailRules.transcriptSpan(starts: starts, from: index, duration: vm.duration) {
            vm.addCut(start: span.lowerBound, end: span.upperBound)
            anchor = index
        }
    }
}
