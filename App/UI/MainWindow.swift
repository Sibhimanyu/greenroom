//
//  MainWindow.swift
//
//  Finds the main window by the scene's identifier instead of by title, so a
//  page may set a navigation title without breaking window lookups. The scene
//  is `Window("Greenroom", id: "main")` in GreenroomApp.swift. Confirmed with a
//  probe program (a real SwiftUI Window scene, accessory-free .prohibited
//  activation policy): the NSWindow's identifier is exactly "main". A
//  "main-..." suffix (WindowGroup style) is also accepted. No title fallback,
//  so pages may set .navigationTitle freely.
//
import AppKit

enum MainWindow {
    static let sceneID = "main"

    static func matches(identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == sceneID || identifier.hasPrefix(sceneID + "-")
    }

    @MainActor
    static func matches(_ window: NSWindow) -> Bool {
        matches(identifier: window.identifier?.rawValue)
    }

    @MainActor
    static var current: NSWindow? {
        NSApp.windows.first { matches(identifier: $0.identifier?.rawValue) }
    }
}
