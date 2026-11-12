//
//  ShortcutStore.swift
//  Greenroom
//
//  The one place the app asks "what key does this action have?". Settings edits
//  it, the menu bar reads it, and ShortcutRuntime registers from it, so the three
//  cannot disagree.
//
//  Holds no Carbon and no coordinator, so the Shortcuts page can be drawn off
//  screen with whatever state a picture needs (a row recording, a conflict).
//
import Foundation
import Combine

/// An inline message under a row, with the move that resolves it if there is one.
struct ShortcutNotice: Equatable {
    enum Kind: Equatable {
        /// macOS or every app owns the combination.
        case reserved
        /// Greenroom already uses it for `other`; `combo` waits for "Use here instead".
        case conflict(other: ShortcutSlot, combo: KeyCombo)
        /// The recorder wants a modifier.
        case hint
    }
    var kind: Kind
    var text: String
}

@MainActor
final class ShortcutStore: ObservableObject {

    static let shared = ShortcutStore(defaults: .standard)
    static let defaultsKey = "shortcuts.bindings"

    @Published private(set) var bindings: ShortcutBindings {
        didSet {
            guard bindings != oldValue else { return }
            save()
        }
    }

    /// The row whose recorder is listening. While it is non-nil the global
    /// hotkeys are released (ShortcutRuntime), so pressing the current combo
    /// records it instead of running it.
    @Published var recordingSlot: ShortcutSlot?

    /// Combinations another app owns, so registration failed: shown on the row.
    @Published private(set) var unavailable: Set<String> = []

    /// At most one inline message per row.
    @Published var notices: [String: ShortcutNotice] = [:]

    private let defaults: UserDefaults?

    /// `defaults` nil keeps everything in memory (the off-screen render, tests).
    init(bindings: ShortcutBindings? = nil, defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let bindings {
            self.bindings = bindings
        } else if let defaults, let data = defaults.data(forKey: Self.defaultsKey),
                  let stored = ShortcutBindings.from(jsonData: data) {
            self.bindings = stored
        } else {
            self.bindings = ShortcutBindings()
        }
    }

    private func save() {
        guard let defaults else { return }
        if bindings.entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = bindings.jsonData() {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: Reading

    /// The combination written for a hint beside a button, or "" when unbound.
    static func glyphs(_ action: ShortcutAction) -> String { shared.combo(for: action)?.glyphs ?? "" }

    /// The combination written into a sentence ("... shows it"), or a stand-in
    /// when the action has no shortcut.
    static func phrase(_ action: ShortcutAction) -> String {
        shared.combo(for: action)?.glyphs ?? "its shortcut"
    }

    func combo(for slot: ShortcutSlot) -> KeyCombo? { bindings.combo(for: slot) }
    func combo(for action: ShortcutAction) -> KeyCombo? { bindings.combo(for: .action(action)) }

    // MARK: Editing

    /// Binds `combo` to `slot`. When another row already has it, nothing is
    /// bound yet: a conflict notice with the move to confirm. Returns whether it
    /// was bound.
    @discardableResult
    func assign(_ combo: KeyCombo, to slot: ShortcutSlot, among slots: [ShortcutSlot],
                titleOf: (ShortcutSlot) -> String) -> Bool {
        if let other = bindings.conflict(for: combo, besides: slot, among: slots) {
            notices[slot.id] = ShortcutNotice(
                kind: .conflict(other: other, combo: combo),
                text: "\(combo.glyphs) is already used by \u{201C}\(titleOf(other))\u{201D}.")
            return false
        }
        notices[slot.id] = nil
        bindings.set(combo, for: slot)
        return true
    }

    /// "Use here instead": the other row gives it up.
    func move(_ combo: KeyCombo, to slot: ShortcutSlot, from other: ShortcutSlot) {
        var next = bindings
        next.clear(other)
        next.set(combo, for: slot)
        bindings = next
        notices[slot.id] = nil
        notices[other.id] = nil
    }

    func clear(_ slot: ShortcutSlot) {
        notices[slot.id] = nil
        bindings.clear(slot)
    }

    func reset(_ slot: ShortcutSlot) {
        notices[slot.id] = nil
        bindings.reset(slot)
    }

    func resetAll() {
        notices = [:]
        var next = bindings
        next.resetAll()
        bindings = next
    }

    /// A settings import, or anything else that hands over a whole set.
    func replace(with new: ShortcutBindings) {
        notices = [:]
        bindings = new
    }

    /// The layout library changed: a deleted layout's binding goes with it.
    func prune(keepingTemplates ids: Set<UUID>) {
        let pruned = bindings.pruned(keepingTemplates: ids)
        if pruned != bindings { bindings = pruned }
    }

    func setUnavailable(_ ids: Set<String>) {
        if ids != unavailable { unavailable = ids }
    }
}
