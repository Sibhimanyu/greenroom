//
//  ShortcutsSettingsTab.swift
//  Greenroom
//
//  Settings -> Shortcuts: which keys do what. A grouped list, one row per
//  action (icon, name, a line saying what it does, and a recorder on the right).
//  The rows are the same family as the Sessions list: roomy, 14pt cards,
//  12pt secondary section labels.
//
//  `ShortcutsPageContent` takes the store and plain values, so it can be drawn
//  off screen with any state (a row recording, a conflict). `ShortcutsSettingsTab`
//  is the glue to the coordinator.
//
import AppKit
import SwiftUI

// MARK: - The tab

struct ShortcutsSettingsTab: View {
    @EnvironmentObject private var coordinator: CoordinatorController
    @ObservedObject private var store = ShortcutStore.shared

    var body: some View {
        ShortcutsPageContent(
            store: store,
            layouts: coordinator.layoutLibrary.templates.map { ShortcutLayoutRef(id: $0.id, name: $0.name) })
    }
}

// MARK: - The page

struct ShortcutsPageContent: View {
    @ObservedObject var store: ShortcutStore
    let layouts: [ShortcutLayoutRef]
    @State private var confirmingRestore = false

    private var allSlots: [ShortcutSlot] { ShortcutCatalog.slots(layouts: layouts) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                intro
                ForEach(ShortcutCatalog.grouped(layouts: layouts), id: \.group) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.group.title.uppercased())
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .accessibilityAddTraits(.isHeader)
                        VStack(spacing: 0) {
                            ForEach(Array(section.slots.enumerated()), id: \.element) { index, slot in
                                if index > 0 { Divider().padding(.leading, 62) }
                                ShortcutRow(slot: slot, store: store, layouts: layouts, allSlots: allSlots)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
                    }
                }
                footer
            }
            .padding(24)
        }
        .alert("Restore the default shortcuts?", isPresented: $confirmingRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Restore Defaults", role: .destructive) { store.resetAll() }
        } message: {
            Text("Every shortcut goes back to how Greenroom shipped. Layout shortcuts go back to None.")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("These work from any app, so you can run the class without leaving your slides.")
                .font(.callout)
            Text("Click a shortcut, then press the keys. Esc cancels and Delete clears it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
    }

    private var footer: some View {
        HStack {
            Button("Restore Defaults\u{2026}") { confirmingRestore = true }
                .disabled(store.bindings.entries.isEmpty)
            Spacer()
        }
        .padding(.horizontal, 10)
    }
}

// MARK: - A row

private struct ShortcutRow: View {
    let slot: ShortcutSlot
    @ObservedObject var store: ShortcutStore
    let layouts: [ShortcutLayoutRef]
    let allSlots: [ShortcutSlot]

    private var title: String { slot.title(layouts: layouts) }
    private var combo: KeyCombo? { store.combo(for: slot) }
    private var notice: RowNotice? { RowNotice.of(slot, store: store, layouts: layouts, allSlots: allSlots) }
    private var differsFromDefault: Bool { store.bindings.isCustomised(slot) }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: slot.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Brand.text)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Brand.green.opacity(0.12)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(slot.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let notice { noticeLine(notice) }
            }

            Spacer(minLength: 12)

            if differsFromDefault, store.recordingSlot != slot {
                Button("Reset") { store.reset(slot) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(Brand.text)
                    .accessibilityLabel("Reset \(title) to its default shortcut")
            }
            ShortcutRecorderField(slot: slot, title: title, store: store, allSlots: allSlots,
                                  titleOf: { $0.title(layouts: layouts) },
                                  pending: notice?.pendingCombo, warns: notice != nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    @ViewBuilder
    private func noticeLine(_ notice: RowNotice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Brand.net)
                .accessibilityHidden(true)
            Text(notice.text)
                .font(.caption)
                .foregroundStyle(Brand.netText)
                .fixedSize(horizontal: false, vertical: true)
            if let c = notice.conflict {
                Button("Use here instead") { store.move(c.combo, to: slot, from: c.other) }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.text)
                Button("Cancel") { store.notices[slot.id] = nil }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if notice.dismissible {
                Button("Dismiss") { store.notices[slot.id] = nil }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }
}

/// What a row says under its description, in priority order: something the
/// recorder just refused, then another app owning the key, then two rows that
/// share one.
private struct RowNotice {
    var text: String
    var conflict: (other: ShortcutSlot, combo: KeyCombo)?
    var dismissible = false

    var pendingCombo: KeyCombo? { conflict?.combo }

    @MainActor
    static func of(_ slot: ShortcutSlot, store: ShortcutStore, layouts: [ShortcutLayoutRef],
                   allSlots: [ShortcutSlot]) -> RowNotice? {
        if let n = store.notices[slot.id] {
            switch n.kind {
            case .conflict(let other, let combo): return RowNotice(text: n.text, conflict: (other, combo))
            case .reserved, .hint: return RowNotice(text: n.text, dismissible: true)
            }
        }
        if store.unavailable.contains(slot.id) {
            return RowNotice(text: "Another app is using this. Pick a different shortcut.")
        }
        // Saved duplicates (an import, say): the first row in the list keeps the key.
        if let combo = store.combo(for: slot),
           let first = allSlots.first(where: { store.combo(for: $0) == combo }), first != slot {
            return RowNotice(text: "Already used by \u{201C}\(first.title(layouts: layouts))\u{201D}, so only that one works.")
        }
        return nil
    }
}

// MARK: - The recorder

/// A capsule showing the combination in menu glyphs. Click (or Space/Return with
/// keyboard focus) to listen; the next key press with Command, Control or Option
/// sets it. While it listens the global hotkeys are released, so pressing the
/// current combination records it instead of running it.
struct ShortcutRecorderField: View {
    let slot: ShortcutSlot
    let title: String
    @ObservedObject var store: ShortcutStore
    let allSlots: [ShortcutSlot]
    let titleOf: (ShortcutSlot) -> String
    /// A combination waiting on "Use here instead", shown in the capsule.
    var pending: KeyCombo?
    var warns = false

    @State private var monitor: Any?
    @State private var resignObserver: NSObjectProtocol?

    private var recording: Bool { store.recordingSlot == slot }
    private var shown: KeyCombo? { pending ?? store.combo(for: slot) }

    var body: some View {
        Button(action: toggle) {
            label
                .padding(.horizontal, 12)
                .frame(minWidth: 132, minHeight: 28)
                .background(Capsule().fill(recording ? Brand.green.opacity(0.12) : Color.secondary.opacity(0.10)))
                .overlay(Capsule().strokeBorder(stroke, lineWidth: recording ? 2 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording
            ? "\(title). Recording a new shortcut. Press the keys, Escape to cancel, Delete to clear."
            : "\(title), shortcut \(shown?.spokenName ?? "none")")
        .accessibilityHint(recording ? "" : "Press to record a new shortcut")
        .onAppear { if recording { startListening() } }
        .onDisappear {
            stopListening()
            if recording { store.recordingSlot = nil }
        }
        .onChange(of: recording) { _, now in now ? startListening() : stopListening() }
    }

    @ViewBuilder
    private var label: some View {
        if recording {
            Text("Type shortcut\u{2026}")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Brand.text)
        } else if let shown {
            Text(shown.glyphs)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(pending == nil ? Color.primary : Brand.netText)
        } else {
            Text("None")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var stroke: Color {
        if recording { return Brand.green }
        if warns { return Brand.net }
        return Color.secondary.opacity(0.28)
    }

    private func toggle() {
        store.notices[slot.id] = nil
        store.recordingSlot = recording ? nil : slot
    }

    // MARK: Listening

    private func startListening() {
        guard monitor == nil else { return }
        // A local monitor sees the key before AppKit's own shortcuts do, so
        // recording Command-W does not close the Settings window.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return nil }
            handle(keyCode: UInt32(event.keyCode),
                   modifiers: KeyCombo.carbonModifiers(cocoaFlags: event.modifierFlags.rawValue))
            return nil
        }
        // Leaving the window (or the app) ends recording rather than leaving the
        // global hotkeys off.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if store.recordingSlot == slot { store.recordingSlot = nil } }
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    private func handle(keyCode: UInt32, modifiers: UInt32) {
        MainActor.assumeIsolated {
            switch ShortcutCapture.interpret(keyCode: keyCode, carbonModifiers: modifiers) {
            case .cancel:
                store.recordingSlot = nil
            case .clear:
                store.clear(slot)
                store.recordingSlot = nil
            case .reject(let why):
                let kind: ShortcutNotice.Kind = why.hasPrefix("Hold") ? .hint : .reserved
                store.notices[slot.id] = ShortcutNotice(kind: kind, text: why)
            case .accept(let combo):
                // A conflict is held on the row for "Use here instead"; either
                // way this recording is over.
                store.assign(combo, to: slot, among: allSlots, titleOf: titleOf)
                store.recordingSlot = nil
            }
        }
    }
}
