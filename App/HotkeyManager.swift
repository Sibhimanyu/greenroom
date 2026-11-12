//
//  HotkeyManager.swift
//  Greenroom
//
//  System-wide keyboard shortcuts via Carbon's RegisterEventHotKey - the
//  one macOS API that works WITHOUT Accessibility or Input Monitoring
//  permission. That matters because these shortcuts exist precisely for
//  when Greenroom is NOT the active app: mid-class, working in the main
//  app, wanting to start a recording or snap dragged windows back
//  without hunting for Greenroom first.
//
//  The system swallows registered hotkey presses entirely (they never
//  reach the focused app as keystrokes), so the same combos can also be
//  shown on Greenroom's menu items purely as documentation without
//  double-firing.
//
import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {

    static let shared = HotkeyManager()

    struct Hotkey {
        /// Whatever the caller uses to tell its shortcuts apart (the slot id).
        let id: String
        let keyCode: UInt32
        /// Carbon modifier mask (cmdKey | optionKey | controlKey | shiftKey).
        let modifiers: UInt32
        let action: () -> Void
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Registers all hotkeys at once, and again whenever the set changes (see
    /// `replaceAll`).
    ///
    /// Returns the ids of any that could not be claimed. RegisterEventHotKey
    /// fails when another running application already owns the combination, and
    /// its status used to be discarded - so a shortcut that had been taken simply
    /// did nothing, forever, with nothing anywhere explaining why. That was
    /// tolerable while these used three modifiers and collisions were unlikely;
    /// it is not tolerable now they use two.
    @discardableResult
    private func register(_ hotkeys: [Hotkey]) -> [String] {
        installHandlerIfNeeded()
        var unavailable: [String] = []
        for hotkey in hotkeys {
            let id = nextID
            nextID += 1

            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x4752_4B59) /* 'GRKY' */, id: id)
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, ref != nil else {
                unavailable.append(hotkey.id)
                continue
            }
            // Only recorded once the registration actually succeeded, so a
            // failed key cannot leave an orphaned action behind.
            actions[id] = hotkey.action
            hotKeyRefs.append(ref)
        }
        return unavailable
    }

    /// Releases everything registered, then registers `hotkeys`. This is how a
    /// change in Settings takes effect without a relaunch. Returns the ids that
    /// could not be claimed.
    @discardableResult
    func replaceAll(_ hotkeys: [Hotkey]) -> [String] {
        unregisterAll()
        return register(hotkeys)
    }

    /// Releases every hotkey. While a shortcut recorder is listening, so the
    /// combination being recorded reaches it instead of running its action.
    func unregisterAll() {
        for ref in hotKeyRefs { if let ref { UnregisterEventHotKey(ref) } }
        hotKeyRefs.removeAll()
        actions.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // Carbon delivers hotkey events on the main run loop, so hopping
        // back into the MainActor-isolated manager below is safe.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                manager.actions[hotKeyID.id]?()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }
}
