//
//  SessionMoments.swift
//
//  The watch page's Moments tab: clips and notes in ONE list, in the order
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
    /// Where a note typed right now would land, in milliseconds.
    var notePosition: () -> Int = { 0 }
    var onSeek: (SessionMoment) -> Void = { _ in }
    var onAddNote: (String, Int) -> Void = { _, _ in }
    var onRemove: (SessionMoment) -> Void = { _ in }
    var onReveal: (SessionMoment) -> Void = { _ in }
    var onExportAll: () -> Void = {}

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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Nothing marked in this class.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .help("Use the clip shortcuts (Settings \u{2192} Shortcuts) during a class to mark the last 1, 2 or 5 minutes. Marks appear here afterwards. Notes you add below land wherever the picture is.")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ moment: SessionMoment) -> some View {
        Button { onSeek(moment) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(SessionDetailRules.clock(moment.at))
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Circle()
                    .fill(moment.kind == .clip ? SessionMarkStyle.clip : SessionMarkStyle.note)
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(moment.label)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if moment.exported {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.text)
                        .help("Cut to a file next to the recording.")
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(moment.kind == .clip ? "Play from the start of this clip" : "Play from just before this note")
        .contextMenu {
            if moment.kind == .clip, moment.exported {
                Button("Show exported file in Finder") { onReveal(moment) }
            }
            Button(moment.kind == .clip ? "Remove clip" : "Delete note", role: .destructive) { onRemove(moment) }
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
