//
//  ClosureButton.swift
//  Greenroom
//
//  An NSButton that runs a closure, and answers the FIRST click.
//
//  Used by every control in the non-activating panels (participants, Cues
//  cards). Those panels are rarely key, and a stock NSButton in a non-key
//  window discards its first press as "make me key" - so every button press
//  was silently eaten the first time. acceptsFirstMouse is the fix, and it
//  belongs on the class rather than being remembered at each call site.
//
import AppKit

final class ClosureButton: NSButton {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) {
        self.body = body
        super.init(frame: .zero)
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func fire() { body() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
