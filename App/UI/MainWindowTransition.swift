//
//  MainWindowTransition.swift
//  Greenroom
//
//  Home steps aside toward the Control bar when a start begins, and comes back
//  the same way if the start fails or is cancelled (StartChoreography.swift has
//  the geometry). 250ms ease-in-out, through the animator proxy like the page
//  change; instant under Reduce Motion and in full screen. The window is only
//  ordered out, never closed, so Home keeps whatever was typed in it.
//
import AppKit

@MainActor
enum MainWindowTransition {
    /// Bumped by every call: a finishing animation that finds a newer call has
    /// been made does nothing, so a quick cancel never leaves Home hidden.
    private static var generation = 0

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Home out, toward `bar`.
    static func hide(_ window: NSWindow, toward bar: CGRect?) {
        generation += 1
        let mine = generation
        let home = window.frame
        guard window.isVisible, !reduceMotion, !window.styleMask.contains(.fullScreen), let bar else {
            window.orderOut(nil)
            return
        }
        let exit = StartChoreography.homeExitFrame(home: home, bar: bar)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = StartChoreography.homeSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(exit, display: true)
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard generation == mine else { return }
                window.orderOut(nil)
                // Put back for the next showing; nobody sees it while hidden.
                window.alphaValue = 1
                window.setFrame(home, display: false)
            }
        })
    }

    /// Home back, from where the bar is, to `frame`.
    static func show(_ window: NSWindow, from bar: CGRect?, to frame: CGRect) {
        generation += 1
        guard !reduceMotion, !window.styleMask.contains(.fullScreen) else {
            window.alphaValue = 1
            window.setFrame(frame, display: true)
            window.orderFront(nil)
            return
        }
        if !window.isVisible {
            window.alphaValue = 0
            window.setFrame(bar.map { StartChoreography.homeExitFrame(home: frame, bar: $0) } ?? frame, display: false)
            // orderFront, not activate: a full-screen app keeps the focus.
            window.orderFront(nil)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = StartChoreography.homeSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
            window.animator().alphaValue = 1
        }
    }
}
