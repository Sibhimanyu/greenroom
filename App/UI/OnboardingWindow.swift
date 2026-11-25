//
//  OnboardingWindow.swift
//  Greenroom
//
//  The setup guide, in a window of its own. It was a sheet on the main window,
//  and the main window is short and wide (about 1140x380) while the guide is
//  taller than it, so macOS shoved the main window up and let the sheet hang
//  down to the Dock (owner, 2026-11-17). Here the guide sits in the middle of
//  the main window, clamped to the screen, and the main window never moves.
//  `coordinator.showOnboarding` stays the one switch: ContentView calls
//  `sync`, and closing the window (the red button, Close setup, Esc) flips it
//  back off.
//
import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private weak var coordinator: CoordinatorController?

    /// Open or close the guide to match `show`. `atLaunch` is the first sync
    /// of a ContentView: the main window is still settling then, so the guide
    /// centres on the screen instead of on it.
    func sync(show: Bool, coordinator: CoordinatorController, atLaunch: Bool) {
        self.coordinator = coordinator
        guard show else {
            if let window {
                self.window = nil
                window.delegate = nil
                window.close()
            }
            return
        }
        if let window {
            window.makeKeyAndOrderFront(nil) // one at a time: reopening brings it forward
            return
        }
        let host = NSHostingView(rootView: OnboardingView().environmentObject(coordinator).tint(Brand.green))
        let size = NSSize(width: 680, height: 700)
        let made = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        made.contentView = host
        made.title = "Set up Greenroom"
        made.titleVisibility = .hidden // the guide's own header carries the name
        made.isReleasedWhenClosed = false
        made.delegate = self
        // Visible to other apps' captures like any Greenroom window (decision 2026-11-25): its
        // secret fields are SecureFields, dotted. Our own capture excludes it through the app-wide filter.
        let main = MainWindow.current
        let anchor = (!atLaunch && main?.isVisible == true) ? main?.frame : nil
        let screen = (anchor == nil ? NSScreen.main : main?.screen) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            made.setFrame(OnboardingPlacement.frame(size: made.frame.size, anchor: anchor, visible: visible), display: false)
        } else {
            made.center()
        }
        WindowFrost.install(in: made, solid: .windowBackgroundColor)
        window = made
        made.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing == window else { return }
        window = nil
        // The red button is Close setup.
        if coordinator?.showOnboarding == true { coordinator?.completeOnboarding() }
    }
}
