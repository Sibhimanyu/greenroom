//
//  MeetingControlPanel.swift
//  Greenroom
//
//  The meeting window's panel: non-activating, with the minimise, close and shrink keys answered here.
//
import AppKit

/// A non-activating panel, not a plain window. Clicking a control must not
/// pull Greenroom in front of whatever the teacher has on their main screen.
final class MeetingControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The yellow traffic light, the Window menu's Minimize, the title bar's
    /// double click and Command-M all arrive here (the standard button calls
    /// performMiniaturize, which calls miniaturize). NSWindowDelegate has no
    /// "should miniaturize", so the window itself decides: while a meeting is
    /// live it runs the shrink-to-control-bar morph instead of going to the Dock.
    /// The red light and Command-W. While a class is live the coordinator puts a
    /// sheet on this window instead (End / Leave, Shrink, Cancel); the close
    /// happens only when nothing is live, or by code.
    override func performClose(_ sender: Any?) {
        if !ParticipantGridWindowController.closingByCode,
           ParticipantGridWindowController.confirmClose?(self) == false { return }
        super.performClose(sender)
    }

    override func miniaturize(_ sender: Any?) {
        if ParticipantGridWindowController.shrinkInsteadOfMinimize?() == true { return }
        super.miniaturize(sender)
    }

    /// The customisable "Shrink meeting to control bar" key (Command-M by
    /// default), answered only while this window is key.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           let combo = ShortcutStore.shared.bindings.combo(for: .action(.shrinkToBar)),
           combo.keyCode == UInt32(event.keyCode),
           combo.modifiers == KeyCombo.carbonModifiers(cocoaFlags: event.modifierFlags.rawValue),
           ParticipantGridWindowController.shrinkInsteadOfMinimize?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
