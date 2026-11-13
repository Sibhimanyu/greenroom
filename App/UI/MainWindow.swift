//
//  MainWindow.swift
//
//  Finds the main window by the scene's identifier instead of by title, so a
//  page may set a navigation title without breaking window lookups. The scene
//  is `Window("Greenroom", id: "main")` in GreenroomApp.swift; SwiftUI sets the
//  NSWindow's identifier to that id (possibly with a suffix such as
//  "-AppWindow-1"), which `matches` accepts. Callers (ContentView.window,
//  CoordinatorController) switch over in chunk C10; nothing uses this yet.
//
import AppKit

enum MainWindow {
    static let sceneID = "main"

    static func matches(identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == sceneID || identifier.hasPrefix(sceneID + "-")
    }

    @MainActor
    static var current: NSWindow? {
        NSApp.windows.first { matches(identifier: $0.identifier?.rawValue) }
    }
}
