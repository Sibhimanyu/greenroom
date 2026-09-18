//
//  MarksSpeakerView.swift
//  Greenroom
//
//  The notes, shown to the person being evaluated, while it is happening.
//
//  This answers the plan's open question - "does the speaker see notes live,
//  or only after? Live makes it coaching; after makes it evaluation" - and it
//  answers it by making it a decision the teacher takes per presentation
//  rather than one the app takes for everybody.
//
//  **It is off unless it is asked for, every time.** Not a stored preference:
//  a setting that persists would mean a teacher who once coached a rehearsal
//  is silently still coaching in an exam three weeks later, and the student
//  would be the one to find out. Marks opens as an evaluation tool on every
//  launch, and coaching is a thing you deliberately turn on for the next
//  twenty minutes.
//
//  Its whole design is "readable from across a room, and impossible to
//  mistake for the teacher's own window": one column, large type, newest at
//  the bottom, no controls at all. The teacher puts it on the second display
//  or hands over an iPad mirroring it.
//
import SwiftUI

struct MarksSpeakerView: View {
    @ObservedObject private var marks = MarksController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if marks.notes.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .tint(Brand.green)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if marks.recorder.isRecording {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            }
            Text(marks.presenter.isEmpty ? "Your presentation" : marks.presenter)
                .font(.title3.weight(.semibold))
            Spacer()
            Text(marks.elapsedLabel)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(marks.canTakeNotes ? "Nothing yet." : "Not started.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(marks.canTakeNotes
                 ? "Notes will appear here as they are written."
                 : "This window shows the notes as they are written.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(marks.notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.offsetLabel)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Brand.green)
                            Text(note.text)
                                .font(.title3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id(note.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(24)
            }
            .onChange(of: marks.notes.count) { _, _ in
                guard let last = marks.notes.last else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}
