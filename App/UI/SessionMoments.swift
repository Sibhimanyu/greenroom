//
//  SessionMoments.swift
//
//  The watch page's Notes tab: clips and notes in ONE list, in the order
//  they happened, with the add-a-note box under it. A click on a row jumps
//  the picture there. The dot in front of each row is the colour of its mark
//  on the timeline.
//
//  Plain values and closures. RecordingsView builds the moments from the
//  clip sidecar and Screenroom's notes and does the removing and exporting.
//
import SwiftUI

struct SessionMomentsList: View {
    let moments: [SessionMoment]
    var exporting: (done: Int, total: Int)?
    /// Notes can be added only when a session folder and the analysed take
    /// are the ones on screen; otherwise `disabledReason` says so in the box.
    var canAddNotes = true
    var disabledReason = "Add a note here"
    /// Where the picture is, for the current-note tint.
    var playhead: Double = 0
    /// Where a note typed right now would land, in milliseconds.
    var notePosition: () -> Int = { 0 }
    var onSeek: (SessionMoment) -> Void = { _ in }
    var onAddNote: (String, Int) -> Void = { _, _ in }
    var onEditNote: (SessionMoment, String) -> Void = { _, _ in }
    var onRetimeNote: (SessionMoment, Int) -> Void = { _, _ in }
    var onRemove: (SessionMoment) -> Void = { _ in }
    var onUndoRemove: () -> Void = {}
    var onReveal: (SessionMoment) -> Void = { _ in }
    var onExportAll: () -> Void = {}

    @State private var editingID: String?
    @State private var editText = ""
    @State private var undoShown = false
    @FocusState private var focusedRow: String?
    @FocusState private var editFocused: Bool

    private var hasClips: Bool { moments.contains { $0.kind == .clip } }

    var body: some View {
        VStack(spacing: 0) {
            if moments.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(SessionDetailRules.ordered(moments)) { moment in
                            row(moment)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
            if undoShown { undoRow }
            if hasClips { exportRow }
            Divider().padding(.top, 4)
            SessionNoteComposer(enabled: canAddNotes,
                                placeholder: canAddNotes ? "Add a note here" : disabledReason,
                                notePosition: notePosition,
                                onAdd: onAddNote)
        }
    }

    // MARK: Pieces

    private var empty: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No notes yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Type one below. It lands wherever the picture is.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var undoRow: some View {
        HStack(spacing: 8) {
            Text("Note deleted").font(.caption).foregroundStyle(.secondary)
            Text("\u{00B7}").font(.caption).foregroundStyle(.tertiary)
            Button("Undo") {
                onUndoRemove()
                undoShown = false
            }
            .buttonStyle(.link)
            .font(.caption)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .task(id: undoShown) {
            guard undoShown else { return }
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { undoShown = false }
        }
    }

    private var currentNoteID: String? {
        SessionNoteEditRules.currentNoteID(
            moments.filter { $0.kind == .note }.map { (id: $0.id, at: $0.at) }, playhead: playhead)
    }

    private func beginEdit(_ moment: SessionMoment) {
        guard moment.kind == .note else { return }
        editText = moment.label
        editingID = moment.id
        DispatchQueue.main.async { editFocused = true }
    }

    private func commitEdit(_ moment: SessionMoment) {
        guard editingID == moment.id else { return }
        editingID = nil
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != moment.label { onEditNote(moment, trimmed) }
        focusedRow = moment.id
    }

    private func cancelEdit(_ moment: SessionMoment) {
        editingID = nil
        focusedRow = moment.id
    }

    private func delete(_ moment: SessionMoment) {
        onRemove(moment)
        if moment.kind == .note { undoShown = true }
    }

    private func row(_ moment: SessionMoment) -> some View {
        let isNote = moment.kind == .note
        let tinted = isNote && currentNoteID == moment.id
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(SessionDetailRules.clock(moment.at))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            Circle()
                .fill(moment.kind == .clip ? SessionMarkStyle.clip : SessionMarkStyle.note)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            if editingID == moment.id {
                TextField("Note", text: $editText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...4)
                    .focused($editFocused)
                    .onSubmit { commitEdit(moment) }
                    .onExitCommand { cancelEdit(moment) }
                    .onChange(of: editFocused) { _, now in
                        if !now { commitEdit(moment) }
                    }
            } else {
                Text(moment.label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if moment.exported {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.text)
                    .help("Cut to a file next to the recording.")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(tinted ? Brand.green.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginEdit(moment) }
        .onTapGesture {
            focusedRow = moment.id
            onSeek(moment)
        }
        .focusable(isNote && editingID != moment.id)
        .focused($focusedRow, equals: moment.id)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard isNote, editingID == nil else { return .ignored }
            beginEdit(moment)
            return .handled
        }
        .onKeyPress(.delete) {
            guard isNote, editingID == nil else { return .ignored }
            delete(moment)
            return .handled
        }
        .help(moment.kind == .clip ? "Play from the start of this clip" : "Play from this note. Double-click to edit.")
        .accessibilityLabel(isNote ? "Note at \(SessionDetailRules.clock(moment.at)): \(moment.label)" : "Clip at \(SessionDetailRules.clock(moment.at))")
        .contextMenu {
            if isNote {
                Button("Edit") { beginEdit(moment) }
                Button("Set to current time") { onRetimeNote(moment, Int(playhead * 1000)) }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(moment.label, forType: .string)
                }
                Divider()
            }
            if moment.kind == .clip, moment.exported {
                Button("Show exported file in Finder") { onReveal(moment) }
            }
            Button(moment.kind == .clip ? "Remove clip" : "Delete note", role: .destructive) { delete(moment) }
        }
    }

    private var exportRow: some View {
        HStack(spacing: 8) {
            if let exporting {
                ProgressView(value: Double(exporting.done), total: Double(max(1, exporting.total)))
                    .frame(maxWidth: 100)
                Text("\(exporting.done)/\(exporting.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Export all clips", action: onExportAll)
                .buttonStyle(.link)
                .font(.system(size: 12))
                .disabled(exporting != nil)
                .help("Cuts every marked clip into its own file, next to the recording.")
        }
        .padding(.top, 6)
    }
}

/// Adding a note while watching: stamped where the picture was when the first
/// character was typed, not when Return was pressed.
struct SessionNoteComposer: View {
    let enabled: Bool
    let placeholder: String
    let notePosition: () -> Int
    let onAdd: (String, Int) -> Void

    @State private var draft = ""
    @State private var draftAtMs: Int?
    @FocusState private var focused: Bool

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(SessionDetailRules.clock(Double(draftAtMs ?? notePosition()) / 1000))
                .font(.system(size: 12, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Brand.text))
                .frame(width: 44, alignment: .leading)
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...4)
                .focused($focused)
                .disabled(!enabled)
                .onChange(of: draft) { old, new in
                    let wasEmpty = old.trimmingCharacters(in: .whitespaces).isEmpty
                    let nowEmpty = new.trimmingCharacters(in: .whitespaces).isEmpty
                    if wasEmpty && !nowEmpty { draftAtMs = notePosition() } else if nowEmpty { draftAtMs = nil }
                }
                .onSubmit(commit)
            Button("Add", action: commit)
                .controlSize(.small)
                .disabled(isEmpty || !enabled)
        }
        .padding(.top, 10)
    }

    private func commit() {
        guard !isEmpty else { return }
        onAdd(draft, draftAtMs ?? notePosition())
        draft = ""
        draftAtMs = nil
        focused = true
    }
}
