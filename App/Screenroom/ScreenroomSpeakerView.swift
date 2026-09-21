//
//  ScreenroomSpeakerView.swift
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
//  would be the one to find out. Screenroom opens as an evaluation tool on every
//  launch, and coaching is a thing you deliberately turn on for the next
//  twenty minutes.
//
//  Its whole design is "readable from across a room, and impossible to
//  mistake for the teacher's own window": one column, large type, newest at
//  the bottom, no controls at all. The teacher puts it on the second display
//  or hands over an iPad mirroring it.
//
import AppKit
import SwiftUI

struct ScreenroomSpeakerView: View {
    @ObservedObject private var screenroom = ScreenroomController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if screenroom.notes.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .tint(Brand.green)
        // Closing this window is the other way of saying "stop showing the
        // speaker my notes", and the eye in the Screenroom header has to
        // agree. Without this it stayed open-eyed over a window that was no
        // longer there, and the next click turned coaching OFF when the
        // teacher meant to turn it on.
        .background(WindowCloseWatcher {
            ScreenroomController.shared.speakerIsWatching = false
        })
    }

    private var header: some View {
        HStack(spacing: 10) {
            if screenroom.recorder.isRecording {
                Image(systemName: "record.circle.fill").foregroundStyle(.red)
            }
            Text(screenroom.presenter.isEmpty ? "Your presentation" : screenroom.presenter)
                .font(.title3.weight(.semibold))
            Spacer()
            Text(screenroom.elapsedLabel)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(screenroom.canTakeNotes ? "Nothing yet." : "Not started.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(screenroom.canTakeNotes
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
                    ForEach(screenroom.notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.offsetLabel)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(Brand.text)
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
            .onChange(of: screenroom.notes.count) { _, _ in
                guard let last = screenroom.notes.last else { return }
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

/// Calls back when the window this view is in closes.
///
/// AppKit's own notification rather than SwiftUI's `onDisappear`, because the
/// two do not mean the same thing. `onDisappear` fires when a view leaves the
/// hierarchy, which for a window scene depends on how SwiftUI decides to keep
/// it around; `NSWindow.willCloseNotification` fires when the window closes,
/// which is the actual event being described. Observed on the window
/// instance, so it needs no window identifier and cannot be confused by
/// another window closing.
private struct WindowCloseWatcher: NSViewRepresentable {

    let onClose: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Deferred: a view has no window until it has been added to one, and
        // makeNSView runs before that.
        DispatchQueue.main.async {
            context.coordinator.watch(view.window, onClose: onClose)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // A second chance, for the case where the first hop still found no
        // window - a window scene opening for the first time.
        DispatchQueue.main.async {
            context.coordinator.watch(view.window, onClose: onClose)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var token: NSObjectProtocol?

        func watch(_ window: NSWindow?, onClose: @escaping @MainActor () -> Void) {
            guard token == nil, let window else { return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { onClose() }
                }
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }
    }
}
