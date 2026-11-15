//
//  PresentMenuSpec.swift
//  Greenroom
//
//  The Present menu as data: what the class sees (the whole screen, one app,
//  one window, the whiteboard, just the camera), how you look over it, and the
//  window layout. The same list opens from the floating control bar's Share
//  cell, the meeting window's Share button and the menu bar, so a person in a
//  live class can change any of it without going back to Home.
//
//  Plain values in, `[MenuEntry]` out, so a test can check every tick and every
//  greyed line. The live wiring (coordinator in, coordinator out) is in
//  PresentMenuLive.swift.
//
import Foundation

enum PresentMenu {

    /// Mirrors `ShareTarget.Kind`: the raw values are the same, so the live
    /// wiring converts by raw value.
    enum Kind: String, Equatable {
        case display, app, window, whiteboard, nothing
    }

    struct Choice: Equatable {
        var id: String
        var title: String
    }

    struct WindowChoice: Equatable {
        var bundleID: String
        var appName: String
        var title: String
        /// "App \u{2013} Title", with where it is (full screen elsewhere) after it.
        var label: String
    }

    struct State: Equatable {
        var kind: Kind = .display
        /// "" is Automatic: the main display.
        var displayID = ""
        var displays: [Choice] = []
        var apps: [Choice] = []
        var appBundleID = ""
        var windows: [WindowChoice] = []
        var windowBundleID = ""
        var windowTitle = ""
        var cameraOff = false
        var shapes: [Choice] = []
        var shapeID = ""
        var layouts: [Choice] = []
        var liveLayoutID: String?
        /// A live layout exists and the layout tools apply to this class.
        var layoutsAvailable = false
    }

    struct Actions {
        var pickKind: (Kind) -> Void = { _ in }
        var pickDisplay: (String) -> Void = { _ in }
        var pickApp: (Choice) -> Void = { _ in }
        var pickWindow: (WindowChoice) -> Void = { _ in }
        var pickShape: (String) -> Void = { _ in }
        var pickLayout: (String) -> Void = { _ in }
    }

    static let cameraOffNote = "No camera is picked, so there is no look to choose."

    static func entries(_ s: State, _ a: Actions) -> [MenuEntry] {
        var out: [MenuEntry] = [.header("What the class sees")]

        // Whole screen: a submenu of displays only when there is a choice to make.
        let onScreen = s.kind == .display
        if s.displays.count > 1 {
            var kids: [MenuEntry] = [
                .item("Automatic (main display)", checked: onScreen && s.displayID.isEmpty) { a.pickDisplay("") },
            ]
            kids += s.displays.map { d in
                .item(d.title, checked: onScreen && s.displayID == d.id) { a.pickDisplay(d.id) }
            }
            out.append(.submenu("Whole screen", checked: onScreen, kids))
        } else {
            out.append(.item("Whole screen", checked: onScreen) { a.pickKind(.display) })
        }

        // One app.
        let apps: [MenuEntry] = s.apps.isEmpty
            ? [.item("No other app is open", enabled: false) {}]
            : s.apps.map { app in
                .item(app.title, checked: s.kind == .app && s.appBundleID == app.id) { a.pickApp(app) }
            }
        out.append(.submenu("One app", checked: s.kind == .app, apps))

        // One window.
        let windows: [MenuEntry] = s.windows.isEmpty
            ? [.item("No window to share", enabled: false) {}]
            : s.windows.map { w in
                .item(w.label, checked: s.kind == .window && s.windowBundleID == w.bundleID
                        && s.windowTitle == w.title) { a.pickWindow(w) }
            }
        out.append(.submenu("One window", checked: s.kind == .window, windows))

        out.append(.item("Whiteboard", checked: s.kind == .whiteboard) { a.pickKind(.whiteboard) })
        out.append(.item("Just my camera", checked: s.kind == .nothing, enabled: !s.cameraOff,
                         note: s.cameraOff ? cameraOffNote : nil) { a.pickKind(.nothing) })

        // Look.
        out.append(.separator)
        out.append(.submenu("Look", enabled: !s.cameraOff, note: s.cameraOff ? cameraOffNote : nil,
                            s.shapes.map { shape in
            .item(shape.title, checked: s.shapeID == shape.id) { a.pickShape(shape.id) }
        }))

        // Layout: only where it can apply.
        if s.layoutsAvailable, s.liveLayoutID != nil, !s.layouts.isEmpty {
            out.append(.submenu("Layout", s.layouts.map { t in
                .item(t.title, checked: t.id == s.liveLayoutID) { a.pickLayout(t.id) }
            }))
        }
        return out
    }
}
